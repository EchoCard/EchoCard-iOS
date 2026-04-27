//
//  AIChatHistoryService.swift
//  CallMate
//
//  SwiftData persistence for AI chat threads (replaces monolithic UserDefaults JSON blobs).
//

import Foundation
import SwiftData

enum AIChatHistoryService {

    /// First paint: load only the tail of the thread (see docs/ios-ai-secretary-chat-history-loading.md).
    static let initialWindowLoadCount = 30
    static let olderPageSize = 40

    // MARK: - Load (windowed)

    /// Loads the **recent** `limit` messages for UI; migrates legacy UserDefaults when the thread is empty in SwiftData.
    static func loadInitialWindow(threadKey: String, context: ModelContext) throws -> [ExtendedMessage]? {
        let totalBefore = try threadRowCount(threadKey: threadKey, context: context)
        let recent = try fetchRecent(threadKey: threadKey, limit: initialWindowLoadCount, context: context)
        if !recent.isEmpty {
            logPartialWindow(phase: "swiftdata_hit", threadKey: threadKey, window: recent, totalRows: totalBefore)
            return recent
        }
        if try migrateLegacyUserDefaultsIfNeeded(threadKey: threadKey, context: context) != nil {
            let totalAfter = try threadRowCount(threadKey: threadKey, context: context)
            let window = try fetchRecent(threadKey: threadKey, limit: initialWindowLoadCount, context: context)
            if window.isEmpty {
                print("[AIChatHistory] loadInitialWindow warn threadKey=\(threadKey) postMigrationFetchEmpty totalRows=\(totalAfter)")
            } else {
                logPartialWindow(phase: "post_migration_window", threadKey: threadKey, window: window, totalRows: totalAfter)
            }
            return window.isEmpty ? nil : window
        }
        if totalBefore == 0 {
            print("[AIChatHistory] loadInitialWindow empty threadKey=\(threadKey) swiftDataRows=0 noLegacyUD")
        }
        return nil
    }

    /// Messages with `sortIndex` strictly **older** than `cursorSortIndex` (oldest currently loaded).
    static func fetchOlder(threadKey: String, cursorSortIndex: Int, pageSize: Int, context: ModelContext) throws -> [ExtendedMessage] {
        let tk = threadKey
        let cursor = cursorSortIndex
        let descriptor = FetchDescriptor<AIChatMessage>(
            predicate: #Predicate<AIChatMessage> { row in
                row.threadKey == tk && row.sortIndex < cursor
            },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        var desc = descriptor
        desc.fetchLimit = pageSize
        let rows = try context.fetch(desc)
        let mapped = rows.reversed().compactMap { Self.mapRowToMessage($0) }
        let rMin = mapped.first?.storageSortIndex
        let rMax = mapped.last?.storageSortIndex
        print(
            "[AIChatHistory] fetch_older threadKey=\(threadKey) cursor<\(cursor) pageSize=\(pageSize) returned=\(mapped.count) sortIndexRange=[\(rMin.map(String.init) ?? "?")..\(rMax.map(String.init) ?? "?")]"
        )
        return mapped
    }

    static func fetchRecent(threadKey: String, limit: Int, context: ModelContext) throws -> [ExtendedMessage] {
        let descriptor = FetchDescriptor<AIChatMessage>(
            predicate: #Predicate { $0.threadKey == threadKey },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        var desc = descriptor
        desc.fetchLimit = limit
        let rows = try context.fetch(desc)
        return rows.reversed().compactMap { Self.mapRowToMessage($0) }
    }

    /// Last `limit` **text** messages in chronological order (for `sessionInitMessages` / reconnect).
    static func recentTextInitPayload(threadKey: String, limit: Int, context: ModelContext) throws -> [[String: String]]? {
        let descriptor = FetchDescriptor<AIChatMessage>(
            predicate: #Predicate { $0.threadKey == threadKey },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        var desc = descriptor
        desc.fetchLimit = 500
        let rows = try context.fetch(desc)
        var collected: [[String: String]] = []
        for row in rows {
            guard row.msgTypeRaw == ExtendedMessageType.text.rawValue else { continue }
            let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let role: String
            switch row.senderRaw {
            case ChatSender.user.rawValue: role = "user"
            case ChatSender.ai.rawValue: role = "assistant"
            default: continue
            }
            collected.append(["role": role, "content": trimmed])
            if collected.count == limit { break }
        }
        guard !collected.isEmpty else { return nil }
        return collected.reversed()
    }

    // MARK: - Save (upsert only; never delete unseen rows)

    /// Upserts rows for the in-memory `messages` slice. Assigns `storageSortIndex` for new rows without an index.
    static func upsertMessages(threadKey: String, messages: inout [ExtendedMessage], context: ModelContext) throws {
        let dbMax = try maxSortIndex(threadKey: threadKey, context: context) ?? -1
        let memMax = messages.compactMap(\.storageSortIndex).max() ?? -1
        var next = max(dbMax, memMax)

        for i in messages.indices {
            if messages[i].storageSortIndex == nil {
                next += 1
                messages[i].storageSortIndex = next
            }
            guard let si = messages[i].storageSortIndex else { continue }

            let tk = threadKey
            let sortIdx = si
            let predicate = #Predicate<AIChatMessage> { row in
                row.threadKey == tk && row.sortIndex == sortIdx
            }
            var descriptor = FetchDescriptor<AIChatMessage>(predicate: predicate)
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                existing.apply(from: messages[i])
            } else {
                context.insert(makeRow(threadKey: threadKey, sortIndex: si, message: messages[i]))
            }
        }
        try context.save()
    }

    // MARK: - Launch migration (threads that were never opened after upgrade)

    static func migrateAllLegacyThreadsIfNeeded(context: ModelContext) {
        var keys = staticLegacyKeys
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.hasPrefix("callmate.call_detail.feedback.") {
                keys.append(key)
            }
        }
        let unique = Set(keys)
        for key in unique {
            _ = try? migrateLegacyUserDefaultsIfNeeded(threadKey: key, context: context)
        }
        print("[AIChatHistory] launch_migrate_scan scannedThreadKeys=\(unique.count) (per-thread migration_ok lines indicate UD→SwiftData inserts)")
    }

    private static var staticLegacyKeys: [String] {
        [
            "callmate.ai_secretary.persisted_messages.v1",
            "callmate.ai_secretary.persisted_messages.v2",
            "callmate.outbound.ai_create.persisted_messages.v2"
        ]
    }

    private static func migrateLegacyUserDefaultsIfNeeded(threadKey: String, context: ModelContext) throws -> [ExtendedMessage]? {
        let existingDescriptor = FetchDescriptor<AIChatMessage>(
            predicate: #Predicate { $0.threadKey == threadKey }
        )
        let existingCount = try context.fetch(existingDescriptor).count
        if existingCount > 0 {
            print("[AIChatHistory] migration_skip threadKey=\(threadKey) reason=swiftdata_already_has_rows count=\(existingCount)")
            // Return nil so callers like `loadInitialWindow` do not treat this as a fresh UD migration.
            return nil
        }

        guard let data = UserDefaults.standard.data(forKey: threadKey),
              !data.isEmpty else {
            return nil
        }

        let payload = try JSONDecoder().decode([PersistedExtendedMessage].self, from: data)
        let messages = payload.compactMap { $0.toExtendedMessage() }
        guard !messages.isEmpty else {
            UserDefaults.standard.removeObject(forKey: threadKey)
            print("[AIChatHistory] migration_skip_empty_decode threadKey=\(threadKey) udRemoved=true")
            return nil
        }

        for (index, message) in messages.enumerated() {
            context.insert(makeRow(threadKey: threadKey, sortIndex: index, message: message))
        }
        try context.save()
        UserDefaults.standard.removeObject(forKey: threadKey)
        print(
            "[AIChatHistory] migration_ok threadKey=\(threadKey) legacyJsonBytes=\(data.count) insertedRows=\(messages.count) sortIndexRange=[0..\(messages.count - 1)] userDefaultsKeyRemoved=true"
        )
        return messages
    }

    // MARK: - Factory reset

    static func deleteAllThreads(context: ModelContext) throws {
        let descriptor = FetchDescriptor<AIChatMessage>()
        let all = try context.fetch(descriptor)
        for row in all {
            context.delete(row)
        }
        try context.save()
        for key in staticLegacyKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("callmate.call_detail.feedback.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Private helpers

    private static func threadRowCount(threadKey: String, context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<AIChatMessage>(
            predicate: #Predicate { $0.threadKey == threadKey }
        )
        return try context.fetch(descriptor).count
    }

    private static func logPartialWindow(phase: String, threadKey: String, window: [ExtendedMessage], totalRows: Int) {
        guard !window.isEmpty else {
            print("[AIChatHistory] partial_load phase=\(phase) threadKey=\(threadKey) windowCount=0 totalRowsInThread=\(totalRows) (empty window)")
            return
        }
        let loaded = window.count
        let minS = window.first?.storageSortIndex
        let maxS = window.last?.storageSortIndex
        let hasMore = window.first?.storageSortIndex.map { $0 > 0 } ?? false
        print(
            "[AIChatHistory] partial_load phase=\(phase) threadKey=\(threadKey) windowCount=\(loaded) totalRowsInThread=\(totalRows) sortIndexRange=[\(minS.map(String.init) ?? "?")..\(maxS.map(String.init) ?? "?")] hasMoreOlder=\(hasMore) windowLimit=\(initialWindowLoadCount)"
        )
    }

    private static func mapRowToMessage(_ row: AIChatMessage) -> ExtendedMessage? {
        guard var m = PersistedExtendedMessage(from: row).toExtendedMessage() else { return nil }
        m.storageSortIndex = row.sortIndex
        return m
    }

    private static func maxSortIndex(threadKey: String, context: ModelContext) throws -> Int? {
        var descriptor = FetchDescriptor<AIChatMessage>(
            predicate: #Predicate { $0.threadKey == threadKey },
            sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.sortIndex
    }
}

// MARK: - Row helpers

private func makeRow(threadKey: String, sortIndex: Int, message: ExtendedMessage) -> AIChatMessage {
    let dto = PersistedExtendedMessage(from: message)
    return AIChatMessage(
        threadKey: threadKey,
        sortIndex: sortIndex,
        legacyMessageId: message.id,
        senderRaw: dto.senderRaw,
        text: dto.text,
        isAudio: dto.isAudio,
        duration: dto.duration,
        msgTypeRaw: dto.msgTypeRaw,
        isConfirmed: dto.isConfirmed,
        proposalStatusRaw: dto.proposalStatusRaw,
        proposalCreatedAt: dto.proposalCreatedAt,
        proposalTitle: dto.proposalTitle,
        proposalBefore: dto.proposalBefore,
        proposalAfter: dto.proposalAfter,
        guideImageId: dto.guideImageId,
        guideImageCaption: dto.guideImageCaption,
        outboundPhone: dto.outboundPhone,
        outboundContactName: dto.outboundContactName,
        outboundGoal: dto.outboundGoal,
        outboundKeyPoints: dto.outboundKeyPoints,
        outboundTemplateName: dto.outboundTemplateName,
        outboundScheduledAt: dto.outboundScheduledAt,
        outboundTimeDescription: dto.outboundTimeDescription,
        proposalFailureMessage: dto.proposalFailureMessage
    )
}

private extension AIChatMessage {
    func apply(from message: ExtendedMessage) {
        let dto = PersistedExtendedMessage(from: message)
        legacyMessageId = message.id
        senderRaw = dto.senderRaw
        text = dto.text
        isAudio = dto.isAudio
        duration = dto.duration
        msgTypeRaw = dto.msgTypeRaw
        isConfirmed = dto.isConfirmed
        proposalStatusRaw = dto.proposalStatusRaw
        proposalCreatedAt = dto.proposalCreatedAt
        proposalTitle = dto.proposalTitle
        proposalBefore = dto.proposalBefore
        proposalAfter = dto.proposalAfter
        guideImageId = dto.guideImageId
        guideImageCaption = dto.guideImageCaption
        outboundPhone = dto.outboundPhone
        outboundContactName = dto.outboundContactName
        outboundGoal = dto.outboundGoal
        outboundKeyPoints = dto.outboundKeyPoints
        outboundTemplateName = dto.outboundTemplateName
        outboundScheduledAt = dto.outboundScheduledAt
        outboundTimeDescription = dto.outboundTimeDescription
        proposalFailureMessage = dto.proposalFailureMessage
    }
}

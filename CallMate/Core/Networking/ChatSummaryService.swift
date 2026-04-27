//
//  ChatSummaryService.swift
//  CallMate
//

import Foundation
import SwiftData

enum ChatSummaryService {
    private struct ChatSummaryItem: Codable {
        let session_id: String
        let chat_summary: ChatSummaryPayload?
        let token_count: Int?
        let duration: Int?
    }

    private struct ChatSummaryPayload: Codable {
        let title: String?
        let identity: String?
        let result: String?
        let summary: String?
        // Backward compatibility for old payloads.
        let suggestion: String?
    }

    private struct SummaryResult {
        let payload: ChatSummaryPayload
        let tokenCount: Int?
        let duration: Int?
    }

    private static let apiBaseURL = URL(string: AppConfig.voiceApiBaseURL)!

    static func pollAndUpdate(callId: UUID, sessionId: String, modelContext: ModelContext) {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task.detached(priority: .background) {
            print("[Summary] poll start session_id=\(sessionId)")
            let result = await pollChatSummary(sessionId: sessionId)
            guard let result,
                  let title = result.payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                print("[Summary] poll finished: no summary session_id=\(sessionId)")
                return
            }
            let identity = result.payload.identity?.trimmingCharacters(in: .whitespacesAndNewlines)
            let responseResult = (
                result.payload.result?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? result.payload.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let backendSummary = result.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                do {
                    var descriptor = FetchDescriptor<CallLog>(
                        predicate: #Predicate { $0.id == callId }
                    )
                    descriptor.fetchLimit = 1
                    if let call = try modelContext.fetch(descriptor).first {
                        let isOutbound = (call.summary ?? "").hasPrefix("[OUTBOUND_TASK]")
                        call.summary = isOutbound ? "[OUTBOUND_TASK] \(title)" : title
                        if let identity, !identity.isEmpty {
                            call.label = identity
                        }
                        if let responseResult, !responseResult.isEmpty {
                            call.fullSummary = responseResult
                        } else {
                            call.fullSummary = nil
                        }
                        if let backendSummary, !backendSummary.isEmpty {
                            call.backendSummary = backendSummary
                        } else {
                            call.backendSummary = nil
                        }
                        if let tc = result.tokenCount, tc > 0 {
                            call.tokenCount = tc
                        }
                        if let dur = result.duration, dur > 0 {
                            call.aiDuration = dur
                        }
                        try modelContext.save()
                        print("[Summary] updated session_id=\(sessionId) title=\(title) identity=\(identity ?? "") tokens=\(result.tokenCount ?? 0) duration=\(result.duration ?? 0)")
                        DesktopLinkService.shared.sendUpdatedCallResultIfMapped(for: call)

                        CallLiveActivityManager.shared.showSummary(
                            summaryTitle: title,
                            summaryDetail: responseResult ?? "",
                            callerName: identity
                        )
                    }
                } catch {
                    print("[Summary] update failed session_id=\(sessionId) error=\(error.localizedDescription)")
                }
            }
        }
    }

    private static func pollChatSummary(sessionId: String) async -> SummaryResult? {
        let maxWait: TimeInterval = 20
        let interval: TimeInterval = 1
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() <= deadline {
            if let result = await fetchChatSummary(sessionId: sessionId, useAuth: true) {
                return result
            }
            // If auth failed or no data, retry without auth once per interval
            if let result = await fetchChatSummary(sessionId: sessionId, useAuth: false) {
                return result
            }
            print("[Summary] poll retry session_id=\(sessionId)")
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return nil
    }

    private static func fetchChatSummary(sessionId: String, useAuth: Bool) async -> SummaryResult? {
        let url = apiBaseURL.appendingPathComponent("/api/chat/summaries")
        let body: [String: Any] = ["session_ids": [sessionId]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if useAuth {
            let token = await BackendAuthManager.shared.ensureToken()
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[Summary] http=\(http.statusCode) auth=\(useAuth ? "on" : "off")")
                return nil
            }
            let items = try JSONDecoder().decode([ChatSummaryItem].self, from: respData)
            print("[Summary] ←── raw response (\(useAuth ? "auth" : "no-auth")):\n\(String(data: respData, encoding: .utf8) ?? "<empty>")")
            for item in items {
                print("""
[Summary] item: session_id=\(item.session_id) \
token_count=\(item.token_count.map { "\($0)" } ?? "nil") \
duration=\(item.duration.map { "\($0)" } ?? "nil") \
title=\(item.chat_summary?.title ?? "nil") \
identity=\(item.chat_summary?.identity ?? "nil") \
result=\(item.chat_summary?.result ?? "nil")
""")
                if item.session_id == sessionId,
                   let summary = item.chat_summary, summary.title?.isEmpty == false {
                    return SummaryResult(
                        payload: summary,
                        tokenCount: item.token_count,
                        duration: item.duration
                    )
                }
            }
        } catch {
            print("[Summary] fetch failed auth=\(useAuth ? "on" : "off") error=\(error.localizedDescription)")
            return nil
        }
        return nil
    }
}

//
//  ChatSummaryService.swift
//  CallMate
//

import Foundation
import SwiftData

enum ChatSummaryService {
    private struct ChatSummaryPayload: Codable {
        let title: String?
        let identity: String?
        let result: String?
        let summary: String?
        /// Backward compatibility for old payloads.
        let suggestion: String?
        /// call_outbound structured summary (plan §5.2).
        let outcome: String?
        let actionRequired: String?

        enum CodingKeys: String, CodingKey {
            case title, identity, result, summary, suggestion, outcome
            case actionRequired = "action_required"
        }
    }

    private struct SummaryResult {
        let payload: ChatSummaryPayload
        /// Raw `chat_summary` object JSON for `OutboundTask.summary`.
        let rawSummaryJSON: String
        let tokenCount: Int?
        let duration: Int?
    }

    private static let apiBaseURL = URL(string: AppConfig.voiceApiBaseURL)!

    static func pollAndUpdate(callId: UUID, sessionId: String, modelContext: ModelContext) {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task.detached(priority: .background) {
            print("[Summary] poll start session_id=\(sessionId)")
            let result = await pollChatSummary(sessionId: sessionId)
            guard let result else {
                print("[Summary] poll finished: no summary session_id=\(sessionId)")
                return
            }
            let title = resolvedTitle(from: result.payload)
            guard !title.isEmpty else {
                print("[Summary] poll finished: empty title session_id=\(sessionId)")
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

                        if isOutbound, let taskId = call.outboundTaskID {
                            OutboundTaskStore.mergeOutboundSummary(
                                taskId: taskId,
                                summaryJSON: result.rawSummaryJSON,
                                outcome: result.payload.outcome
                            )
                        }
                    }
                } catch {
                    print("[Summary] update failed session_id=\(sessionId) error=\(error.localizedDescription)")
                }
            }
        }
    }

    private static func resolvedTitle(from payload: ChatSummaryPayload) -> String {
        let t = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        let r = payload.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !r.isEmpty { return r }
        return payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func pollChatSummary(sessionId: String) async -> SummaryResult? {
        let maxWait: TimeInterval = 20
        let interval: TimeInterval = 1
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() <= deadline {
            if let result = await fetchChatSummary(sessionId: sessionId, useAuth: true) {
                return result
            }
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
            print("[Summary] ←── raw response (\(useAuth ? "auth" : "no-auth")):\n\(String(data: respData, encoding: .utf8) ?? "<empty>")")
            guard let arr = try JSONSerialization.jsonObject(with: respData) as? [[String: Any]] else {
                print("[Summary] decode: top-level not array")
                return nil
            }
            for item in arr {
                guard (item["session_id"] as? String) == sessionId else { continue }
                guard let summaryDict = item["chat_summary"] as? [String: Any] else { continue }
                let payloadData = try JSONSerialization.data(withJSONObject: summaryDict)
                guard let payload = try? JSONDecoder().decode(ChatSummaryPayload.self, from: payloadData) else {
                    print("[Summary] decode ChatSummaryPayload failed session_id=\(sessionId)")
                    continue
                }
                let title = resolvedTitle(from: payload)
                guard !title.isEmpty else { continue }
                let rawString = String(data: payloadData, encoding: .utf8) ?? "{}"
                let tokenCount = Self.intField(item["token_count"])
                let duration = Self.intField(item["duration"])
                print("""
[Summary] item: session_id=\(sessionId) \
token_count=\(tokenCount.map { "\($0)" } ?? "nil") \
duration=\(duration.map { "\($0)" } ?? "nil") \
title=\(payload.title ?? "nil") \
outcome=\(payload.outcome ?? "nil") \
result=\(payload.result ?? "nil")
""")
                return SummaryResult(
                    payload: payload,
                    rawSummaryJSON: rawString,
                    tokenCount: tokenCount,
                    duration: duration
                )
            }
        } catch {
            print("[Summary] fetch failed auth=\(useAuth ? "on" : "off") error=\(error.localizedDescription)")
            return nil
        }
        return nil
    }

    private static func intField(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}

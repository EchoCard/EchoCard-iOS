import Foundation
import SwiftData

@MainActor
final class CallSummaryCoordinator {
    struct Message {
        let text: String
        let isAI: Bool
        let time: Date
    }

    struct PersistRequest {
        let callId: UUID
        let startedAt: Date
        let endedAt: Date
        let duration: Int
        let messages: [Message]
        let number: String
        let language: Language
        let outboundTaskID: UUID?
        let wsSessionId: String?
        let errorMessage: String?
        let recordingFileName: String?
    }

    func persistOutboundCall(_ request: PersistRequest) {
        let label = request.number.isEmpty ? "Outbound Call" : request.number
        let wasAnswered = request.duration > 0 || !request.messages.isEmpty
        print("[OutboundRec][Persist] persistOutboundCall: callId=\(request.callId) phone='\(request.number)' duration=\(request.duration)s messages=\(request.messages.count) wasAnswered=\(wasAnswered) outboundTaskID=\(request.outboundTaskID?.uuidString ?? "⚠️ NIL") wsSession=\(request.wsSessionId ?? "nil")")
        let callLog = CallLog(
            id: request.callId,
            startedAt: request.startedAt,
            endedAt: request.endedAt,
            durationSeconds: request.duration,
            recordingFileName: request.recordingFileName,
            statusRaw: wasAnswered ? CallStatus.handled.rawValue : CallStatus.missed.rawValue,
            phone: request.number,
            label: label,
            summary: "[OUTBOUND_TASK] " + (request.number.isEmpty ? "Outbound" : request.number),
            fullSummary: nil,
            isSimulation: false,
            languageRaw: request.language.rawValue,
            outboundTaskID: request.outboundTaskID,
            wsSessionId: request.wsSessionId,
            errorMessage: request.errorMessage
        )

        let context = CallMateApp.sharedModelContainer.mainContext
        context.insert(callLog)

        for (idx, msg) in request.messages.enumerated() {
            let senderRaw = msg.isAI ? ChatSender.ai.rawValue : ChatSender.caller.rawValue
            let offsetMs = Int(msg.time.timeIntervalSince(request.startedAt) * 1000)
            _ = TranscriptLine(
                index: idx,
                senderRaw: senderRaw,
                text: msg.text,
                timestamp: msg.time,
                startOffsetMs: max(0, offsetMs),
                endOffsetMs: nil,
                typeRaw: nil,
                call: callLog
            )
        }
        do {
            try context.save()
            print("[OutboundRec] CallLog saved: \(request.callId) recording=\(request.recordingFileName ?? "nil") duration=\(request.duration)s transcript=\(request.messages.count) lines")
        } catch {
            print("[OutboundRec] CallLog save failed: \(error.localizedDescription)")
        }
        if let sid = request.wsSessionId, !sid.isEmpty {
            ChatSummaryService.pollAndUpdate(callId: request.callId, sessionId: sid, modelContext: context)
        }
    }
}

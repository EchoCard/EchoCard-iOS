//
//  PersistenceModels.swift
//  CallMate
//
//  SwiftData persistence models for call logs and transcripts.
//

import Foundation
import SwiftData

@Model
final class CallLog {
    @Attribute(.unique) var id: UUID

    var createdAt: Date
    var startedAt: Date
    var endedAt: Date?

    var durationSeconds: Int

    /// Optional local recording file name (stored under app's recordings directory).
    var recordingFileName: String?

    /// Stored raw value mapping to `CallStatus` (handled/blocked/passed).
    var statusRaw: String

    var phone: String
    var label: String

    var summary: String?
    var fullSummary: String?
    /// Full structured summary returned by backend `chat_summary.summary`.
    var backendSummary: String?

    /// Distinguish simulation calls vs. real calls.
    var isSimulation: Bool

    /// True when the AI triggered the emergency notify-owner flow during this call.
    /// Optional so SwiftData can add it as a nullable column without requiring a migration plan.
    var isImportant: Bool?

    /// Stored raw value mapping to `Language` (zh/en).
    var languageRaw: String

    /// Exact outbound task binding. Nil for inbound/simulation or legacy records.
    var outboundTaskID: UUID?

    var wsSessionId: String?
    var errorMessage: String?

    /// LLM token usage returned by the summary service. Optional for zero-migration compatibility.
    var tokenCount: Int?

    /// AI session duration in seconds returned by the summary service. Optional for zero-migration compatibility.
    var aiDuration: Int?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptLine.call)
    var transcript: [TranscriptLine]

    @Relationship(deleteRule: .cascade, inverse: \CallFeedback.call)
    var feedback: [CallFeedback]

    /// User-facing summary with internal tags stripped.
    var displaySummary: String? {
        guard let s = summary else { return nil }
        let cleaned = s.replacingOccurrences(of: "[OUTBOUND_TASK] ", with: "")
                       .replacingOccurrences(of: "[OUTBOUND_TASK]", with: "")
        return cleaned.isEmpty ? nil : cleaned
    }

    var isOutboundCall: Bool {
        (summary ?? "").contains("[OUTBOUND_TASK]")
    }

    /// User-facing AI response with raw outbound rules stripped.
    var displayFullSummary: String? {
        guard let raw = fullSummary else { return nil }
        let cleaned = Self.stripOutboundRuleSections(raw)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleaned
    }

    private static func stripOutboundRuleSections(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var insideRuleBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("####") && trimmed.hasSuffix("####") && trimmed.count > 8 {
                insideRuleBlock = true
                continue
            }
            if trimmed.hasPrefix("&{") && trimmed.contains("} =") {
                continue
            }
            if insideRuleBlock {
                if trimmed.hasPrefix("####") && trimmed.hasSuffix("####") && trimmed.count > 8 {
                    continue
                }
                continue
            }
            result.append(line)
        }
        var output = result.joined(separator: "\n")
        if let jsonStart = output.range(of: "{\"template_name\""),
           let braceEnd = Self.findBalancedBraceEnd(in: output, from: jsonStart.lowerBound) {
            output.removeSubrange(jsonStart.lowerBound...braceEnd)
        }
        return output
    }

    private static func findBalancedBraceEnd(in str: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var i = start
        while i < str.endIndex {
            let c = str[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = str.index(after: i)
        }
        return nil
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        startedAt: Date,
        endedAt: Date? = nil,
        durationSeconds: Int,
        recordingFileName: String? = nil,
        statusRaw: String,
        phone: String,
        label: String,
        summary: String? = nil,
        fullSummary: String? = nil,
        backendSummary: String? = nil,
        isSimulation: Bool,
        isImportant: Bool? = nil,
        languageRaw: String,
        outboundTaskID: UUID? = nil,
        wsSessionId: String? = nil,
        errorMessage: String? = nil,
        transcript: [TranscriptLine] = [],
        feedback: [CallFeedback] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.recordingFileName = recordingFileName
        self.statusRaw = statusRaw
        self.phone = phone
        self.label = label
        self.summary = summary
        self.fullSummary = fullSummary
        self.backendSummary = backendSummary
        self.isSimulation = isSimulation
        self.isImportant = isImportant
        self.languageRaw = languageRaw
        self.outboundTaskID = outboundTaskID
        self.wsSessionId = wsSessionId
        self.errorMessage = errorMessage
        self.transcript = transcript
        self.feedback = feedback
    }
}

@Model
final class TranscriptLine {
    @Attribute(.unique) var id: UUID

    var index: Int
    var senderRaw: String
    var text: String

    var timestamp: Date

    /// Optional offsets since call start.
    var startOffsetMs: Int?
    var endOffsetMs: Int?

    /// Optional type: "stt" or "tts".
    var typeRaw: String?

    var call: CallLog?

    init(
        id: UUID = UUID(),
        index: Int,
        senderRaw: String,
        text: String,
        timestamp: Date,
        startOffsetMs: Int? = nil,
        endOffsetMs: Int? = nil,
        typeRaw: String? = nil,
        call: CallLog? = nil
    ) {
        self.id = id
        self.index = index
        self.senderRaw = senderRaw
        self.text = text
        self.timestamp = timestamp
        self.startOffsetMs = startOffsetMs
        self.endOffsetMs = endOffsetMs
        self.typeRaw = typeRaw
        self.call = call
    }
}

@Model
final class CallFeedback {
    @Attribute(.unique) var id: UUID

    /// Stored raw value: good/average/bad
    var ratingRaw: String
    var note: String?
    var createdAt: Date

    var call: CallLog?

    init(
        id: UUID = UUID(),
        ratingRaw: String,
        note: String? = nil,
        createdAt: Date = Date(),
        call: CallLog? = nil
    ) {
        self.id = id
        self.ratingRaw = ratingRaw
        self.note = note
        self.createdAt = createdAt
        self.call = call
    }
}

extension CallLog {
    var status: CallStatus {
        CallStatus(rawValue: statusRaw) ?? .handled
    }

    var language: Language {
        Language(rawValue: languageRaw) ?? .zh
    }
}

@Model
final class OutboundPromptTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class OutboundContactBookEntry {
    @Attribute(.unique) var id: UUID
    var name: String
    var phone: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        phone: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.phone = phone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - AI chat threads (FeedbackChatModalView)

/// One row per message for a given `messagesPersistenceKey` (`threadKey`).
@Model
final class AIChatMessage {
    @Attribute(.unique) var id: UUID

    /// Same string as `UserDefaults` key used previously (`callmate.ai_secretary.persisted_messages.v2`, etc.).
    var threadKey: String

    /// Monotonic index within the thread (0 = oldest loaded row in storage).
    var sortIndex: Int

    /// `ExtendedMessage.id` for UI logic.
    var legacyMessageId: Int

    var senderRaw: String
    var text: String
    var isAudio: Bool
    var duration: Int?
    var msgTypeRaw: String
    var isConfirmed: Bool
    var proposalStatusRaw: String?
    var proposalCreatedAt: Date?
    var proposalTitle: String?
    var proposalBefore: String?
    var proposalAfter: String?
    var guideImageId: String?
    var guideImageCaption: String?
    var outboundPhone: String?
    var outboundContactName: String?
    var outboundGoal: String?
    var outboundKeyPoints: String?
    var outboundTemplateName: String?
    var outboundScheduledAt: Date?
    var outboundTimeDescription: String?
    var proposalFailureMessage: String?

    init(
        id: UUID = UUID(),
        threadKey: String,
        sortIndex: Int,
        legacyMessageId: Int,
        senderRaw: String,
        text: String,
        isAudio: Bool,
        duration: Int? = nil,
        msgTypeRaw: String,
        isConfirmed: Bool,
        proposalStatusRaw: String? = nil,
        proposalCreatedAt: Date? = nil,
        proposalTitle: String? = nil,
        proposalBefore: String? = nil,
        proposalAfter: String? = nil,
        guideImageId: String? = nil,
        guideImageCaption: String? = nil,
        outboundPhone: String? = nil,
        outboundContactName: String? = nil,
        outboundGoal: String? = nil,
        outboundKeyPoints: String? = nil,
        outboundTemplateName: String? = nil,
        outboundScheduledAt: Date? = nil,
        outboundTimeDescription: String? = nil,
        proposalFailureMessage: String? = nil
    ) {
        self.id = id
        self.threadKey = threadKey
        self.sortIndex = sortIndex
        self.legacyMessageId = legacyMessageId
        self.senderRaw = senderRaw
        self.text = text
        self.isAudio = isAudio
        self.duration = duration
        self.msgTypeRaw = msgTypeRaw
        self.isConfirmed = isConfirmed
        self.proposalStatusRaw = proposalStatusRaw
        self.proposalCreatedAt = proposalCreatedAt
        self.proposalTitle = proposalTitle
        self.proposalBefore = proposalBefore
        self.proposalAfter = proposalAfter
        self.guideImageId = guideImageId
        self.guideImageCaption = guideImageCaption
        self.outboundPhone = outboundPhone
        self.outboundContactName = outboundContactName
        self.outboundGoal = outboundGoal
        self.outboundKeyPoints = outboundKeyPoints
        self.outboundTemplateName = outboundTemplateName
        self.outboundScheduledAt = outboundScheduledAt
        self.outboundTimeDescription = outboundTimeDescription
        self.proposalFailureMessage = proposalFailureMessage
    }
}


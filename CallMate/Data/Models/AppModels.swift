//
//  AppModels.swift
//  CallMate
//

import Foundation

enum AppState: String {
    case landing
    case scanning
    case bound
    case onboarding
    case main
}

enum Language: String, CaseIterable {
    case zh
    case en
}

enum CallStatus: String {
    case handled
    case blocked
    case passed
    /// Outbound call that was hung up before the callee answered.
    case missed
}

struct CallRecord: Identifiable, Equatable {
    let id: Int
    let phone: String
    let label: String
    let time: String
    let status: CallStatus
    let summary: String
    let fullSummary: String
    var transcript: [ChatMessage]?
    let duration: Int
}

enum ChatSender: String {
    case ai
    case user
    case system
    case caller
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int
    let sender: ChatSender
    let text: String
    var isAudio: Bool = false
    var duration: Int?
    var startTime: Int?
    var endTime: Int?
}

struct OnboardingStep {
    let stepId: Int
    let aiQuestions: [(text: String, duration: Int)]
    let topic: String
    let simulatedUserReply: String
    let strategy: (trigger: String, action: String)
}

struct StrategyCard {
    let trigger: String
    let action: String
}

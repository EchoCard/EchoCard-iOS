import Foundation

// MARK: - Session Types

extension CallSessionController {
    nonisolated enum InputSource: Equatable, Sendable {
        case microphone
        case ble
    }

    enum Status: Equatable {
        case connecting
        case ringing
        case connected
        case ended
    }

    struct DialogMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isAI: Bool
        let time: Date = Date()
    }
}

import Foundation

enum CallSessionEvent {
    case startRequested
    case incomingCallReceived
    case callConnected
    case endRequested
}

struct CallStateMachine {
    static func reduce(_ state: CallSessionController.Status, event: CallSessionEvent) -> CallSessionController.Status {
        switch event {
        case .startRequested:
            return .connecting
        case .incomingCallReceived:
            return .ringing
        case .callConnected:
            return .connected
        case .endRequested:
            return .ended
        }
    }
}

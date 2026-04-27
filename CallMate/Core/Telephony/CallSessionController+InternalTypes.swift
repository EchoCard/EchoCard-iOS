import Foundation

// MARK: - Internal Session Types

extension CallSessionController {
    enum BLEAudioCodec: String {
        case opus
    }

    enum BLEWSConnectContext {
        case none
        case incomingCall
        case activeCall
    }
}

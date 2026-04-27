import AppIntents
import CoreFoundation

private enum LiveActivityActionNotifyName {
    static let handoff = "greater.vaca.echocard.liveactivity.handoff"
    static let hangup = "greater.vaca.echocard.liveactivity.hangup"
}

struct LiveCallHandoffIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "真人接听"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(LiveActivityActionNotifyName.handoff as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
        return .result()
    }
}

struct LiveCallHangupIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "挂断"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(LiveActivityActionNotifyName.hangup as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
        return .result()
    }
}

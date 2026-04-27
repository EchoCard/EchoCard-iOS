import Foundation
import CoreFoundation

private let liveActivityCoordinatorDarwinNotificationCallback: CFNotificationCallback = { _, observer, name, _, _ in
    guard let observer else { return }
    let coordinator = Unmanaged<CallLiveActivityCoordinator>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in
        coordinator.handleDarwinNotification(name)
    }
}

@MainActor
final class CallLiveActivityCoordinator {
    enum Action {
        case handoff
        case hangup
    }

    struct Snapshot {
        let status: CallSessionController.Status
        let duration: Int
        let language: Language
        let inputSource: CallSessionController.InputSource
        let currentIncomingCall: CallMateIncomingCall?
        let pendingIncomingCall: CallMateIncomingCall?
        let currentTTSText: String
        let currentSTTText: String
        let emergencyLiveActivityText: String?
    }

    private enum LiveActivityActionNotifyName {
        static let handoff = "greater.vaca.echocard.liveactivity.handoff"
        static let hangup = "greater.vaca.echocard.liveactivity.hangup"
    }

    private let onAction: (Action) -> Void
    private var liveActivityCallId: String?
    private var liveActivityDarwinObserverRegistered: Bool = false

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
    }

    deinit {
        if liveActivityDarwinObserverRegistered {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterRemoveObserver(center, observer, nil, nil)
            liveActivityDarwinObserverRegistered = false
        }
    }

    func registerActionObserverIfNeeded() {
        guard !liveActivityDarwinObserverRegistered else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            liveActivityCoordinatorDarwinNotificationCallback,
            LiveActivityActionNotifyName.handoff as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            observer,
            liveActivityCoordinatorDarwinNotificationCallback,
            LiveActivityActionNotifyName.hangup as CFString,
            nil,
            .deliverImmediately
        )
        liveActivityDarwinObserverRegistered = true
    }

    func unregisterActionObserverIfNeeded() {
        guard liveActivityDarwinObserverRegistered else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)
        liveActivityDarwinObserverRegistered = false
    }

    func sync(snapshot: Snapshot, ttsOverride: String? = nil) {
        guard #available(iOS 16.1, *) else { return }
        if snapshot.status == .ended {
            let call = snapshot.currentIncomingCall ?? snapshot.pendingIncomingCall
            let callerName = call.map { $0.caller.isEmpty ? (snapshot.language == .zh ? "未知来电" : "Unknown") : $0.caller } ?? "EchoCard"
            let callerNumber = call?.number ?? ""
            CallLiveActivityManager.shared.showEndedState(
                callerName: callerName,
                callerNumber: callerNumber,
                durationSeconds: snapshot.duration
            )
            liveActivityCallId = nil
            return
        }
        let residentEnabled = CallLiveActivityManager.shared.isResidentEnabled
        let shouldShowLiveActivity = residentEnabled || snapshot.status == .connected
        if !shouldShowLiveActivity {
            CallLiveActivityManager.shared.end()
            liveActivityCallId = nil
            return
        }
        let call = snapshot.currentIncomingCall ?? snapshot.pendingIncomingCall
        guard let call else { return }
        if liveActivityCallId == nil {
            liveActivityCallId = "ble-\(call.uid)-\(Int(Date().timeIntervalSince1970))"
        }
        guard let liveActivityCallId else { return }
        let ttsSource = ttsOverride ?? snapshot.emergencyLiveActivityText ?? snapshot.currentTTSText
        let tts = ttsSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let stt = snapshot.currentSTTText.trimmingCharacters(in: .whitespacesAndNewlines)
        CallLiveActivityManager.shared.startOrUpdate(
            callId: liveActivityCallId,
            statusText: liveActivityStatusText(snapshot.status, language: snapshot.language),
            durationSeconds: snapshot.duration,
            ttsText: tts,
            sttText: stt,
            callerName: call.caller.isEmpty ? (snapshot.language == .zh ? "未知来电" : "Unknown") : call.caller,
            callerNumber: call.number,
            canHandoff: snapshot.inputSource == .ble && snapshot.status != .ended,
            canHangup: snapshot.status != .ended
        )
    }

    fileprivate func handleDarwinNotification(_ name: CFNotificationName?) {
        guard let raw = name?.rawValue as String? else { return }
        if raw == LiveActivityActionNotifyName.handoff {
            onAction(.handoff)
        } else if raw == LiveActivityActionNotifyName.hangup {
            onAction(.hangup)
        }
    }

    private func liveActivityStatusText(_ status: CallSessionController.Status, language: Language) -> String {
        switch status {
        case .connecting:
            return language == .zh ? "连接中" : "Connecting"
        case .ringing:
            return language == .zh ? "等待接通" : "Ringing"
        case .connected:
            return language == .zh ? "通话中" : "In Call"
        case .ended:
            return language == .zh ? "已结束" : "Ended"
        }
    }
}

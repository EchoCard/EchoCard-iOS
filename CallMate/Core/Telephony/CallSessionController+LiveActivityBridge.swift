import Foundation

// MARK: - Live Activity Bridge

extension CallSessionController {
    func handleLiveActivityAction(_ action: CallLiveActivityCoordinator.Action) {
        guard inputSource == .ble else { return }
        guard isActiveController else {
            print("[LiveActivity] ignore action: inactive controller")
            return
        }
        guard status != .ended else { return }
        switch action {
        case .handoff:
            handoffToHuman()
        case .hangup:
            end(abortReason: "live_activity_hangup_intent")
        }
    }
}

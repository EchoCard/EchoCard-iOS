import Foundation
import UIKit

// MARK: - BLE Runtime Control

extension CallSessionController {
    var isBLEReconnectBlocked: Bool {
        Date() < bleReconnectBlockedUntil
    }

    func markBLEReconnectBlocked(afterHFPDisconnect seconds: TimeInterval = 10.0) {
        bleReconnectBlockedUntil = Date().addingTimeInterval(seconds)
        print(String(format: "[CallSession] BLE reconnect cooldown %.1fs after hfp_disconnect", seconds))
    }

    func sendHFPDisconnectWithCooldown() {
        markBLEReconnectBlocked(afterHFPDisconnect: 10.0)
        ble.sendCommand("hfp_disconnect")
    }

    func tryForceBLEReconnect(reason: String) {
        if shouldSuppressBLEHangup {
            print("[CallSession] skip forceReconnect (\(reason)): passthrough/phone_handled")
            return
        }
        if isBLEReconnectBlocked {
            let remain = max(0, bleReconnectBlockedUntil.timeIntervalSinceNow)
            print(String(format: "[CallSession] skip forceReconnect (\(reason)): cooldown %.1fs left", remain))
            return
        }
        print("[CallSession] forceReconnect reason=\(reason)")
        ble.forceReconnect()
    }

    func startBLEBackgroundSupport(reason: String) {
        guard inputSource == .ble else { return }
        guard !bleBackgroundSupportActive else { return }
        bleBackgroundSupportActive = true
        audio.acquireBLEBackgroundSession()
        if bleBackgroundTaskId == .invalid {
            bleBackgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "CallMate.BLECall") { [weak self] in
                Task { @MainActor [weak self] in
                    self?.endBLEBackgroundTask(reason: "expired")
                }
            }
            scheduleBLEBackgroundTaskAutoEnd(taskId: bleBackgroundTaskId)
        }
        print("[CallSession] BLE background support started reason=\(reason)")
    }

    func stopBLEBackgroundSupport(reason: String) {
        guard inputSource == .ble else { return }
        guard bleBackgroundSupportActive || bleBackgroundTaskId != .invalid else { return }
        bleBackgroundSupportActive = false
        audio.releaseBLEBackgroundSession()
        endBLEBackgroundTask(reason: reason)
        print("[CallSession] BLE background support stopped reason=\(reason)")
    }

    private func scheduleBLEBackgroundTaskAutoEnd(taskId: UIBackgroundTaskIdentifier) {
        bleBackgroundTaskAutoEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.bleBackgroundTaskId == taskId else { return }
                self.endBLEBackgroundTask(reason: "grace_timeout")
            }
        }
        bleBackgroundTaskAutoEndWorkItem = workItem

        /* The audio session is the long-lived background aid.  The UIKit
         * background task is only a short grace window around Phone UI / route
         * transitions; holding it for the full call triggers iOS's 30s warning.
         */
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0, execute: workItem)
    }

    private func endBLEBackgroundTask(reason: String) {
        bleBackgroundTaskAutoEndWorkItem?.cancel()
        bleBackgroundTaskAutoEndWorkItem = nil
        guard bleBackgroundTaskId != .invalid else { return }
        let taskId = bleBackgroundTaskId
        bleBackgroundTaskId = .invalid
        UIApplication.shared.endBackgroundTask(taskId)
        print("[CallSession] BLE background task ended reason=\(reason)")
    }
}

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
                guard let self else { return }
                print("[CallSession] background task expired")
                if self.bleBackgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bleBackgroundTaskId)
                    self.bleBackgroundTaskId = .invalid
                }
            }
        }
        print("[CallSession] BLE background support started reason=\(reason)")
    }

    func stopBLEBackgroundSupport(reason: String) {
        guard inputSource == .ble else { return }
        guard bleBackgroundSupportActive || bleBackgroundTaskId != .invalid else { return }
        bleBackgroundSupportActive = false
        audio.releaseBLEBackgroundSession()
        if bleBackgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bleBackgroundTaskId)
            bleBackgroundTaskId = .invalid
        }
        print("[CallSession] BLE background support stopped reason=\(reason)")
    }
}

import Foundation

// MARK: - System Call Observer

extension CallSessionController {
    func registerSystemCallObserverIfNeeded() {
        guard systemCallObserverToken == nil else { return }
        if systemCallAnsweredObserverToken == nil {
            systemCallAnsweredObserverToken = SystemCallObserver.shared.addCallAnsweredHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 陌生人智能代接：CallKit 报 hasConnected 且 iOS 还没发过 AI answer，
                    // 说明是用户在 pickup_delay 窗口内手动抢接了。没有这条兜底时，MCU 若因时序
                    // 错过检测（bt_hfp_events.c:420 / ancs_handler.c:370-420 的前提不成立），
                    // iOS 的 phoneHandledCall 永远不会翻位，几分钟后 AI ✿END✿ 会发 BLE hangup
                    // → MCU AT+CHUP 把用户的电话挂掉。
                    let userHandledEarly = !self.aiAnswerRequested
                        && self.status != .ended
                        && !self.ble.latencyTestEchoMode
                    guard self.contactPassthroughActive || userHandledEarly else { return }
                    self.phoneHandledCall = true
                    self.pickupDelayTask?.cancel()
                    self.pickupDelayTask = nil
                    if let currentIncomingCall {
                        clearEmergencyBlockedNumber(currentIncomingCall.number)
                    } else if let pendingIncomingCall {
                        clearEmergencyBlockedNumber(pendingIncomingCall.number)
                    } else if let lastSuppressedBlockedNumber {
                        clearEmergencyBlockedNumber(lastSuppressedBlockedNumber)
                        self.lastSuppressedBlockedNumber = nil
                    }
                    print("[CallSession] System call connected -> treat as phone_handled (contactPassthrough=\(self.contactPassthroughActive) userHandledEarly=\(userHandledEarly))")
                }
            }
        }
        systemCallObserverToken = SystemCallObserver.shared.addCallEndedHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.contactPassthroughActive else { return }
                self.contactPassthroughActive = false
                self.ignoredContactIncomingUIDs.removeAll()
                print("[CallSession] System call ended -> keep HFP disconnected")
            }
        }
    }
}

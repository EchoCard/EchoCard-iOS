import Foundation
import SwiftData

// MARK: - Session Helpers

extension CallSessionController {
    func shouldBlockBLEAutoReconnectAfterHello(context: String) -> Bool {
        guard inputSource == .ble else { return false }
        let hasHello = transportCoordinator.hasReceivedWSHello() || hasReceivedWSHelloInCurrentCall
        let wsConnected = ws.isConnected
        let inActiveContext = bleCallActive || status == .connected || bleWSConnectContext == .activeCall
        let shouldBlock = hasHello && !wsConnected && inActiveContext
        print("[WS_RECONNECT_TRACE] gate context=\(context) hasHello=\(hasHello) stickyHello=\(hasReceivedWSHelloInCurrentCall) wsConnected=\(wsConnected) bleCallActive=\(bleCallActive) status=\(status) bleWSConnectContext=\(bleWSConnectContext) shouldBlock=\(shouldBlock)")
        return shouldBlock
    }

    func applyPhoneIDContextForWS() {
        if scene == .call {
            if inputSource == .ble {
                let number = currentIncomingCall?.number
                    ?? pendingIncomingCall?.number
                    ?? ble.lastDialedNumber
                ws.setPhoneIDSource(number)
            } else {
                // Microphone call scene is simulation path.
                ws.setPhoneIDSource("模拟通话")
            }
        } else {
            ws.setPhoneIDSource(nil)
        }
    }

    func bindCallSession(from call: CallMateIncomingCall) {
        transportCoordinator.bindCallSession(from: call)
    }

    func clearCallSessionSID(reason: String) {
        transportCoordinator.clearCallSessionSID(reason: reason)
    }

    func sendCallCommand(_ cmd: String, uid: Int? = nil, extra: [String: Any] = [:], expectAck: Bool = false) {
        transportCoordinator.sendCallCommand(cmd, uid: uid, extra: extra, expectAck: expectAck)
    }

    var shouldSuppressBLEHangup: Bool {
        inputSource == .ble && (contactPassthroughActive || phoneHandledCall)
    }

    func syncLiveActivity(ttsOverride: String? = nil) {
        liveActivityCoordinator.sync(
            snapshot: .init(
                status: status,
                duration: duration,
                language: language,
                inputSource: inputSource,
                currentIncomingCall: currentIncomingCall,
                pendingIncomingCall: pendingIncomingCall,
                currentTTSText: currentTTSText,
                currentSTTText: currentSTTText,
                emergencyLiveActivityText: emergencyLiveActivityText
            ),
            ttsOverride: ttsOverride
        )
    }

    func syncWSSessionIdFromService(reason: String) {
        guard let sid = ws.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty else { return }
        if wsSessionId != sid {
            wsSessionId = sid
            print("[CallSession] synced wsSessionId from service reason=\(reason) sid=\(sid)")
        }
    }

    var shouldGuardMicDuringTTS: Bool {
        // 模拟通话（microphone + call）在 realtime 模式下已开启 AEC 回声消除，
        // 且云端不再发送 tts_stop，保持 guard 会导致麦克风永久静默。
        // AI分身（outboundChat）/ 配置向导（initConfig/updateConfig）均为 manual 场景，
        // 本来就不进此路径，不受影响。
        false
    }

    func engageMicGuardForTTS() {
        guard shouldGuardMicDuringTTS else {
            print("[MIC_CHAIN] mic_guard_engage_skipped: shouldGuard=false inputSource=\(inputSource) scene=\(scene)")
            return
        }
        guard !micMutedByTTSGuard else {
            print("[MIC_CHAIN] mic_guard_engage_skipped: already_muted micMutedByTTSGuard=true")
            return
        }
        micMutedByTTSGuard = true
        audioRouter.setMuted(true)
        print("[MIC_CHAIN] mic_guard_ON: isMicMuted=true ttsStopCount=\(ttsStopCount) wsListeningStarted=\(wsListeningStarted)")
        print("[CallSession] TTS mic guard: muted uplink mic")
        logTTSTrace("mic_guard_on")
    }

    func releaseMicGuardForTTS() {
        guard micMutedByTTSGuard else {
            print("[MIC_CHAIN] mic_guard_release_skipped: micMutedByTTSGuard=false (already released)")
            return
        }
        micMutedByTTSGuard = false
        audioRouter.setMuted(false)
        print("[MIC_CHAIN] mic_guard_OFF: isMicMuted=false ttsStopCount=\(ttsStopCount) wsListeningStarted=\(wsListeningStarted)")
        print("[CallSession] TTS mic guard: restored uplink mic")
        logTTSTrace("mic_guard_off")
    }

    func logTTSTrace(_ event: String, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[TTS_MIN] t=\(nowLogString()) event=\(event) stopCount=\(ttsStopCount) rxCount=\(ttsAudioRxCount) isPlaying=\(audio.isPlaying) micGuard=\(micMutedByTTSGuard)\(suffix)")
    }

    /// Build and push an `IncomingCallContext` to the WebSocket service so it is
    /// included in the next `hello` message's `template_vars`.
    /// Call this immediately before `ws.connect()` / `ws.ensureConnectedForBLECall()`.
    func applyIncomingCallContextToWS(_ call: CallMateIncomingCall) {
        let callerType = call.isContact ? "contact" : "stranger"
        let callCount = fetchCallCount(for: call.number)
        let callHistorySummary = fetchLatestBackendSummary(for: call.number)
        ws.setPhoneIDSource(call.number)
        let ctx = IncomingCallContext(
            callerName: call.caller,
            callerType: callerType,
            isContact: call.isContact,
            callCount: callCount,
            systemCallType: "inbound",
            callHistorySummary: callHistorySummary
        )
        ws.setIncomingCallContext(ctx)
    }

    /// Query SwiftData for the number of `CallLog` entries matching `phoneNumber`.
    private func fetchCallCount(for phoneNumber: String) -> Int {
        guard !phoneNumber.isEmpty else { return 0 }
        let context = CallMateApp.sharedModelContainer.mainContext
        var descriptor = FetchDescriptor<CallLog>(
            predicate: #Predicate { $0.phone == phoneNumber }
        )
        descriptor.fetchLimit = 1000
        let count = (try? context.fetch(descriptor).count) ?? 0
        return count
    }

    /// Fetch the latest non-empty backend summary for the incoming number.
    private func fetchLatestBackendSummary(for phoneNumber: String) -> String {
        guard !phoneNumber.isEmpty else { return "" }
        let context = CallMateApp.sharedModelContainer.mainContext
        var descriptor = FetchDescriptor<CallLog>(
            predicate: #Predicate { $0.phone == phoneNumber }
        )
        descriptor.sortBy = [SortDescriptor(\CallLog.createdAt, order: .reverse)]
        descriptor.fetchLimit = 20
        guard let logs = try? context.fetch(descriptor) else { return "" }
        for log in logs {
            let value = log.backendSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

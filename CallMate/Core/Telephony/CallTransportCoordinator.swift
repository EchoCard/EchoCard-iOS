import Foundation

@MainActor
final class CallTransportCoordinator {
    enum NoHelloDecision {
        case retry(attempt: Int, maxRetries: Int, delaySec: Double, nextRetryCount: Int)
        case endAIOnlyKeepHFP
        case hangupAndEnd
        case endWithoutHangup(windowNote: String)
        case hfpDisconnectThenEnd
    }

    enum DisconnectDecision {
        case endWithoutHangup
        case hangupAndEnd
    }

    enum BLEConnectAction {
        case startPendingActiveFlow
        case startListening
    }

    struct WSConnectPlan {
        let setRinging: Bool
        let bleAction: BLEConnectAction?
    }

    enum BLEWSDisconnectPlan {
        case suppressAndEnd
        case noHelloRetry(attempt: Int, maxRetries: Int, delaySec: Double)
        case noHelloEndAIOnlyKeepHFP
        case noHelloHangupAndEnd
        case noHelloEndWithoutHangup(windowNote: String)
        case noHelloHFPDisconnectThenEnd
        case disconnectEndWithoutHangup
        case disconnectHangupAndEnd
    }

    enum BLECallStatePhase {
        case active
        case outgoingAnswered
        case phoneHandled
        case terminal(normalized: String)
        case other(normalized: String)
    }

    struct BLECallEndPlan {
        let abortReason: String
        let clearSIDReason: String
        let eventPassthroughFlag: Int
        let eventPhoneHandledFlag: Int
        let markPhoneHandledCall: Bool
        let clearPendingIncomingCall: Bool
        let clearPendingActiveConnect: Bool
        let cancelBLEAudioFlowTasks: Bool
        let setBLECallInactive: Bool
    }

    enum BLEActiveWSPlan {
        case skipNetworkUnavailable
        case ensureConnected
    }

    enum BLEOutgoingAnsweredWSPlan {
        case skipNetworkUnavailable
        case connect
    }

    enum BLEActiveCallRoutePlan {
        case activatePending(sendAudioStart: Bool)
        case activateOutgoing
    }

    enum BLEAckPlan {
        case ignore
        case phoneHandledRejected
        case audioStartAccepted
        case ignoreAccepted
        case answerFailed(result: Int)
    }

    enum BLEIncomingCallGatePlan {
        case ignoreStandby
        case ignoreEmergencyBlocked
        case ignoreContactPassthroughActive
        case ignoreAlreadyIgnoredContact
        case allowContactPassthrough
        case ignoreDuplicate
        case recoverConnectedThenProceed
        case proceed
    }

    enum BLEIncomingCallWSPlan {
        case skipNetworkUnavailable
        case ensureConnected(wsAlreadyConnected: Bool)
    }

    private let ble: any CallMateBLELibraryClient
    private var currentBLECallSID: UInt32?
    private var sidBoundUID: Int?
    private var wsNoHelloRetryTask: Task<Void, Never>?
    private var wsConnectStartedAt: Date?
    private var wsHelloReceived: Bool = false
    private var wsNoHelloRetryCount: Int = 0
    private var wsReconnectAttempts: Int = 0

    init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
    }

    func bindCallSession(from call: CallMateIncomingCall) {
        currentBLECallSID = call.sid
        sidBoundUID = call.uid
        ble.setCurrentCallSID(call.sid)
        print("[CallSession] bind sid=\(call.sid ?? 0) uid=\(call.uid)")
    }

    /// For `[OutboundDiag]` logs only — correlates App command sid with MCU `call_state`.
    func diagnosticBleCallSIDForLogging() -> UInt32? {
        currentBLECallSID
    }

    func clearCallSessionSID(reason: String) {
        if let sid = currentBLECallSID {
            print("[CallSession] clear sid=\(sid) reason=\(reason)")
        }
        currentBLECallSID = nil
        sidBoundUID = nil
        ble.clearCurrentCallSID(reason: reason)
    }

    func sendCallCommand(_ cmd: String, uid: Int? = nil, extra: [String: Any] = [:], expectAck: Bool = false) {
        if let uid, let boundUID = sidBoundUID, boundUID != uid, currentBLECallSID != nil {
            print("[CallSession] drop stale cmd=\(cmd) uid=\(uid) boundUID=\(boundUID) sid=\(currentBLECallSID ?? 0)")
            return
        }
        let sid = commandSID(for: uid)
        ble.sendCommand(cmd, uid: uid, extra: extra, expectAck: expectAck, sid: sid)
    }

    private func commandSID(for uid: Int? = nil) -> UInt32? {
        if let uid, let boundUID = sidBoundUID, boundUID != uid {
            return nil
        }
        if let sid = currentBLECallSID {
            return sid
        }
        return ble.currentCallSID
    }

    func decideNoHelloDisconnect(
        inActiveAIContext: Bool,
        status: CallSessionController.Status,
        hasOutboundCall: Bool,
        incomingContextNotActive: Bool,
        isEarlyWindow: Bool,
        currentRetryCount: Int
    ) -> NoHelloDecision {
        if inActiveAIContext {
            let maxRetries = 3
            let nextRetryCount = currentRetryCount + 1
            if nextRetryCount <= maxRetries {
                let delaySec = min(Double(nextRetryCount), 2.0)
                return .retry(
                    attempt: nextRetryCount,
                    maxRetries: maxRetries,
                    delaySec: delaySec,
                    nextRetryCount: nextRetryCount
                )
            }
            if status == .connecting && hasOutboundCall {
                return .endAIOnlyKeepHFP
            }
            return .hangupAndEnd
        }

        if incomingContextNotActive {
            let windowNote = isEarlyWindow ? "quick" : "late"
            return .endWithoutHangup(windowNote: windowNote)
        }

        return .hfpDisconnectThenEnd
    }

    func decideDisconnectAfterHello(incomingContextNotActive: Bool) -> DisconnectDecision {
        incomingContextNotActive ? .endWithoutHangup : .hangupAndEnd
    }

    func cancelNoHelloRetryTask() {
        wsNoHelloRetryTask?.cancel()
        wsNoHelloRetryTask = nil
    }

    func scheduleNoHelloRetryTask(
        delaySec: Double,
        onFire: @escaping @MainActor () -> Void
    ) {
        cancelNoHelloRetryTask()
        wsNoHelloRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            onFire()
            self.wsNoHelloRetryTask = nil
        }
    }

    func markWSConnectStarted() {
        wsConnectStartedAt = Date()
        wsHelloReceived = false
        print("[WS_RECONNECT_TRACE] marker event=markWSConnectStarted wsHelloReceived=false")
    }

    func markWSHelloReceived() {
        wsHelloReceived = true
        print("[WS_RECONNECT_TRACE] marker event=markWSHelloReceived wsHelloReceived=true")
    }

    func clearWSConnectionMarkers() {
        wsConnectStartedAt = nil
        wsHelloReceived = false
        print("[WS_RECONNECT_TRACE] marker event=clearWSConnectionMarkers wsHelloReceived=false")
    }

    func wsConnectElapsed(now: Date = Date()) -> TimeInterval {
        wsConnectStartedAt.map { now.timeIntervalSince($0) } ?? 0
    }

    func hasReceivedWSHello() -> Bool {
        wsHelloReceived
    }

    func resetNoHelloRetryCount() {
        wsNoHelloRetryCount = 0
    }

    func resetWSReconnectAttempts() {
        wsReconnectAttempts = 0
    }

    func wsReconnectAttemptsValue() -> Int {
        wsReconnectAttempts
    }

    func setWSReconnectAttempts(_ value: Int) {
        wsReconnectAttempts = value
    }

    func currentNoHelloRetryCount() -> Int {
        wsNoHelloRetryCount
    }

    func setNoHelloRetryCount(_ value: Int) {
        wsNoHelloRetryCount = value
    }

    func planAfterWSConnect(
        status: CallSessionController.Status,
        inputSource: CallSessionController.InputSource,
        pendingActiveConnect: Bool
    ) -> WSConnectPlan {
        let setRinging = (status == .connecting)
        guard inputSource == .ble else {
            return WSConnectPlan(setRinging: setRinging, bleAction: nil)
        }
        if pendingActiveConnect {
            return WSConnectPlan(setRinging: setRinging, bleAction: .startPendingActiveFlow)
        }
        return WSConnectPlan(setRinging: setRinging, bleAction: .startListening)
    }

    func prepareForWSConnect() {
        markWSHelloReceived()
        resetWSReconnectAttempts()
        resetNoHelloRetryCount()
        cancelNoHelloRetryTask()
    }

    func planBLEWSDisconnect(
        status: CallSessionController.Status,
        hasOutboundCall: Bool,
        inActiveAIContext: Bool,
        incomingContextNotActive: Bool,
        isEarlyWindow: Bool,
        shouldSuppressBLEHangup: Bool,
        hasEverReceivedWSHelloInCall: Bool
    ) -> BLEWSDisconnectPlan {
        if shouldSuppressBLEHangup {
            return .suppressAndEnd
        }

        let hasHello = hasReceivedWSHello() || hasEverReceivedWSHelloInCall
        print("[WS_RECONNECT_TRACE] disconnect_plan hasHello=\(hasHello) markerHello=\(hasReceivedWSHello()) stickyHello=\(hasEverReceivedWSHelloInCall) inActiveAIContext=\(inActiveAIContext) incomingContextNotActive=\(incomingContextNotActive)")
        if !hasHello {
            let decision = decideNoHelloDisconnect(
                inActiveAIContext: inActiveAIContext,
                status: status,
                hasOutboundCall: hasOutboundCall,
                incomingContextNotActive: incomingContextNotActive,
                isEarlyWindow: isEarlyWindow,
                currentRetryCount: currentNoHelloRetryCount()
            )
            switch decision {
            case let .retry(attempt, maxRetries, delaySec, nextRetryCount):
                setNoHelloRetryCount(nextRetryCount)
                return .noHelloRetry(attempt: attempt, maxRetries: maxRetries, delaySec: delaySec)
            case .endAIOnlyKeepHFP:
                return .noHelloEndAIOnlyKeepHFP
            case .hangupAndEnd:
                return .noHelloHangupAndEnd
            case let .endWithoutHangup(windowNote):
                return .noHelloEndWithoutHangup(windowNote: windowNote)
            case .hfpDisconnectThenEnd:
                return .noHelloHFPDisconnectThenEnd
            }
        }

        switch decideDisconnectAfterHello(incomingContextNotActive: incomingContextNotActive) {
        case .endWithoutHangup:
            return .disconnectEndWithoutHangup
        case .hangupAndEnd:
            return .disconnectHangupAndEnd
        }
    }

    func normalizeBLECallState(_ state: String) -> String {
        state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func classifyBLECallState(_ state: String) -> BLECallStatePhase {
        let normalized = normalizeBLECallState(state)
        switch normalized {
        case "active":
            return .active
        case "outgoing_answered":
            return .outgoingAnswered
        case "phone_handled":
            return .phoneHandled
        case "ended", "rejected", "idle", "hangup", "hungup", "cancelled", "canceled", "terminated":
            return .terminal(normalized: normalized)
        default:
            return .other(normalized: normalized)
        }
    }

    func planBLECallEnd(for phase: BLECallStatePhase) -> BLECallEndPlan? {
        switch phase {
        case .phoneHandled:
            return BLECallEndPlan(
                abortReason: "phone_handled",
                clearSIDReason: "call_state_phone_handled",
                eventPassthroughFlag: 1,
                eventPhoneHandledFlag: 1,
                markPhoneHandledCall: true,
                clearPendingIncomingCall: true,
                clearPendingActiveConnect: true,
                cancelBLEAudioFlowTasks: true,
                setBLECallInactive: false
            )
        case let .terminal(normalized):
            return BLECallEndPlan(
                abortReason: "remote_call_ended",
                clearSIDReason: "call_state_\(normalized)",
                eventPassthroughFlag: 0,
                eventPhoneHandledFlag: 0,
                markPhoneHandledCall: false,
                clearPendingIncomingCall: false,
                clearPendingActiveConnect: false,
                cancelBLEAudioFlowTasks: false,
                setBLECallInactive: true
            )
        case .active, .outgoingAnswered, .other:
            return nil
        }
    }

    func planBLEActiveCallWS(networkSatisfied: Bool) -> BLEActiveWSPlan {
        networkSatisfied ? .ensureConnected : .skipNetworkUnavailable
    }

    func planBLEOutgoingAnsweredWS(
        networkSatisfied: Bool
    ) -> BLEOutgoingAnsweredWSPlan {
        guard networkSatisfied else { return .skipNetworkUnavailable }
        return .connect
    }

    func planBLEActiveCallRoute(
        hasPendingIncomingCall: Bool,
        bleAudioStartAcked: Bool
    ) -> BLEActiveCallRoutePlan {
        if hasPendingIncomingCall {
            return .activatePending(sendAudioStart: !bleAudioStartAcked)
        }
        return .activateOutgoing
    }

    func planBLEAck(cmd: String, result: Int) -> BLEAckPlan {
        if cmd.hasPrefix("fw_") {
            return .ignore
        }
        // `play_filler` ACKs (incl. result=-2 "not in audio_streaming" / no active voice path)
        // must not drive session teardown — same numeric code is used for real "phone handled"
        // rejections on other commands.
        if cmd == "play_filler" {
            return .ignore
        }
        if result == -2 {
            return .phoneHandledRejected
        }
        if cmd == "answer", result != 0 {
            return .answerFailed(result: result)
        }
        if cmd == "audio_start", result == 0 {
            return .audioStartAccepted
        }
        if cmd == "ignore", result == 0 {
            return .ignoreAccepted
        }
        return .ignore
    }

    func planBLEIncomingCallGate(
        activeMode: String?,
        isEmergencyBlocked: Bool,
        contactPassthroughActive: Bool,
        ignoredContactContainsUID: Bool,
        isContact: Bool,
        isDuplicateCurrentCall: Bool,
        status: CallSessionController.Status
    ) -> BLEIncomingCallGatePlan {
        if activeMode == "standby" {
            print("[ContactDetect] gate=ignoreStandby (activeMode=standby)")
            return .ignoreStandby
        }
        if isEmergencyBlocked {
            print("[ContactDetect] gate=ignoreEmergencyBlocked")
            return .ignoreEmergencyBlocked
        }
        if contactPassthroughActive {
            print("[ContactDetect] gate=ignoreContactPassthroughActive (已有通讯录放行中)")
            return .ignoreContactPassthroughActive
        }
        if ignoredContactContainsUID {
            print("[ContactDetect] gate=ignoreAlreadyIgnoredContact (本通已按通讯录放行)")
            return .ignoreAlreadyIgnoredContact
        }
        if isContact {
            print("[ContactDetect] gate=allowContactPassthrough isContact=true -> 通讯录略过不接")
            return .allowContactPassthrough
        }
        if isDuplicateCurrentCall {
            print("[ContactDetect] gate=ignoreDuplicate")
            return .ignoreDuplicate
        }
        if status == .connected {
            print("[ContactDetect] gate=recoverConnectedThenProceed (status=connected)")
            return .recoverConnectedThenProceed
        }
        print("[ContactDetect] gate=proceed -> 将代接")
        return .proceed
    }

    func planBLEIncomingCallWS(
        networkSatisfied: Bool,
        wsConnected: Bool
    ) -> BLEIncomingCallWSPlan {
        guard networkSatisfied else { return .skipNetworkUnavailable }
        return .ensureConnected(wsAlreadyConnected: wsConnected)
    }
}

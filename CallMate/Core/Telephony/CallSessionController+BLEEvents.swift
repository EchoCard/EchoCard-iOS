import Foundation
import Combine
import Network

// MARK: - BLE Event Handling

extension CallSessionController {
    func bindBLEEvents() {
        cancellables.removeAll()

        // When MCU disconnects during a BLE call, end the session so Live Activity / Dynamic Island
        // is cleared and the UI does not stay stuck on "in call".
        ble.runtimeSnapshotPublisher
            .map(\.connectedPeripheralID)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self else { return }
                guard id == nil else { return }
                guard self.isActiveController, self.status != .ended else { return }
                print("[CallSession] BLE disconnected while in call -> end session")
                self.end(abortReason: "ble_disconnected")
            }
            .store(in: &cancellables)

        ble.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] evt in
                guard let self else { return }

                // CRITICAL:
                // When offline local playback test is armed/running, this cloud-driven controller
                // must stay completely idle. Otherwise it will:
                // - send `audio_start` repeatedly
                // - trigger "audio not flowing" watchdog
                // - force BLE reconnect, breaking the test mode and sometimes the call
                if isOfflineBLELocalTestActive() {
                    // Only keep minimal logging for debug.
                    if case .incomingCall(let call) = evt {
                        print("[CallSession] BLE evt ignored (offline local test active) incoming_call uid=\(call.uid)")
                    }
                    return
                }

                switch evt {
                case .incomingCall(let call):
                    self.handleBLEIncomingCall(call)
                case .callState(let state):
                    self.handleBLECallState(state)
                case .audioDownlinkOpus(let opus):
                    self.handleBLEAudioDownlinkOpus(opus)
                case .ack(let cmd, let result):
                    self.handleBLEAck(cmd: cmd, result: result)
                case .deviceInfo:
                    break
                case .firmwareChunkAck, .firmwareStatus, .firmwareMissing, .flashdbResponse:
                    break   // Handled by FirmwareUpdateService
                case .preloadMissing:
                    break   // Consumed by TTSFillerSyncCoordinator via its own ble.events sink
                }
            }
            .store(in: &cancellables)
    }

    func handleBLECallState(_ state: String) {
        // During latency test, only LatencyTestRunner should react to call_state (wait for active → SCO).
        if ble.latencyTestEchoMode {
            return
        }
        print("[NOSOUND] call_state: \"\(state)\" bleCallActive=\(bleCallActive) acked=\(bleAudioStartAcked) wsListening=\(wsListeningStarted) wsSession=\(ws.sessionId != nil)")
        print("[OutboundRec] BLE callState received: \"\(state)\" status=\(status) outboundCallId=\(outboundCallId?.uuidString ?? "nil")")
        let callStatePhase = transportCoordinator.classifyBLECallState(state)
        if handleCallStateDuringContactPassthrough(
            state: state,
            phase: callStatePhase
        ) {
            return
        }
        switch callStatePhase {
        case .active:
            handleBLECallStateActive()
        case .outgoingAnswered:
            handleBLECallStateOutgoingAnswered()
        case .phoneHandled, .terminal:
            guard let endPlan = transportCoordinator.planBLECallEnd(for: callStatePhase) else {
                return
            }
            handleBLECallEndPlan(endPlan)
        case .other:
            break
        }
    }

    func isOfflineBLELocalTestActive() -> Bool {
        UserDefaults.standard.bool(forKey: "ble_local_uplink_test_armed") ||
            UserDefaults.standard.bool(forKey: "ble_local_uplink_test_in_progress")
    }

    func handleBLEIncomingCall(_ call: CallMateIncomingCall) {
        bindCallSession(from: call)
        let isContact = call.isContact
        let isEmergencyBlocked = isEmergencyBlockedNumber(call.number)
        let ignoredContactContainsUID = ignoredContactIncomingUIDs.contains(call.uid)
        let isDuplicateCurrentCall = currentIncomingCall?.uid == call.uid && status != .ended
        print("[ContactDetect] gate_input uid=\(call.uid) number=\(call.number) caller=\(call.caller) isContact=\(isContact) isEmergencyBlocked=\(isEmergencyBlocked) contactPassthroughActive=\(contactPassthroughActive) ignoredContactContainsUID=\(ignoredContactContainsUID) isDuplicate=\(isDuplicateCurrentCall) status=\(status)")
        let incomingGatePlan = transportCoordinator.planBLEIncomingCallGate(
            activeMode: UserDefaults.standard.string(forKey: activeModeKey),
            isEmergencyBlocked: isEmergencyBlocked,
            contactPassthroughActive: contactPassthroughActive,
            ignoredContactContainsUID: ignoredContactContainsUID,
            isContact: isContact,
            isDuplicateCurrentCall: isDuplicateCurrentCall,
            status: status
        )
        switch incomingGatePlan {
        case .ignoreStandby:
            // Auto-start if app is foreground and the controller is idle.
            print("[CallSession] active_mode=standby -> send ignore incoming_call uid=\(call.uid)")
            Task { @MainActor in
                AbnormalCallRecordStore.shared.append(reasonCode: "standby")
            }
            sendCallCommand("ignore", uid: call.uid)
            return
        case .ignoreEmergencyBlocked:
            let normalized = normalizePhoneNumber(call.number)
            print("[CallSession] incoming_call ignored (emergency passthrough) uid=\(call.uid) number=\(normalized)")
            Task { @MainActor in
                AbnormalCallRecordStore.shared.append(reasonCode: "emergency_blocked")
            }
            sendCallCommand("ignore", uid: call.uid)
            lastSuppressedBlockedNumber = normalized
            toastMessage = language == .zh
                ? "该号码上次紧急提醒未接通，本次已不再代接"
                : "This number was blocked after no pickup; AI skipped takeover."
            return
        case .ignoreContactPassthroughActive:
            print("[CallSession] incoming_call ignored (contact passthrough active) uid=\(call.uid)")
            return
        case .ignoreAlreadyIgnoredContact:
            print("[CallSession] incoming_call ignored (contact passthrough already active) uid=\(call.uid)")
            return
        case .allowContactPassthrough:
            print("[ContactDetect] 执行通讯录略过不接 uid=\(call.uid) number=\(call.number) caller=\(call.caller) title=\(call.title)")
            print("[CallSession] incoming_call ignored (contact) number=\(call.number) uid=\(call.uid)")
            Task { @MainActor in
                AbnormalCallRecordStore.shared.append(reasonCode: "contact_passthrough")
            }
            ignoredContactIncomingUIDs.insert(call.uid)
            contactPassthroughActive = true
            if ws.isConnected {
                ws.disconnect()
            }
            wsListeningStarted = false
            sendCallCommand("ignore", uid: call.uid)
            // Skip HFP disconnect during latency test — it intentionally uses HFP for audio.
            if !ble.latencyTestEchoMode {
                sendHFPDisconnectWithCooldown()
            }
            toastMessage = language == .zh
                ? "识别为通讯录来电，已放行系统通话"
                : "Contact call detected, AI passthrough enabled."
            return
        case .ignoreDuplicate:
            print("[CallSession] incoming_call duplicate uid=\(call.uid) status=\(status)")
            return
        case .recoverConnectedThenProceed:
            // If already connected (in-call), don't auto-answer a new call.
            // Recovery for stale call state:
            // If previous call teardown notification was missed, we may stay in
            // `.connected` forever and block all future incoming calls.
            // New incoming with different uid should preempt stale session.
            print("[CallSession] incoming_call while status=connected uid=\(call.uid) -> recover stale session")
            suppressHangupOnce = true
            end()
        case .proceed:
            break
        }

        print("[CallSession] incoming_call parsed uid=\(call.uid) caller=\(call.caller) number=\(call.number) isContact=\(call.isContact)")
        print("[CallSession] incoming_call uid=\(call.uid) status=\(status) -> prepareIncomingCall")
        if latIncomingAt == nil {
            latIncomingAt = Date()
        }
        latencyLog("incoming_call_event", uid: call.uid)
        switch transportCoordinator.planBLEIncomingCallWS(
            networkSatisfied: permissions.networkStatus == .satisfied,
            wsConnected: ws.isConnected
        ) {
        case .skipNetworkUnavailable:
            break
        case let .ensureConnected(wsAlreadyConnected):
            // BLE incoming call should immediately establish WS + hello.
            // Do not wait for "AI takeover confirmed".
            ws.addDelegate(self)
            transportCoordinator.resetWSReconnectAttempts()
            bleWSConnectContext = .incomingCall
            if wsAlreadyConnected {
                transportCoordinator.markWSHelloReceived()
            } else {
                transportCoordinator.markWSConnectStarted()
            }
            let audioFormat = bleWSAudioFormat
            print("[CallSession] incoming_call event: ensuring WS connected with audioFormat=\(audioFormat)")
            applyIncomingCallContextToWS(call)
            ws.ensureConnectedForBLECall(audioFormat: audioFormat, scene: .call)
        }
        startBLEBackgroundSupport(reason: "incoming_call")
        prepareIncomingCall(call)
    }

    func handleBLECallStateActive() {
        startBLEBackgroundSupport(reason: "call_state_active")
        latCallActiveAt = Date()
        latencyLog("call_state_active")
        remoteCallTerminalState = false
        /*
         * MCU is the authority on call state.
         * "active" means a call was answered — proceed with AI audio flow.
         * If the user answered on the phone, MCU will send "phone_handled"
         * instead, which is handled separately below.
         *
         * We no longer gate on aiAnswerRequested here because timing races
         * between iOS pickup-delay and MCU auto-answer can cause false
         * "phone handled" detection, breaking BLE audio on the next call.
         */
        if !aiAnswerRequested {
            print("[CallSession] call_state=active: aiAnswerRequested=false, but trusting MCU (cancel pending answer)")
            // Cancel pickup delay since call is already active.
            pickupDelayTask?.cancel()
            pickupDelayTask = nil
            // Mark as AI-driven retroactively.
            aiAnswerRequested = true
        }

        bleCallActive = true
        if inputSource == .ble, !didCountIncomingCall {
            let key = "callmate.ai_calls_total"
            let current = UserDefaults.standard.integer(forKey: key)
            UserDefaults.standard.set(current + 1, forKey: key)
            didCountIncomingCall = true
        }
        let hasPending = pendingIncomingCall != nil
        print("[OutboundRec] call_state(active): pendingIncomingCall=\(hasPending) -> \(hasPending ? "activatePending" : "activateOutgoing")")
        switch transportCoordinator.planBLEActiveCallRoute(
            hasPendingIncomingCall: hasPending,
            bleAudioStartAcked: bleAudioStartAcked
        ) {
        case let .activatePending(sendAudioStart):
            // Incoming call answered by MCU — ensure WS is ready (re-check in case
            // it was suspended between incoming_call and active), then start audio.
            switch transportCoordinator.planBLEActiveCallWS(
                networkSatisfied: permissions.networkStatus == .satisfied
            ) {
            case .ensureConnected:
                if shouldBlockBLEAutoReconnectAfterHello(context: "handleBLECallStateActive") {
                    print("[WS_RECONNECT_TRACE] block context=handleBLECallStateActive action=skip_auto_reconnect")
                    return
                }
                bleWSConnectContext = .activeCall
                let audioFormat = bleWSAudioFormat
                print("[CallSession] call_state(active): ensuring WS connected with audioFormat=\(audioFormat)")
                applyPhoneIDContextForWS()
                ws.ensureConnectedForBLECall(
                    audioFormat: audioFormat,
                    scene: .call,
                    reason: "handleBLECallStateActive"
                )
            case .skipNetworkUnavailable:
                break
            }
            if sendAudioStart {
                latAudioStartSentAt = Date()
                latencyLog("send_audio_start")
                sendCallCommand("audio_start", extra: ["codec": bleMCUAudioCodecName], expectAck: false)
            }
            activatePendingCallIfNeeded()
        case .activateOutgoing:
            // Outgoing call: HFP reports active, but do NOT connect WS or send
            // audio_start yet. WS connect with prompt override is deferred until
            // outgoing_answered to avoid sending hello before callHelloPromptOverride
            // is set (which would cause the prompt to be missing).
            print("[OutboundRec] call_state(active): outgoing call, deferring WS connect and audio_start until outgoing_answered")
            activateOutgoingCallIfNeeded()
        }
    }

    func handleBLECallStateOutgoingAnswered() {
        /*
         * MCU detected ANCS "当前通话" — the callee has answered the outgoing
         * call. Now connect to AI cloud and start audio.
         */
        print("[OutboundRec] call_state(outgoing_answered): callee picked up, connecting WS and starting audio")
        print("[PromptTrace] outgoing_answered ENTRY: activePrompt=\(activeOutboundPrompt == nil ? "nil" : "\(activeOutboundPrompt!.count)chars") pendingPrompt=\(pendingOutboundPrompt == nil ? "nil" : "\(pendingOutboundPrompt!.count)chars")")
        print("[OutboundRec][TaskID] outgoing_answered ENTRY: activeOutboundTaskID=\(activeOutboundTaskID?.uuidString ?? "⚠️ NIL") outboundCallId=\(outboundCallId?.uuidString ?? "⚠️ NIL — call_state(active) may have been missed!")")
        remoteCallTerminalState = false
        bleCallActive = true
        applyPhoneIDContextForWS()

        // Fallback for event-order races:
        // if `active` was missed/delayed, outbound context may still be in `pending*`.
        // Promote it here so hello.initiate.prompt is not dropped.
        if activeOutboundPrompt == nil {
            let fallbackPrompt = pendingOutboundPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let fallbackPrompt, !fallbackPrompt.isEmpty {
                activeOutboundPrompt = fallbackPrompt
                pendingOutboundPrompt = nil
                print("[PromptTrace] outgoing_answered: fallback promoted pendingPrompt→activePrompt len=\(activeOutboundPrompt!.count)")
            } else {
                print("[PromptTrace] outgoing_answered: WARN activePrompt=nil AND pendingPrompt=nil/empty — prompt will NOT be sent in hello!")
            }
        }

        // Guard: only proceed with AI WS/audio for calls explicitly initiated by the app.
        // App-managed outbound calls always have activeOutboundTaskID set via
        // setOutboundTaskContext(taskID:prompt:) before dialing. If neither a task ID
        // nor a non-empty prompt exists at this point, the call was placed manually by
        // the user (not via the app) — skip AI entirely and discard all further handling.
        if activeOutboundTaskID == nil {
            print("[OutboundRec][TaskID] ⚠️ outgoing_answered: activeOutboundTaskID=NIL — call_state(active) was likely missed; outboundCallId=\(outboundCallId?.uuidString ?? "NIL") — CallLog will NOT be associated with task or may not be saved!")
            // Also attempt fallback: promote pendingOutboundTaskID if available
            if let pendingID = pendingOutboundTaskID {
                print("[OutboundRec][TaskID] outgoing_answered: fallback promoting pendingOutboundTaskID=\(pendingID.uuidString) → activeOutboundTaskID")
                activeOutboundTaskID = pendingID
                pendingOutboundTaskID = nil
            }
        }
        let hasAppOutboundContext = (activeOutboundTaskID != nil) ||
            !(activeOutboundPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasAppOutboundContext else {
            print("[OutboundRec] outgoing_answered: no app context (manual call) — skip AI WS and audio_start")
            return
        }

        // Present LiveCallView only after callee answers. call_state(active) for outbound
        // can arrive while still ringing; activateOutgoingCallIfNeeded runs there but must
        // not set liveCallRequest (ContentView fullScreenCover).
        if currentIncomingCall == nil {
            activateOutgoingCallIfNeeded()
        }
        if let call = currentIncomingCall, call.title == "[OUTBOUND_TASK]" {
            liveCallRequest = call
        } else if currentIncomingCall == nil {
            print("[OutboundRec] outgoing_answered: WARN no outbound currentIncomingCall — LiveCall not presented")
        }

        // Connect WS now (deferred from activateOutgoingCallIfNeeded).
        // Always reconnect fresh — never reuse a lingering session from a previous call.
        // A stale session would carry the wrong context and drop the outbound prompt.
        switch transportCoordinator.planBLEOutgoingAnsweredWS(
            networkSatisfied: permissions.networkStatus == .satisfied
        ) {
        case .skipNetworkUnavailable:
            print("[OutboundRec] outgoing_answered: skip ws.connect (network unavailable)")
        case .connect:
            if shouldBlockBLEAutoReconnectAfterHello(context: "handleBLECallStateOutgoingAnswered") {
                print("[WS_RECONNECT_TRACE] block context=handleBLECallStateOutgoingAnswered action=skip_auto_reconnect")
            } else {
                bleWSConnectContext = .activeCall
                // Signal that WS connected for an already-active outbound call, so
                // planAfterWSConnect returns .startPendingActiveFlow → startConnectedFlow()
                // and the status transitions to .connected (instead of stalling at .ringing).
                pendingActiveConnect = true
                print("[PromptTrace] outgoing_answered .connect: calling setCallHelloPromptOverride len=\(activeOutboundPrompt?.count ?? -1) wsIsConnected=\(ws.isConnected) wsIsConnecting=\(ws.isConnecting)")
                if ws.isConnectedInCallScene || ws.isConnectedInCallOutboundScene {
                    // WS is already live in the correct call scene with a valid session.
                    // This happens when outgoing_answered fires for an incoming call (MCU quirk)
                    // or when the call-scene WS was established earlier (e.g., during ring).
                    // Do NOT reconnect — doing so sends a duplicate hello and breaks audio for
                    // both parties.
                    print("[WS_RECONNECT_TRACE] outgoing_answered: skip reconnect, already in valid call-scene WS (sessionId present)")
                } else {
                    if ws.isConnected || ws.isConnecting {
                        // Disconnect stale non-call-scene WS (e.g., lingering outbound-chat/config).
                        // This ensures the outbound call gets a fresh session with the correct prompt.
                        print("[WS_RECONNECT_TRACE] outgoing_answered: force disconnect stale ws before reconnect")
                        ws.disconnect()
                    }
                    let taskForApns = activeOutboundTaskID ?? pendingOutboundTaskID
                    ws.setHelloApnsRequestId(OutboundTaskQueueService.shared.apnsRequestId(forTask: taskForApns))
                    ws.setCallHelloPromptOverride(activeOutboundPrompt)
                    ws.setOutboundHelloContext(OutboundHelloContext(
                        targetPhone: outboundTargetPhone ?? "",
                        callerName: outboundCallerName ?? "",
                        taskGoal: outboundTaskGoal ?? ""
                    ))
                    transportCoordinator.markWSConnectStarted()
                    let audioFormat = bleWSAudioFormat
                    print("[OutboundRec] outgoing_answered: connecting WS audioFormat=\(audioFormat) scene=call_outbound")
                    ws.connect(audioFormat: audioFormat, scene: .callOutbound, reason: "handleBLECallStateOutgoingAnswered")
                }
            }
        }

        if !bleAudioStartAcked {
            latAudioStartSentAt = Date()
            latencyLog("send_audio_start_outgoing_answered")
            sendCallCommand("audio_start", extra: ["codec": bleMCUAudioCodecName], expectAck: false)
        }
        startAudioStartRetryLoop()
    }

    func promoteAckFromDownlinkIfNeeded() {
        guard !bleAudioStartAcked else { return }
        print("[NOSOUND] downlink_implies_ack: promoting bleAudioStartAcked (MCU is streaming, ACK was missed or late)")
        bleAudioStartAcked = true
        bleAudioStartAckAt = Date()
        audioRouter.cancelAudioStartRetryLoop()
        if bleCallActive {
            startAudioFlowWatchdog()
        }
        if audioRouter.hasUplinkData() {
            scheduleTTSUplinkDrain(reason: "downlink_implies_ack")
        }
    }

    func handleBLEAudioDownlinkOpus(_ opus: Data) {
        // Legacy Opus path (kept for rollback).
        traceMark("BLE_downlink_first_rx(opus)", store: &tBleFirstRxNs)
        bleHasAudio = true
        promoteAckFromDownlinkIfNeeded()
        nosoundDownlinkCount += 1
        // 录入本地录音（来话方/Caller - 左声道）
        audio.recordBLECallerOpus(opus, sampleRate: 16000)
        if wsListeningStarted {
            nosoundDownlinkToWS += 1
            if tWsFirstUpSendNs == nil {
                traceMark("WS_uplink_first_send(from_ble_opus)", store: &tWsFirstUpSendNs)
                traceLogDelta("BLE->WS_first_uplink", tBleFirstRxNs, tWsFirstUpSendNs)
            }
            ws.sendAudioData(opus)
        } else {
            nosoundDownlinkBuffered += 1
            bleAudioBuffer.append(opus)
            if bleAudioBuffer.count > bleAudioBufferLimitFrames {
                bleAudioBuffer.removeFirst(bleAudioBuffer.count - bleAudioBufferLimitFrames)
            }
        }
        let now = Date()
        if now.timeIntervalSince(nosoundLastDiagAt) >= 2.0 {
            nosoundLastDiagAt = now
            print("[NOSOUND] downlink: rx=\(nosoundDownlinkCount) toWS=\(nosoundDownlinkToWS) buffered=\(nosoundDownlinkBuffered) wsListening=\(wsListeningStarted) wsSession=\(ws.sessionId != nil) acked=\(bleAudioStartAcked) ttsQ=\(audioRouter.uplinkQueueCount()) blePending=\(ble.pendingAudioWriteCount)")
        }
    }


    func handleBLEAck(cmd: String, result: Int) {
        switch transportCoordinator.planBLEAck(cmd: cmd, result: result) {
        case .ignore:
            return
        case .phoneHandledRejected:
            print("[CallSession] cmd=\(cmd) rejected (phone handled). Exit live call.")
            remoteCallTerminalState = true
            phoneHandledCall = true
            audioRouter.cancelBLEAudioFlowTasks()
            end()
            return
        case .answerFailed(let ackResult):
            Task { @MainActor in
                AbnormalCallRecordStore.shared.append(reasonCode: "answer_failed", detail: "result=\(ackResult)")
            }
            return
        case .audioStartAccepted:
            handleBLEAudioStartAck(result: result)
        case .ignoreAccepted:
            print("[BLE] ack ignore result=\(result)")
        }
    }

    func handleBLEAudioStartAck(result: Int) {
        print("[BLE] ack audio_start result=\(result)")
        print("[NOSOUND] ack_audio_start result=\(result) wasAcked=\(bleAudioStartAcked)")
        guard result == 0 else { return }
        latAudioStartAckAt = Date()
        latencyLog("ack_audio_start_ok")
        bleAudioStartAcked = true
        bleAudioStartAckAt = Date()
        print("[NOSOUND] bleAudioStartAcked=true wsListening=\(wsListeningStarted) bleCallActive=\(bleCallActive) uplinkQ=\(audioRouter.uplinkQueueCount())")
        // Stop spamming audio_start once MCU accepted it.
        audioRouter.cancelAudioStartRetryLoop()
        // If call is active, watch for audio flow. Otherwise wait for call_state(active).
        if bleCallActive {
            startAudioFlowWatchdog()
        } else {
            print("[CallSession] audio_start acked but call not active yet; skip flow watchdog")
        }
        // Delay TTS uplink start slightly to allow MCU audio pipe to stabilize.
        ttsStartDelayTask?.cancel()
        ttsStartDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
            guard let self, !Task.isCancelled else { return }
            guard self.bleAudioStartAcked else { return }
            guard self.audioRouter.hasUplinkData() else { return }
            print("[TTS->BLE] audio_start ACK: delayed drain start (q=\(self.audioRouter.uplinkQueueCount()), ttsStopped=\(self.audioRouter.isTTSStopped()))")
            self.scheduleTTSUplinkDrain(reason: "audio_start_ack_delay")
        }
    }

    @discardableResult
    func handleCallStateDuringContactPassthrough(
        state: String,
        phase: CallTransportCoordinator.BLECallStatePhase
    ) -> Bool {
        guard contactPassthroughActive else { return false }
        let normalizedState = transportCoordinator.normalizeBLECallState(state)
        print("[OutboundRec] callState \"\(normalizedState)\" eaten by contactPassthroughActive=true")
        switch phase {
        case .phoneHandled, .terminal:
            let phoneHandledFlag = normalizedState == "phone_handled" ? 1 : 0
            let passthroughFlag = contactPassthroughActive ? 1 : 0
            let hfp = ble.runtimeSnapshot.deviceHFPState ?? "unknown"
            let wsConnectedFlag = ws.isConnected ? 1 : 0
            print("[CallSession] Event: Call ended (passthrough=\(passthroughFlag), phone_handled=\(phoneHandledFlag), hfp=\(hfp), ws=\(wsConnectedFlag))")
            // User/phone ended the call: always stop cloud session immediately.
            if ws.isConnected {
                ws.sendAbort(reason: "remote_call_ended")
                ws.disconnect()
            }
            wsListeningStarted = false
            contactPassthroughActive = false
            ignoredContactIncomingUIDs.removeAll()
            clearCallSessionSID(reason: "contact_passthrough_terminal_\(normalizedState)")
        case .active, .outgoingAnswered, .other:
            print("[CallSession] call_state ignored during contact passthrough state=\(state)")
        }
        return true
    }

    func handleBLECallEndPlan(_ plan: CallTransportCoordinator.BLECallEndPlan) {
        // Call ended before the session was ever established (e.g. hung up while ringing).
        // Signal waitForOutboundCallStart to break out immediately instead of timing out.
        if outboundCallId == nil, pendingOutboundTaskID != nil {
            outboundCallAborted = true
            pendingOutboundTaskID = nil
            pendingOutboundPrompt = nil
            print("[OutboundDial] call terminated before session started, outboundCallAborted=true")
        }
        if plan.markPhoneHandledCall {
            print("[CallSession] call_state=phone_handled, exit live call")
            if let currentIncomingCall {
                clearEmergencyBlockedNumber(currentIncomingCall.number)
            } else if let pendingIncomingCall {
                clearEmergencyBlockedNumber(pendingIncomingCall.number)
            } else if let lastSuppressedBlockedNumber {
                clearEmergencyBlockedNumber(lastSuppressedBlockedNumber)
                self.lastSuppressedBlockedNumber = nil
            }
            print("[CallSession] Incoming call notification removed (phone handled), suppress app control")
        }

        let hfp = ble.runtimeSnapshot.deviceHFPState ?? "unknown"
        let wsConnectedFlag = ws.isConnected ? 1 : 0
        print("[CallSession] Event: Call ended (passthrough=\(plan.eventPassthroughFlag), phone_handled=\(plan.eventPhoneHandledFlag), hfp=\(hfp), ws=\(wsConnectedFlag))")
        if ws.isConnected {
            ws.sendAbort(reason: plan.abortReason)
            ws.disconnect()
        }
        wsListeningStarted = false
        remoteCallTerminalState = true
        clearCallSessionSID(reason: plan.clearSIDReason)
        if plan.markPhoneHandledCall {
            phoneHandledCall = true
        }
        pickupDelayTask?.cancel()
        pickupDelayTask = nil
        if plan.clearPendingIncomingCall {
            pendingIncomingCall = nil
        }
        if plan.clearPendingActiveConnect {
            pendingActiveConnect = false
        }
        if plan.cancelBLEAudioFlowTasks {
            audioRouter.cancelBLEAudioFlowTasks()
        }
        if plan.setBLECallInactive {
            bleCallActive = false
        }
        end()
    }

    func startAudioStartRetryLoop() {
        guard inputSource == .ble else { return }
        audioRouter.startAudioStartRetryLoop(
            shouldRetry: { [weak self] in
                guard let self else { return false }
                if self.status == .ended { return false }
                if self.bleHasAudio { return false } // audio already flowing
                if self.bleAudioStartAcked { return false } // MCU already accepted; wait for audio flow watchdog
                return true
            },
            onRetry: { [weak self] in
                guard let self else { return }
                // Keep poking MCU to start downlink audio once it's in-call.
                self.sendCallCommand("audio_start", extra: ["codec": self.bleMCUAudioCodecName], expectAck: false)
            }
        )
    }

    func startAudioFlowWatchdog() {
        guard inputSource == .ble else { return }
        audioRouter.startAudioFlowWatchdog { [weak self] in
            guard let self else { return }
            guard self.status != .ended else { return }
            guard self.bleAudioStartAcked else { return }
            guard !self.bleHasAudio else { return }
            // Skip watchdog while TTS is actively being sent to the MCU.
            // Two conditions together guard the full TTS lifecycle:
            //   1. uplinkQueueCount > 0  — frames still waiting to be written to BLE
            //   2. !isTTSStopped()       — server hasn't yet signaled tts_stop
            //                              (queue may be empty but MCU is still playing)
            // This is the normal outbound-call scenario where the AI speaks first and
            // the callee hasn't yet had a chance to reply.  Firing audio_stop here would
            // send an audio_stop to the MCU mid-sentence, causing the callee to hear only
            // the first word before being cut off.
            guard self.audioRouter.uplinkQueueCount() == 0 && self.audioRouter.isTTSStopped() else {
                print("[CallSession] audio watchdog skip: TTS active q=\(self.audioRouter.uplinkQueueCount()) stopped=\(self.audioRouter.isTTSStopped())")
                return
            }
            // Emergency BGM uses uplink-only audio. No downlink within watchdog window is expected.
            // Don't reset audio path mid-clip, otherwise the remote side may hear truncated playback.
            let pendingSec = self.audioRouter.emergencyBGMPendingSeconds()
            if pendingSec > 0 {
                print(String(format: "[FASTCHK][iOS] watchdog skip during emergency_bgm pending=%.2fs",
                             pendingSec))
                return
            }
            guard !self.shouldSuppressBLEHangup else {
                print("[CallSession] audio watchdog exit: passthrough/phone_handled")
                return
            }

            self.audioFlowRestartAttempts += 1
            print("[CallSession] BLE audio not flowing after ack=0, restart attempt \(self.audioFlowRestartAttempts)")

            // Controlled restart: stop then start.
            if !self.shouldSuppressBLEHangup {
                self.sendCallCommand("audio_stop")
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                self.bleAudioStartAcked = false
                self.sendCallCommand("audio_start", extra: ["codec": self.bleMCUAudioCodecName], expectAck: false)
            } else {
                print("[CallSession] audio watchdog suppressed due to passthrough")
            }

            // If still nothing after a couple attempts, reset BLE link.
            if self.audioFlowRestartAttempts >= 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                if !self.bleHasAudio {
                    self.tryForceBLEReconnect(reason: "audio_watchdog_no_flow")
                }
            } else {
                // Re-arm watchdog for next attempt after we get ack.
                self.startAudioStartRetryLoop()
            }
        }
    }
}

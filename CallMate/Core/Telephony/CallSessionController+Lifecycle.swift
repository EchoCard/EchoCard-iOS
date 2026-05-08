import Foundation
import Network
import UserNotifications

// MARK: - Session Lifecycle

extension CallSessionController {
    func start(
        initMessages: [[String: String]]? = nil,
        evaluationChatHistory: [[String: String]]? = nil,
        autoPlayIntro: Bool = false
    ) {
        Self.activeControllerId = controllerId
        Self.activeController = self
        audio.delegate = self
        // Mic flows still call `ws.connect()` when NWPath is unsatisfied; never skip `addDelegate`
        // or a live socket may exist with no delegate while `connect()` later early-returns.
        ws.addDelegate(self)
        traceReset(reason: "start()")
        latencyManualSceneLog(
            "controller_start",
            extra: "autoPlayIntro=\(autoPlayIntro) initMessageCount=\(initMessages?.count ?? 0) evalHistoryCount=\(evaluationChatHistory?.count ?? 0)"
        )
        resetForSessionStartFlow()

        Task { [weak self] in
            guard let self else { return }
            if self.inputSource == .microphone {
                // init_config / update_config / evaluation / outbound_chat：按住说话时再请求麦克风（审核 + 体验）。
                // `.call` 模拟通话仍在本阶段请求，便于接通后立即采集。
                if !self.scene.isManualInteractionScene {
                    _ = await self.audio.requestMicrophonePermission()
                    self.latencyManualSceneLog("mic_permission_resolved")
                    if self.scene == .call {
                        self.audio.enableSpeaker(self.isSpeaker)
                    }
                }
            }
            if self.inputSource == .ble && self.contactPassthroughActive {
                print("[CallSession] start(): skip ws.connect due to passthrough")
                return
            }
            if self.inputSource == .ble && self.permissions.networkStatus != .satisfied {
                print("[CallSession] start(): skip ws.connect due to network unavailable")
                return
            }
            self.transportCoordinator.markWSConnectStarted()
            self.bleWSConnectContext = (self.inputSource == .ble) ? .incomingCall : .none
            let audioFormat = self.inputSource == .ble ? self.bleWSAudioFormat : .opus
            print("[CallSession] start(): connecting WS with audioFormat=\(audioFormat)")
            self.latencyManualSceneLog("ws_connect_begin", extra: "audioFormat=\(audioFormat)")
            self.applyPhoneIDContextForWS()
            self.ws.connect(
                audioFormat: audioFormat,
                scene: self.scene,
                initMessages: initMessages,
                evaluationChatHistory: evaluationChatHistory,
                autoPlayIntro: autoPlayIntro
            )
        }
    }

    /// Start a "real" session driven by MCU BLE events (incoming_call/call_state/audio).
    func startFromIncomingCall(_ call: CallMateIncomingCall) {
        guard inputSource == .ble else { return }
        if contactPassthroughActive {
            print("[CallSession] startFromIncomingCall suppressed due to passthrough uid=\(call.uid)")
            return
        }
        Self.activeControllerId = controllerId
        Self.activeController = self
        audio.delegate = self
        ws.addDelegate(self)
        // Offline local playback test should take over this call.
        if UserDefaults.standard.bool(forKey: "ble_local_uplink_test_armed") ||
            UserDefaults.standard.bool(forKey: "ble_local_uplink_test_in_progress") {
            print("[CallSession] startFromIncomingCall aborted (offline local test armed/in_progress) uid=\(call.uid)")
            return
        }
        traceReset(reason: "startFromIncomingCall(uid=\(call.uid))")
        currentIncomingCall = call
        bindCallSession(from: call)
        latIncomingAt = Date()
        latencyLog("incoming_call_startFromIncomingCall", uid: call.uid)
        resetForIncomingCallFlow(
            resetPendingIncomingCall: true,
            resetPendingActiveConnect: true
        )
        // Critical: drop any leftover BLE uplink backlog from the previous call,
        // otherwise the next call starts by sending stale audio -> extra latency.
        ble.dropPendingAudioWrites(reason: "startFromIncomingCall")

        // Ensure BLE is connected/ready, then answer.
        ble.autoConnectIfPossible()
        scheduleAutoAnswerForIncomingCall(call)

        // Clear stale outbound prompt state so incoming call never inherits
        // a previous outbound task's prompt via callHelloPromptOverride.
        pendingOutboundPrompt = nil
        activeOutboundPrompt = nil
        ws.setCallHelloPromptOverride(nil)
        ws.setHelloApnsRequestId(nil)

        if permissions.networkStatus == .satisfied {
            transportCoordinator.markWSConnectStarted()
            bleWSConnectContext = .incomingCall
            let audioFormat = bleWSAudioFormat
            print("[CallSession] startFromIncomingCall: connecting WS with audioFormat=\(audioFormat)")
            applyIncomingCallContextToWS(call)
            ws.connect(audioFormat: audioFormat, scene: .call)
        } else {
            print("[CallSession] startFromIncomingCall: skip ws.connect due to network unavailable")
        }
        syncLiveActivity()

        // Start retrying audio_start in case call_state(active) is delayed/missed.
        startAudioStartRetryLoop()
    }

    /// Persist outbound call recording and transcript to SwiftData.
    /// Called automatically when an outbound call session ends.
    func persistOutboundCallIfNeeded() {
        guard let callId = outboundCallId,
              let startedAt = outboundCallStartedAt else {
            print("[OutboundRec] persistOutbound: skip (no active outbound session, outboundCallId=\(outboundCallId?.uuidString ?? "nil"))")
            return
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        print("[OutboundRec] persistOutbound: ending session callId=\(callId) elapsed=\(elapsed)s duration=\(duration)s messages=\(messages.count)")
        outboundCallId = nil
        outboundCallStartedAt = nil
        let outboundTaskID = activeOutboundTaskID
        print("[OutboundRec][TaskID] persistOutbound: activeOutboundTaskID=\(activeOutboundTaskID?.uuidString ?? "⚠️ NIL") → will be saved on CallLog")
        activeOutboundTaskID = nil
        activeOutboundPrompt = nil

        let recordingFileName = audio.endConversationRecording()
        print("[OutboundRec] persistOutbound: recordingFileName=\(recordingFileName ?? "nil")")
        let number = currentIncomingCall?.number ?? ble.lastDialedNumber ?? ""
        print("[OutboundRec][Phone] persistOutbound: number='\(number)' (currentIncomingCall.number='\(currentIncomingCall?.number ?? "nil")' lastDialedNumber='\(ble.lastDialedNumber ?? "nil")')")
        let sid = wsSessionId
        summaryCoordinator.persistOutboundCall(
            .init(
                callId: callId,
                startedAt: startedAt,
                endedAt: Date(),
                duration: duration,
                messages: messages.map { .init(text: $0.text, isAI: $0.isAI, time: $0.time) },
                number: number,
                language: language,
                outboundTaskID: outboundTaskID,
                wsSessionId: sid,
                errorMessage: lastErrorMessage,
                recordingFileName: recordingFileName
            )
        )
    }

    func end(abortReason: String = "user_interrupt") {
        // Capture ownership before clearing — another controller (e.g. sharedBLE
        // outbound) may have already claimed activeController; if so we must NOT
        // tear down the shared WebSocket or it kills their session.
        let wasActiveController = (Self.activeControllerId == controllerId)
        print("[OutboundRec] end() called: abortReason=\(abortReason) status=\(status) outboundCallId=\(outboundCallId?.uuidString ?? "nil") wasActive=\(wasActiveController)")
        persistOutboundCallIfNeeded()
        releaseMicGuardForTTS()
        audioRouter.cancelWSDisconnectDrainPlaybackTask()
        manualListenStartTask?.cancel()
        manualListenStartTask = nil
        bleWSDisconnectReactionTask?.cancel()
        bleWSDisconnectReactionTask = nil
        aiHangupReactionTask?.cancel()
        aiHangupReactionTask = nil
        if Self.activeControllerId == controllerId {
            Self.activeControllerId = nil
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
        pickupDelayTask?.cancel()
        pickupDelayTask = nil
        emergencyPlaybackTask?.cancel()
        emergencyPlaybackTask = nil
        ws.removeDelegate(self)
        audioRouter.stopForSessionEnd(inputSource: inputSource)
        if inputSource == .ble {
            // Best-effort: stop device audio stream and hang up.
            // Also drop any queued uplink audio so we don't leak stale audio into next call.
            ble.dropPendingAudioWrites(reason: "end()")
            if remoteCallTerminalState || suppressHangupOnce {
                print("[CallSession] end(): suppressing hangup/audio_stop (terminal/passthrough)")
                suppressHangupOnce = false
            } else if shouldSuppressBLEHangup {
                // Human handoff path: keep the phone call alive, but always stop AI audio stream.
                // Without this, MCU may keep previous audio pipeline state and next AI takeover
                // can become silent until a full state reset.
                print("[CallSession] end(): passthrough -> send audio_stop only")
                sendCallCommand("audio_stop", expectAck: false)
                ble.stopRateMonitorForLocalTeardown(reason: "passthrough_end")
            } else {
                // Fire-and-forget: don't wait for ACK during teardown.
                // BLE notify ACK can be lost under load, causing 5x1s retry stalls.
                sendCallCommand("audio_stop", expectAck: false)
                sendCallCommand("hangup", expectAck: false)
            }
        }
        stopBLEBackgroundSupport(reason: "end()")
        if wasActiveController {
            ws.sendAbort(reason: abortReason)
            ws.disconnect()
        } else {
            print("[CallSession] end(): skip ws.sendAbort/disconnect (another controller owns WS)")
        }
        audioRouter.cancelBLEAudioFlowTasks()
        transportCoordinator.resetNoHelloRetryCount()
        transportCoordinator.cancelNoHelloRetryTask()
        emergencyLiveActivityText = nil
        transportCoordinator.clearWSConnectionMarkers()
        bleWSConnectContext = .none
        transportCoordinator.resetWSReconnectAttempts()
        stopTTSUplinkTimer()
        durationTask?.cancel()
        durationTask = nil
        resetForSessionEndFlow()
    }

    func resetForSessionStartFlow() {
        // Defensive cleanup in case previous session ended abnormally.
        // Cancel any stale drain tasks from a previous session (e.g. outbound_chat TTS drain
        // that was still polling) to prevent them from calling audio.stopPlayback() mid-call.
        if let prev = Self.activeController, prev !== self {
            prev.audioRouter.cancelTTSStopPlaybackTask()
            prev.audioRouter.cancelWSDisconnectDrainPlaybackTask()
        }
        audio.stopPlayback()
        releaseMicGuardForTTS()
        status = CallStateMachine.reduce(status, event: .startRequested)
        duration = 0
        hasReceivedWSHelloInCurrentCall = false
        lastErrorMessage = nil
        latAnswerSentAt = nil
        hasReceivedWSHelloInCurrentCall = false
        callConnectedAt = nil
        wsQuickDisconnectToastShown = false
        isAIHangup = false
        pendingRuleChange = nil
        pendingGuideImage = nil
        pendingGuideCard = nil
        messages.removeAll()
        currentTTSText = ""
        currentSTTText = ""
        ttsStreamBuffer.reset()
        currentIncomingCall = nil
        emergencyLiveActivityText = nil
        CallLiveActivityManager.shared.clearResidentEmergencySummary()
        wsListeningStarted = false
        bleAudioBuffer.removeAll()
        bleAudioStartAckAt = nil
        ttsStartDelayTask?.cancel()
        ttsStartDelayTask = nil
        emergencyPlaybackTask?.cancel()
        emergencyPlaybackTask = nil
        emergencyNotifyAttemptCount = 0
        didTriggerEmergencyNotifyInCurrentCall = false
        didSendAudioResetForCurrentCall = false
    }

    func resetForSessionEndFlow() {
        releaseMicGuardForTTS()
        status = CallStateMachine.reduce(status, event: .endRequested)
        syncLiveActivity()
        latAnswerSentAt = nil
        callConnectedAt = nil
        wsQuickDisconnectToastShown = false
        bleCallActive = false
        bleAudioStartAcked = false
        bleAudioStartAckAt = nil
        bleHasAudio = false
        phoneHandledCall = false
        nosoundDownlinkCount = 0
        nosoundDownlinkToWS = 0
        nosoundDownlinkBuffered = 0
        nosoundLastDiagAt = .distantPast
        currentIncomingCall = nil
        liveCallRequest = nil
        pendingIncomingCall = nil
        pendingActiveConnect = false
        aiAnswerRequested = false
        aiAnswerRequestUID = nil
        remoteCallTerminalState = false
        emergencyNotifyAttemptCount = 0
        didSendAudioResetForCurrentCall = false
        pendingOutboundPrompt = nil
        activeOutboundPrompt = nil
        pendingOutboundTaskID = nil
        activeOutboundTaskID = nil
        clearCallSessionSID(reason: "end")
    }

    func resetForIncomingCallFlow(
        resetPendingIncomingCall: Bool,
        resetPendingActiveConnect: Bool
    ) {
        // Cancel any stale drain tasks from a previous session to prevent stale
        // ttsStopPlaybackTask from interrupting this call's TTS audio.
        if let prev = Self.activeController, prev !== self {
            prev.audioRouter.cancelTTSStopPlaybackTask()
            prev.audioRouter.cancelWSDisconnectDrainPlaybackTask()
        }
        audio.stopPlayback()
        releaseMicGuardForTTS()
        didCountIncomingCall = false
        status = CallStateMachine.reduce(status, event: .incomingCallReceived)
        duration = 0
        hasReceivedWSHelloInCurrentCall = false
        lastErrorMessage = nil
        latAnswerSentAt = nil
        callConnectedAt = nil
        wsQuickDisconnectToastShown = false
        isAIHangup = false
        pendingRuleChange = nil
        pendingGuideImage = nil
        pendingGuideCard = nil
        messages.removeAll()
        currentTTSText = ""
        currentSTTText = ""
        ttsStreamBuffer.reset()
        emergencyLiveActivityText = nil
        CallLiveActivityManager.shared.clearResidentEmergencySummary()
        wsListeningStarted = false
        bleAudioBuffer.removeAll()
        bleHasAudio = false
        bleCallActive = false
        phoneHandledCall = false
        aiAnswerRequested = false
        aiAnswerRequestUID = nil
        audioRouter.cancelAudioStartRetryLoop()
        bleAudioStartAcked = false
        bleAudioStartAckAt = nil
        ttsStartDelayTask?.cancel()
        ttsStartDelayTask = nil
        isFirstTTSInCall = true
        remoteCallTerminalState = false
        lastCloudSTTRxAt = nil
        pendingCloudSTTForTTS = false
        audioRouter.cancelAudioFlowWatchdog()
        audioFlowRestartAttempts = 0
        transportCoordinator.resetWSReconnectAttempts()
        transportCoordinator.clearWSConnectionMarkers()
        transportCoordinator.resetNoHelloRetryCount()
        transportCoordinator.cancelNoHelloRetryTask()
        suppressHangupOnce = false
        emergencyNotifyAttemptCount = 0
        didTriggerEmergencyNotifyInCurrentCall = false
        emergencyPlaybackTask?.cancel()
        emergencyPlaybackTask = nil
        didSendAudioResetForCurrentCall = false
        pendingOutboundPrompt = nil
        activeOutboundPrompt = nil
        stopTTSUplinkTimer()
        if resetPendingIncomingCall {
            pendingIncomingCall = nil
        }
        if resetPendingActiveConnect {
            pendingActiveConnect = false
        }
    }

    func scheduleAutoAnswerForIncomingCall(_ call: CallMateIncomingCall) {
        pickupDelayTask?.cancel()
        let defaults = UserDefaults.standard
        let delaySeconds: Int = {
            if defaults.object(forKey: "callmate.pickup_delay") == nil {
                return 5
            }
            return max(0, defaults.integer(forKey: "callmate.pickup_delay"))
        }()
        pickupDelayTask = Task { [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.status == .ringing else { return }
            guard !self.phoneHandledCall else { return }
            guard self.permissions.networkStatus == .satisfied else {
                print("[CallSession] answer skipped: network unavailable, send ignore uid=\(call.uid)")
                Task { @MainActor in
                    AbnormalCallRecordStore.shared.append(reasonCode: "network_unavailable")
                }
                self.sendCallCommand("ignore", uid: call.uid)
                return
            }
            await self.ensureHFPReadyBeforeAnswerIfNeeded()
            guard !Task.isCancelled, !self.phoneHandledCall else {
                print("[CallSession] BLE auto-answer aborted after HFP wait (cancelled=\(Task.isCancelled) phoneHandled=\(self.phoneHandledCall)) uid=\(call.uid)")
                return
            }
            self.aiAnswerRequested = true
            self.aiAnswerRequestUID = call.uid
            self.latAnswerSentAt = Date()
            self.latencyLog("send_answer", uid: call.uid)
            print("[CallSession] BLE auto-answer send uid=\(call.uid)")
            self.sendCallCommand("answer", uid: call.uid)
            self.scheduleAIAnsweredNotificationIfNeeded(call: call)
        }
    }

    /// 接听瞬间触发「AI 已代接」本地通知，与 LiveCallView 使用同一 identifier（按 uid）避免重复。
    private func scheduleAIAnsweredNotificationIfNeeded(call: CallMateIncomingCall) {
        let identifier = "live_transcript_\(call.uid)"
        let body = language == .zh
            ? "AI分身已接听当前来电，点击查看实时转写。"
            : "AI has answered the call. Tap to view live transcript."
        let content = UNMutableNotificationContent()
        content.title = language == .zh ? "来电代接" : "Call screening"
        content.body = body
        content.sound = .default
        content.threadIdentifier = identifier
        content.userInfo = [
            "live_transcript_call": "1",
            "call_id": "",  // 接通瞬间尚无 CallLog，点击时用 pendingShowLiveCall 拉起通话页
            "ws_session_id": wsSessionId ?? ""
        ]
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[CallSession] AI answered notification failed: \(error.localizedDescription)")
            } else {
                print("[CallSession] AI answered notification sent uid=\(call.uid)")
            }
        }
    }

    func startConnectedFlow() {
        status = CallStateMachine.reduce(status, event: .callConnected)
        if callConnectedAt == nil {
            callConnectedAt = Date()
        }
        syncLiveActivity()
        startDurationTimer()
        if !scene.isManualInteractionScene {
            startListening()
        }
    }

    func prepareIncomingCall(_ call: CallMateIncomingCall) {
        pendingIncomingCall = call
        bindCallSession(from: call)
        latIncomingAt = Date()
        latencyLog("incoming_call_prepare", uid: call.uid)
        resetForIncomingCallFlow(
            resetPendingIncomingCall: false,
            resetPendingActiveConnect: false
        )
        ble.dropPendingAudioWrites(reason: "prepareIncomingCall")
        print("[CallSession] reset incoming-call flags uid=\(call.uid) phoneHandled=\(phoneHandledCall) aiAnswerRequested=\(aiAnswerRequested)")
        syncLiveActivity()

        // Ensure BLE is connected/ready, then answer.
        ble.autoConnectIfPossible()
        scheduleAutoAnswerForIncomingCall(call)
    }

    func activatePendingCallIfNeeded() {
        guard let call = pendingIncomingCall else { return }
        liveCallRequest = call
        pendingActiveConnect = true
        Self.activeControllerId = controllerId
        Self.activeController = self
        audio.delegate = self
        ws.addDelegate(self)
        traceReset(reason: "activatePendingCall(uid=\(call.uid))")
        currentIncomingCall = call
        bindCallSession(from: call)
        wsListeningStarted = false
        // Clear stale outbound prompt state — this is an incoming call activation.
        pendingOutboundPrompt = nil
        activeOutboundPrompt = nil
        ws.setCallHelloPromptOverride(nil)
        ws.setHelloApnsRequestId(nil)
        status = CallStateMachine.reduce(status, event: .startRequested)
        syncLiveActivity()
        if permissions.networkStatus == .satisfied {
            bleWSConnectContext = .activeCall
            if ws.isConnected, ws.sessionId != nil {
                // WS was already established from incoming_call stage.
                syncWSSessionIdFromService(reason: "activatePendingCall_ifAlreadyConnected")
                transportCoordinator.markWSHelloReceived()
                pendingActiveConnect = false
                startConnectedFlow()
            } else {
                if shouldBlockBLEAutoReconnectAfterHello(context: "activatePendingCallIfNeeded") {
                    print("[WS_RECONNECT_TRACE] block context=activatePendingCallIfNeeded action=skip_auto_reconnect")
                    return
                }
                transportCoordinator.markWSConnectStarted()
                let audioFormat = bleWSAudioFormat
                print("[CallSession] activatePendingCall: connecting WS with audioFormat=\(audioFormat)")
                applyPhoneIDContextForWS()
                ws.connect(audioFormat: audioFormat, scene: .call, reason: "activatePendingCallIfNeeded")
            }
            startAudioStartRetryLoop()
        } else {
            print("[CallSession] activatePendingCall: skip ws.connect due to network unavailable")
        }
    }

    func activateOutgoingCallIfNeeded() {
        guard inputSource == .ble else {
            print("[OutboundRec] activateOutgoing: skip (inputSource != ble)")
            return
        }
        guard pendingIncomingCall == nil else {
            print("[OutboundRec] activateOutgoing: skip (pendingIncomingCall != nil)")
            return
        }

        // Skip entirely for manual outgoing calls not initiated by the app.
        // Context lives in pending* before the first activate; after promotion it is only in active*.
        // MCU may emit `call_state(active)` more than once — the second time pending* is nil and
        // must still count as app-managed or we mis-detect "manual call" and skip the whole path.
        let pendingPrompt = pendingOutboundPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let activePrompt = activeOutboundPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAppManaged = pendingOutboundTaskID != nil || !pendingPrompt.isEmpty
            || activeOutboundTaskID != nil || !activePrompt.isEmpty
        guard isAppManaged else {
            print("[OutboundRec] activateOutgoing: no app context (manual call) — skip session setup")
            return
        }

        print("[OutboundRec] activateOutgoing: status=\(status) lastDialedNumber=\(ble.lastDialedNumber ?? "nil")")

        // Cancel any stale drain tasks from a previous session (e.g. outbound_chat)
        // and stop its audio before this call takes over the shared AudioService.
        if let prev = Self.activeController, prev !== self {
            prev.audioRouter.cancelTTSStopPlaybackTask()
            prev.audioRouter.cancelWSDisconnectDrainPlaybackTask()
        }
        audio.stopPlayback()

        Self.activeControllerId = controllerId
        Self.activeController = self
        audio.delegate = self
        ws.addDelegate(self)

        // One outbound session per dial: if active arrives while status is already .connecting
        // (e.g. another path set startRequested, or event ordering), we must still create
        // currentIncomingCall / outboundCallId — do not gate only on status == .ended.
        guard outboundCallId == nil else {
            print("[OutboundRec] activateOutgoing: outbound session already started outboundCallId=\(outboundCallId!.uuidString)")
            return
        }

        if status == .ended {
            status = CallStateMachine.reduce(status, event: .startRequested)
        }

        duration = 0
        messages.removeAll()
        currentTTSText = ""
        currentSTTText = ""
        ttsStreamBuffer.reset()
        wsListeningStarted = false
        bleAudioStartAcked = false
        bleAudioStartAckAt = nil
        bleHasAudio = false
        bleCallActive = false
        bleAudioBuffer.removeAll()
        audioFlowRestartAttempts = 0
        audioRouter.cancelBLEAudioFlowTasks()
        remoteCallTerminalState = false
        phoneHandledCall = false
        ttsStartDelayTask?.cancel()
        ttsStartDelayTask = nil
        isFirstTTSInCall = true
        audioRouter.resetUplinkState()
        ttsAudioRxCount = 0
        didSendAudioResetForCurrentCall = false
        // Reset sticky hello flag so outgoing_answered always gets a fresh WS connect.
        // Without this, a previous call's hello marker survives into the next outbound
        // session and causes shouldBlockBLEAutoReconnectAfterHello to return true even
        // though ws.isConnected=false, blocking ws.connect() and dropping the hello.
        hasReceivedWSHelloInCurrentCall = false
        transportCoordinator.clearWSConnectionMarkers()
        syncLiveActivity()

        let number = ble.lastDialedNumber ?? ""
        let outboundCall = CallMateIncomingCall(
            uid: -1,
            title: "[OUTBOUND_TASK]",
            caller: number,
            number: number,
            isContact: false,
            sid: nil
        )
        currentIncomingCall = outboundCall
        // liveCallRequest is set from handleBLECallStateOutgoingAnswered only, so the
        // live transcript UI opens after the callee answers — not during dial/ring.

        let callId = UUID()
        outboundCallId = callId
        outboundCallStartedAt = Date()
        print("[OutboundDiag] outbound_session_started epoch=\(outboundDiagEpoch) outboundCallId=\(callId.uuidString) seen_outgoing_answered=\(outboundDiagReceivedOutgoingAnswered)")
        print("[OutboundRec][TaskID] activateOutgoing: pendingOutboundTaskID=\(pendingOutboundTaskID?.uuidString ?? "⚠️ NIL") → promoting to activeOutboundTaskID")
        activeOutboundTaskID = pendingOutboundTaskID
        activeOutboundPrompt = pendingOutboundPrompt
        pendingOutboundTaskID = nil
        pendingOutboundPrompt = nil
        print("[PromptTrace] activateOutgoing: promoted pendingPrompt→activePrompt len=\(activeOutboundPrompt?.count ?? -1) empty=\(activeOutboundPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)")
        audio.beginConversationRecording(callId: callId)
        print("[OutboundRec] recording started: callId=\(callId) number=\(number)")

        // Do NOT connect WS here for outgoing calls.
        // WS hello is deferred until MCU sends call_state("outgoing_answered")
        // confirming the callee actually picked up (ANCS "当前通话").
        // This avoids creating an AI cloud session while the phone is still ringing.
    }

    func startDurationTimer() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.status == .connected {
                    self.duration += 1
                    self.syncLiveActivity()
                }
            }
        }
    }

    func startListening() {
        if isMuted {
            print("[CloudAudioProof] startListening BLOCKED isMuted=true")
            print("[NOSOUND] startListening BLOCKED: isMuted=true")
            return
        }
        syncWSSessionIdFromService(reason: "startListening")
        guard status == .connected else {
            print("[CloudAudioProof] startListening BLOCKED status=\(status) (need .connected) — listen will not be sent")
            return
        }
        if ws.sessionId == nil {
            print("[CloudAudioProof] startListening BLOCKED ws.sessionId=nil wsConnected=\(ws.isConnected)")
            print("[NOSOUND] startListening BLOCKED: ws.sessionId=nil wsConnected=\(ws.isConnected)")
            return
        }
        guard !wsListeningStarted else {
            print("[CloudAudioProof] startListening SKIP already_started=true")
            return
        }

        let mode: ListenMode = scene.isManualInteractionScene ? .manual : .realtime
        print("[CloudAudioProof] startListening invoking sendListenStart mode=\(mode.rawValue) scene=\(scene)")
        ws.sendListenStart(mode: mode)
        wsListeningStarted = true
        print("[CloudAudioProof] startListening OK wsListeningStarted=true mode=\(mode.rawValue)")
        print("[NOSOUND] startListening OK: wsListeningStarted=true mode=\(mode) bleAudioBuf=\(bleAudioBuffer.count)")
        print("[MIC_CHAIN] ws_listen_started: mode=\(mode) source=\(inputSource) micGuard=\(micMutedByTTSGuard) isMicMuted=\(audio.isMicMuted)")
        print("[CallSession] wsListeningStarted=true (source=\(inputSource))")

        // Flush buffered BLE audio (caller voice) after listen starts.
        if inputSource == .ble, !bleAudioBuffer.isEmpty {
            let flushed = bleAudioBuffer.count
            for frame in bleAudioBuffer {
                ws.sendAudioData(frame)
            }
            bleAudioBuffer.removeAll()
            print("[NOSOUND] flushed \(flushed) buffered BLE frames to WS")
        }
        if inputSource == .microphone {
            // 模拟通话场景启用回声消除，配置场景不启用
            let enableEchoCancellation = (scene == .call)
            try? audio.startRecording(enableEchoCancellation: enableEchoCancellation)
        }
    }

    func beginManualListen() {
        guard scene.isManualInteractionScene else {
            startListening()
            return
        }
        manualPressActive = true
        guard !isMuted else { return }
        // AI secretary WS may be dropped by server after idle timeout.
        // If user presses-to-talk while disconnected, reconnect first.
        let wsReady = ws.isConnected && ws.sessionId != nil
        if !wsReady {
            reconnectWebSocketForManualListenIfNeeded()
            return
        }
        guard status == .connected else { return }
        if wsListeningStarted {
            return
        }
        if audio.isRecording {
            return
        }
        // Only throttle rapid repeated starts; do NOT throttle stop path.
        // Otherwise quick press-release can miss `listen_stop` and appear stuck.
        let now = Date()
        if let last = lastManualToggleAt, now.timeIntervalSince(last) < 0.1 {
            return
        }
        lastManualToggleAt = now
        if monitorTTSOnPhone {
            // Keep UX immediate on server side, but debounce local audio engine ops.
            audioRouter.cancelTTSStopPlaybackTask()
            ws.sendAbort()
        }
        // Keep UI/session immediate. Only audio engine start is debounced.
        ws.sendListenStart(mode: .manual)
        wsListeningStarted = true
        print("[CallSession] manual listen start")

        // Delay audio engine start slightly to filter fast taps.
        // This avoids rapid AudioUnit start/stop churn (vpio render err -1).
        manualListenStartTask?.cancel()
        manualListenStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms hold threshold (reduced from 150ms)
            guard let self, !Task.isCancelled else { return }
            guard self.scene.isManualInteractionScene else { return }
            guard self.wsListeningStarted else { return }
            guard !self.audio.isRecording else { return }
            // Cool down a bit after previous stop to avoid rapid VP I/O unit churn.
            if let lastStop = self.manualLastRecordingStopAt {
                let dt = Date().timeIntervalSince(lastStop)
                let cooldown: TimeInterval = 0.15
                if dt < cooldown {
                    let remain = cooldown - dt
                    try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    guard self.wsListeningStarted else { return }
                }
            }
            if self.monitorTTSOnPhone, self.audio.isPlaying {
                self.audio.stopPlayback()
            }
            let micOK = await self.audio.requestMicrophonePermission()
            // 系统授权对话框是模态的：用户可能在弹窗期间松开手指（endManualListen 已发了 listen_stop
            // 并 cancel 了本任务，但 await 不会被打断）。授权返回后必须重新校验，否则会启动一个
            // 孤儿录音，把 audio session 推到错误路由，导致后续 TTS 没声音、再次按住因为
            // audio.isRecording==true 而被早返回。
            guard !Task.isCancelled,
                  self.manualPressActive,
                  self.wsListeningStarted else {
                print("[CallSession] manual listen: press released during mic prompt — skip startRecording")
                self.manualListenStartTask = nil
                return
            }
            guard micOK else {
                print("[CallSession] manual listen: microphone permission denied — cancelling listen")
                self.ws.sendListenStop()
                self.wsListeningStarted = false
                self.manualListenStartTask = nil
                return
            }
            // 配置场景（update_config/init_config）不需要回声消除
            try? self.audio.startRecording(enableEchoCancellation: false)
            self.manualListenStartTask = nil
        }
    }

    func endManualListen() {
        guard scene.isManualInteractionScene else { return }
        manualPressActive = false
        manualReconnectPending = false
        // Fast tap release before hold-threshold: just cancel pending start.
        if manualListenStartTask != nil {
            manualListenStartTask?.cancel()
            manualListenStartTask = nil
        }
        guard wsListeningStarted else { return }
        // Never debounce stop; release must always terminate recording/listen.
        lastManualToggleAt = Date()
        ws.sendListenStop()
        wsListeningStarted = false
        if audio.isRecording {
            audio.stopRecording()
            manualLastRecordingStopAt = Date()
        }
        print("[CallSession] manual listen stop")
    }

    func reconnectWebSocketForManualListenIfNeeded() {
        guard inputSource == .microphone else { return }
        guard scene.isManualInteractionScene else { return }
        guard !ws.isConnected || ws.sessionId == nil else { return }
        guard !manualReconnectInFlight else { return }

        manualReconnectPending = true
        manualReconnectInFlight = true

        // `end()` clears active-controller/delegate; restore them before reconnecting.
        Self.activeControllerId = controllerId
        Self.activeController = self
        audio.delegate = self
        ws.addDelegate(self)

        transportCoordinator.markWSConnectStarted()
        status = .connecting
        print("[CallSession] manual listen: WS disconnected, reconnecting...")
        applyPhoneIDContextForWS()
        ws.connect(audioFormat: .opus, scene: scene)
    }

    func hfpLooksReadyForAnswer() -> Bool {
        let state = (ble.runtimeSnapshot.deviceHFPState ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if state.isEmpty { return false }
        return state == "connected" || state == "ringing" || state == "active" || state == "callin" || state == "callout"
    }

    func ensureHFPReadyBeforeAnswerIfNeeded() async {
        guard inputSource == .ble else { return }
        if hfpLooksReadyForAnswer() {
            return
        }
        let current = ble.runtimeSnapshot.deviceHFPState ?? "unknown"
        print("[CallSession] HFP not ready for answer (state=\(current)), send hfp_connect and wait")
        ble.sendCommand("hfp_connect", expectAck: false)
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
        let after = ble.runtimeSnapshot.deviceHFPState ?? "unknown"
        print("[CallSession] HFP state after pre-answer connect wait: \(after)")
    }
}

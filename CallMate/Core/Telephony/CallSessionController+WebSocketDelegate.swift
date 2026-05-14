import Foundation

// MARK: - WebSocketServiceDelegate

extension CallSessionController: WebSocketServiceDelegate {
    func webSocketDidConnect(sessionId: String) {
        hasReceivedWSHelloInCurrentCall = true
        guard isActiveController else {
            print("[CloudAudioProof] delegate_ws_hello_ack_pre_active sessionId_prefix=\(String(sessionId.prefix(12)))… status=\(status) scene=\(scene) note=sticky_hello_marked_for_future_reconnect")
            return
        }
        continuousBleDownlinkSessionPrepared = false
        if usesContinuousCloudDownlinkCallAudio {
            ttsAudioRxCount = 0
            ttsAudioRxBytes = 0
            ttsBinaryRxBatchStartAt = nil
            ttsBinaryRxBatchStartPendingFrames = 0
        }
        print("[CloudAudioProof] delegate_ws_hello_ack sessionId_prefix=\(String(sessionId.prefix(12)))… bleCallActive=\(bleCallActive) bleAudAck=\(bleAudioStartAcked) pendingActiveConnect=\(pendingActiveConnect) status=\(status) scene=\(scene) wsListenAlready=\(wsListeningStarted)")
        print("[NOSOUND] ws_connected: sessionId=\(sessionId) bleCallActive=\(bleCallActive) acked=\(bleAudioStartAcked) wsListening=\(wsListeningStarted)")
        print("[WS_RECONNECT_TRACE] hello_seen sticky=true source=webSocketDidConnect")
        latencyManualSceneLog("ws_hello_ack", extra: "sessionId=\(sessionId)")
        bleWSDisconnectReactionTask?.cancel()
        bleWSDisconnectReactionTask = nil
        manualReconnectInFlight = false
        wsSessionId = sessionId
        transportCoordinator.prepareForWSConnect()
        if inputSource == .ble {
            bleWSConnectContext = bleCallActive ? .activeCall : .incomingCall
        }
        let connectPlan = transportCoordinator.planAfterWSConnect(
            status: status,
            inputSource: inputSource,
            pendingActiveConnect: pendingActiveConnect
        )
        // Don't force ringing if BLE has already moved us to connected.
        if connectPlan.setRinging {
            status = CallStateMachine.reduce(status, event: .incomingCallReceived)
            syncLiveActivity()
        }
        if handleWSConnectBLEAction(connectPlan.bleAction) {
            scheduleCloudAudioProofWatchdog()
            return
        }
        handleWSConnectMicrophoneFlowIfNeeded()
        scheduleCloudAudioProofWatchdog()
    }

    /// 定时打印：区分「云端从未下发 TTS/二进制」vs「已下发但 BLE 未出声」。
    private func scheduleCloudAudioProofWatchdog() {
        Task { @MainActor [weak self] in
            for sec in [5, 15] {
                try? await Task.sleep(nanoseconds: UInt64(sec) * 1_000_000_000)
                guard let self else { return }
                let simMic = self.inputSource == .microphone && self.scene == .call && self.monitorTTSOnPhone
                let v = self.ttsAudioRxCount == 0
                    ? "no_downlink_opus_seen_by_active_session_yet(compare_VERDICT_ws_tts_span_on_tts_stop)"
                    : "downlink_opus_seen_by_session_frames=\(self.ttsAudioRxCount)"
                print("[CloudAudioProof] watchdog t+\(sec)s tts_frames=\(self.ttsAudioRxCount) tts_bytes=\(self.ttsAudioRxBytes) wsListening=\(self.wsListeningStarted) ws_sid_nil=\(self.ws.sessionId == nil) bleAudAck=\(self.bleAudioStartAcked) status=\(self.status) sim_mic_call=\(simMic) verdict=\(v)")
            }
        }
    }

    @discardableResult
    func handleWSConnectBLEAction(_ bleAction: CallTransportCoordinator.BLEConnectAction?) -> Bool {
        guard let bleAction else { return false }
        switch bleAction {
        case .startPendingActiveFlow:
            pendingActiveConnect = false
            startConnectedFlow()
        case .startListening:
            // BLE mode: start listening immediately once WS session is ready.
            // (Call audio will arrive via BLE; we buffer briefly if needed.)
            startListening()
        }
        return true
    }

    func handleWSConnectMicrophoneFlowIfNeeded() {
        guard inputSource == .microphone else { return }
        if scene != .call {
            startConnectedFlow()
            if manualReconnectPending && manualPressActive {
                manualReconnectPending = false
                beginManualListen()
            }
            return
        }
        if skipPickupDelay {
            startConnectedFlow()
            return
        }
        // 模拟响铃后接通（可配置）
        pickupDelayTask?.cancel()
        let delaySeconds: Int = {
            let defaults = UserDefaults.standard
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
            self.startConnectedFlow()
        }
    }

    func webSocketDidDisconnect(error: Error?, disconnectInfo: WebSocketDisconnectInfo?) {
        guard isActiveController else { return }
        if let info = disconnectInfo {
            print("[NOSOUND] ws_disconnected: [WS][CLOSE] \(info.logDescription) error=\(error?.localizedDescription ?? "nil") bleCallActive=\(bleCallActive) acked=\(bleAudioStartAcked) wsListening=\(wsListeningStarted) ttsRx=\(ttsAudioRxCount)")
        } else {
            print("[NOSOUND] ws_disconnected: error=\(error?.localizedDescription ?? "nil") bleCallActive=\(bleCallActive) acked=\(bleAudioStartAcked) wsListening=\(wsListeningStarted) ttsRx=\(ttsAudioRxCount)")
        }
        if inputSource == .ble {
            bleWSDisconnectReactionTask?.cancel()
            bleWSDisconnectReactionTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                defer { self.bleWSDisconnectReactionTask = nil }

                if disconnectInfo?.kind == .normalEnd {
                    print("[CallSession] WS normal_end in BLE call: finish AI call instead of reconnecting")
                    self.processWebSocketDisconnect(error: error, disconnectInfo: disconnectInfo)
                    return
                }

                let inActiveAIContext = self.bleCallActive ||
                    self.bleWSConnectContext == .activeCall ||
                    self.status == .connected
                let canMidCallReconnect = inActiveAIContext &&
                    self.hasReceivedWSHelloInCurrentCall &&
                    self.midCallReconnectWindowSec > 0

                if canMidCallReconnect {
                    let windowSec = self.midCallReconnectWindowSec
                    print(String(format: "[CallSession] WS mid-call disconnect: try reconnect window=%.2fs", windowSec))
                    self.transportCoordinator.markWSConnectStarted()
                    self.applyPhoneIDContextForWS()
                    self.ws.setCallHelloPromptOverride(self.activeOutboundPrompt)
                    let taskForApns = self.activeOutboundTaskID ?? self.pendingOutboundTaskID
                    self.ws.setHelloApnsRequestId(OutboundTaskQueueService.shared.apnsRequestId(forTask: taskForApns))
                    let retryScene: WebSocketScene =
                        (self.outboundCallId != nil || self.currentIncomingCall?.title == "[OUTBOUND_TASK]")
                        ? .callOutbound : .call
                    if retryScene == .callOutbound {
                        self.ws.setOutboundHelloContext(OutboundHelloContext(
                            targetPhone: self.outboundTargetPhone ?? "",
                            callerName: self.outboundCallerName ?? "",
                            taskGoal: self.outboundTaskGoal ?? ""
                        ))
                    }
                    self.ws.connect(audioFormat: self.bleWSAudioFormat,
                                    scene: retryScene,
                                    reason: "mid_call_ws_disconnect_reconnect")

                    let deadline = Date().addingTimeInterval(windowSec)
                    while Date() < deadline {
                        if Task.isCancelled { return }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if self.ws.isConnected {
                            print("[CallSession] WS mid-call reconnected, skip hangup")
                            return
                        }
                    }
                    if Task.isCancelled { return }
                    print(String(format: "[CallSession] WS mid-call reconnect window %.2fs elapsed without recovery, fall through to hangup decision", windowSec))
                } else {
                    let delaySec = self.disconnectReactionDelaySec
                    if delaySec > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                    }
                    guard !Task.isCancelled else { return }
                    if self.ws.isConnected {
                        print(String(format: "[CallSession] WS recovered within %.2fs; skip delayed disconnect handling", delaySec))
                        return
                    }
                }

                guard self.isActiveController else { return }
                self.processWebSocketDisconnect(error: error, disconnectInfo: disconnectInfo)
            }
            return
        }
        processWebSocketDisconnect(error: error, disconnectInfo: disconnectInfo)
    }

    func processWebSocketDisconnect(error: Error?, disconnectInfo: WebSocketDisconnectInfo?) {
        manualReconnectInFlight = false
        lastErrorMessage = resolveLastErrorMessage(error: error, disconnectInfo: disconnectInfo)
        maybeShowQuickWSDisconnectToast(disconnectInfo: disconnectInfo)
        if let plan = makeBLEWSDisconnectPlan(), executeBLEWSDisconnectPlan(plan) {
            return
        }
        handleWSDisconnectDrainOrEnd()
    }

    /// 优先使用网关 Close reason；`normal_end` 不占用 lastErrorMessage。
    private func resolveLastErrorMessage(error: Error?, disconnectInfo: WebSocketDisconnectInfo?) -> String? {
        guard let disconnectInfo else {
            return error?.localizedDescription
        }
        switch disconnectInfo.kind {
        case .normalEnd:
            return nil
        case .idleTimeout:
            return language == .zh ? "会话空闲超时" : "Session idle timeout"
        case .replaced:
            return language == .zh ? "连接已被新会话替换" : "Connection replaced by a new session"
        case .unauthorized:
            return language == .zh ? "鉴权失败，请重新登录" : "Unauthorized; please sign in again"
        case .invalidDevice:
            return language == .zh ? "设备校验失败" : "Device validation failed"
        case .internalError, .asrClosed, .ttsError, .initError, .socketError:
            if let raw = disconnectInfo.closeReasonRaw, !raw.isEmpty {
                return raw
            }
            return error?.localizedDescription
        case .unknown:
            return error?.localizedDescription
                ?? disconnectInfo.closeReasonRaw
        case .transportError:
            return error?.localizedDescription
        }
    }

    /// 网关 `normal_end`（1000）视为正常结束，不弹「网络不稳定」短时 toast。
    func maybeShowQuickWSDisconnectToast(disconnectInfo: WebSocketDisconnectInfo?) {
        if disconnectInfo?.kind == .normalEnd { return }
        guard inputSource == .ble else { return }
        guard !wsQuickDisconnectToastShown else { return }
        guard bleCallActive || bleWSConnectContext == .activeCall || status == .connected else { return }
        guard let answeredAt = latAnswerSentAt else { return }
        let elapsed = Date().timeIntervalSince(answeredAt)
        guard elapsed <= wsDisconnectToastWindowSec else { return }
        wsQuickDisconnectToastShown = true
        toastMessage = language == .zh
            ? "网络连接不稳定，通话已中断，请稍后重试"
            : "Network unstable. Call interrupted, please try again."
        print(String(format: "[CallSession] quick WS disconnect toast shown elapsed=%.2fs window=%.2fs",
                     elapsed, wsDisconnectToastWindowSec))
    }

    func makeBLEWSDisconnectPlan() -> CallTransportCoordinator.BLEWSDisconnectPlan? {
        guard inputSource == .ble, status != .ended else { return nil }
        let now = Date()
        let sinceStart = transportCoordinator.wsConnectElapsed(now: now)
        let isEarlyWindow = sinceStart < wsQuickDisconnectWindowSec
        let inActiveAIContext = bleCallActive || bleWSConnectContext == .activeCall || status == .connected
        let incomingContextNotActive = (bleWSConnectContext == .incomingCall && !bleCallActive)
        wsListeningStarted = false
        return transportCoordinator.planBLEWSDisconnect(
            status: status,
            hasOutboundCall: outboundCallId != nil,
            inActiveAIContext: inActiveAIContext,
            incomingContextNotActive: incomingContextNotActive,
            isEarlyWindow: isEarlyWindow,
            shouldSuppressBLEHangup: shouldSuppressBLEHangup,
            hasEverReceivedWSHelloInCall: hasReceivedWSHelloInCurrentCall
        )
    }

    @discardableResult
    func executeBLEWSDisconnectPlan(_ plan: CallTransportCoordinator.BLEWSDisconnectPlan) -> Bool {
        switch plan {
        case .suppressAndEnd:
            print("[CallSession] WS disconnect: suppressing hangup/audio_stop due to passthrough")
            end()
            return true
        case let .noHelloRetry(attempt, maxRetries, delaySec):
            scheduleWSNoHelloRetry(attempt: attempt, maxRetries: maxRetries, delaySec: delaySec)
            return true
        case .noHelloEndAIOnlyKeepHFP:
            print("[CallSession] WS no-hello retries exhausted during outbound connecting: end AI session only, keep HFP call alive")
            suppressHangupOnce = true
            end()
            return true
        case .noHelloHangupAndEnd:
            print("[CallSession] WS no-hello retries exhausted in active AI context -> hangup MCU")
            suppressBLEAutoReconnectBeforeIntentionalMCUHangup(reason: "ws_no_hello_hangup")
            sendCallCommand("audio_stop", expectAck: false)
            sendCallCommand("hangup", expectAck: false)
            end()
            return true
        case let .noHelloEndWithoutHangup(windowNote):
            print("[CallSession] WS \(windowNote) disconnect (no hello) during incoming call; end without MCU hangup")
            suppressHangupOnce = true
            end()
            return true
        case .noHelloHFPDisconnectThenEnd:
            print("[CallSession] WS disconnect (no hello) -> hfp_disconnect")
            if !shouldSuppressBLEHangup {
                sendHFPDisconnectWithCooldown()
            }
            suppressHangupOnce = true
            end()
            return true
        case .disconnectEndWithoutHangup:
            print("[CallSession] WS disconnected during incoming call; ending session without MCU hangup")
            suppressHangupOnce = true
            end()
            return true
        case .disconnectHangupAndEnd:
            print("[CallSession] WS disconnected in active call context -> hangup MCU")
            suppressBLEAutoReconnectBeforeIntentionalMCUHangup(reason: "ws_disconnect_hangup")
            sendCallCommand("audio_stop", expectAck: false)
            sendCallCommand("hangup", expectAck: false)
            return false
        }
    }

    func scheduleWSNoHelloRetry(attempt: Int, maxRetries: Int, delaySec: Double) {
        print("[CallSession] WS disconnect (no hello) in active call: retry \(attempt)/\(maxRetries) after \(delaySec)s")
        transportCoordinator.scheduleNoHelloRetryTask(delaySec: delaySec) { [weak self] in
            guard let self else { return }
            guard self.status != .ended else { return }
            let audioFormat = self.bleWSAudioFormat
            print("[WS_RECONNECT_TRACE] no_hello_retry attempt=\(attempt)/\(maxRetries) audioFormat=\(audioFormat) hasHello=\(self.transportCoordinator.hasReceivedWSHello()) stickyHello=\(self.hasReceivedWSHelloInCurrentCall) status=\(self.status) bleCallActive=\(self.bleCallActive) context=\(self.bleWSConnectContext)")
            self.transportCoordinator.markWSConnectStarted()
            self.applyPhoneIDContextForWS()
            self.ws.setCallHelloPromptOverride(self.activeOutboundPrompt)
            let taskForApns = self.activeOutboundTaskID ?? self.pendingOutboundTaskID
            self.ws.setHelloApnsRequestId(OutboundTaskQueueService.shared.apnsRequestId(forTask: taskForApns))
            let retryScene: WebSocketScene =
                (self.outboundCallId != nil || self.currentIncomingCall?.title == "[OUTBOUND_TASK]")
                ? .callOutbound : .call
            if retryScene == .callOutbound {
                self.ws.setOutboundHelloContext(OutboundHelloContext(
                    targetPhone: self.outboundTargetPhone ?? "",
                    callerName: self.outboundCallerName ?? "",
                    taskGoal: self.outboundTaskGoal ?? ""
                ))
            }
            self.ws.connect(audioFormat: audioFormat, scene: retryScene, reason: "scheduleWSNoHelloRetry_\(attempt)")
        }
    }

    func handleWSDisconnectDrainOrEnd() {
        let shouldDeferEndForDrain = audioRouter.handleWSDisconnectDrainIfNeeded(
            monitorTTSOnPhone: monitorTTSOnPhone,
            inputSource: inputSource,
            frameDurationMs: max(1, ws.downstreamFrameDuration),
            baseGrace: 2.0
        ) { [weak self] pendingEstimate, timeout in
            guard let self else { return }
            print(String(format: "[CallSession] WS disconnected: defer end until playback drain (pending=%.2f s timeout=%.2f s frameMs=%d)",
                         pendingEstimate, timeout, max(1, self.ws.downstreamFrameDuration)))
            self.audioRouter.scheduleWSDisconnectDrainPlayback(timeout: timeout) { [weak self] in
                guard let self else { return }
                self.end(abortReason: "ws_disconnect")
            }
        }
        if shouldDeferEndForDrain {
            return
        }
        end(abortReason: "ws_disconnect")
    }

    func webSocketDidReceiveSTT(text: String) {
        guard isActiveController else { return }
        lastCloudSTTRxAt = Date()
        pendingCloudSTTForTTS = true
        print("[NOSOUND] stt_rx: len=\(text.count) text=\"\(text.prefix(60))\"")
        latencyWSLog("stt_rx", extra: "text_len=\(text.count)")
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            currentSTTText = cleaned
            syncLiveActivity()
        }
        messages.append(.init(text: text, isAI: false))
    }

    /// 手机监听下行：`tts start` 可能晚于首包 Opus；`scene=call` 时还有连续背景流。
    /// 播放管线须在未真正运行时按帧补建（亦覆盖 `init_config` 等麦克风监听场景）。
    ///
    /// 注意：判断必须基于「引擎在 running + player 仍 attached」，而非 `isPlaying` 标志。
    /// 中断 / 路由切换时 `AVAudioEngine` 会被悄悄停掉而 `isPlaying` 还是 true，
    /// 那种状态下早 return 会导致 `playOpusData` 一直被 drop（[CloudAudioProof] LOCAL_playOpus_skipped_not_prepared）。
    private func ensureSimMicCloudDownlinkPlaybackReady(reason: String) {
        guard monitorTTSOnPhone, inputSource == .microphone else { return }
        if audioRouter.isPlaybackPipelineHealthy() { return }
        let sr = max(8000, currentTTSSampleRate > 0 ? currentTTSSampleRate : ws.downstreamSampleRate)
        let playbackOnly = scene.isManualInteractionScene
        // 连续流：先尝试「同 SR / 同模式下图仍在」的轻量恢复，避免仅因引擎被 pause 走整段 teardown。
        if usesContinuousCloudDownlinkCallAudio,
           audioRouter.tryResumeContinuousOpusPlaybackIfPossible(sampleRate: sr, playbackOnly: playbackOnly) {
            print("[CloudAudioProof] sim_continuous_downlink_resume_inline reason=\(reason) sr=\(sr) playbackOnly=\(playbackOnly)")
            return
        }
        let isPlayingFlag = audioRouter.isPlaying()
        print("[CloudAudioProof] sim_continuous_downlink_prepare reason=\(reason) sr=\(sr) ws_downstream_sr=\(ws.downstreamSampleRate) current_tts_sr=\(currentTTSSampleRate) scene=\(scene.rawValue) isPlayingFlag=\(isPlayingFlag) healthy=false")
        audioRouter.prepareForTTSStart(
            monitorTTSOnPhone: monitorTTSOnPhone,
            inputSource: inputSource,
            scene: scene,
            sampleRate: sr,
            isSpeaker: isSpeaker
        )
        if !audioRouter.isPlaybackPipelineHealthy() {
            print("[CloudAudioProof] sim_continuous_downlink_prepare_STILL_IDLE search=prepareForTTSStart_preparePlayback_FAILED")
        }
    }

    func webSocketDidReceiveTTSStart(sampleRate: Int) {
        guard isActiveController else { return }
        print("[NOSOUND] tts_start: sampleRate=\(sampleRate) acked=\(bleAudioStartAcked) uplinkQ=\(audioRouter.uplinkQueueCount())")
        print("[MIC_CHAIN] tts_start_rx: sampleRate=\(sampleRate) micGuard=\(micMutedByTTSGuard) wsListeningStarted=\(wsListeningStarted) inputSource=\(inputSource)")
        print("[CallSession] webSocketDidReceiveTTSStart: sampleRate=\(sampleRate) inputSource=\(inputSource)")
        latencyManualSceneLog("tts_start_delegate", extra: "sampleRate=\(sampleRate) wsAudioFormat=\(ws.audioFormat)")
        // New utterance started: cancel any prior stop-after-drain task to avoid
        // stale timers stopping playback in the middle of the new sentence.
        audioRouter.cancelTTSStopPlaybackTask()
        engageMicGuardForTTS()
        logTTSTrace("tts_start", extra: "sampleRate=\(sampleRate)")
        currentTTSSampleRate = sampleRate
        if usesContinuousCloudDownlinkCallAudio {
            // 连续下行：不在 JSON 边界重建播放/录音管线；由 hello 后首包二进制 + ensure 驱动。
            latencyManualSceneLog(
                "tts_prepare_skipped_continuous_call",
                extra: "sampleRate=\(sampleRate) monitorOnPhone=\(monitorTTSOnPhone)"
            )
            print("[CloudAudioProof] tts_json_start_continuous_mode no_prepare_on_json sampleRate=\(sampleRate) input=\(inputSource)")
        } else {
            let prepareStartedAt = Date()
            audioRouter.prepareForTTSStart(
                monitorTTSOnPhone: monitorTTSOnPhone,
                inputSource: inputSource,
                scene: scene,
                sampleRate: sampleRate,
                isSpeaker: isSpeaker
            )
            let prepareDurationMs = Int(Date().timeIntervalSince(prepareStartedAt) * 1000)
            latencyManualSceneLog(
                "tts_prepare_complete",
                extra: "sampleRate=\(sampleRate) duration=\(prepareDurationMs)ms monitorOnPhone=\(monitorTTSOnPhone)"
            )
        }
        if inputSource == .microphone && scene == .call && monitorTTSOnPhone {
            print("[CloudAudioProof] sim_mic_tts_json_start utterance_boundary isPlaying_after_delegate_prepare=\(audioRouter.isPlaying()) note=continuous_call_audio_binary_driven")
        }
        currentTTSText = ""
        currentSTTText = ""
        // flushAndReset: 若上一句还在逐字播出，把完整文字提交到消息列表后再清空，
        // 避免 tool_call 触发新 tts_start 时正在显示的流式气泡和文字消失。
        ttsStreamBuffer.flushAndReset()

        if !usesContinuousCloudDownlinkCallAudio {
            ttsAudioRxCount = 0
            ttsAudioRxBytes = 0
            ttsBinaryRxBatchStartAt = nil
            ttsBinaryRxBatchStartPendingFrames = 0
        }

        if inputSource == .ble {
            if usesContinuousCloudDownlinkCallAudio {
                // 连续流：加强窗与 uplink 诊断计数在首包二进制处 `startNewTTSBoostWindow`，避免句边界 resetCounters。
                print("[TTS->BLE] tts_start_continuous_skip_boost_reset")
            } else {
                audioRouter.startNewTTSBoostWindow(boostMs: ttsUplinkBoostMs)
            }
        }
    }

    func webSocketDidReceiveTTSAudio(data: Data) {
        guard isActiveController else { return }
        // 新到二进制：先取消上一句 `tts_stop` 的延迟停播，避免与连续下行（背景音）冲突。
        audioRouter.cancelTTSStopPlaybackTask()
        if usesContinuousCloudDownlinkCallAudio && inputSource == .ble && !continuousBleDownlinkSessionPrepared {
            continuousBleDownlinkSessionPrepared = true
            let sr = max(
                8000,
                ws.downstreamSampleRate > 0
                    ? ws.downstreamSampleRate
                    : (currentTTSSampleRate > 0 ? currentTTSSampleRate : 16000)
            )
            print("[CloudAudioProof] continuous_ble_downlink_prepare_first_binary sr=\(sr) monitorOnPhone=\(monitorTTSOnPhone)")
            audioRouter.prepareForTTSStart(
                monitorTTSOnPhone: monitorTTSOnPhone,
                inputSource: inputSource,
                scene: scene,
                sampleRate: sr,
                isSpeaker: isSpeaker
            )
            audioRouter.startNewTTSBoostWindow(boostMs: ttsUplinkBoostMs)
        }
        // 模拟通话：二进制先于/晚于 `tts start` 都常见；`tts_stop` drain 也可能短暂 teardown — 任意帧到达时若未播放则重新 prepare。
        ensureSimMicCloudDownlinkPlaybackReady(reason: "binary_rx")
        traceMark("WS_downlink_first_rx(binary)", store: &tWsFirstDownRxNs)
        // Debug: confirm delegate call arrives
        lastTtsAudioRxAt = Date()
        ttsAudioRxCount += 1
        ttsAudioRxBytes += data.count
        let pendingFramesNow = audio.effectivePendingPlaybackBufferCount()
        if ttsAudioRxCount == 1 {
            print("[CloudAudioProof] first_tts_audio_to_session bytes=\(data.count) bleAudAck=\(bleAudioStartAcked) input=\(inputSource) activeCtl=\(isActiveController)")
            let tsMs = Int(Date().timeIntervalSince1970 * 1000)
            let queueAheadMs = pendingFramesNow * max(1, ws.downstreamFrameDuration)
            print("[TTS_LATENCY] stage=binary_first_rx t=\(nowLogString()) ts_ms=\(tsMs) bytes=\(data.count)")
            print("[TTS_QUEUE] t=\(nowLogString()) pending_frames=\(pendingFramesNow) queue_ahead_ms=\(queueAheadMs) frame_ms=\(max(1, ws.downstreamFrameDuration))")
            ttsBinaryRxBatchStartAt = Date()
            ttsBinaryRxBatchStartPendingFrames = pendingFramesNow
            logTTSTrace("tts_audio_first", extra: "bytes=\(data.count)")
            latFirstTtsRxAt = Date()
            latencyLog("ws_first_tts_audio_rx")
            latencyWSLog("tts_first_audio_rx", extra: "bytes=\(data.count)")
            latencyManualSceneLog("tts_first_audio_rx", extra: "bytes=\(data.count) wsAudioFormat=\(ws.audioFormat)")
            if pendingCloudSTTForTTS, let sttAt = lastCloudSTTRxAt {
                let deltaMs = Int(Date().timeIntervalSince(sttAt) * 1000)
                latencyWSLog("stt_to_tts_first_audio_delta", extra: "dt=\(deltaMs)ms")
                pendingCloudSTTForTTS = false
            } else {
                latencyWSLog("stt_to_tts_first_audio_delta", extra: "dt=unknown(no_pending_stt)")
            }
            if verboseRealtimeAudioLoggingEnabled {
                print("[TTS] first frame rx at \(nowLogString()) format=\(ws.audioFormat) bytes=\(data.count)")
            }
        } else if ttsAudioRxCount % 20 == 0 {
            let now = Date()
            let startedAt = ttsBinaryRxBatchStartAt ?? now
            let inLastMs = Int(now.timeIntervalSince(startedAt) * 1000)
            let startPending = ttsBinaryRxBatchStartPendingFrames
            let deltaPending = pendingFramesNow - startPending
            print("[TTS_WS_RATE] binary 20 in_last_ms=\(inLastMs) rx_total=\(ttsAudioRxCount) pending_start=\(startPending) pending_end=\(pendingFramesNow) delta_pending=\(deltaPending) frame_ms=\(max(1, ws.downstreamFrameDuration))")
            ttsBinaryRxBatchStartAt = now
            ttsBinaryRxBatchStartPendingFrames = pendingFramesNow
        }
        if verboseRealtimeAudioLoggingEnabled && (ttsAudioRxCount <= 3 || (ttsAudioRxCount % 50) == 0) {
            print("[CallSession] TTS audio rx: count=\(ttsAudioRxCount) bytes=\(ttsAudioRxBytes) inputSource=\(inputSource)")
        }

        if inputSource == .ble {
            // 主 actor 上显式入队（回滚 968e9885 的 URLSession-queue fast hook）：
            // fast hook 让入队绕过主 actor，drain 仍留在主 actor 上；主 actor 被 UI/Task 拖
            // 住时 `TTSUplinkState` 的 10 帧 cap 会被 WS 突发帧打穿，`removeFirst` 丢弃最老
            // 帧 → 对方听到 TTS 顿挫/断续。保持旧路径：入队和其余诊断都在主 actor 串行跑，
            // 主 actor 卡时 WS Task 会排队而不是 uplinkState 溢出。
            _ = audioRouter.enqueueTTSUplinkAudio(
                data: data,
                bleAudioStartAcked: bleAudioStartAcked,
                isFirstTTSInCall: isFirstTTSInCall,
                maxQueueItems: ttsUplinkMaxQueueItemsOpus
            )
            if tTtsFirstEnqueueNs == nil {
                traceMark("TTS_enqueue_first(opus)", store: &tTtsFirstEnqueueNs)
                traceLogDelta("WS_down->enqueue_first", tWsFirstDownRxNs, tTtsFirstEnqueueNs)
                print("[NOSOUND] tts_first_enqueue: bytes=\(data.count) acked=\(bleAudioStartAcked) format=\(ws.audioFormat)")
            }
            let queueCountNow = audioRouter.uplinkQueueCount()
            if verboseRealtimeAudioLoggingEnabled && audioRouter.shouldLogUplinkEnqueue() {
                let counters = audioRouter.uplinkEnqueueCounters()
                print("[TTS->BLE] enqueue: frames=\(counters.enqueuedFrames) bytes=\(counters.enqueuedBytes) q=\(queueCountNow)")
            }
            if ttsAudioRxCount == 1 || ttsAudioRxCount % 10 == 0 {
                let sent = audioRouter.uplinkSentCounters()
                print("[NOSOUND] tts_enqueue: rxTotal=\(ttsAudioRxCount) rxBytes=\(ttsAudioRxBytes) uplinkQ=\(queueCountNow) sentFrames=\(sent.sentFrames) sentBytes=\(sent.sentBytes) acked=\(bleAudioStartAcked) blePending=\(ble.pendingAudioWriteCount)")
            }

            // Start uplink drain only after MCU has ACKed `audio_start`.
            // Otherwise some MCU firmware may reset/flush uplink audio around `audio_start`,
            // causing the beginning of the first TTS (greeting) to be dropped.
            if bleAudioStartAcked {
                // Start drain immediately on first audio frame after audio_start ACK
                // to avoid introducing an artificial silent lead-in.
                scheduleTTSUplinkDrain(reason: "tts_audio_enqueue")
            } else {
                if ttsAudioRxCount <= 3 || ttsAudioRxCount % 20 == 0 {
                    print("[NOSOUND] tts_drain_BLOCKED: bleAudioStartAcked=false rxCount=\(ttsAudioRxCount) q=\(audioRouter.uplinkQueueCount())")
                }
            }
            if usesContinuousCloudDownlinkCallAudio && bleAudioStartAcked && isFirstTTSInCall && ttsAudioRxCount >= 32 {
                isFirstTTSInCall = false
                print("[TTS->BLE] continuous_call_first_tts_window_cleared rxCount=\(ttsAudioRxCount)")
            }
        }
        // 下行准备：`scene=call` 连续流依赖 (1) 首包二进制 + `ensureSimMicCloudDownlinkPlaybackReady`（mic），
        // 或 BLE 首包 `continuous_ble_downlink_prepare_first_binary`；(2) 管线异常清空时按帧补。
        // 不再在 ttsAudioRxCount==1 时二次 prepare：会与 (1) 叠打，先 `stopPlayback` 再建，易造成下一帧 `!isPlaying` 与可感卡顿。
        audioRouter.consumeIncomingTTSAudioFrame(
            data: data,
            monitorTTSOnPhone: monitorTTSOnPhone
        )
        // 首帧须先入解码/调度队列再动路由：此前在 playOpus 之前 reassert 扬声器曾触发
        // AVAudioSession 变更，使下一帧 `ensure` 看到 `!isPlaying` 又走一遍 teardown。
        if monitorTTSOnPhone, ttsAudioRxCount == 1 {
            audioRouter.reassertSpeakerOnFirstTTSAudioFrameIfNeeded(
                monitorTTSOnPhone: monitorTTSOnPhone,
                isSpeakerEnabled: isSpeaker
            )
        }
    }

    func webSocketDidReceiveTTSSentence(text: String, isStart: Bool) {
        guard isActiveController else { return }
        if isStart {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                print("[CallSession] TTS sentence start -> skip empty text")
                return
            }
            // 追加到缓冲区，由 TTSCharacterStreamBuffer 逐字输出
            lastTTSSentenceText = cleaned
            ttsStreamBuffer.append(cleaned)
            print("[CallSession] TTS sentence start -> buffer append: \(cleaned)")
        } else {
            // sentence_end no-op (avoid duplicate UI)
            print("[CallSession] TTS sentence end -> UI no-op")
        }
    }

    func webSocketDidReceiveTTSStop() {
        guard isActiveController else { return }
        let sent = audioRouter.uplinkSentCounters()
        print("[NOSOUND] tts_stop: ttsRxCount=\(ttsAudioRxCount) ttsRxBytes=\(ttsAudioRxBytes) sentFrames=\(sent.sentFrames) sentBytes=\(sent.sentBytes) uplinkQ=\(audioRouter.uplinkQueueCount()) blePending=\(ble.pendingAudioWriteCount)")
        let simMicCall = inputSource == .microphone && scene == .call && monitorTTSOnPhone
        if simMicCall {
            if usesContinuousCloudDownlinkCallAudio {
                print("[CloudAudioProof] VERDICT_sim_mic_call_continuous tts_stop_json_only rx_session_frames=\(ttsAudioRxCount) note=per_utterance_verdict_disabled")
            } else {
                let explain: String
                if ttsAudioRxCount == 0 {
                    explain = "SILENCE_LIKELY_NOT_LOCAL_PLAYBACK: zero opus frames reached active CallSession for this utterance — compare log line VERDICT_ws_tts_span (if opus_frames_between_start_stop=0 → cloud/link did not send binary TTS)"
                } else {
                    explain = "CLOUD_DELIVERED_OPUS: frames=\(ttsAudioRxCount) reached session — if still no sound, search logs for LOCAL_playOpus_skipped_not_prepared or decode errors"
                }
                print("[CloudAudioProof] VERDICT_sim_mic_call_session \(explain)")
            }
        }
        // 通知缓冲区不再有新句子；缓冲区会继续流式输出剩余字符，
        // 排空后自动回调 onFinished 把文本固化到 messages。
        ttsStreamBuffer.markDone()

        ttsStopCount += 1
        print("[MIC_CHAIN] tts_stop_rx: ttsStopCount=\(ttsStopCount) micGuard=\(micMutedByTTSGuard) wsListeningStarted=\(wsListeningStarted) monitorOnPhone=\(monitorTTSOnPhone)")
        logTTSTrace("tts_stop_rx")
        if usesContinuousCloudDownlinkCallAudio {
            print("[TTS->BLE] webSocketDidReceiveTTSStop: continuous_call_mode ttsStopped=false q=\(audioRouter.uplinkQueueCount()) ttsStopCount=\(ttsStopCount)")
        } else {
            print("[TTS->BLE] webSocketDidReceiveTTSStop: setting ttsStopped=true, q=\(audioRouter.uplinkQueueCount()) ttsStopCount=\(ttsStopCount)")
        }
        if monitorTTSOnPhone {
            if usesContinuousCloudDownlinkCallAudio {
                print("[CallSession] TTS stop (continuous call): skip stop-after-drain; playback follows binary stream / WS end")
            } else {
                let frameDurationMs = max(1, ws.downstreamFrameDuration)
                let baseGrace: TimeInterval = scene.isManualInteractionScene ? 8.0 : 4.0
                let window = audioRouter.estimateTTSStopDrainWindow(
                    frameDurationMs: frameDurationMs,
                    baseGrace: baseGrace
                )
                print(String(format: "[CallSession] TTS stop: pending estimate=%.2f s timeout=%.2f s frameMs=%d",
                             window.pendingEstimate, window.timeout, frameDurationMs))

                let frameSec = Double(frameDurationMs) / 1000.0
                let minSilence = max(1.5, frameSec * 2 + 0.3)
                audioRouter.scheduleTTSStopPlaybackAfterDrain(
                    timeout: window.timeout,
                    minSilenceAfterLastAudio: minSilence,
                    lastAudioRxAt: { [weak self] in
                        self?.lastTtsAudioRxAt ?? .distantPast
                    },
                    isActive: { [weak self] in
                        self?.isActiveController ?? false
                    },
                    onPlaybackStopped: { [weak self] in
                        self?.releaseMicGuardForTTS()
                    }
                )
                print(String(format: "[CallSession] TTS stop drain: minSilence=%.2f s timeout=%.2f s", minSilence, window.timeout))
            }
        } else {
            releaseMicGuardForTTS()
        }
        audioRouter.stopRecordingForConfigIfNeeded(scene: scene, wsListeningStarted: wsListeningStarted)
        audioRouter.setTTSStopped(!usesContinuousCloudDownlinkCallAudio)
        scheduleBLEFarewellHangupAfterTTSStopIfNeeded()
        if inputSource == .ble && !usesContinuousCloudDownlinkCallAudio {
            isFirstTTSInCall = false
        }
    }

    func scheduleBLEFarewellHangupAfterTTSStopIfNeeded() {
        guard inputSource == .ble else { return }
        guard !shouldSuppressBLEHangup else { return }
        guard bleCallActive || status == .connected || bleWSConnectContext == .activeCall else { return }
        let sentence = lastTTSSentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFarewellTTSSentence(sentence) else { return }

        bleFarewellHangupTask?.cancel()
        bleFarewellHangupTask = Task { [weak self] in
            guard let self else { return }
            let raw = UserDefaults.standard.double(forKey: "callmate.ble_farewell_hangup_grace_sec")
            let delaySec = raw == 0 ? 1.2 : max(0.2, min(5.0, raw))
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            guard !Task.isCancelled else { return }
            defer { self.bleFarewellHangupTask = nil }
            guard self.isActiveController else { return }
            guard self.inputSource == .ble else { return }
            guard self.status != .ended else { return }
            guard self.bleCallActive || self.status == .connected || self.bleWSConnectContext == .activeCall else { return }
            print(String(format: "[CallSession] BLE farewell TTS stop: auto hangup after %.2fs sentence=\"%@\"", delaySec, sentence))
            self.suppressBLEAutoReconnectBeforeIntentionalMCUHangup(reason: "ble_farewell_tts_stop")
            self.sendCallCommand("audio_stop", expectAck: false)
            self.sendCallCommand("hangup", expectAck: false)
            self.end()
        }
    }

    func isFarewellTTSSentence(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("再见") ||
            normalized.contains("拜拜") ||
            normalized.contains("挂了") ||
            normalized.contains("bye") ||
            normalized.contains("goodbye")
    }

    func webSocketDidReceiveFiller(id: String) {
        guard isActiveController else { return }
        // play_filler 是给 MCU 在通话中通过 HFP eSCO 播 mSBC blob，让对端在 AI think-gap
        // 听到"嗯/啊"。模拟麦克风通话/分身配置等没有 BLE 通话的场景没有对端、没有 eSCO，
        // 转过去只会让 MCU 回 result=-2（"无通话不能播 filler"），反过来触发 iOS 的
        // `phone_handled_rejected → end()`，把会话整段拆掉。所以只在真实 BLE 通话里转发。
        guard inputSource == .ble else {
            print("[WS][filler] forward suppressed (no_ble_call inputSource=\(inputSource) scene=\(scene.rawValue)) id=\(id)")
            return
        }
        print("[WS][filler] forward id=\(id) inputSource=ble scene=\(scene.rawValue)")
        ble.sendCommand("play_filler", extra: ["filler_id": id], expectAck: false)
    }

    func webSocketDidReceiveToolCall(callId: String, name: String, arguments: [String: Any]) {
        guard isActiveController else {
            if scene == .updateConfig {
                print("\(WebSocketService.outboundAIUCv1Tag) tool_dropped side=client reason=inactive_controller name=\(name) call_id=\(callId)")
            }
            print("[OutboundAI][Tool] dropped (not active controller) name=\(name) callId=\(callId) — another session may own WS")
            return
        }
        print("[OutboundAI][Tool] recv name=\(name) scene=\(scene.rawValue) callId=\(callId) argKeys=\(Array(arguments.keys))")
        if scene == .updateConfig {
            let sortedKeys = Array(arguments.keys).sorted().joined(separator: ",")
            print("\(WebSocketService.outboundAIUCv1Tag) tool_handler_enter side=client scene=\(scene.rawValue) name=\(name) call_id=\(callId) arg_keys=\(sortedKeys)")
        }
        if name == "notify_owner_to_pickup" {
            handleNotifyOwnerToPickup(callId: callId, arguments: arguments)
            return
        }
        if name == "save_user_appellation" {
            print("[Tool] save_user_appellation called, arguments=\(arguments)")
            let raw = (arguments["appellation"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                ws.sendToolResponse(callId: callId, result: nil, error: "称呼为空")
                print("[Tool] save_user_appellation rejected: empty")
                return
            }
            UserDefaults.standard.set(raw, forKey: "callmate.userAppellation")
            ws.sendToolResponse(callId: callId, result: ["success": true])
            print("[Tool] save_user_appellation responded success, callId=\(callId)")
            return
        }
        if name == "load_rules" {
            let tag = (arguments["tag"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !tag.isEmpty else {
                ws.sendToolResponse(callId: callId, result: nil, error: "缺少 tag")
                return
            }
            guard let rule = ProcessStrategyStore.getRule(tag: tag) else {
                ws.sendToolResponse(callId: callId, result: nil, error: "规则不存在: \(tag)")
                return
            }
            ws.sendToolResponse(callId: callId, result: [
                "tag": tag,
                "name": rule.name,
                "content": rule.content
            ])
            print("[Tool] load_rules tag=\(tag) name=\(rule.name) contentLen=\(rule.content.count)")
            return
        }
        if name == "load_template" {
            let target = (arguments["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty else {
                ws.sendToolResponse(callId: callId, result: nil, error: "缺少 name")
                return
            }
            switch OutboundTemplateStore.lookup(name: target) {
            case .hit(let n, let taskType, let content):
                ws.sendToolResponse(callId: callId, result: [
                    "name": n,
                    "task_type": taskType,
                    "content": content
                ])
                print("[Tool] load_template name=\(n) taskType=\(taskType) contentLen=\(content.count)")
            case .ambiguous(let matches):
                let list = matches.joined(separator: "、")
                ws.sendToolResponse(callId: callId, result: nil, error: "找到多个匹配模板：\(list)")
                print("[Tool] load_template ambiguous target=\(target) matches=\(matches)")
            case .miss:
                ws.sendToolResponse(callId: callId, result: nil, error: "未找到模板「\(target)」")
                print("[Tool] load_template miss target=\(target)")
            }
            return
        }
        if name == "create_template" {
            let templateName = (arguments["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let templateContent = (arguments["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !templateName.isEmpty, !templateContent.isEmpty else {
                print("[Tool] create_template missing or empty fields, callId=\(callId) args=\(arguments)")
                ws.sendToolResponse(callId: callId, result: nil, error: "模板名称或内容不能为空")
                return
            }
            print("[Tool] create_template name=\(templateName) contentLen=\(templateContent.count)")
            // 先把流式中的句子固化为消息，避免顺序错位
            ttsStreamBuffer.flushAndReset()
            pendingCreateTemplate = OutboundTemplateRequest(id: callId, name: templateName, content: templateContent)
            print("[OutboundAI][Tool] pendingCreateTemplate set callId=\(callId) name=\(templateName)")
            return
        }
        if name == "initiate_call" {
            let phone = (arguments["phone"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let templateName = (arguments["template_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !phone.isEmpty, !templateName.isEmpty else {
                print("[Tool] initiate_call missing fields, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "电话号码或模板名称不能为空")
                return
            }
            if pendingInitiateCall != nil || pendingScheduleCall != nil {
                ws.sendToolResponse(callId: callId, result: nil, error: "已有一通外呼待确认，请先处理")
                print("[Tool] initiate_call rejected: pending outbound exists")
                return
            }
            if !isValidPhoneFormat(phone) {
                ws.sendToolResponse(callId: callId, result: nil, error: "号码格式不正确：\(phone)")
                print("[Tool] initiate_call rejected: invalid phone=\(phone)")
                return
            }
            if let templateErr = outboundTemplatePrecheckError(name: templateName) {
                ws.sendToolResponse(callId: callId, result: nil, error: templateErr)
                print("[Tool] initiate_call rejected: template=\(templateName) err=\(templateErr)")
                return
            }
            print("[Tool] initiate_call phone=\(phone) template=\(templateName)")
            // 先把流式中的句子固化为消息，避免顺序错位
            ttsStreamBuffer.flushAndReset()
            pendingInitiateCall = OutboundCallRequest(id: callId, phone: phone, templateName: templateName)
            return
        }
        if name == "display_guide_image" {
            guard let imageId = arguments["image_id"] as? String,
                  !imageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[WS] display_guide_image missing image_id, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "缺少 image_id")
                return
            }
            let caption = arguments["caption"] as? String
            // 先把当前正在逐字输出的句子提交到 messages，再设置 pendingGuideImage。
            // 这样 SwiftUI 在同一次批量刷新中先处理 messages.count 变化（追加文字气泡），
            // 再处理 pendingGuideImage 变化（追加图片卡片），保证顺序正确。
            ttsStreamBuffer.flushAndReset()
            pendingGuideImage = GuideImageRequest(id: callId, imageId: imageId.trimmingCharacters(in: .whitespacesAndNewlines), caption: caption)
            ws.sendToolResponse(callId: callId, result: ["success": true])
            print("[WS] display_guide_image imageId=\(pendingGuideImage!.imageId) callId=\(callId)")
            return
        }
        if name == "display_guide_card" {
            guard let cardId = arguments["card_id"] as? String,
                  !cardId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[WS] display_guide_card missing card_id, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "缺少 card_id")
                return
            }
            // 先把当前正在流式输出的句子提交到 messages，保证文字气泡顺序正确
            ttsStreamBuffer.flushAndReset()
            pendingGuideCard = GuideCardRequest(id: callId, cardId: cardId.trimmingCharacters(in: .whitespacesAndNewlines))
            print("[WS] display_guide_card cardId=\(pendingGuideCard!.cardId) callId=\(callId)")
            return
        }
        if name == "schedule_call" {
            let phone = (arguments["phone"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let templateName = (arguments["template_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !phone.isEmpty, !templateName.isEmpty else {
                print("[Tool] schedule_call missing fields, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "电话号码或模板名称不能为空")
                return
            }
            if pendingInitiateCall != nil || pendingScheduleCall != nil {
                ws.sendToolResponse(callId: callId, result: nil, error: "已有一通外呼待确认，请先处理")
                print("[Tool] schedule_call rejected: pending outbound exists")
                return
            }
            if !isValidPhoneFormat(phone) {
                ws.sendToolResponse(callId: callId, result: nil, error: "号码格式不正确：\(phone)")
                print("[Tool] schedule_call rejected: invalid phone=\(phone)")
                return
            }
            if let templateErr = outboundTemplatePrecheckError(name: templateName) {
                ws.sendToolResponse(callId: callId, result: nil, error: templateErr)
                print("[Tool] schedule_call rejected: template=\(templateName) err=\(templateErr)")
                return
            }
            let timeDescription = (arguments["time_description"] as? String) ?? ""
            // Resolve scheduled time from absolute ISO string or relative minutes_from_now
            let scheduledAt: Date
            if let isoString = (arguments["scheduled_time"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !isoString.isEmpty {
                if let parsed = parseISODate(isoString) {
                    scheduledAt = parsed
                } else {
                    print("[Tool] schedule_call invalid scheduled_time=\(isoString)")
                    ws.sendToolResponse(callId: callId, result: nil, error: "时间格式无法识别：\(isoString)")
                    return
                }
            } else if let minutes = arguments["minutes_from_now"] as? Int, minutes > 0 {
                scheduledAt = Date().addingTimeInterval(Double(minutes) * 60.0)
            } else {
                print("[Tool] schedule_call no valid time provided, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "请提供 scheduled_time 或 minutes_from_now")
                return
            }
            // Reject times in the past (allow 30s slack)
            guard scheduledAt > Date().addingTimeInterval(-30) else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                ws.sendToolResponse(
                    callId: callId,
                    result: nil,
                    error: "时间已过：\(formatter.string(from: scheduledAt))"
                )
                print("[Tool] schedule_call time is in the past: \(scheduledAt)")
                return
            }
            if let conflict = findScheduleConflict(scheduledAt: scheduledAt) {
                ws.sendToolResponse(callId: callId, result: nil, error: conflict)
                print("[Tool] schedule_call rejected: conflict=\(conflict)")
                return
            }
            print("[Tool] schedule_call phone=\(phone) template=\(templateName) scheduledAt=\(scheduledAt) desc=\(timeDescription)")
            // 先把流式中的句子固化为消息，避免顺序错位
            ttsStreamBuffer.flushAndReset()
            pendingScheduleCall = OutboundScheduleCallRequest(
                id: callId,
                phone: phone,
                templateName: templateName,
                scheduledAt: scheduledAt,
                timeDescription: timeDescription
            )
            return
        }
        guard name == "display_rule_change" else {
            if scene == .updateConfig {
                print("\(WebSocketService.outboundAIUCv1Tag) tool_no_handler side=client name=\(name) call_id=\(callId) note=no_matching_branch")
            }
            print("[WS] tool_call ignored name=\(name) args=\(arguments)")
            return
        }
        print("[WS] display_rule_change rawArgs=\(arguments)")
        guard let originalRule = arguments["original_rule"] as? String,
              let updatedRuleSummary = arguments["updated_rule_summary"] as? String,
              let updatedRulesRaw = arguments["updated_rules"] as? [[String: Any]] else {
            print("[WS] display_rule_change missing fields")
            ws.sendToolResponse(callId: callId, result: nil, error: "规则变更参数不完整")
            return
        }
        let updatedRules: [RuleChangeItem] = updatedRulesRaw.compactMap { item in
            guard let type = item["type"] as? String,
                  let rule = item["rule"] as? String,
                  let action = item["action"] as? String else {
                return nil
            }
            let id = (item["id"] as? String) ?? UUID().uuidString
            return RuleChangeItem(id: id, type: type, rule: rule, action: action)
        }
        pendingRuleChange = RuleChangeRequest(
            id: callId,
            originalRule: originalRule,
            updatedRuleSummary: updatedRuleSummary,
            updatedRules: updatedRules
        )
    }

    // MARK: - update_config tool helpers (v1)

    /// Lightweight phone-format gate: ≥5 digits, only `+` / `-` / spaces / digits.
    /// Spec §3.6 requires a human-readable error like "号码格式不正确：1234".
    func isValidPhoneFormat(_ phone: String) -> Bool {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789+-() ")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }
        let digitsOnly = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        return digitsOnly.count >= 5
    }

    /// Spec §3.6/§3.7: pre-validate template before popping a card — same resolution
    /// as `load_template`, but **ambiguous** names must not proceed (error to server).
    /// - Returns: `nil` if exactly one template matches; otherwise a human-readable `error` string.
    func outboundTemplatePrecheckError(name: String) -> String? {
        switch OutboundTemplateStore.lookup(name: name) {
        case .hit:
            return nil
        case .ambiguous(let matches):
            let list = matches.joined(separator: "、")
            return "找到多个匹配模板：\(list)"
        case .miss:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "未找到模板「\(trimmed)」"
        }
    }

    /// ISO 8601 with or without timezone — both accepted.
    func parseISODate(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let parsed = formatter.date(from: isoString) {
            return parsed
        }
        let fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fallback.locale = Locale(identifier: "en_US_POSIX")
        return fallback.date(from: isoString)
    }

    /// Spec §3.7: detect a ±5min window collision with an existing scheduled task.
    /// Returns the human-readable error text, or nil when no conflict.
    func findScheduleConflict(scheduledAt: Date) -> String? {
        let conflictWindow: TimeInterval = 5 * 60
        let tasks = OutboundTaskStore.load()
        for task in tasks where task.status == .scheduled {
            guard let existing = task.scheduledAt else { continue }
            if abs(existing.timeIntervalSince(scheduledAt)) <= conflictWindow {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "HH:mm"
                let lower = existing.addingTimeInterval(-conflictWindow)
                let upper = existing.addingTimeInterval(conflictWindow)
                return "与已有定时任务「\(task.promptType)」冲突（\(formatter.string(from: lower)) - \(formatter.string(from: upper))）"
            }
        }
        return nil
    }

    // MARK: - TTS Uplink Drain

    func bindBLEUplinkReadyCallback() {
        ble.onAudioWriteWindowOpen = { [weak self] in
            // peripheralIsReady fires on bleQueue; hop to MainActor so the
            // ttsUplinkDrainTask nil-check and task creation are always
            // performed on the actor that owns them, avoiding stale reads
            // that would silently skip the drain restart.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleTTSUplinkDrain(reason: "ble_write_window_open")
            }
        }
    }

    func scheduleTTSUplinkDrain(reason: String) {
        audioRouter.scheduleTTSUplinkDrainIfNeeded(
            canStart: { [weak self] in
                guard let self else { return false }
                guard self.inputSource == .ble else { return false }
                guard self.bleAudioStartAcked else { return false }
                return self.audioRouter.hasUplinkData()
            },
            shouldRetryNoProgressSoon: { [weak self] in
                guard let self else { return false }
                guard self.audioRouter.hasUplinkData() else { return false }
                if self.audioRouter.emergencyBGMPendingSeconds() > 0 { return true }
                // Keep drain alive while BLE TX is blocked (pending writes at soft cap).
                // Without this, drain exits immediately on sent=0 and misses
                // the brief windows when canSendWriteWithoutResponse recovers.
                if self.ble.pendingAudioWriteCount > 0 { return true }
                return false
            },
            onCompleted: { [weak self] rounds in
                guard let self else { return }
                if rounds > 0 && self.audioRouter.isTTSStopped() && !self.audioRouter.hasUplinkData() {
                  //  print("[TTS->BLE] drain task completed after TTS stop rounds=\(rounds)")
                }
            },
            onFirstSend: { [weak self] in
                guard let self else { return }
                if self.tBleFirstUpSendNs == nil {
                    self.latFirstBleUplinkAt = Date()
                    self.latencyLog("ble_first_tts_uplink_send_to_mcu")
                    self.traceMark("BLE_uplink_first_send(to_mcu)", store: &self.tBleFirstUpSendNs)
                    self.traceLogDelta("WS_down->BLE_up_first_send", self.tWsFirstDownRxNs, self.tBleFirstUpSendNs)
                    self.traceLogDelta("enqueue->BLE_up_first_send", self.tTtsFirstEnqueueNs, self.tBleFirstUpSendNs)
                }
            },
            currentBLEPendingWriteCount: { [weak self] in
                self?.ble.pendingAudioWriteCount ?? 0
            },
            pendingSoftCap: ttsUplinkPendingSoftCap,
            sendOpus: { [weak self] payload in
                self?.ble.sendUplinkOpus(payload)
            },
            reason: reason
        )
    }

    @discardableResult
    func drainTTSUplinkOnce(reason: String) -> Int {
        let result = audioRouter.drainTTSUplinkOnce(
            reason: reason,
            currentBLEPendingWriteCount: { self.ble.pendingAudioWriteCount },
            pendingSoftCap: ttsUplinkPendingSoftCap,
            ttsUplinkSpeedX: ttsUplinkSpeedX,
            onFirstSend: {
                if tBleFirstUpSendNs == nil {
                    latFirstBleUplinkAt = Date()
                    latencyLog("ble_first_tts_uplink_send_to_mcu")
                    traceMark("BLE_uplink_first_send(to_mcu)", store: &tBleFirstUpSendNs)
                    traceLogDelta("WS_down->BLE_up_first_send", tWsFirstDownRxNs, tBleFirstUpSendNs)
                    traceLogDelta("enqueue->BLE_up_first_send", tTtsFirstEnqueueNs, tBleFirstUpSendNs)
                }
            },
            sendOpus: { payload in
                ble.sendUplinkOpus(payload)
            }
        )
        let sentCounters = audioRouter.uplinkSentCounters()

        if verboseRealtimeAudioLoggingEnabled,
           result.sent > 0,
           (sentCounters.sentFrames <= 3 || (sentCounters.sentFrames % 20) == 0) {
            print("[TTS->BLE] drain(\(reason)): frames=\(sentCounters.sentFrames) bytes=\(sentCounters.sentBytes) q=\(audioRouter.uplinkQueueCount()) speed=\(result.speedThisRound)x pendingBLE=\(ble.pendingAudioWriteCount)")
        }
        if let audioSec = result.probeCompletedAudioSec, let elapsed = result.probeCompletedElapsedSec {
            let speedX = audioSec / elapsed
            print(String(format: "[FASTCHK][iOS] emergency_bgm send_done audio=%.2fs elapsed=%.2fs speed=%.2fx q_now=%d",
                         audioSec,
                         elapsed,
                         speedX,
                         audioRouter.uplinkQueueCount()))
        }
        return result.sent
    }

    func stopTTSUplinkTimer() {
        audioRouter.resetUplinkState()
    }

    func webSocketDidReceiveError(message: String) {
        guard isActiveController else { return }
        lastErrorMessage = message
        // If connect() failed before websocketDidConnect/websocketDidDisconnect,
        // unblock manual push-to-talk retry path.
        manualReconnectInFlight = false
        if status == .ringing || pendingIncomingCall != nil {
            Task { @MainActor in
                if message.contains("MCU is not connected or device-id is unavailable") {
                    AbnormalCallRecordStore.shared.append(reasonCode: "device_id_not_synced")
                } else {
                    AbnormalCallRecordStore.shared.append(reasonCode: "websocket_connect_failed", detail: message)
                }
            }
        }
        if message.contains("MCU is not connected or device-id is unavailable") {
            toastMessage = language == .zh
                ? "请先连接 EchoCard"
                : "Please connect EchoCard first"
        }
    }

    func webSocketDidReceiveAIHangup() {
        guard isActiveController else { return }
        // AI 主动挂断：标记后延时结束通话
        print("[CallSession] AI 主动挂断，设置 isAIHangup = true")
        isAIHangup = true
        aiHangupReactionTask?.cancel()
        aiHangupReactionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let delaySec = self.disconnectReactionDelaySec
            if delaySec > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            defer { self.aiHangupReactionTask = nil }
            guard self.isActiveController else { return }

            // Avoid race: TTS-stop drain timer and AI-hangup delayed end should not
            // fight over playback/session teardown.
            self.audioRouter.cancelTTSStopPlaybackTask()
            self.logTTSTrace("ai_hangup_rx")
            self.releaseMicGuardForTTS()
            if self.inputSource == .ble {
                if self.shouldSuppressBLEHangup {
                    print("[CallSession] AI hangup suppressed due to passthrough")
                } else {
                    self.suppressBLEAutoReconnectBeforeIntentionalMCUHangup(reason: "ai_hangup")
                    self.sendCallCommand("hangup", expectAck: false)
                    self.sendCallCommand("audio_stop", expectAck: false)
                }
            }
            print(String(format: "[CallSession] 延迟结束（%.2fs），调用 end()", delaySec))
            self.end()
        }
    }
}

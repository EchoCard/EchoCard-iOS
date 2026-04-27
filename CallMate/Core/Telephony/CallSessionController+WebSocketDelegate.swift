import Foundation

// MARK: - WebSocketServiceDelegate

extension CallSessionController: WebSocketServiceDelegate {
    func webSocketDidConnect(sessionId: String) {
        guard isActiveController else { return }
        hasReceivedWSHelloInCurrentCall = true
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
            return
        }
        handleWSConnectMicrophoneFlowIfNeeded()
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
                let delaySec = self.disconnectReactionDelaySec
                if delaySec > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                defer { self.bleWSDisconnectReactionTask = nil }
                guard self.isActiveController else { return }
                guard !self.ws.isConnected else {
                    print(String(format: "[CallSession] WS recovered within %.2fs; skip delayed disconnect handling", delaySec))
                    return
                }
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
            self.ws.connect(audioFormat: audioFormat, scene: .call, reason: "scheduleWSNoHelloRetry_\(attempt)")
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
        // Realtime / BLE TTS start audio setup is delegated to audio router.
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
        currentTTSText = ""
        currentSTTText = ""
        // flushAndReset: 若上一句还在逐字播出，把完整文字提交到消息列表后再清空，
        // 避免 tool_call 触发新 tts_start 时正在显示的流式气泡和文字消失。
        ttsStreamBuffer.flushAndReset()

        // Reset TTS audio counters (drain starts when first audio frame arrives)
        ttsAudioRxCount = 0
        ttsAudioRxBytes = 0
        ttsBinaryRxBatchStartAt = nil
        ttsBinaryRxBatchStartPendingFrames = 0

        // Reset uplink counters for BLE (don't start drain yet; wait for first audio frame)
        if inputSource == .ble {
            audioRouter.startNewTTSBoostWindow(boostMs: ttsUplinkBoostMs)
            // Note: drain is kicked in webSocketDidReceiveTTSAudio when first frame arrives
        }
    }

    func webSocketDidReceiveTTSAudio(data: Data) {
        guard isActiveController else { return }
        traceMark("WS_downlink_first_rx(binary)", store: &tWsFirstDownRxNs)
        // Debug: confirm delegate call arrives
        lastTtsAudioRxAt = Date()
        audioRouter.cancelTTSStopPlaybackTask()
        ttsAudioRxCount += 1
        ttsAudioRxBytes += data.count
        let pendingFramesNow = audio.effectivePendingPlaybackBufferCount()
        if ttsAudioRxCount == 1 {
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
            // Re-assert speaker preference on first audible frame in case
            // session/route changed during startListening/startRecording.
            audioRouter.reassertSpeakerOnFirstTTSAudioFrameIfNeeded(
                monitorTTSOnPhone: monitorTTSOnPhone,
                isSpeakerEnabled: isSpeaker
            )
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
        }
        // If server sent binary before "tts" state "start", playback was never prepared and every frame
        // would be dropped (isPlaying false or decoder nil). On first frame when monitoring on phone,
        // ensure we prepare with fallback sample rate so this frame and the rest can play.
        if ttsAudioRxCount == 1 && monitorTTSOnPhone {
            let sampleRate = currentTTSSampleRate > 0 ? currentTTSSampleRate : ws.downstreamSampleRate
            audioRouter.prepareForTTSStart(
                monitorTTSOnPhone: monitorTTSOnPhone,
                inputSource: inputSource,
                scene: scene,
                sampleRate: sampleRate,
                isSpeaker: isSpeaker
            )
        }
        audioRouter.consumeIncomingTTSAudioFrame(
            data: data,
            monitorTTSOnPhone: monitorTTSOnPhone
        )
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
        // 通知缓冲区不再有新句子；缓冲区会继续流式输出剩余字符，
        // 排空后自动回调 onFinished 把文本固化到 messages。
        ttsStreamBuffer.markDone()

        ttsStopCount += 1
        print("[MIC_CHAIN] tts_stop_rx: ttsStopCount=\(ttsStopCount) micGuard=\(micMutedByTTSGuard) wsListeningStarted=\(wsListeningStarted) monitorOnPhone=\(monitorTTSOnPhone)")
        logTTSTrace("tts_stop_rx")
        print("[TTS->BLE] webSocketDidReceiveTTSStop: setting ttsStopped=true, q=\(audioRouter.uplinkQueueCount()) ttsStopCount=\(ttsStopCount)")
        if monitorTTSOnPhone {
            let frameDurationMs = max(1, ws.downstreamFrameDuration)
            let baseGrace: TimeInterval = scene.isManualInteractionScene ? 8.0 : 4.0
            let window = audioRouter.estimateTTSStopDrainWindow(
                frameDurationMs: frameDurationMs,
                baseGrace: baseGrace
            )
            print(String(format: "[CallSession] TTS stop: pending estimate=%.2f s timeout=%.2f s frameMs=%d",
                         window.pendingEstimate, window.timeout, frameDurationMs))

            // Keep playback alive until:
            // 1) No new TTS binary frames for minSilenceAfterLastAudio seconds
            //    (guards against jittery links where tts_stop arrives before tail frames).
            // 2) The silence window covers at least one frame duration + small buffer
            //    because scheduleBuffer completion fires when rendering STARTS not ends,
            //    so hasPendingPlaybackBuffers() can return false while audio is still audible.
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
        } else {
            releaseMicGuardForTTS()
        }
        audioRouter.stopRecordingForConfigIfNeeded(scene: scene, wsListeningStarted: wsListeningStarted)
        // Signal drain task to exit after draining remaining queue
        audioRouter.setTTSStopped(true)
        // First TTS has completed; subsequent TTS can use latency-bounding drops.
        if inputSource == .ble {
            isFirstTTSInCall = false
        }
    }

    func webSocketDidReceiveToolCall(callId: String, name: String, arguments: [String: Any]) {
        guard isActiveController else {
            print("[OutboundAI][Tool] dropped (not active controller) name=\(name) callId=\(callId) — another session may own WS")
            return
        }
        print("[OutboundAI][Tool] recv name=\(name) scene=\(scene.rawValue) callId=\(callId) argKeys=\(Array(arguments.keys))")
        if name == "notify_owner_to_pickup" {
            handleNotifyOwnerToPickup(callId: callId, arguments: arguments)
            return
        }
        if name == "save_user_appellation" {
            print("[Tool] save_user_appellation called, arguments=\(arguments)")
            if let appellation = arguments["appellation"] as? String,
               !appellation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(appellation, forKey: "callmate.userAppellation")
                print("[Tool] save_user_appellation saved appellation=\(appellation)")
            } else {
                print("[Tool] save_user_appellation skipped: appellation missing or empty")
            }
            ws.sendToolResponse(callId: callId, result: ["success": true])
            print("[Tool] save_user_appellation responded success, callId=\(callId)")
            return
        }
        if name == "create_template" {
            guard let templateName = arguments["name"] as? String,
                  let templateContent = arguments["content"] as? String,
                  !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !templateContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[Tool] create_template missing or empty fields, callId=\(callId) args=\(arguments)")
                ws.sendToolResponse(callId: callId, result: nil, error: "模板名称或内容不能为空")
                return
            }
            print("[Tool] create_template name=\(templateName) contentLen=\(templateContent.count)")
            pendingCreateTemplate = OutboundTemplateRequest(id: callId, name: templateName, content: templateContent)
            print("[OutboundAI][Tool] pendingCreateTemplate set callId=\(callId) name=\(templateName)")
            return
        }
        if name == "initiate_call" {
            guard let phone = arguments["phone"] as? String,
                  let templateName = arguments["template_name"] as? String,
                  !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[Tool] initiate_call missing fields, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "电话号码或模板名称不能为空")
                return
            }
            let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTemplateName = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[Tool] initiate_call phone=\(cleanPhone) template=\(cleanTemplateName)")
            pendingInitiateCall = OutboundCallRequest(id: callId, phone: cleanPhone, templateName: cleanTemplateName)
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
            guard let phone = arguments["phone"] as? String,
                  let templateName = arguments["template_name"] as? String,
                  !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[Tool] schedule_call missing fields, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "电话号码或模板名称不能为空")
                return
            }
            let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTemplateName = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
            let timeDescription = (arguments["time_description"] as? String) ?? ""
            // Resolve scheduled time from absolute ISO string or relative minutes_from_now
            let scheduledAt: Date
            if let isoString = arguments["scheduled_time"] as? String,
               !isoString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                if let parsed = formatter.date(from: isoString) {
                    scheduledAt = parsed
                } else {
                    // Try without timezone
                    let fallbackFormatter = DateFormatter()
                    fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                    if let parsed = fallbackFormatter.date(from: isoString) {
                        scheduledAt = parsed
                    } else {
                        print("[Tool] schedule_call invalid scheduled_time=\(isoString)")
                        ws.sendToolResponse(callId: callId, result: nil, error: "时间格式解析失败，请使用 ISO 8601 格式")
                        return
                    }
                }
            } else if let minutes = arguments["minutes_from_now"] as? Int, minutes > 0 {
                scheduledAt = Date().addingTimeInterval(Double(minutes) * 60.0)
            } else {
                print("[Tool] schedule_call no valid time provided, callId=\(callId)")
                ws.sendToolResponse(callId: callId, result: nil, error: "请提供 scheduled_time 或 minutes_from_now")
                return
            }
            // Reject times in the past
            guard scheduledAt > Date().addingTimeInterval(-30) else {
                print("[Tool] schedule_call time is in the past: \(scheduledAt)")
                ws.sendToolResponse(callId: callId, result: nil, error: "预定时间已过，请重新指定")
                return
            }
            print("[Tool] schedule_call phone=\(cleanPhone) template=\(cleanTemplateName) scheduledAt=\(scheduledAt) desc=\(timeDescription)")
            pendingScheduleCall = OutboundScheduleCallRequest(
                id: callId,
                phone: cleanPhone,
                templateName: cleanTemplateName,
                scheduledAt: scheduledAt,
                timeDescription: timeDescription
            )
            return
        }
        guard name == "display_rule_change" else {
            print("[WS] tool_call ignored name=\(name) args=\(arguments)")
            return
        }
        print("[WS] display_rule_change rawArgs=\(arguments)")
        guard let originalRule = arguments["original_rule"] as? String,
              let updatedRuleSummary = arguments["updated_rule_summary"] as? String,
              let updatedRulesRaw = arguments["updated_rules"] as? [[String: Any]] else {
            print("[WS] display_rule_change missing fields")
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
            drainOnce: { [weak self] reason in
                guard let self else { return 0 }
                return self.drainTTSUplinkOnce(reason: reason)
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
                    self.sendCallCommand("hangup", expectAck: false)
                    self.sendCallCommand("audio_stop", expectAck: false)
                }
            }
            print(String(format: "[CallSession] 延迟结束（%.2fs），调用 end()", delaySec))
            self.end()
        }
    }
}

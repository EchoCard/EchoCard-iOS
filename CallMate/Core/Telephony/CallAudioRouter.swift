import Foundation

/// Lock-protected container for the TTS uplink queue and its counters.
///
/// Before: `CallAudioRouter` held `ttsUplinkQueue` / `ttsUplink*Frames/Bytes` as plain
/// `@MainActor` fields, so every TTS binary frame from the WebSocket receive queue had to
/// hop to main just to be enqueued. Under UI stalls this silently delayed BLE uplink audio.
///
/// Now: all queue + counter state lives inside `TTSUplinkState`, guarded by a single
/// `NSLock`. The nonisolated fast-enqueue path (`CallAudioRouter.enqueueTTSUplinkAudio`)
/// and the @MainActor drain loop (`CallAudioRouter.takeUplinkDrainBatch`) share the same
/// lock, which is held only for the trivial append / removeFirst / counter bumps.
nonisolated final class TTSUplinkState: @unchecked Sendable {
    struct Counters {
        var enqueuedFrames: Int = 0
        var enqueuedBytes: Int = 0
        var sentFrames: Int = 0
        var sentBytes: Int = 0
        var droppedFrames: Int = 0
    }

    struct EnqueueOutcome {
        let queueCount: Int
        let enqueuedFrames: Int
        let enqueuedBytes: Int
        /// -1 on first enqueue in the session.
        let dtMs: Int
        let totalEnqueueCalls: Int
        let droppedCount: Int
        let droppedReason: String?
    }

    struct FlowSnapshot {
        let queueCount: Int
        let enqueuedFrames: Int
        let sentFrames: Int
        let droppedFrames: Int
        let fps: Double
        let elapsed: Double
    }

    private let lock = NSLock()
    private var queue: [Data] = []
    private var counters = Counters()
    private var enqueueLastAt: Date = .distantPast
    private var enqueueTotalFrames: Int = 0
    private var lastLogAt: Date = .distantPast
    private var flowWindowStartAt: Date = .distantPast
    private var flowSentFramesInWindow: Int = 0

    init() {}

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    var isEmpty: Bool { count == 0 }

    func snapshotCounters() -> Counters {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    /// Append `data` to the uplink queue under lock, then trim to `maxItems` (or `max(maxItems, 8)`
    /// when `preAckOrFirst` is true). Mirrors the original `enqueueTTSUplinkAudio` logic exactly.
    func enqueueAndTrim(_ data: Data, maxItems: Int, preAckOrFirst: Bool) -> EnqueueOutcome {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let dtMs = (enqueueLastAt == .distantPast) ? -1 : Int(now.timeIntervalSince(enqueueLastAt) * 1000)
        enqueueLastAt = now
        enqueueTotalFrames += 1

        queue.append(data)
        counters.enqueuedFrames += 1
        counters.enqueuedBytes += data.count

        var droppedCount = 0
        var droppedReason: String? = nil
        if preAckOrFirst {
            let cap = max(maxItems, 8)
            if queue.count > cap {
                let drop = queue.count - cap
                if drop > 0 {
                    queue.removeFirst(drop)
                    counters.droppedFrames += drop
                    droppedCount = drop
                    droppedReason = "pre-ack cap(opus)"
                }
            }
        } else if queue.count > maxItems {
            let drop = queue.count - maxItems
            if drop > 0 {
                queue.removeFirst(drop)
                counters.droppedFrames += drop
                droppedCount = drop
                droppedReason = "queue cap(opus)"
            }
        }
        return EnqueueOutcome(
            queueCount: queue.count,
            enqueuedFrames: counters.enqueuedFrames,
            enqueuedBytes: counters.enqueuedBytes,
            dtMs: dtMs,
            totalEnqueueCalls: enqueueTotalFrames,
            droppedCount: droppedCount,
            droppedReason: droppedReason
        )
    }

    func tryRemoveFirst() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    func insertAtFront(_ data: Data) {
        lock.lock(); queue.insert(data, at: 0); lock.unlock()
    }

    func recordSent(bytes: Int) {
        lock.lock()
        counters.sentFrames += 1
        counters.sentBytes += bytes
        lock.unlock()
    }

    func recordSentAndMaybeFlowLog(bytes: Int, now: Date = Date()) -> FlowSnapshot? {
        lock.lock(); defer { lock.unlock() }
        counters.sentFrames += 1
        counters.sentBytes += bytes
        if flowWindowStartAt == .distantPast {
            flowWindowStartAt = now
            flowSentFramesInWindow = 0
        }
        flowSentFramesInWindow += 1
        let elapsed = now.timeIntervalSince(flowWindowStartAt)
        guard elapsed >= 2.0 else { return nil }
        let fps = elapsed > 0 ? Double(flowSentFramesInWindow) / elapsed : 0
        let snapshot = FlowSnapshot(
            queueCount: queue.count,
            enqueuedFrames: counters.enqueuedFrames,
            sentFrames: counters.sentFrames,
            droppedFrames: counters.droppedFrames,
            fps: fps,
            elapsed: elapsed
        )
        flowWindowStartAt = now
        flowSentFramesInWindow = 0
        return snapshot
    }

    func appendAll(_ items: [Data]) {
        lock.lock(); queue.append(contentsOf: items); lock.unlock()
    }

    func clearQueue() {
        lock.lock(); queue.removeAll(); lock.unlock()
    }

    func resetCounters() {
        lock.lock()
        counters = Counters()
        lastLogAt = .distantPast
        flowWindowStartAt = .distantPast
        flowSentFramesInWindow = 0
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        queue.removeAll()
        counters = Counters()
        enqueueLastAt = .distantPast
        enqueueTotalFrames = 0
        lastLogAt = .distantPast
        flowWindowStartAt = .distantPast
        flowSentFramesInWindow = 0
        lock.unlock()
    }

    /// Returns true and updates `lastLogAt` if the throttling window has elapsed.
    func shouldLogUplinkEnqueue(now: Date, intervalSec: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(lastLogAt) > intervalSec else { return false }
        lastLogAt = now
        return true
    }
}

@MainActor
final class CallAudioRouter {
    struct UplinkCounters {
        var sentFrames: Int
        var sentBytes: Int
    }

    struct DrainResult {
        let sent: Int
        let speedThisRound: Int
        let probeCompletedAudioSec: Double?
        let probeCompletedElapsedSec: Double?
    }

    struct UplinkEnqueueCounters {
        var enqueuedFrames: Int
        var enqueuedBytes: Int
    }

    struct UplinkEnqueueResult {
        let queueCount: Int
        let counters: UplinkEnqueueCounters
    }

    private let audio: AudioService
    private var audioStartRetryTask: Task<Void, Never>?
    private var audioFlowWatchdogTask: Task<Void, Never>?
    private var ttsUplinkDrainTask: Task<Void, Never>?
    private var ttsUplinkDrainTimer: DispatchSourceTimer?
    private let ttsUplinkDrainQueue = DispatchQueue(label: "callmate.tts-uplink-drain", qos: .userInitiated)
    private var wsDisconnectDrainPlaybackTask: Task<Void, Never>?
    private var ttsStopPlaybackTask: Task<Void, Never>?
    /// Queue + counters shared between the nonisolated WS fast-enqueue path and the @MainActor
    /// drain loop. See `TTSUplinkState` at top of file for the locking discipline.
    nonisolated let uplinkState = TTSUplinkState()
    private var ttsBoostUntil: Date = .distantPast
    // ---- TTS delivery diagnostics (drain-side, touched only on @MainActor) ----
    private var ttsDrainSentFrames: Int = 0             // frames sent in current 2s window
    private var ttsDrainWindowStart: Date = .distantPast
    private let ttsUplinkFrameDurationNs: UInt64 = 58_000_000
    private let ttsUplinkCatchupFrameDurationNs: UInt64 = 45_000_000
    private let ttsUplinkCatchupQueueThreshold: Int = 8
    private var emergencyBGMProbeFramesRemaining: Int = 0
    private var emergencyBGMProbeFramesTotal: Int = 0
    private var emergencyBGMProbeFrameDurationMs: Double = 0
    private var emergencyBGMProbeStartAt: Date?
    private var emergencyBGMPacedSentMs: Double = 0
    private var ttsStopped: Bool = false

    init(audio: AudioService) {
        self.audio = audio
    }

    func cancelAudioStartRetryLoop() {
        audioStartRetryTask?.cancel()
        audioStartRetryTask = nil
    }

    func cancelAudioFlowWatchdog() {
        audioFlowWatchdogTask?.cancel()
        audioFlowWatchdogTask = nil
    }

    func cancelBLEAudioFlowTasks() {
        cancelAudioStartRetryLoop()
        cancelAudioFlowWatchdog()
    }

    func cancelTTSUplinkDrain() {
        ttsUplinkDrainTask?.cancel()
        ttsUplinkDrainTask = nil
        ttsUplinkDrainTimer?.cancel()
        ttsUplinkDrainTimer = nil
    }

    func cancelWSDisconnectDrainPlaybackTask() {
        wsDisconnectDrainPlaybackTask?.cancel()
        wsDisconnectDrainPlaybackTask = nil
    }

    func cancelTTSStopPlaybackTask() {
        ttsStopPlaybackTask?.cancel()
        ttsStopPlaybackTask = nil
    }

    func uplinkQueueCount() -> Int {
        uplinkState.count
    }

    func hasUplinkData() -> Bool {
        !uplinkState.isEmpty
    }

    func isTTSStopped() -> Bool {
        ttsStopped
    }

    func setTTSStopped(_ stopped: Bool) {
        ttsStopped = stopped
    }

    func configureEmergencyBGMProbe(totalFrames: Int, frameDurationMs: Double) -> Double {
        emergencyBGMProbeFramesTotal = totalFrames
        emergencyBGMProbeFramesRemaining = totalFrames
        emergencyBGMProbeFrameDurationMs = frameDurationMs
        emergencyBGMProbeStartAt = nil
        emergencyBGMPacedSentMs = 0
        return (Double(totalFrames) * frameDurationMs) / 1000.0
    }

    func emergencyBGMPendingSeconds() -> Double {
        guard emergencyBGMProbeFramesRemaining > 0 else { return 0 }
        return (Double(emergencyBGMProbeFramesRemaining) * emergencyBGMProbeFrameDurationMs) / 1000.0
    }

    func startNewTTSBoostWindow(boostMs: Int) {
        ttsBoostUntil = Date().addingTimeInterval(TimeInterval(boostMs) / 1000.0)
        uplinkState.resetCounters()
        ttsStopped = false
    }

    nonisolated func shouldLogUplinkEnqueue(now: Date = Date(), intervalSec: Double = 2.0) -> Bool {
        uplinkState.shouldLogUplinkEnqueue(now: now, intervalSec: intervalSec)
    }

    func uplinkEnqueueCounters() -> UplinkEnqueueCounters {
        let c = uplinkState.snapshotCounters()
        return UplinkEnqueueCounters(
            enqueuedFrames: c.enqueuedFrames,
            enqueuedBytes: c.enqueuedBytes
        )
    }

    func uplinkSentCounters() -> UplinkCounters {
        let c = uplinkState.snapshotCounters()
        return UplinkCounters(
            sentFrames: c.sentFrames,
            sentBytes: c.sentBytes
        )
    }

    func appendUplinkPackets(_ packets: [Data]) {
        uplinkState.appendAll(packets)
    }

    func clearUplinkQueue() {
        uplinkState.clearQueue()
    }

    func resetUplinkState() {
        cancelTTSUplinkDrain()
        uplinkState.resetAll()
        emergencyBGMProbeFramesRemaining = 0
        emergencyBGMProbeFramesTotal = 0
        emergencyBGMProbeFrameDurationMs = 0
        emergencyBGMProbeStartAt = nil
        emergencyBGMPacedSentMs = 0
        ttsStopped = false
        ttsDrainSentFrames = 0
        ttsDrainWindowStart = .distantPast
    }

    func setMuted(_ muted: Bool) {
        audio.isMicMuted = muted
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        audio.enableSpeaker(enabled)
    }

    func isPlaying() -> Bool {
        audio.isPlaying
    }

    /// 反映播放管线的"实际"健康状态（引擎在 running、player 仍 attached）。
    /// 用于「连续下行」路径判断是否需要重建管线 —— `isPlaying()` 仅是 @Published 标志，
    /// 路由变化或被中断时可能与真实状态不一致。
    func isPlaybackPipelineHealthy() -> Bool {
        audio.isPlaybackPipelineHealthy
    }

    func tryResumeContinuousOpusPlaybackIfPossible(sampleRate: Int, playbackOnly: Bool) -> Bool {
        audio.tryResumeContinuousOpusPlaybackIfPossible(sampleRate: sampleRate, playbackOnly: playbackOnly)
    }

    /// 模拟通话（mic + scene=.call）：用户不希望被附近的 BT/HFP 设备（包括已配对的 MCU）
    /// 抢走输出，要求始终走手机扬声器。BLE 通话则相反 —— MCU 自己就是 HFP 端点。
    private func shouldAllowBluetoothHFP(
        inputSource: CallSessionController.InputSource,
        scene: WebSocketScene
    ) -> Bool {
        if inputSource == .microphone && scene == .call { return false }
        return true
    }

    func reassertSpeakerOnFirstTTSAudioFrameIfNeeded(
        monitorTTSOnPhone: Bool,
        isSpeakerEnabled: Bool
    ) {
        guard monitorTTSOnPhone else { return }
        // playbackOnly 模式（AI 分身/配置场景）已使用 .playback 类别走喇叭+媒体音量，
        // 此时不能调 enableSpeaker，否则会切回 .playAndRecord+.voiceChat，
        // 导致音量变小且激活距离传感器（手机靠脸时切听筒）。
        guard !audio.isPlaybackOnlyMode else { return }
        audio.enableSpeaker(isSpeakerEnabled)
    }

    func stopForSessionEnd(inputSource: CallSessionController.InputSource) {
        cancelTTSStopPlaybackTask()
        if inputSource == .microphone {
            audio.stopRecording()
        }
        audio.stopPlayback()
    }

    func prepareForTTSStart(
        monitorTTSOnPhone: Bool,
        inputSource: CallSessionController.InputSource,
        scene: WebSocketScene,
        sampleRate: Int,
        isSpeaker: Bool
    ) {
        if monitorTTSOnPhone {
            let allowHFP = shouldAllowBluetoothHFP(inputSource: inputSource, scene: scene)
            if inputSource == .microphone && !scene.isManualInteractionScene && !audio.isRecording {
                try? audio.startRecording(
                    enableEchoCancellation: true,
                    allowBluetoothHFP: allowHFP
                )
            }
            // AI 分身/配置场景：TTS 始终用纯播放（.playback）走扬声器 + 媒体音量，避免听筒；
            // 主动打电话场景：始终走通话音频路径（.playAndRecord），确保对方能听到声音。
            let ttsPlaybackOnly = scene.isManualInteractionScene
            print("[CallAudioRouter] inputSource=\(inputSource) monitorOnPhone=\(monitorTTSOnPhone) allowHFP=\(allowHFP)")

            do {
                try audio.preparePlayback(
                    sampleRate: sampleRate,
                    playbackOnly: ttsPlaybackOnly,
                    allowBluetoothHFP: allowHFP
                )
            } catch {
                print("[CloudAudioProof] prepareForTTSStart_preparePlayback_FAILED sampleRate=\(sampleRate) playbackOnly=\(ttsPlaybackOnly) scene=\(scene.rawValue) err=\(error.localizedDescription)")
            }
            if !ttsPlaybackOnly {
                audio.enableSpeaker(isSpeaker)
            }
            return
        }

        audio.prepareDownstreamRecording(audioFormat: .opus, sampleRate: sampleRate)
    }

    func consumeIncomingTTSAudioFrame(
        data: Data,
        monitorTTSOnPhone: Bool
    ) {
        if monitorTTSOnPhone {
            audio.playOpusData(data)
            return
        }
        audio.recordDownstreamTTSAudioFrame(data, audioFormat: .opus)
    }

    func estimateTTSStopDrainWindow(
        frameDurationMs: Int,
        baseGrace: TimeInterval
    ) -> (pendingEstimate: Double, timeout: TimeInterval) {
        let pendingEstimate = audio.estimatedPendingPlaybackDuration(frameDurationMs: max(1, frameDurationMs))
        let timeout = min(30.0, max(baseGrace, pendingEstimate + 1.0))
        return (pendingEstimate, timeout)
    }

    /// - Parameter stopPipeline: 为 true 时 drain 后调用 `audio.stopPlayback()`；为 false 时只回调 onPlaybackStopped，不关管线（云端 TTS stop 后仍会持续下发背景音时应传 false，避免后续二进制被丢弃）。
    func stopPlaybackAfterDrain(
        timeout: TimeInterval,
        minSilenceAfterLastAudio: TimeInterval = 0,
        lastAudioRxAt: @escaping @MainActor () -> Date = { .distantPast },
        isActive: (@MainActor () -> Bool)? = nil,
        stopPipeline: Bool = true,
        onPlaybackStopped: (@MainActor () -> Void)? = nil
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            let pending = await MainActor.run { audio.hasPendingPlaybackBuffers() }
            let lastRx = await MainActor.run { lastAudioRxAt() }
            let silentLongEnough = minSilenceAfterLastAudio <= 0
                || Date().timeIntervalSince(lastRx) >= minSilenceAfterLastAudio
            if ((!pending && silentLongEnough) || Date() >= deadline) {
                let pendingStr = pending ? "yes" : "no"
                let silence = Date().timeIntervalSince(lastRx)
                print(String(format: "[CallAudioRouter] stopPlaybackAfterDrain trigger: pending=%@ silenceSinceLastAudio=%.2f s stopPipeline=%@", pendingStr, silence, stopPipeline ? "yes" : "no"))
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            // Guard: if a newer session has taken over, do not stop its audio.
            if let isActive, !isActive() {
                print("[CallAudioRouter] stopPlaybackAfterDrain: skip (controller no longer active)")
                return
            }
            if stopPipeline {
                audio.stopPlayback()
            } else {
                print("[CallAudioRouter] stopPlaybackAfterDrain: drain done, keeping pipeline (continuous background audio)")
            }
            onPlaybackStopped?()
        }
    }

    /// - Parameter stopPipeline: 为 false 时 drain 后不关播放管线，用于「TTS stop 后云端仍持续下发背景音」的场景。
    func scheduleTTSStopPlaybackAfterDrain(
        timeout: TimeInterval,
        minSilenceAfterLastAudio: TimeInterval,
        lastAudioRxAt: @escaping @MainActor () -> Date,
        isActive: (@MainActor () -> Bool)? = nil,
        stopPipeline: Bool = false,
        onPlaybackStopped: (@MainActor () -> Void)? = nil
    ) {
        cancelTTSStopPlaybackTask()
        print(String(format: "[TTS_MIN] schedule_stop_after_drain timeout=%.2f minSilence=%.2f stopPipeline=%@", timeout, minSilenceAfterLastAudio, stopPipeline ? "yes" : "no"))
        ttsStopPlaybackTask = Task { [weak self] in
            guard let self else { return }
            await self.stopPlaybackAfterDrain(
                timeout: timeout,
                minSilenceAfterLastAudio: minSilenceAfterLastAudio,
                lastAudioRxAt: lastAudioRxAt,
                isActive: isActive,
                stopPipeline: stopPipeline,
                onPlaybackStopped: onPlaybackStopped
            )
            print("[TTS_MIN] stop_after_drain_completed")
            self.ttsStopPlaybackTask = nil
        }
    }

    func scheduleWSDisconnectDrainPlayback(
        timeout: TimeInterval,
        onDrainFinished: @escaping @MainActor () -> Void
    ) {
        cancelWSDisconnectDrainPlaybackTask()
        wsDisconnectDrainPlaybackTask = Task { [weak self] in
            guard let self else { return }
            // WS disconnect drain: no "last audio rx" guard needed; default params suffice.
            await self.stopPlaybackAfterDrain(timeout: timeout)
            guard !Task.isCancelled else {
                self.wsDisconnectDrainPlaybackTask = nil
                return
            }
            onDrainFinished()
            self.wsDisconnectDrainPlaybackTask = nil
        }
    }

    func handleWSDisconnectDrainIfNeeded(
        monitorTTSOnPhone: Bool,
        inputSource: CallSessionController.InputSource,
        frameDurationMs: Int,
        baseGrace: TimeInterval,
        onDrainFinished: @escaping @MainActor (_ pendingEstimate: Double, _ timeout: TimeInterval) -> Void
    ) -> Bool {
        guard monitorTTSOnPhone, inputSource == .microphone, isPlaying() else {
            return false
        }
        let window = estimateTTSStopDrainWindow(
            frameDurationMs: frameDurationMs,
            baseGrace: baseGrace
        )
        onDrainFinished(window.pendingEstimate, window.timeout)
        return true
    }

    func stopRecordingForConfigIfNeeded(
        scene: WebSocketScene,
        wsListeningStarted: Bool
    ) {
        guard scene.isManualInteractionScene else { return }
        guard !wsListeningStarted else { return }
        guard audio.isRecording else { return }
        audio.stopRecording()
    }

    func startAudioStartRetryLoop(
        shouldRetry: @escaping @MainActor () -> Bool,
        onRetry: @escaping @MainActor () -> Void
    ) {
        cancelAudioStartRetryLoop()
        audioStartRetryTask = Task { [weak self] in
            while let _ = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                guard !Task.isCancelled else { break }
                guard shouldRetry() else { break }
                onRetry()
            }
            self?.audioStartRetryTask = nil
        }
    }

    func startAudioFlowWatchdog(
        onTimeout: @escaping @MainActor () async -> Void
    ) {
        cancelAudioFlowWatchdog()
        audioFlowWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            guard let self, !Task.isCancelled else { return }
            await onTimeout()
            self.audioFlowWatchdogTask = nil
        }
    }

    func scheduleTTSUplinkDrainIfNeeded(
        canStart: @escaping @MainActor () -> Bool,
        shouldRetryNoProgressSoon: @escaping @MainActor () -> Bool,
        onCompleted: @escaping @MainActor (_ rounds: Int) -> Void,
        onFirstSend: @escaping @MainActor () -> Void,
        currentBLEPendingWriteCount: @escaping @Sendable () -> Int,
        pendingSoftCap: Int,
        sendOpus: @escaping (Data) -> Void,
        reason: String
    ) {
        if !canStart() {
            // `ble_write_window_open` fires every time CoreBluetooth reopens
            // the write window (every 7.5–15 ms during bursts); logging every
            // tick when the TTS queue is empty is pure noise. Only log when
            // there is actual backpressure worth investigating.
            let qCount = uplinkState.count
            if (reason == "tts_audio_enqueue" || reason == "ble_write_window_open"),
               qCount > 0 {
                print("[NOSOUND] drain_skip: canStart=false reason=\(reason) q=\(qCount)")
            }
            return
        }
        guard ttsUplinkDrainTask == nil, ttsUplinkDrainTimer == nil else { return }
        print("[NOSOUND] drain_start: reason=\(reason) q=\(uplinkState.count)")
        let state = uplinkState
        let frameDelayNs = ttsUplinkFrameDurationNs
        let catchupDelayNs = ttsUplinkCatchupFrameDurationNs
        let catchupThreshold = ttsUplinkCatchupQueueThreshold
        let source = DispatchSource.makeTimerSource(queue: ttsUplinkDrainQueue)
        ttsUplinkDrainTimer = source
        var didCallFirstSend = false
        var didComplete = false
        var rounds = 0
        var totalSent = 0
        source.setEventHandler { [weak self] in
            func finish() {
                guard !didComplete else { return }
                didComplete = true
                source.cancel()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("[NOSOUND] drain_done: reason=\(reason) rounds=\(rounds) totalSent=\(totalSent) qLeft=\(state.count)")
                    onCompleted(rounds)
                    self.ttsUplinkDrainTimer = nil
                }
            }

            let blePending = currentBLEPendingWriteCount()
            if blePending >= pendingSoftCap {
                if state.isEmpty {
                    finish()
                } else {
                    // CoreBluetooth is already backed up. Keep the drain alive,
                    // but do not move more TTS frames into the BLE client's
                    // pending queue until the write window catches up.
                    source.schedule(deadline: .now() + .milliseconds(20), leeway: .milliseconds(5))
                }
                return
            }

            guard let payload = state.tryRemoveFirst() else {
                if state.isEmpty {
                    finish()
                } else {
                    Task { @MainActor in
                        if shouldRetryNoProgressSoon() {
                            source.schedule(deadline: .now() + .milliseconds(20), leeway: .milliseconds(5))
                        } else {
                            finish()
                        }
                    }
                }
                return
            }

            rounds += 1
            totalSent += 1
            if !didCallFirstSend {
                didCallFirstSend = true
                Task { @MainActor in onFirstSend() }
            }
            sendOpus(payload)
            if let flow = state.recordSentAndMaybeFlowLog(bytes: payload.count) {
                let qNow = state.count
                let delayMs = qNow >= catchupThreshold
                    ? (catchupDelayNs / 1_000_000)
                    : (frameDelayNs / 1_000_000)
                let mode = qNow >= catchupThreshold ? "catchup" : "paced"
                print(String(format: "[TTS-DIAG] ble_send_rate: sent_fps=%.1f needed_fps=16.7 window=%.1fs total_sent=%d q=%d",
                             flow.fps, flow.elapsed, flow.sentFrames, qNow))
                print(String(format: "[FLOW][iOS][TTS] mode=%@ q=%d delay_ms=%llu enq=%d sent=%d drop=%d sent_fps=%.1f",
                             mode,
                             qNow,
                             delayMs,
                             flow.enqueuedFrames,
                             flow.sentFrames,
                             flow.droppedFrames,
                             flow.fps))
            }
            let qNow = state.count
            let delayNs = qNow >= catchupThreshold ? catchupDelayNs : frameDelayNs
            source.schedule(deadline: .now() + .nanoseconds(Int(delayNs)), leeway: .milliseconds(5))
        }
        source.schedule(deadline: .now(), leeway: .milliseconds(2))
        source.resume()
    }

    @discardableResult
    func drainTTSUplinkOnce(
        reason: String,
        currentBLEPendingWriteCount: () -> Int,
        pendingSoftCap: Int,
        ttsUplinkSpeedX: Int,
        onFirstSend: () -> Void,
        sendOpus: (Data) -> Void
    ) -> DrainResult {
        guard !uplinkState.isEmpty else {
            return DrainResult(sent: 0, speedThisRound: 1, probeCompletedAudioSec: nil, probeCompletedElapsedSec: nil)
        }
        let speedThisRound = (Date() < ttsBoostUntil) ? ttsUplinkSpeedX : 1
        // Opus: each dequeue returns 1 frame × 60ms = 60ms/payload.
        // Send one frame per drain tick.  Burst throughput is handled by the
        // pacing sleep in `scheduleTTSUplinkDrainIfNeeded`; keeping this at 1
        // prevents one actor turn from overfeeding CoreBluetooth/MCU.
        let burstBudget = 1

        var sent = 0
        var probeFramesSentThisRound = 0
        var probeCompletedAudioSec: Double?
        var probeCompletedElapsedSec: Double?

        while sent < burstBudget {
            if currentBLEPendingWriteCount() >= pendingSoftCap {
                break
            }
            guard let payload = uplinkState.tryRemoveFirst() else { break }

            let mediaMs: Double = 60.0
            if emergencyBGMProbeFramesRemaining > 0 {
                if emergencyBGMProbeStartAt == nil {
                    emergencyBGMProbeStartAt = Date()
                    print("[FASTCHK][iOS] emergency_bgm first_send reason=\(reason)")
                }
                if let startAt = emergencyBGMProbeStartAt {
                    let elapsedMs = Date().timeIntervalSince(startAt) * 1000.0
                    let allowedLeadMs = 200.0
                    if (emergencyBGMPacedSentMs + mediaMs) > (elapsedMs + allowedLeadMs) {
                        uplinkState.insertAtFront(payload)
                        break
                    }
                }
            }

            onFirstSend()
            sendOpus(payload)
            uplinkState.recordSent(bytes: payload.count)
            probeFramesSentThisRound += 1
            if emergencyBGMProbeFramesRemaining > 0 {
                emergencyBGMPacedSentMs += mediaMs
            }
            sent += 1
        }

        if probeFramesSentThisRound > 0, emergencyBGMProbeFramesRemaining > 0 {
            emergencyBGMProbeFramesRemaining = max(0, emergencyBGMProbeFramesRemaining - probeFramesSentThisRound)
            if emergencyBGMProbeFramesRemaining == 0, let startAt = emergencyBGMProbeStartAt {
                let elapsed = max(0.001, Date().timeIntervalSince(startAt))
                let audioSec = (Double(emergencyBGMProbeFramesTotal) * emergencyBGMProbeFrameDurationMs) / 1000.0
                probeCompletedAudioSec = audioSec
                probeCompletedElapsedSec = elapsed
                emergencyBGMPacedSentMs = 0
            }
        }

        // ---- BLE send-rate diagnostics (2-second rolling window) ----
        // Opus: 1000ms ÷ 60ms/frame ≈ 16.7 payloads/sec
        if sent > 0 {
            if ttsDrainWindowStart == .distantPast {
                ttsDrainWindowStart = Date()
                ttsDrainSentFrames = 0
            }
            ttsDrainSentFrames += sent
            let elapsed = Date().timeIntervalSince(ttsDrainWindowStart)
            if elapsed >= 2.0 {
                let fps = elapsed > 0 ? Double(ttsDrainSentFrames) / elapsed : 0
                let snap = uplinkState.snapshotCounters()
                print(String(format: "[TTS-DIAG] ble_send_rate: sent_fps=%.1f needed_fps=16.7 window=%.1fs total_sent=%d q=%d",
                             fps, elapsed, snap.sentFrames, uplinkState.count))
                let qNow = uplinkState.count
                let delayMs = qNow >= ttsUplinkCatchupQueueThreshold
                    ? (ttsUplinkCatchupFrameDurationNs / 1_000_000)
                    : (ttsUplinkFrameDurationNs / 1_000_000)
                let mode = qNow >= ttsUplinkCatchupQueueThreshold ? "catchup" : "paced"
                print(String(format: "[FLOW][iOS][TTS] mode=%@ q=%d delay_ms=%llu enq=%d sent=%d drop=%d sent_fps=%.1f",
                             mode,
                             qNow,
                             delayMs,
                             snap.enqueuedFrames,
                             snap.sentFrames,
                             snap.droppedFrames,
                             fps))
                ttsDrainWindowStart = Date()
                ttsDrainSentFrames = 0
            }
        }

        return DrainResult(
            sent: sent,
            speedThisRound: speedThisRound,
            probeCompletedAudioSec: probeCompletedAudioSec,
            probeCompletedElapsedSec: probeCompletedElapsedSec
        )
    }

    /// TTS audio enqueue is `nonisolated` so `WebSocketService`'s receive queue can land
    /// binary TTS frames into the BLE uplink queue without hopping the main actor. All
    /// mutable state is inside `TTSUplinkState` which serialises via its own `NSLock`, so
    /// the @MainActor drain loop and the nonisolated receive-queue enqueue share the queue
    /// safely.
    nonisolated func enqueueTTSUplinkAudio(
        data: Data,
        bleAudioStartAcked: Bool,
        isFirstTTSInCall: Bool,
        maxQueueItems: Int
    ) -> UplinkEnqueueResult {
        let preAckOrFirst = (!bleAudioStartAcked) || isFirstTTSInCall
        let outcome = uplinkState.enqueueAndTrim(data, maxItems: maxQueueItems, preAckOrFirst: preAckOrFirst)

        // ---- Delivery-interval diagnostics ----
        // Measures how TTS audio arrives from WebSocket:
        //   dt_ms  : time since previous enqueue call (inter-arrival interval)
        //   audio_ms: audio content in this batch (e.g. 60ms per Opus frame, 7.5ms per mSBC frame)
        //   q      : queue depth after this enqueue
        // If dt_ms >> audio_ms and arrives in large batches → server delivery is chunky (root cause)
        // If dt_ms ≈ audio_ms continuously                  → BLE throughput is the bottleneck
        print(String(format: "[TTS-DIAG] enqueue: dt=%dms audio=60ms total_frames=%d q=%d bytes=%d",
                     outcome.dtMs, outcome.totalEnqueueCalls, outcome.queueCount, data.count))
        if let reason = outcome.droppedReason, outcome.droppedCount > 0 {
            print("[TTS->BLE] \(reason): droppedOld=\(outcome.droppedCount) q=\(outcome.queueCount)")
        }

        return UplinkEnqueueResult(
            queueCount: outcome.queueCount,
            counters: UplinkEnqueueCounters(
                enqueuedFrames: outcome.enqueuedFrames,
                enqueuedBytes: outcome.enqueuedBytes
            )
        )
    }
}

//
//  AudioService.swift
//  CallMate
//
//  音频服务 - 录音、播放、Opus 编解码
//

@preconcurrency import AVFoundation
import Accelerate
import Combine
import MediaPlayer

/// 音频服务代理
///
/// 实现方可能是 `@MainActor` 类（如 `CallSessionController`），但回调是从 CoreAudio
/// 实时线程（`AVAudioEngine` tap）直接同步调用的 —— 不经过主线程 hop。实现必须做到
/// 无锁、无 UI 副作用，把真正需要 UI 同步的工作自己 dispatch 到主线程。
protocol AudioServiceDelegate: AnyObject, Sendable {
    func audioServiceDidCaptureOpusPacket(_ data: Data)
    func audioServiceDidFinishPlaying()
}

/// Nonisolated mirror of the `AudioService` state that the CoreAudio realtime capture tap
/// needs to read. `AudioService` itself remains `@MainActor`; writes to `isMicMuted` /
/// `opusEncoder` / `conversationWriter` forward to this context under a lock via `didSet`,
/// so the tap never touches main-actor-isolated storage directly and Swift 6 strict
/// concurrency won't complain.
fileprivate nonisolated final class MicTapContext: @unchecked Sendable {
    struct Snapshot {
        let muted: Bool
        let encoder: OpusEncoderProtocol?
        let writer: ConversationAudioWriter?
    }

    private let lock = NSLock()
    private var muted: Bool = false
    private var encoder: OpusEncoderProtocol?
    private var writer: ConversationAudioWriter?

    init() {}

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
    }

    func setEncoder(_ value: OpusEncoderProtocol?) {
        lock.lock(); encoder = value; lock.unlock()
    }

    func setWriter(_ value: ConversationAudioWriter?) {
        lock.lock(); writer = value; lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(muted: muted, encoder: encoder, writer: writer)
    }
}

/// 音频服务 - 处理录音和播放
@MainActor
class AudioService: NSObject, ObservableObject {
    
    static let shared = AudioService()
    
    // MARK: - 配置
    /// `recordSampleRate` 是 `nonisolated let`，realtime 音频线程的 tap 闭包可以直接读取。
    nonisolated let recordSampleRate: Double = 16000
    private let recordChannels: AVAudioChannelCount = 1
    private let frameMs: Int = 60  // 60ms per frame
    
    // MARK: - 状态
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published private(set) var micPermissionGranted = false
    /// SwiftUI 仍可 observe，但 tap 闭包永远通过 `micTapContext` 读取镜像值。
    @Published var isMicMuted: Bool = false {
        didSet { micTapContext.setMuted(isMicMuted) }
    }

    /// 与 tap 闭包共享的 nonisolated 快照容器 —— 见 `MicTapContext` 注释。
    /// 引用本身标 `nonisolated` 以便 realtime 音频线程可以直接访问；内部状态靠 NSLock 保护。
    fileprivate nonisolated let micTapContext = MicTapContext()
    
    /// Delegate is set/cleared from the main thread but the tap closure reads it from the
    /// CoreAudio realtime thread. `weak var` loads are atomic on Apple platforms and the
    /// write/read race is acceptable here (worst case: one frame lost around detach).
    nonisolated(unsafe) weak var delegate: AudioServiceDelegate?
    
    // MARK: - 音频引擎
    // Separate engines to avoid graph reconnect races between duplex recording and TTS playback.
    private var recordingEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playbackNode: AVAudioPlayerNode?
    private var opusEncoder: OpusEncoderProtocol? {
        didSet { micTapContext.setEncoder(opusEncoder) }
    }
    private var opusDecoder: OpusDecoderProtocol?
    private var tapInstalled: Bool = false
    
    // 播放缓冲
    private var playbackFormat: AVAudioFormat?
    private var playSampleRate: Int = 24000
    private(set) var isPlaybackOnlyMode: Bool = false
    private var bleBackgroundSessionRefCount: Int = 0
    private let preferredIOBufferDuration: TimeInterval = 0.005
    private var audioSessionObserverTokens: [NSObjectProtocol] = []

    // TTS 解码提交计数（仍在主线程，用于首帧延迟诊断打点）
    private var ttsLatencyDecodeSubmitCount: Int = 0
    /// 下行 Opus 已到 `playOpusData` 但播放管线未就绪被丢弃的次数（用于与 `[CloudAudioProof] VERDICT_ws` 对照：云端有帧仍无声时查本地）。
    private var ttsPlayOpusDroppedNotPrepared: Int = 0

    // 调度热路径：所有 buffer 调度和计数管理均在专用队列上运行，完全不涉及主线程
    private let playbackScheduler = PlaybackScheduler()

    // MIC_CHAIN debug counters removed: the tap closure is now called synchronously on the
    // realtime audio thread without hopping main, so accumulating @MainActor state from the
    // tap was both a data race and a source of main-thread pressure. If per-frame visibility
    // is needed again, prefer os_signpost or a nonisolated counter container.

    // MARK: - 本地录音（双向：mic + TTS）
    private var conversationWriter: ConversationAudioWriter? {
        didSet { micTapContext.setWriter(conversationWriter) }
    }
    private var ttsToRecordingConverter: AVAudioConverter?
    private let recordingSampleRate: Double = 16000
    private let playbackDecodeWorker = PlaybackDecodeWorker(recordingSampleRate: 16000)
    private var playbackDecodeGeneration: Int = 0
    private let conversationRecordingWorker = ConversationRecordingWorker(targetSampleRate: 16000)

    enum ConversationClockSource {
        case mic
        case tts
    }
    
    // MARK: - 初始化
    private override init() {
        super.init()
        registerAudioSessionObservers()
    }

    // MARK: - BLE Background Session

    /// Keep an active audio session during BLE calls so iOS is less likely to suspend
    /// realtime networking while app is backgrounded. This does NOT start microphone tap.
    func acquireBLEBackgroundSession() {
        bleBackgroundSessionRefCount += 1
        print("[AudioSession] acquireBLEBackgroundSession refCount=\(bleBackgroundSessionRefCount) isPlaying=\(isPlaying)")
        if bleBackgroundSessionRefCount > 1 {
            return
        }
        do {
            try configureAudioSession(
                category: .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            print("[Audio] BLE background session acquired")
        } catch {
            // Keep flow best-effort; caller should continue even if session activation fails.
            print("[Audio] BLE background session acquire failed: \(error.localizedDescription)")
        }
    }

    func releaseBLEBackgroundSession() {
        bleBackgroundSessionRefCount = max(0, bleBackgroundSessionRefCount - 1)
        guard bleBackgroundSessionRefCount == 0 else { return }
        // If app is still recording/playing, keep session active for those pipelines.
        guard !isRecording && !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            print("[Audio] BLE background session released")
        } catch {
            print("[Audio] BLE background session release failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 扬声器与音量控制
    
    /// 启用外部扬声器
    func enableSpeaker(_ enabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            // `overrideOutputAudioPort` only works reliably with `.playAndRecord`.
            // Some flows call this before recording starts, which can trigger -50.
            var options = session.categoryOptions
            if enabled {
                options.insert(.defaultToSpeaker)
            } else {
                options.remove(.defaultToSpeaker)
            }

            let targetCategory: AVAudioSession.Category = .playAndRecord
            let targetMode: AVAudioSession.Mode = (session.mode == .default) ? .voiceChat : session.mode
            let isCurrentRouteSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
            let alreadyTargetCategory = session.category == targetCategory
            let alreadyTargetMode = session.mode == targetMode
            let alreadyTargetOptions = session.categoryOptions == options
            let alreadyTargetRoute = enabled ? isCurrentRouteSpeaker : !isCurrentRouteSpeaker

            // Avoid reasserting the same route while playback is starting. Repeated
            // override calls can cause transient vpio render errors/noise on some devices.
            if alreadyTargetCategory && alreadyTargetMode && alreadyTargetOptions && alreadyTargetRoute {
                print("[Audio] 扬声器模式已是目标状态，跳过重复设置: \(enabled ? "开启" : "关闭")")
                return
            }

            if session.category != targetCategory || session.mode != targetMode || session.categoryOptions != options {
                try session.setCategory(targetCategory, mode: targetMode, options: options)
            }
            try session.setActive(true)

            do {
                try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            } catch {
                // Keep best-effort behavior: category with `.defaultToSpeaker` is already set.
                print("[Audio] 扬声器 override 失败，使用 category 路由兜底: \(error.localizedDescription)")
            }

            print("[Audio] 扬声器模式: \(enabled ? "开启" : "关闭")")
            logCurrentAudioRoute(tag: "enableSpeaker")
        } catch {
            print("[Audio] 切换扬声器失败: \(error.localizedDescription)")
        }
    }
    
    /// 设置音量到最大
    func setMaxVolume() {
        // 使用 MPVolumeView 获取系统音量滑块并设置为最大
        let volumeView = MPVolumeView(frame: .zero)
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                slider.value = 1.0
                print("[Audio] 音量已设置为最大")
            }
        }
    }
    
    // MARK: - 权限
    
    /// 请求麦克风权限
    func requestMicrophonePermission() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        
        switch status {
        case .granted:
            micPermissionGranted = true
            return true
        case .denied:
            micPermissionGranted = false
            return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            micPermissionGranted = granted
            return granted
        @unknown default:
            return false
        }
    }
    
    // MARK: - 录音
    
    /// 开始录音
    /// - Parameter enableEchoCancellation: 是否启用回声消除（Voice Processing I/O）
    ///   - true: 模拟通话场景，需要回声消除
    ///   - false: AI 配置/私人秘书场景，不需要回声消除
    func startRecording(enableEchoCancellation: Bool = true) throws {
        guard !isRecording else { return }
        
        // 配置音频会话（如已匹配则避免重复 setCategory）
        try configureAudioSession(
            category: .playAndRecord,
            mode: .videoChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        
        // Recording uses a dedicated engine.
        let engine: AVAudioEngine
        if let existing = recordingEngine {
            engine = existing
        } else {
            let e = AVAudioEngine()
            recordingEngine = e
            engine = e
        }
        
        let inputNode = engine.inputNode

        // Voice Processing I/O provides echo cancellation for full-duplex calls.
        // Only enabled for simulated call scenarios (not for AI config/assistant).
        if enableEchoCancellation, #available(iOS 13.0, *) {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                inputNode.isVoiceProcessingBypassed = false
                print("[Audio] Voice Processing I/O: enabled (echo cancellation active)")
            } catch {
                print("[Audio] Voice Processing 启用失败: \(error.localizedDescription)")
            }
        } else {
            if #available(iOS 13.0, *) {
                inputNode.isVoiceProcessingBypassed = true
            }
            let reason = enableEchoCancellation ? "device_unsupported" : "config_scene"
            print("[Audio] Voice Processing I/O: disabled (reason: \(reason))")
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.formatError
        }
        
        // 目标格式: 16kHz mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: recordSampleRate,
            channels: recordChannels,
            interleaved: true
        ) else {
            throw AudioError.formatError
        }
        
        // 创建格式转换器
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioError.converterError
        }
        
        // 创建 Opus 编码器
        opusEncoder = createOpusEncoder(sampleRate: Int32(recordSampleRate), channels: Int32(recordChannels))
        
        // 每帧采样数 (60ms @ 16kHz = 960 samples)
        let frameSamples = Int(recordSampleRate * Double(frameMs) / 1000.0)
        // Tap buffer frames are in the INPUT format sample rate.
        let tapFrameSamples = max(1, Int(inputFormat.sampleRate * Double(frameMs) / 1000.0))
        var pcmBuffer = Data()
        
        // 安装录音 tap（只装一次；realtime 下播放期间也持续录音）
        if tapInstalled {
            // already installed
        } else {
            tapInstalled = true
            inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(tapFrameSamples), format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // 转换为目标格式
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate)
            ) else { return }
            
            var error: NSError?
            var inputProvided = false
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if inputProvided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputProvided = true
                outStatus.pointee = .haveData
                return buffer
            }
            
            guard status != .error, error == nil else { return }
            
            // 提取 PCM 数据
            if let channelData = convertedBuffer.int16ChannelData {
                let data = Data(bytes: channelData[0], count: Int(convertedBuffer.frameLength) * 2)
                pcmBuffer.append(data)

                // Snapshot 一次 mic tap 共享状态（muted/encoder/writer）—— NSLock 保护，
                // 对整个这一批 buffer 视作统一视图，避免在逐帧循环里反复加锁。
                let ctx = self.micTapContext.snapshot()
                let sampleRate = self.recordSampleRate

                // 每积累够一帧就编码发送
                let frameBytes = frameSamples * 2  // 16-bit = 2 bytes per sample
                while pcmBuffer.count >= frameBytes {
                    let frameData = pcmBuffer.prefix(frameBytes)
                    pcmBuffer.removeFirst(frameBytes)
                    
                    // Mic muted: drop frames (do not record or send).
                    if ctx.muted {
                        continue
                    }

                    // 录入本地录音（来电方/用户侧 - 左声道）
                    ctx.writer?.appendMicPCM(Data(frameData), sourceSampleRate: sampleRate)

                    // Opus 编码 → 直接在 CoreAudio 实时线程把包交给 delegate（nonisolated），
                    // 避免原先 `Task { @MainActor in delegate?... }` 每帧 ~16–50Hz 的主线程 hop。
                    if let encoder = ctx.encoder,
                       let opusData = encoder.encode(pcm: Data(frameData), frameSize: Int32(frameSamples)) {
                        self.delegate?.audioServiceDidCaptureOpusPacket(opusData)
                    }
                }
            }
            }
        }
        
        if !engine.isRunning {
            try engine.start()
        }
        isRecording = true
        print("[MIC_CHAIN] recording_started: isMicMuted=\(isMicMuted) inputFormat=\(inputFormat)")
        print("[Audio] 开始录音 (inputFormat=\(inputFormat))")
    }
    
    /// 停止录音
    func stopRecording() {
        guard isRecording else { return }
        
        recordingEngine?.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        opusEncoder = nil
        isRecording = false
        print("[Audio] 停止录音")

        teardownRecordingEngineIfIdle()
    }
    
    // MARK: - 播放

    /// 连续模拟通话：`isPlaying` 可能与「图仍在、仅引擎暂停或未置位」短暂不一致；若与当前下行参数一致则只恢复运行，避免 `preparePlayback` 开头的 `stopPlayback` 拆掉 BGM。
    func tryResumeContinuousOpusPlaybackIfPossible(sampleRate: Int, playbackOnly: Bool) -> Bool {
        if isPlaying, playbackFormat != nil, playbackNode != nil { return true }
        guard playbackFormat != nil, let eng = playbackEngine, playbackNode != nil else { return false }
        guard playSampleRate == sampleRate, isPlaybackOnlyMode == playbackOnly else { return false }
        if !eng.isRunning {
            do {
                try eng.start()
            } catch {
                print("[CloudAudioProof] tryResumeContinuousOpusPlaybackIfPossible engine_start_failed err=\(error.localizedDescription)")
                return false
            }
        }
        isPlaying = true
        return true
    }
    
    /// 准备播放（收到 TTS start 时调用）
    /// 准备播放（收到 TTS start 时调用）
    /// - Parameters:
    ///   - sampleRate: 服务端下行采样率
    ///   - playbackOnly: 为 true 时使用 .playback 类别（音量更大，走扬声器），
    ///     适用于 updateConfig/initConfig 等不需要同时录音的场景。
    ///     为 false 时使用 .playAndRecord + .voiceChat（支持全双工 + 回声消除）。
    func preparePlayback(sampleRate: Int, playbackOnly: Bool = false) throws {
        let startedAt = Date()
        // Some servers can emit duplicate `tts start` events within one utterance.
        // If playback pipeline is already configured the same way, keep current
        // decoder/player to avoid cutting speech mid-sentence.
        if playSampleRate == sampleRate,
           isPlaybackOnlyMode == playbackOnly,
           playbackFormat != nil,
           let engine = playbackEngine,
           playbackNode != nil {
            var reuseGraph = true
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    print("[Audio] preparePlayback reuse_graph engine start failed, rebuilding: \(error.localizedDescription)")
                    reuseGraph = false
                }
            }
            if reuseGraph {
                isPlaying = true
                print("[CloudAudioProof] preparePlayback reuse_graph_no_teardown sr=\(sampleRate) playbackOnly=\(playbackOnly)")
                return
            }
        }

        // 停止之前的播放（不影响录音引擎）
        stopPlayback()
        print("[CloudAudioProof] preparePlayback pipeline_teardown_then_rebuild sr=\(sampleRate) playbackOnly=\(playbackOnly)")

        playSampleRate = sampleRate
        isPlaybackOnlyMode = playbackOnly
        playbackDecodeGeneration += 1
        let decodeGeneration = playbackDecodeGeneration

        // 配置音频会话（如已匹配则避免重复 setCategory）
        do {
            if playbackOnly {
                // 纯播放模式：音量正常、走扬声器，适合 AI分身等仅播放 TTS 的场景
                try configureAudioSession(category: .playback, mode: .default, options: [])
            } else {
                // 全双工模式：支持同时录音 + 播放，带回声消除
                try configureAudioSession(
                    category: .playAndRecord,
                    mode: .videoChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            }
        } catch {
            print("[CloudAudioProof] preparePlayback_FAILED_configure_session sr=\(sampleRate) playbackOnly=\(playbackOnly) err=\(error.localizedDescription)")
            throw error
        }

        // 创建播放格式: 24kHz mono (服务端下行格式)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.formatError
        }
        playbackFormat = format
        opusDecoder = nil
        ttsToRecordingConverter = nil
        playbackDecodeWorker.configureOpus(sampleRate: sampleRate, generation: decodeGeneration)

        // Playback uses a dedicated engine.
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        if let existingEngine = playbackEngine, let existingPlayer = playbackNode {
            engine = existingEngine
            player = existingPlayer
            // 重新连接 playerNode 到正确的播放格式
            player.stop()
            let points = engine.outputConnectionPoints(for: player, outputBus: 0)
            if !points.isEmpty { engine.disconnectNodeOutput(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)
        } else {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            playbackEngine = e
            playbackNode = p
            engine = e
            player = p
        }

        if !engine.isRunning {
            do {
                try engine.start()
                print("[Audio] playbackEngine started OK")
            } catch {
                print("[Audio] playbackEngine start FAILED: \(error)")
                throw error
            }
        }
        player.reset()
        player.volume = 1.0

        playbackScheduler.configure(
            engine: engine, player: player, format: format,
            generation: decodeGeneration, isPlaybackOnlyMode: playbackOnly
        )
        playbackScheduler.scheduleWarmup()

        isPlaying = true
        ttsPlayOpusDroppedNotPrepared = 0
        print("[Audio] 準備播放, 採樣率: \(sampleRate) playbackOnly=\(playbackOnly)")
        logCurrentAudioRoute(tag: "preparePlayback")
        logManualPlaybackLatency(
            "prepare_playback_complete",
            startedAt: startedAt,
            extra: "sampleRate=\(sampleRate) generation=\(decodeGeneration)"
        )
    }

    /// 接收并播放 Opus 音频数据
    func playOpusData(_ opusData: Data) {
        guard isPlaying, playbackFormat != nil, playbackNode != nil else {
            ttsPlayOpusDroppedNotPrepared += 1
            if ttsPlayOpusDroppedNotPrepared <= 10 || (ttsPlayOpusDroppedNotPrepared % 30) == 0 {
                print("[CloudAudioProof] LOCAL_playOpus_skipped_not_prepared drops=\(ttsPlayOpusDroppedNotPrepared) bytes=\(opusData.count) isPlaying=\(isPlaying) hasFormat=\(playbackFormat != nil) hasNode=\(playbackNode != nil) → if drops>0 while WS shows opus_rx: LOCAL_AUDIO_PIPELINE")
            }
            return
        }
        ttsLatencyDecodeSubmitCount += 1
        if ttsLatencyDecodeSubmitCount == 1 {
            logTTSLatencyStage("decode_submit", extra: "bytes=\(opusData.count)")
        }
        let gen = playbackDecodeGeneration
        let scheduler = playbackScheduler
        let writer = conversationWriter
        // Completion fires on the decode worker's background queue, which then hands
        // off to the scheduler queue — the main thread is never touched in this path.
        playbackDecodeWorker.decodeOpus(opusData, generation: gen) { frame in
            guard let frame else { return }
            scheduler.schedule(frame, conversationWriter: writer)
        }
    }

    /// 停止播放（收到 TTS stop 时调用）
    func stopPlayback() {
        playbackNode?.stop()
        playbackDecodeGeneration += 1
        playbackDecodeWorker.reset(generation: playbackDecodeGeneration)
        playbackScheduler.reset(newGeneration: playbackDecodeGeneration)
        opusDecoder = nil
        playbackFormat = nil
        ttsToRecordingConverter = nil
        isPlaybackOnlyMode = false
        isPlaying = false
        ttsLatencyDecodeSubmitCount = 0
        print("[Audio] 停止播放")

        teardownPlaybackEngineIfIdle()
    }


    private func teardownPlaybackEngineIfIdle() {
        guard !isPlaying else { return }
        playbackEngine?.stop()
        playbackEngine = nil
        playbackNode = nil
    }

    private func teardownRecordingEngineIfIdle() {
        guard !isRecording else { return }
        recordingEngine?.stop()
        recordingEngine = nil
        tapInstalled = false
    }

    private func configureAudioSession(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        let session = AVAudioSession.sharedInstance()
        let prevCat = session.category.rawValue
        let prevMode = session.mode.rawValue
        let prevOpts = session.categoryOptions.rawValue
        if session.category != category || session.mode != mode || session.categoryOptions != options {
            try session.setCategory(category, mode: mode, options: options)
            print("[AudioSession] setCategory: \(prevCat)/\(prevMode)/\(prevOpts) → \(category.rawValue)/\(mode.rawValue)/\(options.rawValue)")
        } else {
            print("[AudioSession] setCategory skip (already): \(category.rawValue)/\(mode.rawValue)/\(options.rawValue)")
        }
        try? session.setPreferredIOBufferDuration(preferredIOBufferDuration)
        try session.setActive(true)
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        print("[AudioSession] active outputs=[\(outputs)] category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
    }

    private func logCurrentAudioRoute(tag: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        print("[AudioRoute][\(tag)] category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=[\(outputs)] inputs=[\(inputs)]")
    }

    private func currentRouteSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=[\(outputs)] inputs=[\(inputs)]"
    }

    private func logManualPlaybackLatency(_ event: String, startedAt: Date? = nil, extra: String = "") {
        guard isPlaybackOnlyMode else { return }
        let durationText: String
        if let startedAt {
            durationText = " duration=\(Int(Date().timeIntervalSince(startedAt) * 1000))ms"
        } else {
            durationText = ""
        }
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[LAT][AudioManual] t=\(Self.logTimestamp()) event=\(event)\(durationText)\(suffix)")
    }

    private func registerAudioSessionObservers() {
        let center = NotificationCenter.default
        audioSessionObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let snapshot = Self.makeRouteChangeSnapshot(notification)
                Task { @MainActor [weak self, snapshot] in
                    self?.handleAudioSessionRouteChange(snapshot)
                }
            }
        )
        audioSessionObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                let snapshot = Self.makeInterruptionSnapshot(notification)
                Task { @MainActor [weak self, snapshot] in
                    self?.handleAudioSessionInterruption(snapshot)
                }
            }
        )
        audioSessionObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.logAudioSessionEvent("media_services_reset")
                }
            }
        )
    }

    private func handleAudioSessionRouteChange(_ snapshot: AudioSessionRouteChangeSnapshot) {
        logAudioSessionEvent(
            "route_change",
            extra: "reason=\(snapshot.reasonText) \(snapshot.previousRouteText) current=\(currentRouteSummary())"
        )
    }

    private func handleAudioSessionInterruption(_ snapshot: AudioSessionInterruptionSnapshot) {
        logAudioSessionEvent(
            "interruption",
            extra: "type=\(snapshot.typeText) options=\(snapshot.optionsRaw) shouldResume=\(snapshot.shouldResume) reason=\(snapshot.reasonText) current=\(currentRouteSummary())"
        )
    }

    private func logAudioSessionEvent(_ event: String, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[AudioSessionEvt] t=\(Self.logTimestamp()) event=\(event)\(suffix)")
    }

    private static func logTimestamp() -> String {
        CallSessionController.logDateFormatter.string(from: Date())
    }

    /// 用于诊断「二进制到达 → 实际播放」间隔，各阶段打点；用 ts_ms 相减得毫秒数
    private func logTTSLatencyStage(_ stage: String, extra: String = "") {
        let t = Self.logTimestamp()
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[TTS_LATENCY] stage=\(stage) t=\(t) ts_ms=\(tsMs)\(suffix)")
    }

    nonisolated private static func makeRouteChangeSnapshot(_ notification: Notification) -> AudioSessionRouteChangeSnapshot {
        let reasonRaw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        let reasonText = reason.map { "\($0)" } ?? "unknown(\(reasonRaw))"
        let previousRouteText: String
        if let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            let outputs = previousRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            let inputs = previousRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            previousRouteText = "prevOutputs=[\(outputs)] prevInputs=[\(inputs)]"
        } else {
            previousRouteText = "prevRoute=nil"
        }
        return AudioSessionRouteChangeSnapshot(reasonText: reasonText, previousRouteText: previousRouteText)
    }

    nonisolated private static func makeInterruptionSnapshot(_ notification: Notification) -> AudioSessionInterruptionSnapshot {
        let typeRaw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        let typeText = type.map { "\($0)" } ?? "unknown(\(typeRaw))"
        let optionsRaw = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        let reasonRaw = (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue
        let reason = reasonRaw.flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
        let reasonText = reason.map { "\($0)" } ?? reasonRaw.map { "raw_\($0)" } ?? "nil"
        return AudioSessionInterruptionSnapshot(
            typeText: typeText,
            optionsRaw: optionsRaw,
            shouldResume: options.contains(.shouldResume),
            reasonText: reasonText
        )
    }

    func hasPendingPlaybackBuffers() -> Bool {
        playbackScheduler.hasPendingBuffers()
    }

    func effectivePendingPlaybackBufferCount() -> Int {
        playbackScheduler.effectivePendingCount()
    }

    func estimatedPendingPlaybackDuration(frameDurationMs: Int) -> TimeInterval {
        playbackScheduler.estimatedPendingDuration(frameDurationMs: frameDurationMs)
    }

    // MARK: - 本地录音（双向）

    /// 开始本地通话录音（会把 mic + TTS 两路写入同一个文件）
    func beginConversationRecording(callId: UUID, clockSource: ConversationClockSource = .mic) {
        conversationRecordingWorker.resetSynchronously()
        do {
            conversationWriter = try ConversationAudioWriter(
                callId: callId,
                sampleRate: recordingSampleRate,
                clockSource: clockSource
            )
            print("[Audio] 开始本地录音(异步准备): \(CallAudioStore.fileName(for: callId))")
        } catch {
            conversationWriter = nil
            print("[Audio] 本地录音初始化失败: \(error.localizedDescription)")
        }
    }

    /// 结束本地录音并返回文件名
    func endConversationRecording() -> String? {
        let name = conversationWriter?.fileName
        conversationRecordingWorker.resetSynchronously()
        conversationWriter?.finish()
        conversationWriter = nil
        return name
    }

    // MARK: - BLE 通话录音：Caller(左) + Cloud TTS(右)

    /// 准备“云端下行音频”的录音解码器（BLE 模式下不在手机端播放，也要录制）。
    /// - Note: 仅在 `beginConversationRecording` 已调用后才会生效。
    func prepareDownstreamRecording(audioFormat: WSAudioFormat, sampleRate: Int) {
        guard conversationWriter != nil else { return }
        conversationRecordingWorker.prepareDownstreamRecording(
            audioFormat: audioFormat,
            sampleRate: sampleRate
        )
    }

    /// 录入“云端下行 TTS 音频”（右声道）。
    /// - Important: 在 BLE 模式 `monitorTTSOnPhone=false` 时由 `CallSessionController` 调用。
    func recordDownstreamTTSAudioFrame(_ data: Data, audioFormat: WSAudioFormat) {
        guard let writer = conversationWriter else { return }
        conversationRecordingWorker.recordDownstreamTTSAudioFrame(
            data,
            audioFormat: audioFormat,
            writer: writer
        )
    }

    /// 录入“MCU BLE 下行来话音频”（左声道）。
    func recordBLECallerOpus(_ opus: Data, sampleRate: Int = 16000) {
        guard let writer = conversationWriter else { return }
        conversationRecordingWorker.recordBLECallerOpus(
            opus,
            sampleRate: sampleRate,
            writer: writer
        )
    }

    private func resampleInt16Mono(_ pcmData: Data, using converter: AVAudioConverter) -> Data? {
        let srcFormat = converter.inputFormat
        let dstFormat = converter.outputFormat
        let srcFrames = AVAudioFrameCount(pcmData.count / 2)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else { return nil }
        srcBuf.frameLength = srcFrames

        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dstPtr = srcBuf.int16ChannelData?[0] else { return }
            dstPtr.update(from: int16Ptr, count: Int(srcFrames))
        }

        let estimatedDstFrames = AVAudioFrameCount(Double(srcFrames) * dstFormat.sampleRate / srcFormat.sampleRate) + 32
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: estimatedDstFrames) else { return nil }

        // FIX: Track whether the input block has already provided data.
        // The block-based convert API may call the input block multiple times.
        // Without tracking, the same source buffer is returned on every call,
        // causing the converter to process duplicate data and produce extra output
        // samples - stretching the audio (making TTS sound slow in recordings).
        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        guard status != .error, error == nil, let outPtr = dstBuf.int16ChannelData?[0] else { return nil }
        return Data(bytes: outPtr, count: Int(dstBuf.frameLength) * 2)
    }
    
    // MARK: - 错误类型
    enum AudioError: Error {
        case formatError
        case converterError
        case engineError
    }
}

private struct AudioSessionRouteChangeSnapshot: Sendable {
    let reasonText: String
    let previousRouteText: String
}

private struct AudioSessionInterruptionSnapshot: Sendable {
    let typeText: String
    let optionsRaw: UInt
    let shouldResume: Bool
    let reasonText: String
}

private struct TTSFrameDebugTag: Sendable {
    let generation: Int
    let sequence: Int
    let sampleCount: Int
    let hash: UInt64

    nonisolated var logSummary: String {
        "gen=\(generation) seq=\(sequence) hash=\(hashHex) samples=\(sampleCount)"
    }

    nonisolated var hashHex: String {
        String(format: "%016llx", CUnsignedLongLong(hash))
    }
}

private final class PlaybackDecodeWorker {
    struct DecodedFrame {
        let generation: Int
        let floatSamples: [Float]
        let recordingPCMData: Data?
        let debugTag: TTSFrameDebugTag
    }

    private let queue = DispatchQueue(
        label: "CallMate.AudioService.PlaybackDecodeWorker",
        qos: .userInitiated
    )
    private let generationLock = NSLock()
    private let recordingSampleRate: Double

    private var activeGeneration: Int = 0
    private var opusDecoder: OpusDecoderProtocol?
    private var ttsToRecordingConverter: AVAudioConverter?
    private var playSampleRate: Int = 24000
    private var nextFrameSequence: Int = 0

    init(recordingSampleRate: Double) {
        self.recordingSampleRate = recordingSampleRate
    }

    func configureOpus(sampleRate: Int, generation: Int) {
        setActiveGeneration(generation)
        queue.async { [weak self] in
            guard let self, self.isGenerationActive(generation) else { return }
            self.playSampleRate = sampleRate
            self.nextFrameSequence = 0
            self.opusDecoder = createOpusDecoder(sampleRate: Int32(sampleRate), channels: 1)
            self.ttsToRecordingConverter = self.makeRecordingConverter(sourceSampleRate: Double(sampleRate))
        }
    }

    func reset(generation: Int) {
        setActiveGeneration(generation)
        queue.async { [weak self] in
            guard let self, self.isGenerationActive(generation) else { return }
            self.opusDecoder = nil
            self.ttsToRecordingConverter = nil
            self.nextFrameSequence = 0
        }
    }

    func decodeOpus(_ opusData: Data, generation: Int, completion: @escaping (DecodedFrame?) -> Void) {
        let chunk = opusData
        queue.async { [weak self] in
            guard let self,
                  self.isGenerationActive(generation),
                  let decoder = self.opusDecoder else { return }

            let frameSize = Int32(Double(self.playSampleRate) * 0.06)
            guard let pcmData = decoder.decode(opus: chunk, frameSize: frameSize) else {
                print("[Audio] Opus 解码失败")
                return
            }
            guard self.isGenerationActive(generation) else { return }
            let recordingPCMData = self.recordingPCMData(from: pcmData)
            let debugTag = self.makeDebugTag(
                generation: generation,
                pcmData: recordingPCMData ?? pcmData
            )

            let frame = DecodedFrame(
                generation: generation,
                floatSamples: Self.floatSamples(from: pcmData),
                recordingPCMData: recordingPCMData,
                debugTag: debugTag
            )
            guard self.isGenerationActive(generation) else { return }
            // Call completion directly on this decode queue; the caller
            // (PlaybackScheduler.schedule) re-dispatches to its own queue.
            completion(frame)
        }
    }

    private func recordingPCMData(from pcmData: Data) -> Data? {
        if playSampleRate == Int(recordingSampleRate) {
            return pcmData
        }
        guard let converter = ttsToRecordingConverter else { return nil }
        return resampleInt16Mono(pcmData, using: converter)
    }

    private func makeRecordingConverter(sourceSampleRate: Double) -> AVAudioConverter? {
        let src = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )
        let dst = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: recordingSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let src, let dst else { return nil }
        return AVAudioConverter(from: src, to: dst)
    }

    private func setActiveGeneration(_ generation: Int) {
        generationLock.lock()
        activeGeneration = generation
        generationLock.unlock()
    }

    private func isGenerationActive(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return activeGeneration == generation
    }

    private func makeDebugTag(generation: Int, pcmData: Data) -> TTSFrameDebugTag {
        let tag = TTSFrameDebugTag(
            generation: generation,
            sequence: nextFrameSequence,
            sampleCount: pcmData.count / 2,
            hash: Self.fnv1a64(pcmData)
        )
        nextFrameSequence += 1
        return tag
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func floatSamples(from pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return [] }
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                floatSamples[i] = Float(int16Ptr[i]) / 32768.0
            }
        }
        return floatSamples
    }

    private func resampleInt16Mono(_ pcmData: Data, using converter: AVAudioConverter) -> Data? {
        let srcFormat = converter.inputFormat
        let dstFormat = converter.outputFormat
        let srcFrames = AVAudioFrameCount(pcmData.count / 2)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else { return nil }
        srcBuf.frameLength = srcFrames

        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dstPtr = srcBuf.int16ChannelData?[0] else { return }
            dstPtr.update(from: int16Ptr, count: Int(srcFrames))
        }

        let estimatedDstFrames = AVAudioFrameCount(Double(srcFrames) * dstFormat.sampleRate / srcFormat.sampleRate) + 32
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: estimatedDstFrames) else { return nil }

        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        guard status != .error, error == nil, let outPtr = dstBuf.int16ChannelData?[0] else { return nil }
        return Data(bytes: outPtr, count: Int(dstBuf.frameLength) * 2)
    }
}

// MARK: - PlaybackScheduler

/// Owns all TTS buffer scheduling and runs entirely on a private `.userInteractive`
/// serial queue. The main thread is never touched in the hot decode → schedule path.
private final class PlaybackScheduler: @unchecked Sendable {

    // fileprivate: AudioService (same file) dispatches completion closures onto this queue
    fileprivate let queue = DispatchQueue(
        label: "CallMate.AudioService.PlaybackScheduler",
        qos: .userInteractive
    )

    // Set from main during prepare; read only from `queue` during hot path
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var generation: Int = 0
    private var isPlaybackOnlyMode: Bool = false

    // Pending buffer counters (only on `queue`)
    private var pendingCount: Int = 0
    private var warmupCount: Int = 0
    private var tailDeadline: CFAbsoluteTime = 0

    // Diagnostic counters (only on `queue`)
    private var firstFrameGen: Int?
    private var decodeDoneLogged = false
    private var scheduleFirstLogged = false
    private var playbackStartLogged = false
    private var lastScheduleAt: CFAbsoluteTime = 0
    private var lastPlayedAt: CFAbsoluteTime = 0
    private var scheduleTotal: Int = 0
    private var scheduleBatchAt: CFAbsoluteTime = 0
    private var playedTotal: Int = 0
    private var playedBatchAt: CFAbsoluteTime = 0
    private var pileUpLastLogged: Int = -1

    // MARK: - Setup (called from main)

    func configure(
        engine: AVAudioEngine,
        player: AVAudioPlayerNode,
        format: AVAudioFormat,
        generation: Int,
        isPlaybackOnlyMode: Bool
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.engine = engine
            self.player = player
            self.format = format
            self.generation = generation
            self.isPlaybackOnlyMode = isPlaybackOnlyMode
            self.pendingCount = 0
            self.warmupCount = 0
            self.tailDeadline = 0
            self.resetDiagnostics()
        }
    }

    /// Schedule a 150 ms silence warmup so the player node is primed before real audio arrives.
    /// Call from main immediately after `configure`.
    func scheduleWarmup() {
        queue.async { [weak self] in
            guard let self, let player = self.player, let format = self.format else { return }
            let frameCount = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.15)))
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buf.frameLength = frameCount
            if let ch = buf.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    ch[c].update(repeating: 0, count: Int(frameCount))
                }
            }
            self.pendingCount += 1
            self.warmupCount += 1
            player.scheduleBuffer(buf) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.pendingCount = max(0, self.pendingCount - 1)
                    self.warmupCount = max(0, self.warmupCount - 1)
                }
            }
        }
    }

    // MARK: - Hot path (called from PlaybackDecodeWorker's decode queue)

    /// Receive a decoded frame and schedule it for playback. This method dispatches
    /// internally to `queue` so it is safe to call from any thread.
    func schedule(_ frame: PlaybackDecodeWorker.DecodedFrame, conversationWriter: ConversationAudioWriter?) {
        queue.async { [weak self] in
            guard let self, frame.generation == self.generation else { return }
            guard let player = self.player, let format = self.format, let engine = self.engine else { return }

            if !self.decodeDoneLogged {
                self.decodeDoneLogged = true
                let tsMs = Int(Date().timeIntervalSince1970 * 1000)
                print("[TTS_LATENCY] stage=decode_done ts_ms=\(tsMs) samples=\(frame.floatSamples.count)")
            }

            guard self.ensurePipelineReady(engine: engine, player: player, format: format) else { return }

            // Conversation recording — ConversationAudioWriter serialises on its own ioQueue
            if let writer = conversationWriter, let pcm = frame.recordingPCMData {
                writer.appendTTSPCM(pcm, sourceSampleRate: 16000, debugTag: frame.debugTag)
            }

            // Build PCM float buffer for the player
            let count = AVAudioFrameCount(frame.floatSamples.count)
            guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
            buf.frameLength = count
            if let ch = buf.floatChannelData?[0] {
                frame.floatSamples.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress { ch.update(from: base, count: Int(count)) }
                }
            }

            // Diagnostics
            if self.isPlaybackOnlyMode, self.firstFrameGen != frame.generation {
                self.firstFrameGen = frame.generation
                print("[LAT][AudioManual] event=first_decoded_frame_scheduled generation=\(frame.generation) frames=\(count)")
            }
            let now = CFAbsoluteTimeGetCurrent()
            if self.lastScheduleAt > 0 {
                let gapMs = (now - self.lastScheduleAt) * 1000
                if gapMs > 200 {
                    print("[TTS_SCHED] schedule_gap_ms=\(Int(gapMs)) — scheduler queue may be starved")
                }
            }
            self.lastScheduleAt = now

            let duration = Double(buf.frameLength) / max(1.0, format.sampleRate)
            self.tailDeadline = max(self.tailDeadline, now) + duration

            if !self.scheduleFirstLogged {
                self.scheduleFirstLogged = true
                let tsMs = Int(Date().timeIntervalSince1970 * 1000)
                print("[TTS_LATENCY] stage=schedule_first ts_ms=\(tsMs) frameLength=\(buf.frameLength)")
            }

            self.pendingCount += 1
            self.scheduleTotal += 1
            if self.scheduleTotal == 1 { self.scheduleBatchAt = now }
            else if self.scheduleTotal % 20 == 0 {
                let ms = Int((now - self.scheduleBatchAt) * 1000)
                print("[TTS_BUFFER_RATE] schedule 20 in_last_ms=\(ms) total=\(self.scheduleTotal) pending=\(self.effectivePending)")
                self.scheduleBatchAt = now
            }
            let eff = self.effectivePending
            if eff >= 30, eff > self.pileUpLastLogged {
                self.pileUpLastLogged = eff
                print("[TTS_BUFFER] pile_up pending=\(eff) (schedule 堆积)")
            }
            if eff < 30 { self.pileUpLastLogged = -1 }

            let logFirst = !self.playbackStartLogged
            player.scheduleBuffer(buf) { [weak self] in
                // Completion fires on AVAudioEngine's internal render thread — hop back to our queue.
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.pendingCount = max(0, self.pendingCount - 1)
                    if logFirst, !self.playbackStartLogged {
                        self.playbackStartLogged = true
                        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
                        print("[TTS_LATENCY] stage=playback_start ts_ms=\(tsMs) frameLength=\(buf.frameLength)")
                    }
                    let now2 = CFAbsoluteTimeGetCurrent()
                    self.playedTotal += 1
                    if self.playedTotal == 1 { self.playedBatchAt = now2 }
                    else if self.playedTotal % 20 == 0 {
                        let ms = Int((now2 - self.playedBatchAt) * 1000)
                        print("[TTS_BUFFER_RATE] played 20 in_last_ms=\(ms) total=\(self.playedTotal) pending=\(self.effectivePending)")
                        self.playedBatchAt = now2
                    }
                    if self.lastPlayedAt > 0 {
                        let gap = (now2 - self.lastPlayedAt) * 1000
                        if gap > 200 {
                            print("[TTS_SCHED] played_gap_ms=\(Int(gap)) — underrun risk, player starved")
                        }
                    }
                    self.lastPlayedAt = now2
                }
            }
        }
    }

    // MARK: - Teardown (called from main)

    func reset(newGeneration: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = newGeneration
            self.pendingCount = 0
            self.warmupCount = 0
            self.tailDeadline = 0
            self.player = nil
            self.engine = nil
            self.format = nil
            self.resetDiagnostics()
        }
    }

    // MARK: - Thread-safe queries
    // `queue.sync` is safe here because the scheduler queue never calls back to main,
    // so there is no deadlock risk.

    func effectivePendingCount() -> Int {
        queue.sync { effectivePending }
    }

    func hasPendingBuffers() -> Bool {
        queue.sync {
            if effectivePending > 0 { return true }
            return CFAbsoluteTimeGetCurrent() < tailDeadline
        }
    }

    func estimatedPendingDuration(frameDurationMs: Int) -> TimeInterval {
        queue.sync {
            let eff = effectivePending
            let byCount = (frameDurationMs > 0 && eff > 0) ? Double(eff * frameDurationMs) / 1000.0 : 0
            let byTail = max(0, tailDeadline - CFAbsoluteTimeGetCurrent())
            return max(byCount, byTail)
        }
    }

    // MARK: - Private (must only be called from `queue`)

    private var effectivePending: Int { max(0, pendingCount - warmupCount) }

    private func ensurePipelineReady(engine: AVAudioEngine, player: AVAudioPlayerNode, format: AVAudioFormat) -> Bool {
        let points = engine.outputConnectionPoints(for: player, outputBus: 0)
        if points.isEmpty {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard !engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty else {
                print("[Audio] playback node still disconnected; dropping frame")
                return false
            }
            print("[Audio] playback node reconnected on scheduler queue")
        }
        if !engine.isRunning {
            do {
                try engine.start()
                print("[Audio] playback engine restarted from scheduler queue")
            } catch {
                print("[Audio] playback engine restart failed: \(error.localizedDescription)")
                return false
            }
        }
        if !player.isPlaying {
            player.play()
        }
        return true
    }

    private func resetDiagnostics() {
        firstFrameGen = nil
        decodeDoneLogged = false
        scheduleFirstLogged = false
        playbackStartLogged = false
        lastScheduleAt = 0
        lastPlayedAt = 0
        scheduleTotal = 0
        scheduleBatchAt = 0
        playedTotal = 0
        playedBatchAt = 0
        pileUpLastLogged = -1
    }
}

private final class ConversationRecordingWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "CallMate.ConversationRecordingWorker",
        qos: .userInitiated
    )
    private let targetSampleRate: Double

    private var recordingDownstreamOpusDecoder: OpusDecoderProtocol?
    private var recordingDownstreamSampleRate: Int = 16000
    private var recordingDownstreamTo16kConverter: AVAudioConverter?

    private var recordingBleOpusDecoder: OpusDecoderProtocol?
    private var recordingBleTo16kConverter: AVAudioConverter?

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
    }

    func resetSynchronously() {
        queue.sync {
            recordingDownstreamOpusDecoder = nil
            recordingDownstreamSampleRate = Int(targetSampleRate)
            recordingDownstreamTo16kConverter = nil
            recordingBleOpusDecoder = nil
            recordingBleTo16kConverter = nil
        }
    }

    func prepareDownstreamRecording(audioFormat: WSAudioFormat, sampleRate: Int) {
        queue.async { [self] in
            recordingDownstreamSampleRate = sampleRate
            recordingDownstreamOpusDecoder = createOpusDecoder(sampleRate: Int32(sampleRate), channels: 1)
            recordingDownstreamTo16kConverter = makeInt16MonoConverter(sourceSampleRate: Double(sampleRate))
        }
    }

    func recordDownstreamTTSAudioFrame(
        _ data: Data,
        audioFormat: WSAudioFormat,
        writer: ConversationAudioWriter
    ) {
        let chunk = data
        queue.async { [self] in
            let sr = recordingDownstreamSampleRate
            if recordingDownstreamOpusDecoder == nil {
                recordingDownstreamOpusDecoder = createOpusDecoder(sampleRate: Int32(sr), channels: 1)
            }
            let frameSize = Int32(Double(sr) * 0.06) // 60ms
            guard let pcm = recordingDownstreamOpusDecoder?.decode(opus: chunk, frameSize: frameSize) else { return }
            if sr == Int(targetSampleRate) {
                writer.appendRightPCM(pcm, sourceSampleRate: targetSampleRate)
                return
            }
            if recordingDownstreamTo16kConverter == nil {
                recordingDownstreamTo16kConverter = makeInt16MonoConverter(sourceSampleRate: Double(sr))
            }
            guard let converter = recordingDownstreamTo16kConverter,
                  let resampled = resampleInt16Mono(pcm, using: converter) else { return }
            writer.appendRightPCM(resampled, sourceSampleRate: targetSampleRate)
        }
    }

    func recordBLECallerOpus(
        _ opus: Data,
        sampleRate: Int,
        writer: ConversationAudioWriter
    ) {
        let chunk = opus
        queue.async { [self] in
            if recordingBleOpusDecoder == nil {
                recordingBleOpusDecoder = createOpusDecoder(sampleRate: Int32(sampleRate), channels: 1)
            }
            let frameSize = Int32(Double(sampleRate) * 0.06) // 60ms
            guard let pcm = recordingBleOpusDecoder?.decode(opus: chunk, frameSize: frameSize) else { return }
            if sampleRate == Int(targetSampleRate) {
                writer.appendLeftPCM(pcm, sourceSampleRate: targetSampleRate)
                return
            }
            if recordingBleTo16kConverter == nil {
                recordingBleTo16kConverter = makeInt16MonoConverter(sourceSampleRate: Double(sampleRate))
            }
            guard let converter = recordingBleTo16kConverter,
                  let resampled = resampleInt16Mono(pcm, using: converter) else { return }
            writer.appendLeftPCM(resampled, sourceSampleRate: targetSampleRate)
        }
    }

    private func makeInt16MonoConverter(sourceSampleRate: Double) -> AVAudioConverter? {
        let src = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )
        let dst = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let src, let dst else { return nil }
        return AVAudioConverter(from: src, to: dst)
    }

    private func resampleInt16Mono(_ pcmData: Data, using converter: AVAudioConverter) -> Data? {
        let srcFormat = converter.inputFormat
        let dstFormat = converter.outputFormat
        let srcFrames = AVAudioFrameCount(pcmData.count / 2)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else { return nil }
        srcBuf.frameLength = srcFrames

        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dstPtr = srcBuf.int16ChannelData?[0] else { return }
            dstPtr.update(from: int16Ptr, count: Int(srcFrames))
        }

        let estimatedDstFrames = AVAudioFrameCount(Double(srcFrames) * dstFormat.sampleRate / srcFormat.sampleRate) + 32
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: estimatedDstFrames) else { return nil }

        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        guard status != .error, error == nil, let outPtr = dstBuf.int16ChannelData?[0] else { return nil }
        return Data(bytes: outPtr, count: Int(dstBuf.frameLength) * 2)
    }
}

// MARK: - ConversationAudioWriter

/// 双声道混音录音器：
/// - 左声道：来话音频（模拟模式=用户麦克风，BLE 模式=MCU BLE 下行 caller 音频）
/// - 右声道：AI/TTS（云端下行）
/// 使用时间线对齐，支持同时说话时的叠加混音
private final class ConversationAudioWriter {
    private struct PendingTTSDebugWrite {
        let tag: TTSFrameDebugTag
        let endSample: Int
    }

    let fileName: String
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private let ioQueue = DispatchQueue(label: "CallMate.ConversationAudioWriter")
    private var finished: Bool = false
    
    private let sampleRate: Double
    private let flushIntervalMs: Int = 100
    private var flushTimer: DispatchSourceTimer?
    private let clockSource: AudioService.ConversationClockSource
    
    private var startTime: CFAbsoluteTime = 0
    private var micBuffer: [Int16] = []
    private var ttsBuffer: [Int16] = []
    private var micReadIndex: Int = 0
    private var ttsReadIndex: Int = 0
    private var writtenSamples: Int = 0
    private var micTotalReceivedSamples: Int = 0
    private var ttsTotalReceivedSamples: Int = 0
    private var ttsTotalFlushedSamples: Int = 0
    private var pendingTTSDebugWrites: [PendingTTSDebugWrite] = []
    
    init(
        callId: UUID,
        sampleRate: Double,
        clockSource: AudioService.ConversationClockSource
    ) throws {
        self.fileName = CallAudioStore.fileName(for: callId)
        self.sampleRate = sampleRate
        self.clockSource = clockSource
        self.startTime = CFAbsoluteTimeGetCurrent()
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw AudioService.AudioError.formatError
        }
        self.format = format
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]

        startFlushTimer()
        prepareFileAsync(callId: callId, settings: settings)
    }
    
    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + .milliseconds(flushIntervalMs), repeating: .milliseconds(flushIntervalMs))
        timer.setEventHandler { [weak self] in
            self?.flushBuffers()
        }
        timer.resume()
        flushTimer = timer
    }

    private func prepareFileAsync(callId: UUID, settings: [String: Any]) {
        let startedAt = Date()
        ioQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            do {
                let url = try CallAudioStore.url(for: callId)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                self.file = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatInt16,
                    interleaved: false
                )
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                print("[LAT][Recording] t=\(CallAudioStore.logTimestamp()) event=writer_ready file=\(self.fileName) duration=\(durationMs)ms")
                self.flushBuffers()
            } catch {
                print("[LAT][Recording] t=\(CallAudioStore.logTimestamp()) event=writer_prepare_failed file=\(self.fileName) error=\(error.localizedDescription)")
            }
        }
    }
    
    func appendLeftPCM(_ data: Data, sourceSampleRate: Double) {
        guard sourceSampleRate == sampleRate else { return }
        let chunk = data
        ioQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            chunk.withUnsafeBytes { rawPtr in
                guard let src = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let count = chunk.count / 2
                for i in 0..<count {
                    self.micBuffer.append(src[i])
                }
                self.micTotalReceivedSamples += count
            }
        }
    }
    
    func appendRightPCM(_ data: Data, sourceSampleRate: Double, debugTag: TTSFrameDebugTag? = nil) {
        guard sourceSampleRate == sampleRate else { return }
        let chunk = data
        ioQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            chunk.withUnsafeBytes { rawPtr in
                guard let src = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let count = chunk.count / 2
                let endSample = self.ttsTotalReceivedSamples + count
                for i in 0..<count {
                    self.ttsBuffer.append(src[i])
                }
                self.ttsTotalReceivedSamples = endSample
                if let debugTag {
                    self.pendingTTSDebugWrites.append(
                        PendingTTSDebugWrite(tag: debugTag, endSample: endSample)
                    )
                }
            }
        }
    }

    // Backward-compatible names used by microphone simulation flow.
    func appendMicPCM(_ data: Data, sourceSampleRate: Double) {
        appendLeftPCM(data, sourceSampleRate: sourceSampleRate)
    }
    
    func appendTTSPCM(_ data: Data, sourceSampleRate: Double, debugTag: TTSFrameDebugTag? = nil) {
        appendRightPCM(data, sourceSampleRate: sourceSampleRate, debugTag: debugTag)
    }
    
    func appendInt16PCM(_ data: Data, sourceSampleRate: Double) {
        // 已废弃，保留兼容性
    }
    
    private func flushBuffers() {
        guard !finished else { return }
        guard let file else { return }

        // Use wall-clock time as the single timeline source.
        // This matches the previously working simulation behavior and avoids
        // pushing one channel later just because it arrives slightly delayed.
        let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
        let targetSamples = Int(elapsedTime * sampleRate)
        let samplesToWrite = targetSamples - writtenSamples
        
        guard samplesToWrite > 0 else { return }
        
        var leftChannel: [Int16] = []
        var rightChannel: [Int16] = []
        
        leftChannel.reserveCapacity(samplesToWrite)
        rightChannel.reserveCapacity(samplesToWrite)

        let micAvailable = max(0, micBuffer.count - micReadIndex)
        let ttsAvailable = max(0, ttsBuffer.count - ttsReadIndex)
        let ttsSamplesConsumed = min(samplesToWrite, ttsAvailable)

        for i in 0..<samplesToWrite {
            if i < micAvailable {
                leftChannel.append(micBuffer[micReadIndex])
                micReadIndex += 1
            } else {
                leftChannel.append(0)
            }
            if i < ttsAvailable {
                rightChannel.append(ttsBuffer[ttsReadIndex])
                ttsReadIndex += 1
            } else {
                rightChannel.append(0)
            }
        }
        
        let frames = AVAudioFrameCount(samplesToWrite)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        
        if let channelData = buffer.int16ChannelData {
            for i in 0..<samplesToWrite {
                channelData[0][i] = leftChannel[i]
                channelData[1][i] = rightChannel[i]
            }
        }
        
        do {
            try file.write(from: buffer)
            writtenSamples += samplesToWrite
            ttsTotalFlushedSamples += ttsSamplesConsumed
            logCompletedTTSDebugWritesIfNeeded(stage: "recording_write")
        } catch {
            print("[Audio] 写入本地录音失败: \(error.localizedDescription)")
        }

        // Periodically trim consumed samples to avoid unbounded growth.
        let trimThreshold = 8192
        if micReadIndex > trimThreshold {
            micBuffer.removeFirst(micReadIndex)
            micReadIndex = 0
        }
        if ttsReadIndex > trimThreshold {
            ttsBuffer.removeFirst(ttsReadIndex)
            ttsReadIndex = 0
        }
    }
    
    func finish() {
        ioQueue.sync {
            flushTimer?.cancel()
            flushTimer = nil
            
            // BUG FIX: Use the REMAINING unread count, not the total buffer count.
            // Previously used micBuffer.count / ttsBuffer.count which includes
            // already-consumed samples, causing extra silence to be written.
            let micAvailable = max(0, micBuffer.count - micReadIndex)
            let ttsAvailable = max(0, ttsBuffer.count - ttsReadIndex)
            let remainingSamples = max(micAvailable, ttsAvailable)
            if remainingSamples > 0 {
                let ttsSamplesConsumed = min(remainingSamples, ttsAvailable)
                var leftChannel: [Int16] = []
                var rightChannel: [Int16] = []
                leftChannel.reserveCapacity(remainingSamples)
                rightChannel.reserveCapacity(remainingSamples)
                for i in 0..<remainingSamples {
                    if i < micAvailable {
                        leftChannel.append(micBuffer[micReadIndex])
                        micReadIndex += 1
                    } else {
                        leftChannel.append(0)
                    }
                    if i < ttsAvailable {
                        rightChannel.append(ttsBuffer[ttsReadIndex])
                        ttsReadIndex += 1
                    } else {
                        rightChannel.append(0)
                    }
                }
                
                let frames = AVAudioFrameCount(remainingSamples)
                if let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                    buffer.frameLength = frames
                    if let channelData = buffer.int16ChannelData {
                        for i in 0..<remainingSamples {
                            channelData[0][i] = leftChannel[i]
                            channelData[1][i] = rightChannel[i]
                        }
                    }
                    do {
                        try file.write(from: buffer)
                        ttsTotalFlushedSamples += ttsSamplesConsumed
                        logCompletedTTSDebugWritesIfNeeded(stage: "recording_finish_write")
                    } catch {
                        print("[Audio] 写入本地录音尾包失败: \(error.localizedDescription)")
                    }
                }
            }
            
            finished = true
        }
        print("[Audio] 本地录音完成: \(fileName)")
    }

    private func logCompletedTTSDebugWritesIfNeeded(stage: String) {
        while let first = pendingTTSDebugWrites.first, first.endSample <= ttsTotalFlushedSamples {
          //  let tag = first.tag
          //  print("[TTS_FRAME] t=\(CallAudioStore.logTimestamp()) stage=\(stage) gen=\(tag.generation) seq=\(tag.sequence) hash=\(tag.hashHex) samples=\(tag.sampleCount) file=\(fileName) flushed=\(ttsTotalFlushedSamples)")
            pendingTTSDebugWrites.removeFirst()
        }
    }
}

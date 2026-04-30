//
//  CallSessionController.swift
//  CallMate
//
//  将 WebSocketService + AudioService 组合成一个通话会话控制器，
//  供 SwiftUI 页面直接绑定（避免在 View struct 里做 delegate）。
//

import Foundation
import Combine
import Dispatch
import Network
import UIKit
import SwiftData
@preconcurrency import AVFoundation
import UserNotifications

@MainActor
protocol PermissionsProviding: AnyObject {
    var networkStatus: NWPath.Status { get }
}

extension PermissionsCenter: PermissionsProviding {}

/// Nonisolated mirror of the few `@MainActor` flags that the WS binary fast-enqueue
/// hook needs to read. Keeping the originals `@MainActor` preserves SwiftUI binding
/// behaviour for the rest of the codebase; `didSet` writes the mirror under a small
/// lock so the nonisolated reader in `WebSocketService.binaryFastRxHook` sees a
/// consistent value without hopping the main actor.
nonisolated final class CallSessionRuntimeFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _bleAudioStartAcked: Bool = false
    private var _isFirstTTSInCall: Bool = true

    init() {}

    var bleAudioStartAcked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _bleAudioStartAcked }
        set { lock.lock(); _bleAudioStartAcked = newValue; lock.unlock() }
    }

    var isFirstTTSInCall: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isFirstTTSInCall }
        set { lock.lock(); _isFirstTTSInCall = newValue; lock.unlock() }
    }
}

@MainActor
final class CallSessionController: NSObject, ObservableObject {
    static let sharedBLE = CallSessionController(
        language: .zh,
        inputSource: .ble,
        monitorTTSOnPhone: false,
        ws: .shared,
        audio: .shared,
        ble: CallMateBLEClient.shared,
        permissions: PermissionsCenter.shared
    )

    // MARK: - Active controller gating
    //
    // This app can have multiple CallSessionController instances alive (e.g. BLE live call + simulation views).
    // They all attach to the singleton WebSocketService and singleton AudioService.
    // If more than one controller reacts to the same WS TTS frames, we may:
    // - append TTS audio into the same conversation recording multiple times
    // - reconfigure AudioService playback/recording state unexpectedly
    // which can make the recorded TTS sound "slow" (stretched) or otherwise wrong.
    //
    // We therefore gate WS callbacks to ONLY the last-started controller.
    let controllerId = UUID()
    @MainActor static var activeControllerId: UUID?
    static weak var activeController: CallSessionController?
    var isActiveController: Bool { Self.activeControllerId == controllerId }
    lazy var liveActivityCoordinator = CallLiveActivityCoordinator { [weak self] action in
        guard let self else { return }
        self.handleLiveActivityAction(action)
    }
    let summaryCoordinator = CallSummaryCoordinator()
    lazy var transportCoordinator = CallTransportCoordinator(ble: ble)
    /// `audioRouter` is `nonisolated let` so the WS fast-enqueue hook (running on the
    /// URLSession receive queue, outside the main actor) can call its `nonisolated`
    /// `enqueueTTSUplinkAudio` without hopping main. `CallAudioRouter` itself remains
    /// `@MainActor` — only the enqueue entry is nonisolated.
    nonisolated let audioRouter: CallAudioRouter
    lazy var sessionContext = CallSessionContext(ws: ws, audio: audio, ble: ble)

    /// Nonisolated mirror for `bleAudioStartAcked` / `isFirstTTSInCall`; see
    /// `CallSessionRuntimeFlags` for the rationale.
    nonisolated let runtimeFlags = CallSessionRuntimeFlags()

    @Published var status: Status = .ended
    @Published var duration: Int = 0
    @Published var isMuted: Bool = false
    @Published var isSpeaker: Bool = true
    @Published var messages: [DialogMessage] = []

    @Published var lastErrorMessage: String?
    @Published var isAIHangup: Bool = false  // AI 主动挂断标记
    @Published var pendingRuleChange: RuleChangeRequest?
    @Published var pendingGuideImage: GuideImageRequest?
    @Published var pendingGuideCard: GuideCardRequest?
    @Published var pendingCreateTemplate: OutboundTemplateRequest?
    @Published var pendingInitiateCall: OutboundCallRequest?
    @Published var pendingScheduleCall: OutboundScheduleCallRequest?
    @Published var toastMessage: String?
    @Published var wsSessionId: String?
    /// 累计 TTS 停止次数（每次 webSocketDidReceiveTTSStop 触发时 +1）
    @Published var ttsStopCount: Int = 0

    let language: Language

    /// `ws` / `inputSource` are `nonisolated let` so the audio capture hot path
    /// (`AudioServiceDelegate.audioServiceDidCaptureOpusPacket`) can run on the CoreAudio
    /// realtime thread without hopping the main actor. Both are immutable after `init`.
    nonisolated let ws: WebSocketService
    let audio: AudioService
    let ble: any CallMateBLELibraryClient
    nonisolated let inputSource: InputSource
    var monitorTTSOnPhone: Bool
    let scene: WebSocketScene
    let skipPickupDelay: Bool

    var durationTask: Task<Void, Never>?
    var currentTTSText: String = ""
    var currentSTTText: String = ""
    /// AI TTS 流式气泡状态：独立 ObservableObject，避免触发 controller 全量重绘
    let ttsStreamingState = TTSStreamingBubbleState()
    lazy var ttsStreamBuffer: TTSCharacterStreamBuffer = {
        TTSCharacterStreamBuffer(
            baseSpeedMs: 30,
            bufferSpeedK: 10,
            onDisplayUpdate: { [weak self] text in
                guard let self else { return }
                self.ttsStreamingState.text = text
                if !text.isEmpty {
                    if self.ttsStreamingState.isLoading {
                        self.ttsStreamingState.stopLoading()
                    }
                    self.currentTTSText = text
                    self.syncLiveActivity()
                }
            },
            onFinished: { [weak self] finalText in
                guard let self else { return }
                self.ttsStreamingState.stopLoading()
                self.currentTTSText = ""
                self.syncLiveActivity()
                print("[CallSession] TTS stream finished -> messages: \(finalText.prefix(50))")
                self.messages.append(.init(text: finalText, isAI: true))
            }
        )
    }()
    var emergencyLiveActivityText: String?
    var currentTTSSampleRate: Int = 16000
    var cancellables: Set<AnyCancellable> = []
    var currentIncomingCall: CallMateIncomingCall?
    let activeModeKey = "callmate_active_mode"
    var wsListeningStarted: Bool = false
    var bleAudioBuffer: [Data] = []
    let bleAudioBufferLimitFrames: Int = 10  // ~600ms at 60ms/frame (aligned with ttsUplinkMaxQueueItemsOpus)
    var bleHasAudio: Bool = false
    var bleAudioStartAcked: Bool = false {
        didSet { runtimeFlags.bleAudioStartAcked = bleAudioStartAcked }
    }
    var bleAudioStartAckAt: Date?
    var nosoundDownlinkCount: Int = 0
    var nosoundDownlinkToWS: Int = 0
    var nosoundDownlinkBuffered: Int = 0
    var nosoundLastDiagAt: Date = .distantPast
    var bleCallActive: Bool = false
    var phoneHandledCall: Bool = false
    var pendingIncomingCall: CallMateIncomingCall?
    var pendingActiveConnect: Bool = false
    var ttsStartDelayTask: Task<Void, Never>?
    var lastManualToggleAt: Date?
    var manualListenStartTask: Task<Void, Never>?
    var manualLastRecordingStopAt: Date?
    var manualPressActive: Bool = false
    var manualReconnectPending: Bool = false
    var manualReconnectInFlight: Bool = false
    var bleWSDisconnectReactionTask: Task<Void, Never>?
    var aiHangupReactionTask: Task<Void, Never>?
    /// For the very first TTS in a call, prefer preserving the head of the audio queue
    /// (greeting) over latency-bounding drops. This avoids "first sentence missing".
    var isFirstTTSInCall: Bool = true {
        didSet { runtimeFlags.isFirstTTSInCall = isFirstTTSInCall }
    }
    var audioFlowRestartAttempts: Int = 0
    var bleWSConnectContext: BLEWSConnectContext = .none
    var suppressHangupOnce: Bool = false
    var bleReconnectBlockedUntil: Date = .distantPast
    let permissions: any PermissionsProviding

    var wsQuickDisconnectWindowSec: Double {
        let raw = UserDefaults.standard.double(forKey: "ws_quick_disconnect_window_sec")
        let v = raw == 0 ? 2.0 : raw
        return max(0.5, min(10.0, v))
    }
    var wsDisconnectToastWindowSec: Double {
        let raw = UserDefaults.standard.double(forKey: "callmate.ws_disconnect_toast_window_sec")
        let v = raw == 0 ? 5.0 : raw
        return max(1.0, min(30.0, v))
    }
    /// Unified delay (seconds) before handling terminal WS/AI hangup reactions.
    /// Configure via UserDefaults key: `callmate.disconnect_reaction_delay_sec`.
    var disconnectReactionDelaySec: Double {
        let raw = UserDefaults.standard.double(forKey: "callmate.disconnect_reaction_delay_sec")
        let v = raw == 0 ? 1.0 : raw
        return max(0.0, min(30.0, v))
    }
    /// Off by default so realtime audio logging does not distort debug-session performance.
    /// Enable manually with UserDefaults key `callmate.verbose_realtime_audio_logging`.
    var verboseRealtimeAudioLoggingEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "callmate.verbose_realtime_audio_logging")
        #else
        false
        #endif
    }
    var callConnectedAt: Date?
    var wsQuickDisconnectToastShown: Bool = false
    var bleAudioCodec: BLEAudioCodec {
        let raw = (UserDefaults.standard.string(forKey: "callmate.ble_audio_codec") ?? "opus").lowercased()
        return BLEAudioCodec(rawValue: raw) ?? .opus
    }
    var bleWSAudioFormat: WSAudioFormat { .opus }
    var bleMCUAudioCodecName: String {
        bleAudioCodec.rawValue
    }
    var contactPassthroughActive: Bool = false
    var ignoredContactIncomingUIDs: Set<Int> = []
    var systemCallObserverToken: UUID?
    var systemCallAnsweredObserverToken: UUID?
    var pickupDelayTask: Task<Void, Never>?
    var emergencyPlaybackTask: Task<Void, Never>?
    var didCountIncomingCall: Bool = false
    /// True only after iOS has actually sent `answer` for current incoming call.
    /// We use BLE call_state notifications + this flag to distinguish:
    /// - AI answered (flag=true)
    /// - user manually answered on phone (flag=false)
    var aiAnswerRequested: Bool = false
    var aiAnswerRequestUID: Int?
    var outboundCallId: UUID?
    var outboundCallStartedAt: Date?
    var pendingOutboundTaskID: UUID?
    var activeOutboundTaskID: UUID?
    var pendingOutboundPrompt: String?
    var activeOutboundPrompt: String?
    /// 外呼场景 hello 元数据（号码、相关方、任务目标）。
    var outboundTargetPhone: String?
    var outboundCallerName: String?
    var outboundTaskGoal: String?
    /// Set when BLE reports call terminated before the session was ever established
    /// (e.g. user hangs up while phone is still ringing, before call_state(active)).
    /// Allows waitForOutboundCallStart to exit early instead of hanging for 60 s.
    var outboundCallAborted: Bool = false

    // MARK: - Outbound BLE diagnostics (grep `[OutboundDiag]`)
    /// Increments each `prepareForOutboundDial()` — correlates one dial with subsequent `call_state` lines.
    var outboundDiagEpoch: UInt64 = 0
    /// True after `call_state` is classified as `outgoingAnswered` for the current epoch.
    var outboundDiagReceivedOutgoingAnswered: Bool = false
    /// Recent `raw|normalized|phase` tail for this epoch (max `outboundDiagRecentBleStatesMax`).
    var outboundDiagRecentBleStates: [String] = []
    private let outboundDiagRecentBleStatesMax: Int = 16
    /// True when MCU already told us call is terminal (ended/rejected/phone_handled).
    /// In this case end() should NOT send hangup/audio_stop again.
    var remoteCallTerminalState: Bool = false
    var emergencyNotifyAttemptCount: Int = 0
    /// Sticky flag for the active call. Once emergency notify is triggered,
    /// keep this true until next call setup so post-call persistence can rely on it.
    var didTriggerEmergencyNotifyInCurrentCall: Bool = false
    var lastSuppressedBlockedNumber: String?
    var emergencyNoPickupBlockedNumbers: Set<String> = []
    let emergencyBlockedNumbersKey = "callmate.emergency_no_pickup_blocked_numbers"
    var didSendAudioResetForCurrentCall: Bool = false
    var micMutedByTTSGuard: Bool = false
    /// Sticky per-call flag: once a WS hello reply is observed, keep it true until call reset/end.
    /// This must not be cleared by reconnect attempts, otherwise disconnect handling may
    /// incorrectly downgrade to "no-hello" and trigger auto-reconnect.
    var hasReceivedWSHelloInCurrentCall: Bool = false

    @Published var liveCallRequest: CallMateIncomingCall?

    // MARK: - Trace (latency instrumentation)
    var traceClock = TraceClock()
    var traceSessionSeq: UInt64 = 0
    var tBleFirstRxNs: UInt64?
    var tWsFirstUpSendNs: UInt64?
    var tWsFirstDownRxNs: UInt64?
    var tBleFirstUpSendNs: UInt64?
    var tTtsFirstEnqueueNs: UInt64?
    var latIncomingAt: Date?
    var latAnswerSentAt: Date?
    var latCallActiveAt: Date?
    var latAudioStartSentAt: Date?
    var latAudioStartAckAt: Date?
    var latFirstTtsRxAt: Date?
    var latFirstBleUplinkAt: Date?
    var lastCloudSTTRxAt: Date?
    var pendingCloudSTTForTTS: Bool = false
    var bleBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    var bleBackgroundSupportActive: Bool = false
    
    // TTS throttling for BLE uplink (send at real-time rate, not burst)
    let ttsUplinkPendingSoftCap: Int = 64
    /// Cap uplink queue to keep latency bounded (drop oldest).
    /// 10 frames × 60ms = 600ms — aligned with Android `MAX_PENDING_TTS_FRAMES`;
    /// absorbs modest WebSocket jitter while the BLE drain
    /// pipeline pushes audio to the MCU at real-time (or 2x during boost).
    ///
    /// `nonisolated let` so the WS fast-enqueue hook can pass it as the `maxQueueItems`
    /// argument from the nonisolated receive queue.
    nonisolated let ttsUplinkMaxQueueItemsOpus: Int = 10
    /// BLE uplink speed multiplier for cloud TTS audio.
    /// Default 2 = send 2 frames per 60ms tick (2x throughput).
    /// Can be overridden via UserDefaults key `ble_tts_uplink_speed_x`.
    var ttsUplinkSpeedX: Int {
        let raw = UserDefaults.standard.integer(forKey: "ble_tts_uplink_speed_x")
        let v = raw == 0 ? 2 : raw
        return max(1, min(4, v))
    }
    /// Boost duration (ms) for using speedX>1 at the start of each TTS.
    /// After boost window, we revert to 1x to avoid sustained overfeed that can
    /// overflow MCU/BT uplink buffers and cause choppiness.
    /// Override via UserDefaults key `ble_tts_uplink_boost_ms` (default 800ms).
    var ttsUplinkBoostMs: Int {
        let raw = UserDefaults.standard.integer(forKey: "ble_tts_uplink_boost_ms")
        let v = raw == 0 ? 1500 : raw
        return max(0, min(5000, v))
    }
    var ttsAudioRxCount: Int = 0
    var ttsAudioRxBytes: Int = 0
    var lastTtsAudioRxAt: Date = .distantPast
    var ttsBinaryRxBatchStartAt: Date?
    var ttsBinaryRxBatchStartPendingFrames: Int = 0
    
    static let logDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy.MM.dd HH.mm.ss.SSS"
        return df
    }()
    
    init(
        language: Language,
        inputSource: InputSource = .microphone,
        monitorTTSOnPhone: Bool? = nil,
        scene: WebSocketScene = .call,
        skipPickupDelay: Bool = false,
        ws: WebSocketService? = nil,
        audio: AudioService? = nil,
        ble: (any CallMateBLELibraryClient)? = nil,
        permissions: (any PermissionsProviding)? = nil
    ) {
        self.language = language
        self.inputSource = inputSource
        self.ble = ble ?? CallMateBLEClient.shared
        self.monitorTTSOnPhone = monitorTTSOnPhone ?? (inputSource == .microphone)
        self.scene = scene
        self.skipPickupDelay = skipPickupDelay
        let resolvedWS = ws ?? .shared
        self.ws = resolvedWS
        let resolvedAudio = audio ?? .shared
        self.audio = resolvedAudio
        self.audioRouter = CallAudioRouter(audio: resolvedAudio)
        self.permissions = permissions ?? PermissionsCenter.shared
        self.emergencyNoPickupBlockedNumbers = Set(
            UserDefaults.standard.stringArray(forKey: emergencyBlockedNumbersKey) ?? []
        )
        super.init()

        if inputSource == .ble {
            bindBLEEvents()
            bindBLEUplinkReadyCallback()
            registerSystemCallObserverIfNeeded()
            liveActivityCoordinator.registerActionObserverIfNeeded()
        }
        // 历史上这里调过 `installBinaryFastRxHook(on: resolvedWS)`，把 WS TTS 二进制入队
        // 搬到 URLSession 接收队列（968e9885）。上线后对方听 TTS 顿挫 —— fast hook 不再被主
        // actor 节流，主 actor 被 UI/Task 拖住时 `TTSUplinkState` 的 10 帧 cap 会被连续打穿，
        // `enqueueAndTrim` 直接 `removeFirst` 丢弃最老帧（= 对方正要听到的那段）。
        // 旧路径因为入队在主 actor 上，帧会堆在 Swift 并发 Task 队列里而不是 uplinkState，
        // 恢复后一进一出自然平衡，cap 不会被打到。故回滚入队到主 actor；fast hook 基础设施
        // （TTSUplinkState / runtimeFlags / binaryFastRxHook 属性）保留，方便未来真的要做
        // off-main drain 时复用，但默认不装载。
    }

    @MainActor deinit {
        emergencyPlaybackTask?.cancel()
        bleWSDisconnectReactionTask?.cancel()
        aiHangupReactionTask?.cancel()
        // Best-effort cleanup: remove from WS multicast delegate table.
        ws.removeDelegate(self)
        // Avoid leaving a dangling audio delegate if we were the last one assigned.
        if audio.delegate === self {
            audio.delegate = nil
        }
        // Clear active owner if we are it.
        if Self.activeControllerId == controllerId {
            Self.activeControllerId = nil
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
        if let token = systemCallObserverToken {
            SystemCallObserver.shared.removeHandler(token)
        }
        if let token = systemCallAnsweredObserverToken {
            SystemCallObserver.shared.removeHandler(token)
        }
        if inputSource == .ble {
            ble.onAudioWriteWindowOpen = nil
            liveActivityCoordinator.unregisterActionObserverIfNeeded()
        }
    }

}

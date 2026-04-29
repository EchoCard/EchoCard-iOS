//
//  WebSocketService.swift
//  CallMate
//
//  WebSocket 协议服务 - 对接 xiaozhi-protocal
//

import Foundation
import Combine
import CryptoKit

/// WebSocket audio format for binary frames.
enum WSAudioFormat: Equatable {
    /// Binary frames are raw Opus packets.
    case opus
}

/// WebSocket 消息类型
enum WSMessageType: String {
    case hello
    case listen
    case abort
    case stt
    case tts
    case error
    case mcp
}

/// WebSocket 场景
enum WebSocketScene: String {
    case call = "call"
    case initConfig = "init_config"
    case updateConfig = "update_config"
    case evaluation = "evaluation"
    /// AI 外呼助手对话场景（创建话术模板 + 发起外呼确认）
    case outboundChat = "outbound_chat"

    var isManualInteractionScene: Bool {
        self == .initConfig || self == .updateConfig || self == .evaluation || self == .outboundChat
    }
}

/// TTS 状态
enum TTSState: String {
    case start
    case sentenceStart = "sentence_start"
    case sentenceEnd = "sentence_end"
    case stop
}

/// Listen 模式
enum ListenMode: String {
    case manual
    case auto
    case realtime
}

/// Thread-safe uplink audio pump for `WebSocketService`.
///
/// `URLSessionWebSocketTask.send(_:completionHandler:)` is documented thread-safe, and the
/// per-frame work (counter bumps, verbose rate logs, `task.send`) carries no UI side effects.
/// Keeping the hot send path behind a `nonisolated` facade lets mic uplink packets bypass the
/// main-actor hop they'd otherwise inherit from `WebSocketService` and avoids having realtime
/// audio traffic be gated by SwiftUI layout / scheduler stalls.
///
/// Lifecycle is driven from the main-actor `WebSocketService` methods:
/// - `attach(task:)` on new `URLSessionWebSocketTask` creation,
/// - `markConnected(sessionId:)` on hello ack,
/// - `markDisconnected()` on receive failure / disconnect,
/// - `detach()` when the task reference is cleared.
/// `nonisolated` 原因：本项目 default actor isolation 会把整类默认推成 `@MainActor`，
/// 让 `send` / `attach` / `markConnected` / ... 都变成 main-actor 隔离，`WebSocketService.sendAudioData`
/// 的 `nonisolated` 承诺（以后从音频实时线程直接调用）就无法兑现。按 CORE_MEMORY 红线处理：
/// 整类一起标 `nonisolated` + `@unchecked Sendable`，所有方法/属性一次性退回类级 nonisolated 域，
/// 避免只修单点引发"can not be mutated from a nonisolated context"连锁告警。
nonisolated final class WSAudioTxPump: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var connected: Bool = false
    private var sessionIdSnapshot: String?
    private var txCount: Int = 0
    private var txBytes: Int = 0
    private var lastLogAt: Date = .distantPast

    func attach(task: URLSessionWebSocketTask) {
        lock.lock()
        self.task = task
        self.connected = false
        self.sessionIdSnapshot = nil
        self.txCount = 0
        self.txBytes = 0
        self.lastLogAt = .distantPast
        lock.unlock()
    }

    func markConnected(sessionId: String?) {
        lock.lock()
        self.connected = true
        self.sessionIdSnapshot = sessionId
        self.txCount = 0
        self.txBytes = 0
        self.lastLogAt = .distantPast
        lock.unlock()
    }

    func markDisconnected() {
        lock.lock()
        self.connected = false
        lock.unlock()
    }

    func detach() {
        lock.lock()
        self.task = nil
        self.connected = false
        self.sessionIdSnapshot = nil
        lock.unlock()
    }

    func send(_ data: Data, verboseLogging: Bool) {
        guard !data.isEmpty else { return }

        lock.lock()
        let task = self.task
        let connected = self.connected
        let sessionId = self.sessionIdSnapshot
        if connected {
            txCount += 1
            txBytes += data.count
        }
        let count = txCount
        let bytes = txBytes
        let now = Date()
        let isFirstFrame = verboseLogging && connected && count == 1
        let shouldLogRate = verboseLogging && connected && now.timeIntervalSince(lastLogAt) > 2.0
        if shouldLogRate { lastLogAt = now }
        lock.unlock()

        guard connected, let task else {
            print("[MIC_CHAIN] ws_send_audio_blocked: isConnected=false bytes=\(data.count)")
            return
        }

        if isFirstFrame {
            print("[MIC_CHAIN][SIM] ws_first_audio_tx: bytes=\(data.count) sessionId=\(sessionId ?? "nil")")
        }
        if shouldLogRate {
            print("[MIC_CHAIN] ws_audio_tx: frames=\(count) bytes=\(bytes) isConnected=true sessionId=\(sessionId ?? "nil")")
            print("[WS] audio tx: frames=\(count) bytes=\(bytes)")
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { error in
            if let error = error {
                print("[MIC_CHAIN] ws_send_audio_error: \(error)")
                print("[WS] 发送音频失败: \(error)")
            }
        }
    }
}

/// WebSocket 事件代理
protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect(sessionId: String)
    /// - Parameter disconnectInfo: 服务端 Close 帧解析结果；无有效 Close 信息（如本地 `disconnect()`、或仅有传输错误）时为 `nil`。
    func webSocketDidDisconnect(error: Error?, disconnectInfo: WebSocketDisconnectInfo?)
    func webSocketDidReceiveSTT(text: String)
    func webSocketDidReceiveTTSStart(sampleRate: Int)
    func webSocketDidReceiveTTSAudio(data: Data)
    func webSocketDidReceiveTTSSentence(text: String, isStart: Bool)
    func webSocketDidReceiveTTSStop()
    func webSocketDidReceiveError(message: String)
    func webSocketDidReceiveAIHangup()  // AI 主动挂断
    func webSocketDidReceiveToolCall(callId: String, name: String, arguments: [String: Any])
}

// MARK: - Incoming Call Context

/// Context about the current incoming call to include as template_vars in the hello message.
struct IncomingCallContext {
    /// Display name of the caller (empty string if unknown).
    var callerName: String
    /// "contact" if the caller is in the user's contacts, otherwise "stranger".
    var callerType: String
    /// Whether the caller is a saved contact.
    var isContact: Bool
    /// Number of previous calls from this phone number recorded in call history.
    var callCount: Int
    /// Call direction/type — always "inbound" for passive incoming calls.
    var systemCallType: String
    /// Last saved backend structured summary for this caller from call history.
    var callHistorySummary: String
}

/// WebSocket 服务 - 处理与服务端的通信
class WebSocketService: NSObject, ObservableObject {
    /// 与 `[OutboundAI][Tool]`、`[OutboundAI][WS]` 同族过滤前缀；联调/云端归因时 grep **`OutboundAI`** 或 **`UCv1`**（update_config v1 客户端侧证据链）。
    static let outboundAIUCv1Tag = "[OutboundAI][UCv1]"
    private struct DownstreamAudioParams: Sendable {
        let format: WSAudioFormat?
        let sampleRate: Int?
        let frameDuration: Int?
    }

    private struct ToolCallPayload: @unchecked Sendable {
        let callId: String
        let name: String
        let arguments: [String: Any]
        let rawArgumentsType: String
    }

    private struct ConnectPreparationSnapshot: Sendable {
        let wsURL: URL
        let protocolVersion: String
        let deviceId: String
        let bluetoothId: String
        let phoneIDHeaderValue: String
        let scene: WebSocketScene
        let audioFormat: WSAudioFormat
    }

    private struct ConnectPreparationResult: Sendable {
        let request: URLRequest
        let deviceId: String
        let bluetoothId: String
        let phoneIDPrefix: String
    }
    
    static let shared = WebSocketService()

  
    
    // MARK: - 配置
    private let wsURL = URL(string: AppConfig.wsBaseURL)!
    private let protocolVersion = "1"
    private let sendPromptEnabledKey = "ws_send_prompt_enabled"
    /// 开关：scene=init_config 时是否在 hello 中发送 init_config 调试 prompt。默认开。
    private let initConfigSendPromptEnabledKey = "ws_init_config_send_prompt_enabled"
    private let voiceIdKey = "callmate.voiceId"
    private let callScenePromptResourceName = "daijie"
    private let initConfigPromptResourceName = "init_config"
    private let initAndEvaluationPromptResourceName = "config"
    private let promptResourceExtension = "txt"
    private let promptSubdirectory = "Prompts"
    private let callEndMarkerToken = "✿END✿"
    /// 过早输出 ✿END✿ 会触发 `webSocketDidReceiveAIHangup()`。旧提示「判断要挂断就加」易误触发；须限定为真正终局回合。
    private let callEndMarkerInstruction = "【✿END✿】仅当本轮之后不应再由你开口、且通话可以结束时，才在本轮回复末尾追加 ✿END✿（例：对方已挂断；对方明确要求结束且你无需再补充；任务已完全达成且只剩简短道别）。不要在开场寒暄、信息未问全、尚在协商或追问、等待对方回应、多轮任务中途追加 ✿END✿。"

    
    // MARK: - 状态
    @MainActor @Published private(set) var isConnected = false
    @MainActor @Published private(set) var sessionId: String?
    @MainActor private var helloScene: WebSocketScene = .call

    /// True when the WS is fully connected (hello acked) in the `.call` scene with a live session.
    /// Use this to avoid redundant reconnects when `outgoing_answered` fires for an already-live
    /// incoming-call WS session.
    @MainActor var isConnectedInCallScene: Bool {
        isConnected && helloScene == .call && sessionId != nil
    }
    @MainActor private var callHelloPromptOverride: String?
    /// APNs `command` 的 `request_id`（仅外呼且由静默推送触发时）；填入 `hello.initiate.apns_request_id`。
    @MainActor private var helloApnsRequestId: String?
    // Per-session init messages injected for config/onboarding flows only.
    // Stored here rather than in UserDefaults so they can never leak into unrelated WS sessions.
    @MainActor private var pendingInitMessages: [[String: String]]?
    @MainActor private var pendingEvaluationChatHistory: [[String: String]]?
    @MainActor private var pendingAutoPlayIntro: Bool = false
    /// Caller context for the current incoming call; injected into template_vars for scene=call.
    /// Cleared on disconnect so it never leaks into subsequent sessions.
    @MainActor private var pendingIncomingCallContext: IncomingCallContext?
    /// Raw source used to build `phone_id` request header via SHA256.
    @MainActor private var pendingPhoneIDSource: String?
    
    // IMPORTANT:
    // This app can create multiple CallSessionController instances (BLE live call + simulation views).
    // A single `delegate` would be overwritten, causing TTS frames not to be forwarded to BLE.
    // Use a weak multicast delegate set instead.
    @MainActor private let delegateTable = NSHashTable<AnyObject>.weakObjects()
    
    @MainActor
    func addDelegate(_ delegate: WebSocketServiceDelegate) {
        // Avoid duplicates.
        removeDelegate(delegate)
        delegateTable.add(delegate)
    }
    
    @MainActor
    func removeDelegate(_ delegate: WebSocketServiceDelegate) {
        delegateTable.remove(delegate)
    }
    
    @MainActor
    private func notifyDelegates(_ block: (WebSocketServiceDelegate) -> Void) {
        // Snapshot to avoid mutation during iteration.
        let objects = delegateTable.allObjects
        for obj in objects {
            if let d = obj as? WebSocketServiceDelegate {
                block(d)
            }
        }
    }
    
    @MainActor private var webSocketTask: URLSessionWebSocketTask?
    private let receiveQueue: DispatchQueue
    private let urlSession: URLSession
    private var bluetoothId: String
    @MainActor private var connectPreparationTask: Task<Void, Never>?
    @MainActor private var connectAttemptID = UUID()
    @MainActor private(set) var isConnecting: Bool = false
    @MainActor private var pingTask: Task<Void, Never>?
    /// Nonisolated uplink audio pump — see `WSAudioTxPump` for the rationale.
    /// Owns the per-frame counters (`txCount` / `txBytes` / `lastLogAt`) that used to live on
    /// `WebSocketService` directly, so the send hot path no longer touches main-actor state.
    ///
    /// 属性本身不需要 `nonisolated(unsafe)`：`WSAudioTxPump` 是 `Sendable` 常量，Swift 允许
    /// 跨 actor 直接访问；真正关键的是 `WSAudioTxPump` 类显式标了 `nonisolated`，让 `send(_:…)`
    /// 脱离 main-actor 隔离，`nonisolated func sendAudioData(_:)` 才能无 actor hop 调它。
    private let audioTxPump = WSAudioTxPump()

    /// Nonisolated hook invoked from the URLSession receive queue for every incoming binary
    /// (TTS audio) frame — fires **before** the `@MainActor` delegate notification. Owners
    /// (`CallSessionController`) register a fast-enqueue closure here so that TTS bytes land
    /// in the BLE uplink queue without waiting on the main actor. Updated from the main
    /// thread; the assignment itself is a pointer write, which is atomic on Apple platforms.
    nonisolated(unsafe) var binaryFastRxHook: (@Sendable (Data) -> Void)?
    nonisolated private var verboseRealtimeAudioLoggingEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "callmate.verbose_realtime_audio_logging")
        #else
        false
        #endif
    }
    
    // Auto-reconnect is intentionally disabled.
    private var lastConnectAttemptAt: Date = .distantPast
    
    // 下行音频参数（服务端返回）
    @MainActor private(set) var downstreamSampleRate: Int = 24000
    @MainActor private(set) var downstreamFrameDuration: Int = 60
    @MainActor private(set) var audioFormat: WSAudioFormat = .opus
    
    // MARK: - 初始化
    private override init() {
        // Runtime-only identifiers. Never persist to disk.
        bluetoothId = UUID().uuidString
        let delegateQueue = OperationQueue()
        delegateQueue.name = "CallMate.WebSocketService.URLSession"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let receiveQueue = DispatchQueue(
            label: "CallMate.WebSocketService.Receive",
            qos: .userInitiated
        )
        self.receiveQueue = receiveQueue
        delegateQueue.underlyingQueue = receiveQueue
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: delegateQueue)
        super.init()
    }

    @MainActor
    var runtimeBluetoothID: String {
        bluetoothId
    }
    
    // MARK: - 连接管理
    
    /// 建立 WebSocket 连接
    @MainActor
    func connect(
        audioFormat: WSAudioFormat = .opus,
        scene: WebSocketScene = .call,
        initMessages: [[String: String]]? = nil,
        evaluationChatHistory: [[String: String]]? = nil,
        autoPlayIntro: Bool = false,
        reason: String? = nil
    ) {
        if isConnected || isConnecting {
            if helloScene == scene && self.audioFormat == audioFormat {
                if scene == .call && callHelloPromptOverride != nil {
                    let savedOverride = callHelloPromptOverride
                    let savedApns = helloApnsRequestId
                    print("[PromptTrace] connect() FORCE-RECONNECT: same scene=call but callHelloPromptOverride was set (\(callHelloPromptOverride!.count)chars), need fresh hello")
                    disconnect()
                    callHelloPromptOverride = savedOverride
                    helloApnsRequestId = savedApns
                } else {
                    print("[PromptTrace] connect() EARLY-RETURN: already \(isConnected ? "connected" : "connecting") scene=\(scene.rawValue) — callHelloPromptOverride=\(callHelloPromptOverride == nil ? "nil" : "\(callHelloPromptOverride!.count)chars")")
                    return
                }
            }
            // A shared WebSocket may still be connected for config flow
            // (update_config/init_config). Incoming calls must switch back to
            // call scene so server uses the call template.
            if helloScene != scene {
                print("[WS] connect scene switch \(helloScene.rawValue) -> \(scene.rawValue), reconnect")
            }
            if self.audioFormat != audioFormat {
                print("[WS] connect audioFormat switch \(self.audioFormat) -> \(audioFormat), reconnect")
            }
            let savedOverride = callHelloPromptOverride
            let savedApns = helloApnsRequestId
            disconnect()
            if scene == .call {
                callHelloPromptOverride = savedOverride
                helloApnsRequestId = savedApns
            }
        }
        if let initMessages {
            // Explicit caller input always wins (including explicit empty -> clear).
            pendingInitMessages = initMessages.isEmpty ? nil : initMessages
        } else if !scene.isManualInteractionScene {
            // Non-manual scenes should not carry stale conversation context.
            pendingInitMessages = nil
        } else if scene == helloScene {
            // Same manual-scene reconnect: keep the last context for continuity.
            print("[WS] connect: keep pendingInitMessages for same-scene reconnect scene=\(scene.rawValue) count=\(pendingInitMessages?.count ?? 0)")
        } else {
            // Switching between different manual scenes: clear stale context.
            print("[WS] connect: clear pendingInitMessages on manual-scene switch \(helloScene.rawValue) -> \(scene.rawValue)")
            pendingInitMessages = nil
        }
        pendingEvaluationChatHistory = evaluationChatHistory
        pendingAutoPlayIntro = autoPlayIntro
        isConnecting = true
        lastConnectAttemptAt = Date()
        self.audioFormat = audioFormat
        self.helloScene = scene
        connectPreparationTask?.cancel()
        let connectAttemptID = UUID()
        self.connectAttemptID = connectAttemptID
        if let reason {
            print("[WS_RECONNECT_TRACE] connect scene=\(scene.rawValue) audioFormat=\(audioFormat) reason=\(reason)")
        } else {
            print("[WS_RECONNECT_TRACE] connect scene=\(scene.rawValue) audioFormat=\(audioFormat)")
        }

        guard let identifiers = resolveActiveMCUIdentifiers() else {
            connectPreparationTask = nil
            isConnecting = false
            notifyDelegates {
                $0.webSocketDidReceiveError(message: "MCU is not connected or device-id is unavailable.")
            }
            print("[WS] connect blocked: MCU not ready or runtime device-id missing")
            return
        }
        let preparationSnapshot = ConnectPreparationSnapshot(
            wsURL: wsURL,
            protocolVersion: protocolVersion,
            deviceId: identifiers.deviceId,
            bluetoothId: identifiers.bluetoothId,
            phoneIDHeaderValue: resolvePhoneIDHeaderValue(),
            scene: scene,
            audioFormat: audioFormat
        )

        connectPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            let token = await BackendAuthManager.shared.ensureToken()
            if let token {
                print("[WS][AUTH] Bearer token prefix=\(String(token.prefix(12)))... len=\(token.count) (used in WS Authorization header)")
            } else {
                print("[WS][AUTH] token=nil — cannot set Authorization; handshake will fail or be rejected")
            }

            guard let token, BackendAuthManager.looksLikeJWT(token) else {
                let service = self
                await MainActor.run {
                    guard let service, service.connectAttemptID == connectAttemptID else { return }
                    service.connectPreparationTask = nil
                    service.isConnecting = false
                    service.notifyDelegates { $0.webSocketDidReceiveError(message: "Token missing; cannot connect WebSocket.") }
                }
                return
            }
            guard !Task.isCancelled else { return }

            do {
                try await BackendAuthManager.shared.reportDevice(
                    deviceId: preparationSnapshot.deviceId,
                    bluetoothId: preparationSnapshot.bluetoothId,
                    token: token
                )
            } catch {
                print("[WS] device/report failed (will still connect): \(error)")
            }
            guard !Task.isCancelled else { return }

            let prepared = Self.prepareConnectResult(snapshot: preparationSnapshot, token: token)
            let service = self

            await MainActor.run {
                guard let service, service.connectAttemptID == connectAttemptID else { return }
                guard service.isConnecting,
                      service.helloScene == preparationSnapshot.scene,
                      service.audioFormat == preparationSnapshot.audioFormat else {
                    service.connectPreparationTask = nil
                    return
                }

                service.connectPreparationTask = nil
                service.suppressReceiveFailureOnce = true
                service.webSocketTask?.cancel(with: .goingAway, reason: nil)
                service.webSocketTask = nil
                service.audioTxPump.detach()

                print("[WS][AUTH] WebSocket upgrade request url=\(prepared.request.url?.absoluteString ?? service.wsURL.absoluteString) deviceId=\(prepared.deviceId) bluetoothId=\(prepared.bluetoothId) phone_id_prefix=\(prepared.phoneIDPrefix)")
                let task = service.urlSession.webSocketTask(with: prepared.request)
                service.webSocketTask = task
                service.audioTxPump.attach(task: task)
                task.resume()
                print("[WS][AUTH] webSocketTask.resume() — if upgrade fails, next lines should be [WS][FAIL] with HTTP status/body hints")

                service.receiveMessage(task: task)

                service.helloAcked = false
                service.helloRetryTask?.cancel()
                service.helloRetryTask = Task { @MainActor [weak service] in
                    guard let service else { return }
                    for attempt in 1...3 {
                        if Task.isCancelled { return }
                        if service.helloAcked { return }
                        print("[WS] send hello attempt=\(attempt)")
                        service.sendHello()
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    if !service.helloAcked {
                        print("[WS] hello timeout after 3 attempts, disconnecting")
                        service.disconnect()
                    }
                }
            }
        }
    }

    /// Ensure websocket is usable for a BLE incoming call.
    /// If we are stuck in `isConnecting` for too long (e.g. background-suspended handshake),
    /// force reset and reconnect immediately.
    @MainActor
    func ensureConnectedForBLECall(
        audioFormat: WSAudioFormat = .opus,
        scene: WebSocketScene = .call,
        staleAfter: TimeInterval = 1.5,
        reason: String? = nil
    ) {
        if let reason {
            print("[WS_RECONNECT_TRACE] ensure_enter scene=\(scene.rawValue) audioFormat=\(audioFormat) reason=\(reason) isConnected=\(isConnected) isConnecting=\(isConnecting) sessionId=\(sessionId ?? "nil")")
        } else {
            print("[WS_RECONNECT_TRACE] ensure_enter scene=\(scene.rawValue) audioFormat=\(audioFormat) isConnected=\(isConnected) isConnecting=\(isConnecting) sessionId=\(sessionId ?? "nil")")
        }
        if isConnected {
            if helloScene != scene || self.audioFormat != audioFormat {
                if helloScene != scene {
                    print("[WS] ensureConnectedForBLECall: connected in \(helloScene.rawValue), need \(scene.rawValue)")
                }
                if self.audioFormat != audioFormat {
                    print("[WS] ensureConnectedForBLECall: audioFormat mismatch \(self.audioFormat) -> \(audioFormat)")
                }
                connect(audioFormat: audioFormat, scene: scene, reason: "ensureConnectedForBLECall:switch_from_connected")
            }
            return
        }
        if isConnecting {
            let elapsed = Date().timeIntervalSince(lastConnectAttemptAt)
            if helloScene != scene || self.audioFormat != audioFormat {
                if helloScene != scene {
                    print("[WS] ensureConnectedForBLECall: connecting in \(helloScene.rawValue), switch to \(scene.rawValue)")
                }
                if self.audioFormat != audioFormat {
                    print("[WS] ensureConnectedForBLECall: connecting with wrong audioFormat \(self.audioFormat), need \(audioFormat)")
                }
                connect(audioFormat: audioFormat, scene: scene, reason: "ensureConnectedForBLECall:switch_while_connecting")
                return
            }
            if elapsed < staleAfter {
                return
            }
            print(String(format: "[WS] ensureConnectedForBLECall: stale connecting %.2fs -> force reconnect", elapsed))
            disconnect()
        }
        connect(audioFormat: audioFormat, scene: scene, reason: "ensureConnectedForBLECall:disconnected_or_stale")
    }

    /// Set caller context to be included in `hello.initiate.template_vars` for the next call session.
    /// Pass `nil` to clear (e.g., after a call ends or before an outbound call).
    @MainActor
    func setIncomingCallContext(_ context: IncomingCallContext?) {
        pendingIncomingCallContext = context
        print("[WS] setIncomingCallContext callerName=\(context?.callerName ?? "nil") callerType=\(context?.callerType ?? "nil") isContact=\(context?.isContact.description ?? "nil") callCount=\(context?.callCount.description ?? "nil") systemCallType=\(context?.systemCallType ?? "nil")")
    }

    /// Set raw phone identifier source for `phone_id` header.
    /// - Parameter source: Usually caller/callee phone number. For simulation, use "模拟通话".
    @MainActor
    func setPhoneIDSource(_ source: String?) {
        let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pendingPhoneIDSource = trimmed.isEmpty ? nil : trimmed
        print("[WS] setPhoneIDSource raw=\(pendingPhoneIDSource ?? "nil")")
    }

    /// Update `initiate.messages` payload used by subsequent (re)connects.
    /// - Important: This does not force reconnect immediately.
    @MainActor
    func setInitMessagesForReconnect(_ initMessages: [[String: String]]?) {
        guard helloScene.isManualInteractionScene else { return }
        if let initMessages {
            pendingInitMessages = initMessages.isEmpty ? nil : initMessages
        } else {
            pendingInitMessages = nil
        }
        print("[WS] setInitMessagesForReconnect scene=\(helloScene.rawValue) count=\(pendingInitMessages?.count ?? 0)")
    }

    /// Toggle whether `hello.initiate.prompt` should be sent.
    /// Default is `true` when not set.
    @MainActor
    func setSendPromptEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: sendPromptEnabledKey)
        print("[WS] setSendPromptEnabled=\(enabled)")
    }

    /// Returns whether `hello.initiate.prompt` is enabled.
    /// Default is `false` when not set.
    @MainActor
    func isSendPromptEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: sendPromptEnabledKey) == nil {
            return false
        }
        return defaults.bool(forKey: sendPromptEnabledKey)
    }

    /// 开关：scene=init_config 时是否在 hello 中发送 init_config prompt。默认开。
    @MainActor
    func setInitConfigSendPromptEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: initConfigSendPromptEnabledKey)
        print("[WS] setInitConfigSendPromptEnabled=\(enabled)")
    }

    @MainActor
    func isInitConfigSendPromptEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: initConfigSendPromptEnabledKey) == nil {
            return false
        }
        return defaults.bool(forKey: initConfigSendPromptEnabledKey)
    }

    /// Set outbound-call specific prompt for hello.initiate.prompt.
    /// This is only used for `scene=call`.
    @MainActor
    func setCallHelloPromptOverride(_ prompt: String?) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        callHelloPromptOverride = trimmed.isEmpty ? nil : trimmed
        print("[WS] setCallHelloPromptOverride length=\(callHelloPromptOverride?.count ?? 0)")
    }

    /// 下一通 `scene=call` 的 hello 是否在 `initiate` 中带 `apns_request_id`（非 APNs 外呼传 nil）。
    @MainActor
    func setHelloApnsRequestId(_ requestId: String?) {
        let trimmed = requestId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        helloApnsRequestId = trimmed.isEmpty ? nil : trimmed
        print("[WS] setHelloApnsRequestId=\(helloApnsRequestId ?? "nil")")
    }
    
    /// 断开连接
    @MainActor
    func disconnect() {
        connectPreparationTask?.cancel()
        connectPreparationTask = nil
        connectAttemptID = UUID()
        suppressReceiveFailureOnce = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        audioTxPump.detach()
        isConnected = false
        isConnecting = false
        sessionId = nil
        pingTask?.cancel()
        pingTask = nil
        helloRetryTask?.cancel()
        helloRetryTask = nil
        helloAcked = false
        callHelloPromptOverride = nil
        helloApnsRequestId = nil
        pendingInitMessages = nil
        pendingIncomingCallContext = nil
        pendingPhoneIDSource = nil
        pendingEvaluationChatHistory = nil
    }
    
    // MARK: - 发送消息
    
    /// 发送 Hello 握手
    @MainActor
    private func sendHello() {
        if helloScene == .call {
            print("[PromptTrace] sendHello: scene=call callHelloPromptOverride=\(callHelloPromptOverride == nil ? "nil ← MISSING PROMPT" : "\(callHelloPromptOverride!.count)chars ✓")")
        } else if helloScene != .updateConfig {
            print("[PromptTrace] sendHello: scene=\(helloScene.rawValue) callHelloPromptOverride=\(callHelloPromptOverride == nil ? "nil" : "\(callHelloPromptOverride!.count)chars")")
        }
        var audioParams: [String: Any] = [
            "sample_rate": 16000,
            "channels": 1
        ]
        audioParams["format"] = "opus"
        audioParams["frame_duration"] = 60

        var hello: [String: Any] = [
            "type": "hello",
            "audio_params": audioParams
        ]

        // 构建 initiate 对象
        var initiate: [String: Any] = [:]

        // Scene (call/init_config/update_config)
        initiate["scene"] = helloScene.rawValue

        // Prompt rule:
        // - outbound call scene uses task template prompt override
        // - outbound chat scene always loads from outbound_call.txt
        // - other scenes do not send prompt by default
        if helloScene == .call {
            if let prompt = callHelloPromptOverride {
                initiate["prompt"] = appendCallEndMarkerInstructionIfNeeded(to: prompt)
            }
            if let rid = helloApnsRequestId?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty {
                initiate["apns_request_id"] = rid
            }
        } else if helloScene == .updateConfig {
            // v1 (update_config client spec, 2026-04-28): prompt is fully owned
            // by the server. Client only injects template_vars below — no
            // `initiate.prompt` is sent. Summary: `logOutboundAIUCv1HelloSummary` (single line).
        } else if helloScene == .outboundChat {
            if let prompt = loadPromptIfNeeded(for: helloScene) {
                initiate["prompt"] = prompt
                print("[OutboundAI][WS] hello outbound_chat promptLen=\(prompt.count)")
            }
        } else if helloScene == .initConfig {
            if isInitConfigSendPromptEnabled(), let prompt = loadPromptIfNeeded(for: .initConfig) {
                initiate["prompt"] = prompt
                print("[WS] hello init_config promptLen=\(prompt.count)")
            } else if !isInitConfigSendPromptEnabled() {
                print("[WS] init_config prompt disabled by flag")
            }
        } else {
            // evaluation 等
            let sendPromptEnabled = isSendPromptEnabled()
            if sendPromptEnabled, let prompt = loadPromptIfNeeded(for: helloScene) {
                initiate["prompt"] = prompt
            } else if !sendPromptEnabled {
                print("[WS] prompt sending disabled by flag")
            }
        }
        
        var templateVars: [String: Any] = [:]
        if let rawLang = UserDefaults.standard.string(forKey: "callmate.language"),
           let lang = Language(rawValue: rawLang) {
            templateVars["languageName"] = (lang == .zh) ? "中文" : "English"
        } else {
            templateVars["languageName"] = "中文"
        }

        if let appellation = UserDefaults.standard.string(forKey: "callmate.userAppellation"),
           !appellation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            templateVars["appellation"] = appellation
        }

        if helloScene == .updateConfig {
            // v1 §2 update_config template_vars:
            //   - greeting (optional)
            //   - strategyManifest (omit when user has no rules)
            //   - templateManifest (presence is the gate that unlocks template/outbound skills)
            // The legacy `processStrategy` (full JSON) is **not** sent for this scene.
            if let greeting = UserDefaults.standard.string(forKey: "callmate.userGreeting"),
               !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                templateVars["greeting"] = greeting
            }
            let strategyManifest = ProcessStrategyStore.getStrategyManifest()
            if !strategyManifest.isEmpty {
                templateVars["strategyManifest"] = strategyManifest
            }
            // Outbound capability is currently universal in this build — always
            // send `templateManifest` (possibly empty) to unlock the LLM's
            // template/outbound skills. If a future build introduces a gate,
            // wrap this with the relevant flag and omit the field when off.
            templateVars["templateManifest"] = OutboundTemplateStore.getManifest()
        } else {
            let processStrategy = ProcessStrategyStore.processStrategyJSONString()
            if let processStrategy, !processStrategy.isEmpty {
                templateVars["processStrategy"] = processStrategy
            }
        }

        if helloScene == .evaluation,
           let chatHistory = buildChatHistoryTemplateVar(from: pendingEvaluationChatHistory) {
            templateVars["chatHistory"] = chatHistory
        }

        // Inject incoming-call context for scene=call (passive inbound calls only).
        if helloScene == .call, let callCtx = pendingIncomingCallContext {
            templateVars["isContact"] = callCtx.isContact
            templateVars["callerName"] = callCtx.callerName
            templateVars["callerType"] = callCtx.callerType
            templateVars["callCount"] = callCtx.callCount
            templateVars["systemCallType"] = callCtx.systemCallType
            if !callCtx.callHistorySummary.isEmpty {
                templateVars["callHistorySummary"] = callCtx.callHistorySummary
            }
        }

        if !templateVars.isEmpty {
            initiate["template_vars"] = templateVars
        }

        // tts_voice for TTS（AI分身、AI配置向导、evaluation 不传 tts_voice）
        let skipTtsVoice = helloScene == .outboundChat || helloScene == .initConfig || helloScene == .updateConfig || helloScene == .evaluation
        if !skipTtsVoice,
           let voiceId = UserDefaults.standard.string(forKey: voiceIdKey),
           !voiceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initiate["tts_voice"] = voiceId
        }

        // Optional auto-play intro and init messages.
        // Values come from the per-session instance vars set by connect(); never from UserDefaults.
        if pendingAutoPlayIntro {
            initiate["auto_play_intro"] = true
        }
        // outbound_chat: do not send initiate.messages — server/chat UX does not use history replay on hello.
        if helloScene != .outboundChat,
           let msgs = pendingInitMessages, !msgs.isEmpty {
            initiate["messages"] = msgs
        }
        if helloScene == .outboundChat {
            let hasPrompt = initiate["prompt"] != nil
            print("[OutboundAI][WS] hello outbound_chat hasPrompt=\(hasPrompt) (initiate.messages omitted)")
        }
        
        if !initiate.isEmpty {
            hello["initiate"] = initiate
        }

        if helloScene == .updateConfig {
            logOutboundAIUCv1HelloSummary(initiate: initiate)
        }

        if let data = try? JSONSerialization.data(withJSONObject: hello, options: [.prettyPrinted, .sortedKeys]),
           let payload = String(data: data, encoding: .utf8) {
            if helloScene == .updateConfig {
                print("[WS] hello_sent scene=update_config json_bytes=\(data.count) wire_json_omitted=1 pair_with_prior_UCv1_line=1")
            } else {
                print("[WS] hello payload:\n\(payload)")
            }
        } else {
            print("[WS] hello payload serialization failed")
        }

        sendJSON(hello)
    }
    
    /// 开始录音/监听
    @MainActor
    func sendListenStart(mode: ListenMode = .realtime) {
        guard let sid = sessionId else { return }
        print("[WS] sendListenStart mode=\(mode.rawValue) sid=\(sid)")
        let msg: [String: Any] = [
            "session_id": sid,
            "type": "listen",
            "state": "start",
            "mode": mode.rawValue
        ]
        sendJSON(msg)
    }
    
    /// 停止录音/监听
    @MainActor
    func sendListenStop() {
        guard let sid = sessionId else { return }
        print("[WS] sendListenStop sid=\(sid)")
        let msg: [String: Any] = [
            "session_id": sid,
            "type": "listen",
            "state": "stop"
        ]
        sendJSON(msg)
    }
    
    /// 发送文本（不走语音）
    @MainActor
    func sendListenText(_ text: String) {
        guard let sid = sessionId else { return }
        let msg: [String: Any] = [
            "session_id": sid,
            "type": "listen",
            "state": "text",
            "text": text
        ]
        sendJSON(msg)
    }
    
    /// 中断当前操作
    @MainActor
    func sendAbort(reason: String = "user_interrupt") {
        guard let sid = sessionId else { return }
        print("[WS] sendAbort sid=\(sid) reason=\(reason)")
        let msg: [String: Any] = [
            "session_id": sid,
            "type": "abort",
            "reason": reason
        ]
        sendJSON(msg)
    }
    
    /// 发送音频数据（Opus 编码后的二进制）
    ///
    /// 现已 `nonisolated` — 所有状态（task 快照、计数器、verbose 日志节流）都封在 `audioTxPump`
    /// 里，调用方无需处于主线程即可调用。今天的 caller 仍为 `@MainActor`（CallSessionController
    /// 系列），语义位对位不变；真正受益的是之后把 AudioService tap 闭包的 delegate hop 拆掉时，
    /// 可以直接从音频实时线程调到这里，彻底跳过主线程。
    nonisolated func sendAudioData(_ data: Data) {
        audioTxPump.send(data, verboseLogging: verboseRealtimeAudioLoggingEnabled)
    }

    /// 发送工具调用响应
    @MainActor
    func sendToolResponse(callId: String, result: [String: Any]? = nil, error: String? = nil) {
        if helloScene == .updateConfig {
            print("\(Self.outboundAIUCv1Tag) tool_response side=client scene=\(helloScene.rawValue) call_id=\(callId) \(Self.outboundAIUCv1ToolResponseSummary(result: result, error: error))")
        }
        var payload: [String: Any] = [
            "type": "tool_response",
            "call_id": callId
        ]
        if let result {
            payload["result"] = result
        }
        if let error {
            payload["error"] = error
        }
        sendJSON(payload)
    }

    /// `update_config` hello 摘要：不含 prompt 全文，仅键与条数，供云端区分「客户端未发旧 prompt / manifest 已带上」。
    @MainActor
    private func logOutboundAIUCv1HelloSummary(initiate: [String: Any]) {
        let hasClientPrompt = initiate["prompt"] != nil
        guard let tv = initiate["template_vars"] as? [String: Any] else {
            print("\(Self.outboundAIUCv1Tag) hello side=client scene=update_config client_prompt=\(hasClientPrompt) note=server_owned_prompt template_vars=missing")
            return
        }
        let smCount: Int = {
            if let sm = tv["strategyManifest"] as? [[String: Any]] { return sm.count }
            if let sm = tv["strategyManifest"] as? [Any] { return sm.count }
            return 0
        }()
        let tmCount: Int = {
            if let tm = tv["templateManifest"] as? [[String: Any]] { return tm.count }
            if let tm = tv["templateManifest"] as? [Any] { return tm.count }
            return 0
        }()
        let keys = tv.keys.sorted().joined(separator: ",")
        let hasProcessStrategy = tv["processStrategy"] != nil
        let msgCount = (initiate["messages"] as? [Any])?.count ?? 0
        print("\(Self.outboundAIUCv1Tag) hello side=client scene=update_config client_prompt=\(hasClientPrompt) note=server_owned_prompt initiate_messages_count=\(msgCount) strategyManifest_count=\(smCount) templateManifest_count=\(tmCount) template_var_keys=\(keys) processStrategy_in_template_vars=\(hasProcessStrategy)")
    }

    /// 单行摘要：不打印 `load_template` 等大字段，避免日志爆炸。
    private static func outboundAIUCv1ToolResponseSummary(result: [String: Any]?, error: String?) -> String {
        if let error {
            let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…(len=\(trimmed.count))" : trimmed
            return "kind=error msg=\"\(preview)\""
        }
        guard let result else {
            return "kind=empty"
        }
        let keys = result.keys.sorted().joined(separator: ",")
        var bits = ["kind=result", "keys=\(keys)"]
        if let b = result["success"] as? Bool { bits.append("success=\(b)") }
        if let s = result["action"] as? String { bits.append("action=\(s)") }
        if let s = result["reason"] as? String {
            let p = s.count > 80 ? String(s.prefix(80)) + "…" : s
            bits.append("reason=\(p)")
        }
        if let s = result["name"] as? String { bits.append("name_len=\(s.count)") }
        if let s = result["scheduled_at"] as? String { bits.append("scheduled_at=\(s)") }
        if result["content"] != nil { bits.append("has_content_blob=true") }
        if result["tag"] != nil { bits.append("has_tag=true") }
        return bits.joined(separator: " ")
    }
    
    // MARK: - 内部方法
    
    @MainActor
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return
        }
        let message = URLSessionWebSocketTask.Message.string(str)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("[WS] 发送失败: \(error)")
            }
        }
    }

    @MainActor
    private func startPingLoopIfNeeded() {
        guard pingTask == nil else { return }
        pingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                if Task.isCancelled { break }
                guard self.webSocketTask != nil else { continue }
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        print("[WS] ping failed: \(error)")
                    } else {
                        // Uncomment if needed:
                        // print("[WS] ping ok")
                    }
                }
            }
        }
    }
    
    private func receiveMessage(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.processReceivedMessage(message, on: task)
            case .failure(let error):
                Task { @MainActor [weak self] in
                    self?.handleReceiveFailure(error, task: task)
                }
            }
        }
    }

    /// Diagnostics when WS handshake or receive fails (token/auth problems often surface here).
    private static func logWebSocketFailureContext(error: Error, task: URLSessionWebSocketTask) {
        let urlStr = task.originalRequest?.url?.absoluteString ?? task.currentRequest?.url?.absoluteString ?? "nil"
        print("[WS][FAIL] error=\(error.localizedDescription)")
        print("[WS][FAIL] url=\(urlStr)")
        if let taskErr = task.error {
            print("[WS][FAIL] task.error=\(taskErr.localizedDescription)")
        }
        if let http = task.response as? HTTPURLResponse {
            print("[WS][FAIL] HTTP upgrade status=\(http.statusCode) headers=\(http.allHeaderFields)")
        } else if let resp = task.response {
            print("[WS][FAIL] response (non-HTTP)=\(resp)")
        } else {
            print("[WS][FAIL] task.response=nil")
        }
        let ns = error as NSError
        print("[WS][FAIL] NSError domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let u = underlying as NSError
            print("[WS][FAIL] underlying domain=\(u.domain) code=\(u.code) desc=\(u.localizedDescription) userInfo=\(u.userInfo)")
        }
    }

    private func processReceivedMessage(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        switch message {
        case .string(let text):
            print("[WS][RX][text] \(text)")
            processTextMessage(text)
        case .data(let data):
            // Fast path: synchronously on the URLSession receive queue, forward raw TTS bytes
            // to any listener that only cares about pushing them into an onward audio pipeline
            // (e.g. CallSessionController enqueueing into the BLE uplink `TTSUplinkState`).
            // Runs fully nonisolated — a SwiftUI main-thread stall cannot delay call audio.
            binaryFastRxHook?(data)
            // Slow path: @MainActor handler still runs the legacy delegate notification for
            // diagnostic counters, drain scheduling, first-frame playback prep, etc.
            Task { @MainActor [weak self] in
                self?.handleBinaryMessage(data)
            }
        @unknown default:
            break
        }
        receiveMessage(task: task)
    }

    private func processTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeStr = json["type"] as? String else {
            return
        }
        
        switch typeStr {
        case "hello":
            let sessionId = json["session_id"] as? String
            let audioParams = parseDownstreamAudioParams(json["audio_params"] as? [String: Any])
            Task { @MainActor [weak self] in
                self?.handleHelloMessage(sessionId: sessionId, audioParams: audioParams)
            }
            
        case "stt":
            let rawText = json["text"] as? String ?? ""
            let displayText = rawText.replacingOccurrences(of: "✿END✿", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let containsHangup = rawText.contains("✿END✿")
            Task { @MainActor [weak self] in
                self?.handleSTTMessage(displayText: displayText, rawText: rawText, containsHangup: containsHangup)
            }
            
        case "tts":
            processTTSMessage(json)

        case "filler":
            // Server pushes `{type:"filler", id:"mm_short", text:"嗯"}` during AI
            // think-gaps. iOS forwards to MCU which plays a pre-loaded mSBC blob
            // over HFP eSCO. No sid, no ack wait — see docs/tts-filler-low-latency.md §7.
            //
            // 调试开关：UserDefaults `callmate.debug_disable_filler_forward`。
            // 对方听 TTS 顿挫残留排查（docs/tts-uplink-stutter-pending.md P0 候选 A），
            // 由设备诊断页的 Toggle 控制，打开时跳过本端 play_filler 转发，MCU 就不走
            // `0cec1615` 引入的 filler mute gate，A/B 验证 filler 边界是否造成顿挫。
            let id = (json["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if UserDefaults.standard.bool(forKey: "callmate.debug_disable_filler_forward") {
                print("[WS][filler] DEBUG_DISABLED forward id=\(id)")
                break
            }
            guard !id.isEmpty else {
                print("[WS][filler] ignore: empty id")
                break
            }
            print("[WS][filler] forward id=\(id)")
            CallMateBLEClient.shared.sendCommand(
                "play_filler",
                extra: ["filler_id": id],
                expectAck: false
            )

        case "error":
            // Server-side errors (incl. auth/token) — log full payload; `message` alone may omit fields.
            print("[WS][server_error] raw_json=\(text)")
            let message = json["message"] as? String ?? ""
            Task { @MainActor [weak self] in
                self?.handleServerErrorMessage(message, rawJSON: text)
            }
            
        case "tool_call":
            print("[WS] tool_call raw: \(text)")
            guard let callId = json["call_id"] as? String,
                  let tool = json["tool"] as? [String: Any],
                  let name = tool["name"] as? String else {
                print("[WS] tool_call missing fields")
                return
            }
            let rawArguments = tool["arguments"]
            let payload = ToolCallPayload(
                callId: callId,
                name: name,
                arguments: parseToolArguments(rawArguments),
                rawArgumentsType: rawArguments.map { String(describing: type(of: $0)) } ?? "nil"
            )
            Task { @MainActor [weak self] in
                self?.handleToolCallMessage(payload, source: "tool_call")
            }

        case "mcp":
            print("[WS] mcp raw: \(text)")
            guard let payload = json["payload"] as? [String: Any] else {
                print("[WS] mcp missing payload")
                return
            }
            // Support MCP tools/call -> map to tool_call delegate.
            if let method = payload["method"] as? String, method == "tools/call",
               let params = payload["params"] as? [String: Any],
               let name = params["name"] as? String {
                let rawArguments = params["arguments"]
                let toolPayload = ToolCallPayload(
                    callId: String(describing: payload["id"] ?? UUID().uuidString),
                    name: name,
                    arguments: parseToolArguments(rawArguments),
                    rawArgumentsType: rawArguments.map { String(describing: type(of: $0)) } ?? "nil"
                )
                Task { @MainActor [weak self] in
                    self?.handleToolCallMessage(toolPayload, source: "mcp tools/call")
                }
            } else {
                print("[WS] mcp unsupported payload: \(payload)")
            }

        default:
            print("[WS] 未知消息: \(typeStr)")
        }
    }
    
    @MainActor
    private func handleBinaryMessage(_ data: Data) {
        // 二进制帧 = Opus 编码的音频数据
        // Debug: confirm binary frames are being received
        binaryRxCount += 1
        binaryRxBytes += data.count
        if binaryRxCount <= 3 || (binaryRxCount % 50) == 0 {
            print("[WS] binary rx: count=\(binaryRxCount) bytes=\(binaryRxBytes) frameSize=\(data.count)")
        }
        notifyDelegates { $0.webSocketDidReceiveTTSAudio(data: data) }
    }
    
    @MainActor
    private func handleReceiveFailure(_ error: Error, task: URLSessionWebSocketTask) {
        if suppressReceiveFailureOnce {
            suppressReceiveFailureOnce = false
            print("[WS] receive stopped after intentional disconnect")
            return
        }
        Self.logWebSocketFailureContext(error: error, task: task)
        let disconnectInfo = WebSocketCloseSemantics.disconnectInfo(from: task, error: error)
        print("[WS][CLOSE] \(disconnectInfo.logDescription)")
        print("[WS] 接收失败: \(error)")
        isConnected = false
        isConnecting = false
        sessionId = nil
        audioTxPump.markDisconnected()
        notifyDelegates { $0.webSocketDidDisconnect(error: error, disconnectInfo: disconnectInfo) }
    }

    @MainActor
    private func handleHelloMessage(sessionId: String?, audioParams: DownstreamAudioParams?) {
        suppressReceiveFailureOnce = false
        helloAcked = true
        if helloScene == .call {
            callHelloPromptOverride = nil
            helloApnsRequestId = nil
        }
        if !helloScene.isManualInteractionScene {
            pendingInitMessages = nil
        }
        pendingAutoPlayIntro = false
        helloRetryTask?.cancel()
        helloRetryTask = nil
        self.sessionId = sessionId
        isConnected = true
        isConnecting = false
        audioTxPump.markConnected(sessionId: sessionId)
        startPingLoopIfNeeded()

        if let format = audioParams?.format {
            audioFormat = format
        }
        if let sampleRate = audioParams?.sampleRate {
            downstreamSampleRate = sampleRate
        }
        if let frameDuration = audioParams?.frameDuration {
            downstreamFrameDuration = frameDuration
        }

        print("[WS] 已连接, sessionId: \(self.sessionId ?? "nil"), 下行采样率: \(downstreamSampleRate)")
        notifyDelegates { $0.webSocketDidConnect(sessionId: self.sessionId ?? "") }
    }

    @MainActor
    private func handleSTTMessage(displayText: String, rawText: String, containsHangup: Bool) {
        print("[WS] STT: \(rawText)")
        if !displayText.isEmpty {
            notifyDelegates { $0.webSocketDidReceiveSTT(text: displayText) }
        }
        if containsHangup {
            print("[WS] AI 主动挂断（STT）")
            notifyDelegates { $0.webSocketDidReceiveAIHangup() }
        }
    }

    private func processTTSMessage(_ json: [String: Any]) {
        guard let stateStr = json["state"] as? String else { return }
        let text = json["text"] as? String ?? ""

        switch stateStr {
        case "start":
            let sampleRate = json["sample_rate"] as? Int
            let sid = json["session_id"] as? String ?? "nil"
            let rawDescription = String(describing: json)
            Task { @MainActor [weak self] in
                self?.handleTTSStartMessage(sampleRate: sampleRate, sessionID: sid, rawDescription: rawDescription)
            }
        case "sentence_start":
            let displayText = text.replacingOccurrences(of: "✿END✿", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let containsHangup = text.contains("✿END✿")
            Task { @MainActor [weak self] in
                self?.handleTTSSentenceMessage(text: displayText, isStart: true, containsHangup: containsHangup)
            }
        case "sentence_end":
            let displayText = text.replacingOccurrences(of: "✿END✿", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let containsHangup = text.contains("✿END✿")
            Task { @MainActor [weak self] in
                self?.handleTTSSentenceMessage(text: displayText, isStart: false, containsHangup: containsHangup)
            }
        case "stop":
            Task { @MainActor [weak self] in
                self?.handleTTSStopMessage()
            }
        default:
            break
        }
    }

    @MainActor
    private func handleTTSStartMessage(sampleRate: Int?, sessionID: String, rawDescription: String) {
        let resolvedSampleRate = sampleRate ?? downstreamSampleRate
        print("[WS] TTS 开始, session_id=\(sessionID) sample_rate=\(resolvedSampleRate) raw=\(rawDescription)")
        notifyDelegates { $0.webSocketDidReceiveTTSStart(sampleRate: resolvedSampleRate) }
    }

    @MainActor
    private func handleTTSSentenceMessage(text: String, isStart: Bool, containsHangup: Bool) {
        if isStart {
            print("[WS] TTS 句子开始: \(text)")
        } else {
            print("[WS] TTS 句子结束: \(text)")
        }
        notifyDelegates { $0.webSocketDidReceiveTTSSentence(text: text, isStart: isStart) }
        if containsHangup {
            let source = isStart ? "sentence_start" : "sentence_end"
            print("[WS] AI 主动挂断（\(source)）")
            notifyDelegates { $0.webSocketDidReceiveAIHangup() }
        }
    }

    @MainActor
    private func handleTTSStopMessage() {
        print("[WS] TTS 结束")
        notifyDelegates { $0.webSocketDidReceiveTTSStop() }
    }

    @MainActor
    private func handleServerErrorMessage(_ message: String, rawJSON: String) {
        print("[WS] 错误(message): \(message) raw_len=\(rawJSON.count)")
        if helloScene == .updateConfig {
            let m = message.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
            let preview = m.count > 200 ? String(m.prefix(200)) + "…(len=\(m.count))" : m
            print("\(Self.outboundAIUCv1Tag) server_error side=server scene=\(helloScene.rawValue) msg=\"\(preview)\" raw_len=\(rawJSON.count) note=client_will_disconnect")
        }
        notifyDelegates { $0.webSocketDidReceiveError(message: message) }

        // Must run while still connected: after `hello`, `isConnected` is true. The old
        // `if !isConnected` branch never ran in normal calls, so teardown relied only on
        // the server closing the socket. Proactively disconnect + notify so mic uplink
        // stops immediately; `disconnect()` sets `suppressReceiveFailureOnce` so the
        // follow-up receive failure does not double-notify.
        guard isConnected else { return }
        let err = NSError(
            domain: "WebSocketService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        disconnect()
        notifyDelegates { $0.webSocketDidDisconnect(error: err, disconnectInfo: nil) }
    }

    @MainActor
    private func handleToolCallMessage(_ payload: ToolCallPayload, source: String) {
        print("[WS] \(source) dispatch name=\(payload.name) callId=\(payload.callId) rawArgsType=\(payload.rawArgumentsType) parsedArgKeys=\(Array(payload.arguments.keys))")
        if helloScene == .updateConfig {
            let keys = Array(payload.arguments.keys).sorted().joined(separator: ",")
            print("\(Self.outboundAIUCv1Tag) tool_call_rx side=client scene=\(helloScene.rawValue) name=\(payload.name) call_id=\(payload.callId) arg_keys=\(keys)")
        }
        notifyDelegates {
            $0.webSocketDidReceiveToolCall(
                callId: payload.callId,
                name: payload.name,
                arguments: payload.arguments
            )
        }
    }

    private func parseDownstreamAudioParams(_ audioParams: [String: Any]?) -> DownstreamAudioParams? {
        guard let audioParams else { return nil }
        let format: WSAudioFormat?
        if audioParams["format"] != nil {
            format = .opus
        } else {
            format = nil
        }
        return DownstreamAudioParams(
            format: format,
            sampleRate: audioParams["sample_rate"] as? Int,
            frameDuration: audioParams["frame_duration"] as? Int
        )
    }

    nonisolated private static func prepareConnectResult(
        snapshot: ConnectPreparationSnapshot,
        token: String
    ) -> ConnectPreparationResult {
        var request = URLRequest(url: snapshot.wsURL)
        request.setValue(snapshot.deviceId, forHTTPHeaderField: "Device-Id")
        request.setValue("CallMate-iOS", forHTTPHeaderField: "Client-Id")
        request.setValue(snapshot.protocolVersion, forHTTPHeaderField: "Protocol-Version")
        request.setValue(snapshot.phoneIDHeaderValue, forHTTPHeaderField: "phone_id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return ConnectPreparationResult(
            request: request,
            deviceId: snapshot.deviceId,
            bluetoothId: snapshot.bluetoothId,
            phoneIDPrefix: String(snapshot.phoneIDHeaderValue.prefix(8))
        )
    }

    @MainActor private var binaryRxCount: Int = 0
    @MainActor private var binaryRxBytes: Int = 0
    @MainActor private var helloRetryTask: Task<Void, Never>?
    @MainActor private var helloAcked: Bool = false
    @MainActor private var suppressReceiveFailureOnce: Bool = false
    @MainActor private var cachedPromptsByResourceName: [String: String] = [:]

    @MainActor
    private func promptResourceName(for scene: WebSocketScene) -> String? {
        switch scene {
        case .call:
            return callScenePromptResourceName
        case .initConfig:
            return initConfigPromptResourceName
        case .evaluation:
            return initAndEvaluationPromptResourceName
        case .updateConfig:
            // v1: server owns the update_config prompt; we never load locally.
            return nil
        case .outboundChat:
            return "outbound_call"
        }
    }

    @MainActor
    private func buildChatHistoryTemplateVar(from initMessages: [[String: String]]?) -> String? {
        guard let initMessages, !initMessages.isEmpty else { return nil }
        let items = initMessages.compactMap { item -> [String: String]? in
            guard let roleRaw = item["role"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let contentRaw = item["content"] else {
                return nil
            }
            let content = contentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let role: String
            switch roleRaw {
            case "assistant", "ai":
                role = "assistant"
            case "other", "caller":
                role = "other"
            default:
                role = "user"
            }
            return ["role": role, "content": content]
        }
        guard !items.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @MainActor
    private func loadPromptIfNeeded(for scene: WebSocketScene) -> String? {
        guard let resourceName = promptResourceName(for: scene) else {
            return nil
        }
        if let cached = cachedPromptsByResourceName[resourceName] {
            return cached
        }

        let bundle = Bundle.main
        let url = bundle.url(
            forResource: resourceName,
            withExtension: promptResourceExtension,
            subdirectory: promptSubdirectory
        ) ?? bundle.url(
            forResource: resourceName,
            withExtension: promptResourceExtension
        )
        guard let url else {
            let knownPromptFiles = bundle.paths(
                forResourcesOfType: promptResourceExtension,
                inDirectory: nil
            ).filter { $0.lowercased().contains(resourceName.lowercased()) }
            print("[WS] prompt resource not found for scene=\(scene.rawValue): \(promptSubdirectory)/\(resourceName).\(promptResourceExtension)")
            print("[WS] bundle prompt candidates: \(knownPromptFiles)")
            return nil
        }
        print("[WS] loaded prompt for scene=\(scene.rawValue) from: \(url.path)")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("[WS] failed to read prompt resource: \(url.path)")
            return nil
        }
        let prompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            print("[WS] prompt resource is empty for scene=\(scene.rawValue)")
            return nil
        }
        cachedPromptsByResourceName[resourceName] = prompt
        return prompt
    }

    @MainActor
    private func appendCallEndMarkerInstructionIfNeeded(to prompt: String) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return prompt }
        if trimmedPrompt.contains(callEndMarkerToken) {
            return trimmedPrompt
        }
        return "\(trimmedPrompt)\n\n\(callEndMarkerInstruction)"
    }

    private func parseToolArguments(_ rawArguments: Any?) -> [String: Any] {
        if let dict = rawArguments as? [String: Any] {
            return dict
        }
        if let text = rawArguments as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                return [:]
            }
            if let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let dict = json as? [String: Any] {
                return dict
            }
            print("[WS] parseToolArguments failed to decode JSON string: \(trimmed)")
        }
        return [:]
    }

    @MainActor
    private func resolveActiveMCUIdentifiers() -> (deviceId: String, bluetoothId: String)? {
        let ble = CallMateBLEClient.shared
        guard ble.isReady,
              ble.connectedPeripheralID != nil else {
            return nil
        }
        guard let runtimeDeviceId = ble.runtimeMCUDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runtimeDeviceId.isEmpty else {
            return nil
        }
        return (runtimeDeviceId, bluetoothId)
    }

    @MainActor
    private func resolvePhoneIDHeaderValue() -> String {
        // `phone_id` is mandatory for backend routing. Use caller/callee number if available.
        // If unavailable in call scene (e.g. simulation), hash the fixed marker "模拟通话".
        // For non-call scenes, keep a deterministic fallback.
        let raw = pendingPhoneIDSource
            ?? (helloScene == .call ? "模拟通话" : "config_scene")
        return sha256Hex(raw)
    }

    private func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

//
//  FeedbackChatModalView.swift
//  CallMate
//
//  全局 AI分身 - 支持策略修改提案流程
//

import SwiftUI
import SwiftData
import Combine
import AVKit
import UIKit

// MARK: - 扩展消息类型

enum ExtendedMessageType: String {
    case text
    case proposal
    case successAction
    case guideImage
    case outboundConfirmation
}

struct GuideImageData: Equatable {
    let imageId: String
    let caption: String?
}

struct OutboundConfirmationData: Equatable {
    let phone: String
    let contactName: String?
    let goal: String?
    let keyPoints: String?
    let templateName: String
    let scheduledAt: Date?
    let timeDescription: String?
}

enum ProposalStatus: String {
    case pending
    case cancelled
    case applied
    case failed
}

private enum ProposalCardStatus {
    case pending
    case cancelled
    case applied
    case expired
    case failed
}

struct ProposalData: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let before: String
    let after: String
}

struct ExtendedMessage: Identifiable, Equatable {
    var id: Int
    /// SwiftData `AIChatMessage.sortIndex` when loaded from store; set when persisting new rows.
    var storageSortIndex: Int? = nil
    let sender: ChatSender
    var text: String
    var isAudio: Bool = false
    var duration: Int? = nil
    var msgType: ExtendedMessageType = .text
    var proposalData: ProposalData? = nil
    var guideImageData: GuideImageData? = nil
    var outboundConfirmationData: OutboundConfirmationData? = nil
    var isConfirmed: Bool = false
    var proposalStatus: ProposalStatus = .pending
    var proposalCreatedAt: Date? = nil
    var proposalFailureMessage: String? = nil
}

private struct AvatarQuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let prompt: String
}

private struct FeedbackStreamingBubble: View {
    @ObservedObject var state: TTSStreamingBubbleState
    let proxy: ScrollViewProxy
    var useAvatarStyle: Bool = false
    var isNearBottom: Bool = true
    var enableLongPressCopy: Bool = false

    var body: some View {
        if useAvatarStyle {
            HStack {
                StreamingTextBubble(
                    state: state,
                    uiFont: .systemFont(ofSize: 17),
                    textColor: AppColors.textPrimary,
                    bubbleColor: Color.white.opacity(0.82),
                    cornerRadius: 18,
                    borderColor: .clear,
                    borderWidth: 0,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    useGlassMaterial: true,
                    lineSpacing: 6,
                    enableLongPressCopy: enableLongPressCopy
                )
                Spacer(minLength: UIScreen.main.bounds.width * 0.2)
            }
            .id("feedback-streaming")
            .onChange(of: state.text) { _, newText in
                if !newText.isEmpty, isNearBottom {
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                    }
                }
            }
        } else {
            StreamingTextBubble(state: state, enableLongPressCopy: enableLongPressCopy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("feedback-streaming")
                .onChange(of: state.text) { _, newText in
                    if !newText.isEmpty, isNearBottom {
                        DispatchQueue.main.async {
                            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                        }
                    }
                }
        }
    }
}

private final class PersistedMessagesBox: NSObject {
    let messages: [ExtendedMessage]

    init(messages: [ExtendedMessage]) {
        self.messages = messages
    }
}

// MARK: - FeedbackVoiceControl

/// Shared bridge that lets a parent view own the sticky voice input bar
/// while FeedbackChatModalView owns the WS session and recording logic.
final class FeedbackVoiceControl: ObservableObject {
    @Published var isRecording: Bool = false
    /// Increment to trigger "begin recording" inside FeedbackChatModalView.
    @Published var beginCount: Int = 0
    /// Increment to trigger "end recording" inside FeedbackChatModalView.
    @Published var endCount: Int = 0
    /// Increment to trigger "cancel current recording" inside FeedbackChatModalView.
    @Published var cancelCount: Int = 0
    /// Text payload to send from parent-owned sticky input.
    @Published var pendingText: String = ""
    /// Increment to trigger "send pendingText" inside FeedbackChatModalView.
    @Published var sendTextCount: Int = 0
}

// MARK: - FeedbackChatModalView

struct FeedbackChatModalView: View {
    private static let persistedMessagesCache = NSCache<NSString, PersistedMessagesBox>()
    private static let initLogFlags = NSCache<NSString, NSNumber>()

    let language: Language
    let feedbackType: String // "good" | "bad" | "none"
    let scene: WebSocketScene
    let onClose: () -> Void
    var isEmbedded: Bool = false
    /// When true: render messages as a plain LazyVStack (no inner ScrollView, no input bar).
    /// The parent is responsible for providing a sticky input bar via FeedbackVoiceControl.
    var inlineMessagesMode: Bool = false
    var voiceControl: FeedbackVoiceControl? = nil
    var showCloseButton: Bool = true
    var initialMessages: [ExtendedMessage]? = nil
    var showInitialMessage: Bool = true
    var initMessagesOverride: [[String: String]]? = nil
    var evaluationChatHistoryOverride: [[String: String]]? = nil
    var autoPlayIntro: Bool = true
    var isSoundEnabled: Binding<Bool>? = nil
    var messagesPersistenceKey: String? = nil
    var onMessagesChanged: (() -> Void)? = nil
    /// Called when the AI requests creating a new outbound template.
    /// Parent should save the template and call `respond(true)` on success or `respond(false)` to reject.
    var onCreateTemplate: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil
    /// Called when the AI requests initiating an outbound call immediately.
    /// Parent should show a confirmation card.
    /// - respond(true, nil): confirmed
    /// - respond(false, nil): cancelled by user
    /// - respond(false, "reason"): rejected by local validation/business logic
    var onInitiateCall: ((String, String, @escaping (Bool, String?) -> Void) -> Void)? = nil
    /// Called when the AI requests scheduling an outbound call at a specific time.
    /// Parent should show a scheduled confirmation card.
    /// - respond(true, nil): confirmed
    /// - respond(false, nil): cancelled by user
    /// - respond(false, "reason"): rejected by local validation/business logic
    var onScheduleCall: ((String, String, Date, String, @escaping (Bool, String?) -> Void) -> Void)? = nil
    var outboundConfirmationDataProvider: ((String, String, Date?, String?) -> OutboundConfirmationData)? = nil
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    @State private var messages: [ExtendedMessage]
    @State private var isSending = false
    @State private var isRecording = false
    @State private var wsMessageIndex = 0
    @State private var shownProposalIds: Set<String> = []
    @StateObject private var controller: CallSessionController
    @State private var recordStartAt: Date?
    @State private var lastStopAt: Date?
    @State private var now = Date()
    @State private var isVoiceCancelling = false
    @State private var hasPersistedContext = false
    @State private var nextMessageID: Int
    @State private var screenFrameInGlobal: CGRect = .zero
    @State private var isNearBottom = true
    @State private var shouldAutoFollowCurrentTurn = true
    @State private var shownGuideImageCallIds: Set<String> = []
    @State private var pendingOutboundConfirmations: [Int: OutboundCallConfirmRequest] = [:]
    /// When `messagesPersistenceKey` is set: more rows exist older than the loaded window.
    @State private var hasMoreOlder = false
    @State private var isLoadingOlder = false
    @State private var lastLoadOlderAt: Date?
    @State private var persistDebounceTask: Task<Void, Never>?
    /// 串行化"按住说话"时控制器（beginManualListen / endManualListen / cancelManualListen）的调用，
    /// 避免 begin/end 在同一帧触发时抢占主线程、撞坏状态。UI 状态不等它。
    @State private var voiceGate = VoiceRecordingGate()
    private let chatBackgroundName: String = "ChatBg"
    private var avatarQuickActions: [AvatarQuickAction] {
        [
            AvatarQuickAction(
                id: "call_rules",
                title: t("接听规则调整", "Update Call Rules"),
                icon: "slider.horizontal.3",
                prompt: t("帮我调整接听规则", "Help me adjust the call answering rules")
            )
        ]
    }
    private var shouldShowAvatarQuickActions: Bool {
        isEmbedded && scene == .updateConfig && !isRecording
    }

    /// In inline mode with external voice control, parent view owns the recording overlay.
    private var shouldShowLocalRecordingOverlay: Bool {
        isRecording && !(inlineMessagesMode && voiceControl != nil)
    }
    
    /// Show branded chat background only on AI Avatar chat page.
    private var shouldShowAvatarChatBackground: Bool {
        scene == .updateConfig || scene == .evaluation
    }

    init(
        language: Language,
        feedbackType: String,
        scene: WebSocketScene = .updateConfig,
        onClose: @escaping () -> Void,
        isEmbedded: Bool = false,
        inlineMessagesMode: Bool = false,
        voiceControl: FeedbackVoiceControl? = nil,
        showCloseButton: Bool = true,
        initialMessages: [ExtendedMessage]? = nil,
        showInitialMessage: Bool = true,
        initMessagesOverride: [[String: String]]? = nil,
        evaluationChatHistoryOverride: [[String: String]]? = nil,
        autoPlayIntro: Bool = true,
        isSoundEnabled: Binding<Bool>? = nil,
        messagesPersistenceKey: String? = nil,
        onMessagesChanged: (() -> Void)? = nil,
        onCreateTemplate: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil,
        onInitiateCall: ((String, String, @escaping (Bool, String?) -> Void) -> Void)? = nil,
        onScheduleCall: ((String, String, Date, String, @escaping (Bool, String?) -> Void) -> Void)? = nil,
        outboundConfirmationDataProvider: ((String, String, Date?, String?) -> OutboundConfirmationData)? = nil
    ) {
        self.language = language
        self.feedbackType = feedbackType
        self.scene = scene
        self.onClose = onClose
        self.isEmbedded = isEmbedded
        self.inlineMessagesMode = inlineMessagesMode
        self.voiceControl = voiceControl
        self.showCloseButton = showCloseButton
        self.showInitialMessage = showInitialMessage
        self.initMessagesOverride = initMessagesOverride
        self.evaluationChatHistoryOverride = evaluationChatHistoryOverride
        self.autoPlayIntro = autoPlayIntro
        self.isSoundEnabled = isSoundEnabled
        self.messagesPersistenceKey = messagesPersistenceKey
        self.onMessagesChanged = onMessagesChanged
        self.onCreateTemplate = onCreateTemplate
        self.onInitiateCall = onInitiateCall
        self.onScheduleCall = onScheduleCall
        self.outboundConfirmationDataProvider = outboundConfirmationDataProvider
        
        _controller = StateObject(
            wrappedValue: CallSessionController(
                language: language,
                inputSource: .microphone,
                monitorTTSOnPhone: true,
                scene: scene
            )
        )

        if let key = messagesPersistenceKey,
           let loaded = Self.loadPersistedWindow(for: key),
           !loaded.messages.isEmpty {
            let normalized = Self.normalizeMessageIDs(loaded.messages)
            _messages = State(initialValue: normalized)
            _nextMessageID = State(initialValue: Self.nextMessageIDSeed(from: normalized))
            _hasPersistedContext = State(initialValue: true)
            _hasMoreOlder = State(initialValue: loaded.hasMoreOlder)
            Self.logInitOnce(
                key: "loaded_\(key)",
                message: "[AIChat][Init] loaded persisted window key=\(key) count=\(normalized.count) hasMoreOlder=\(loaded.hasMoreOlder)"
            )
        } else if let initial = initialMessages {
            let normalized = Self.normalizeMessageIDs(initial)
            _messages = State(initialValue: normalized)
            _nextMessageID = State(initialValue: Self.nextMessageIDSeed(from: normalized))
            _hasPersistedContext = State(initialValue: false)
            Self.logInitOnce(
                key: "initial_messages",
                message: "[AIChat][Init] using initialMessages count=\(normalized.count)"
            )
        } else {
            _messages = State(initialValue: [])
            _nextMessageID = State(initialValue: 10_000)
            _hasPersistedContext = State(initialValue: false)
            if let key = messagesPersistenceKey {
                Self.logInitOnce(
                    key: "no_persisted_\(key)",
                    message: "[AIChat][Init] no persisted messages key=\(key), start with empty"
                )
            } else {
                Self.logInitOnce(
                    key: "no_persistence_key",
                    message: "[AIChat][Init] no persistence key, start with empty"
                )
            }
        }
    }
    
    @ViewBuilder
    private var bodyCore: some View {
        if inlineMessagesMode {
            messageListInline
        } else {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Color.clear
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ScreenFramePreferenceKey.self, value: g.frame(in: .global))
                        })
                    Group {
                        if isEmbedded {
                            if shouldShowAvatarChatBackground {
                                ZStack(alignment: .bottom) {
                                    messageList
                                    inputBar(screenFrameInGlobal: screenFrameInGlobal)
                                        .opacity(isRecording ? 0 : 1)
                                }
                            } else {
                                mainContent(screenFrameInGlobal: screenFrameInGlobal)
                            }
                        } else {
                            navigationContainer(screenFrameInGlobal: screenFrameInGlobal)
                        }
                    }
                    if shouldShowLocalRecordingOverlay {
                        VoiceRecordingOverlay(language: language, isCancelling: isVoiceCancelling)
                            .transition(.identity)
                    }
                }
                .onPreferenceChange(ScreenFramePreferenceKey.self) { screenFrameInGlobal = $0 }
            }
        }
    }

    var body: some View {
        bodyCore
            .overlay {
                if let toast = controller.toastMessage {
                    Text(toast)
                        .font(DS.Typography.body)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(AppSpacing.md)
                        .frame(maxWidth: 280)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                        .transition(.opacity)
                }
            }
            .onAppear {
            controller.latencyManualSceneLog(
                "view_on_appear",
                extra: "view=FeedbackChatModalView autoPlayIntro=\(autoPlayIntro) existingMessages=\(messages.count)"
            )
            let startInitMessages = sessionInitMessages()
            print("[AIChat][Start] hasPersistedContext=\(hasPersistedContext) currentUIMessageCount=\(messages.count) startInitCount=\(startInitMessages?.count ?? 0) autoPlayIntro=\(autoPlayIntro)")
            print("[AIChat][Start] startInitPreview=\(debugInitMessagesPreview(startInitMessages))")
            controller.start(
                initMessages: startInitMessages,
                evaluationChatHistory: evaluationChatHistoryOverride,
                autoPlayIntro: autoPlayIntro
            )
            if showInitialMessage && messages.isEmpty {
                let initialText = t("你好，我是你的 AI分身。你可以直接告诉我需要查询的数据，或者想调整的接听策略。",
                                    "Hi, I am your AI Private Secretary. Ask me anything or adjust settings.")
                messages.append(ExtendedMessage(id: allocateMessageID(), sender: .ai, text: initialText, msgType: .text))
            }
            }
            .onDisappear {
            persistDebounceTask?.cancel()
            persistDebounceTask = nil
            if isRecording {
                endVoiceMessage()
            }
            controller.end()
            }
            .onChange(of: isSoundEnabled?.wrappedValue) { _, newValue in
                if let enabled = newValue {
                    controller.monitorTTSOnPhone = enabled
                    if !enabled {
                        controller.audio.stopPlayback()
                    }
                }
            }
            .onChange(of: controller.messages.count) { _, newCount in
            wsMessageIndex = min(wsMessageIndex, newCount)
            var addedUserMessage = false
            while wsMessageIndex < newCount {
                let msg = controller.messages[wsMessageIndex]
                let sender: ChatSender = msg.isAI ? .ai : .user
                if msg.isAI,
                   let lastIndex = messages.indices.last,
                   messages[lastIndex].sender == .ai,
                   messages[lastIndex].msgType == .text {
                    messages[lastIndex].text += "\n" + msg.text
                } else {
                    messages.append(ExtendedMessage(id: allocateMessageID(), sender: sender, text: msg.text, msgType: .text))
                    if sender == .user { addedUserMessage = true }
                }
                wsMessageIndex += 1
            }
            if addedUserMessage {
                shouldAutoFollowCurrentTurn = isNearBottom
                controller.ttsStreamingState.startLoading()
            }
            if newCount > 0 { onMessagesChanged?() }
            }
            .onChange(of: controller.pendingRuleChange?.id) { _, newValue in
            guard let change = controller.pendingRuleChange, let id = newValue else { return }
            guard !shownProposalIds.contains(id) else { return }
            shownProposalIds.insert(id)
            let title = change.updatedRules.first?.type ?? t("规则修改", "Rule Change")
            let resolvedRules = resolveProposalRules(for: change)
            let proposal = ExtendedMessage(
                id: allocateMessageID(),
                sender: .ai,
                text: "",
                msgType: .proposal,
                proposalData: ProposalData(
                    title: title,
                    before: resolvedRules.before,
                    after: resolvedRules.after
                ),
                proposalStatus: .pending,
                proposalCreatedAt: Date()
            )
            messages.append(proposal)
            onMessagesChanged?()
            }
            .onChange(of: controller.pendingCreateTemplate?.id) { _, _ in
            guard let req = controller.pendingCreateTemplate else { return }
            guard !shownProposalIds.contains("tpl_\(req.id)") else { return }
            shownProposalIds.insert("tpl_\(req.id)")
            print("[OutboundAI][UI] pendingCreateTemplate observed callId=\(req.id) name=\(req.name) contentLen=\(req.content.count) hasHandler=\(onCreateTemplate != nil)")
            // v1 §3.5: silent overwrite via OutboundTemplateStore — succeeds regardless
            // of whether the host view supplied an `onCreateTemplate` callback (the
            // callback is now a side-effect hook, e.g. AISecView's identity-default
            // sniffing). Response payload follows spec: `{ success, name, updated_at }`.
            let saveResult = OutboundTemplateStore.save(name: req.name, content: req.content)
            if saveResult.success {
                onCreateTemplate?(req.name, req.content) { _ in /* legacy ack ignored */ }
                controller.ws.sendToolResponse(callId: req.id, result: [
                    "success": true,
                    "name": req.name,
                    "updated_at": saveResult.updatedAt
                ])
            } else {
                controller.ws.sendToolResponse(callId: req.id, result: nil, error: "模板创建失败")
            }
            controller.pendingCreateTemplate = nil
            }
            .onChange(of: controller.pendingInitiateCall?.id) { _, _ in
            guard let req = controller.pendingInitiateCall else { return }
            guard !shownProposalIds.contains("call_\(req.id)") else { return }
            shownProposalIds.insert("call_\(req.id)")
            if onInitiateCall == nil {
                controller.ws.sendToolResponse(callId: req.id, result: nil, error: "不支持发起外呼")
                controller.pendingInitiateCall = nil
            } else {
                appendOutboundConfirmationMessage(
                    OutboundCallConfirmRequest(
                        phone: req.phone,
                        templateName: req.templateName,
                        scheduledAt: nil,
                        timeDescription: nil,
                        respond: { confirmed, rejectionReason, wasUserCancel in
                            // v1 §3.6:
                            //   confirm OK   → result {success:true, action:"dialing"}
                            //   user cancel  → result {success:false, action:"cancelled", reason:"user_cancelled"}
                            //   host failure → error text
                            if confirmed {
                                self.controller.ws.sendToolResponse(callId: req.id, result: [
                                    "success": true,
                                    "action": "dialing"
                                ])
                            } else if wasUserCancel {
                                self.controller.ws.sendToolResponse(callId: req.id, result: [
                                    "success": false,
                                    "action": "cancelled",
                                    "reason": "user_cancelled"
                                ])
                            } else {
                                self.controller.ws.sendToolResponse(
                                    callId: req.id,
                                    result: nil,
                                    error: rejectionReason ?? "外呼失败"
                                )
                            }
                            self.controller.pendingInitiateCall = nil
                        }
                    )
                )
            }
            }
            .onChange(of: controller.pendingScheduleCall?.id) { _, _ in
            guard let req = controller.pendingScheduleCall else { return }
            guard !shownProposalIds.contains("sched_\(req.id)") else { return }
            shownProposalIds.insert("sched_\(req.id)")
            if onScheduleCall == nil {
                controller.ws.sendToolResponse(callId: req.id, result: nil, error: "不支持定时外呼")
                controller.pendingScheduleCall = nil
            } else {
                let scheduledAt = req.scheduledAt
                appendOutboundConfirmationMessage(
                    OutboundCallConfirmRequest(
                        phone: req.phone,
                        templateName: req.templateName,
                        scheduledAt: scheduledAt,
                        timeDescription: req.timeDescription,
                        respond: { confirmed, rejectionReason, wasUserCancel in
                            // v1 §3.7:
                            //   confirm OK   → result {success:true, scheduled_at:<ISO>}
                            //   user cancel  → result {success:false, action:"cancelled", reason:"user_cancelled"}
                            //   host failure → error text
                            if confirmed {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime]
                                self.controller.ws.sendToolResponse(callId: req.id, result: [
                                    "success": true,
                                    "scheduled_at": formatter.string(from: scheduledAt)
                                ])
                            } else if wasUserCancel {
                                self.controller.ws.sendToolResponse(callId: req.id, result: [
                                    "success": false,
                                    "action": "cancelled",
                                    "reason": "user_cancelled"
                                ])
                            } else {
                                self.controller.ws.sendToolResponse(
                                    callId: req.id,
                                    result: nil,
                                    error: rejectionReason ?? "定时外呼失败"
                                )
                            }
                            self.controller.pendingScheduleCall = nil
                        }
                    )
                )
            }
            }
            .onChange(of: controller.pendingGuideImage?.id) { _, newId in
            guard let req = controller.pendingGuideImage, newId != nil else { return }
            guard !shownGuideImageCallIds.contains(req.id) else {
                controller.clearPendingGuideImage()
                return
            }
            shownGuideImageCallIds.insert(req.id)
            let data = GuideImageData(imageId: req.imageId, caption: req.caption)
            messages.append(ExtendedMessage(
                id: allocateMessageID(),
                sender: .ai,
                text: "",
                msgType: .guideImage,
                guideImageData: data
            ))
            controller.clearPendingGuideImage()
            onMessagesChanged?()
            }
            .onChange(of: messages) { _, _ in
            scheduleDebouncedPersistAndReconnect()
            }
            // voiceControl bridge: respond to begin/end signals from the sticky input bar.
            // 不再用 `if isRecording` 守卫——ChatComposerBar 通过 Binding 同步写 UI 状态，
            // 父侧守卫会和 SwiftUI 的 .onChange 顺序抢跑，导致 end 被丢（蓝色半圆卡死）。
            // 改由 `beginVoiceMessage` / `endVoiceMessage` 内部用 `recordStartAt` 做幂等。
            .onChange(of: voiceControl?.beginCount) { _, _ in
                beginVoiceMessage()
            }
            .onChange(of: voiceControl?.endCount) { _, _ in
                endVoiceMessage()
            }
            .onChange(of: voiceControl?.cancelCount) { _, _ in
                endVoiceMessage(cancelled: true)
            }
            .onChange(of: voiceControl?.sendTextCount) { _, _ in
            let text = voiceControl?.pendingText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            sendTextMessage(text)
            voiceControl?.pendingText = ""
            }
            .onChange(of: controller.toastMessage) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    controller.toastMessage = nil
                }
            }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { tick in
            now = tick
            }
    }

    private func navigationContainer(screenFrameInGlobal: CGRect) -> some View {
        NavigationStack {
            mainContent(screenFrameInGlobal: screenFrameInGlobal)
        }
        .background(AppColors.backgroundSecondary)
        .navigationTitle(t("AI分身", "AI Private Secretary"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(DS.Typography.body)
                    }
                }
            }
        }
        .edgeSwipeBack(
            enabled: showCloseButton,
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: onClose
        )
    }

    private func mainContent(screenFrameInGlobal: CGRect) -> some View {
        VStack(spacing: 0) {
            messageList
            inputBar(screenFrameInGlobal: screenFrameInGlobal)
        }
    }

    /// Inline variant: plain LazyVStack with no inner ScrollView and no input bar.
    /// Used when the parent ScrollView handles scrolling and owns the sticky input bar.
    private var messageListInline: some View {
        LazyVStack(alignment: .leading, spacing: DS.Spacing.x2) {
            ForEach(messages) { msg in
                messageView(for: msg)
            }
            if shouldShowAvatarChatBackground {
                HStack {
                    StreamingTextBubble(
                        state: controller.ttsStreamingState,
                        uiFont: .systemFont(ofSize: 17),
                        textColor: AppColors.textPrimary,
                        bubbleColor: Color.white.opacity(0.82),
                        cornerRadius: 18,
                        borderColor: .clear,
                        borderWidth: 0,
                        horizontalPadding: 14,
                        verticalPadding: 10,
                        useGlassMaterial: true,
                        lineSpacing: 6,
                        enableLongPressCopy: true
                    )
                    Spacer(minLength: UIScreen.main.bounds.width * 0.2)
                }
                .id("feedback-streaming")
            } else {
                StreamingTextBubble(state: controller.ttsStreamingState, enableLongPressCopy: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("feedback-streaming")
            }
            if isSending {
                HStack(spacing: DS.Spacing.x1) {
                    ProgressView()
                    Text(t("正在回复...", "Replying..."))
                        .font(DS.Typography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(DS.Spacing.x2)
                .dsCardStyle()
            }
        }
        .padding(.horizontal, DS.Spacing.x2)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(hex: "E5EEFF").opacity(0.55))
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messagesPersistenceKey != nil, hasMoreOlder {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                loadOlderIfNeeded(proxy: proxy)
                            }
                    }
                    ForEach(messages) { msg in
                        messageView(for: msg)
                    }
                    FeedbackStreamingBubble(
                        state: controller.ttsStreamingState,
                        proxy: proxy,
                        useAvatarStyle: shouldShowAvatarChatBackground,
                        isNearBottom: isNearBottom && shouldAutoFollowCurrentTurn,
                        enableLongPressCopy: true
                    )
                    if isSending {
                        HStack(spacing: DS.Spacing.x1) {
                            ProgressView()
                            Text(t("正在回复...", "Replying..."))
                                .font(DS.Typography.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .padding(DS.Spacing.x2)
                        .dsCardStyle()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom-anchor")
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: FeedbackBottomVisibleKey.self,
                                    value: geo.frame(in: .named("feedbackScroll")).minY
                                )
                            }
                        )
                }
                .padding(.horizontal, shouldShowAvatarChatBackground ? 20 : DS.Spacing.x2)
                .padding(.top, shouldShowAvatarChatBackground ? 16 : 8)
                .padding(.bottom, shouldShowAvatarChatBackground ? (shouldShowAvatarQuickActions ? 146 : 98) : DS.Spacing.x6 * 2)
                .onPreferenceChange(FeedbackBottomVisibleKey.self) { minY in
                    isNearBottom = minY < UIScreen.main.bounds.height + 150
                }
            }
            .coordinateSpace(name: "feedbackScroll")
            .background(chatBackgroundView)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowAvatarChatBackground {
                    Color.clear.frame(height: shouldShowAvatarQuickActions ? 128 : 72)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            )
            .onAppear {
                scrollToLatestMessage(using: proxy, animated: false)
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                let isCard = last.msgType == .proposal
                    || last.msgType == .guideImage
                    || last.msgType == .outboundConfirmation
                if isCard || shouldAutoFollowCurrentTurn {
                    scrollToLatestMessage(using: proxy, animated: true)
                }
            }
        }
    }
    
    @ViewBuilder
    private var chatBackgroundView: some View {
        if shouldShowAvatarChatBackground {
            Color.clear
        } else {
            AppColors.backgroundSecondary
        }
    }

    private func scrollToLatestMessage(using proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else { return }
        let action = {
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(AppAnimations.easeOut, action)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                action()
            }
        }
    }
    
    // MARK: - 消息视图
    
    @ViewBuilder
    private func messageView(for msg: ExtendedMessage) -> some View {
        Group {
            switch msg.msgType {
            case .text:
                textMessageView(msg)
            case .proposal:
                proposalMessageView(msg)
            case .successAction:
                successActionView(msg)
            case .guideImage:
                guideImageMessageView(msg)
            case .outboundConfirmation:
                outboundConfirmationMessageView(msg)
            }
        }
        .id(msg.id)
    }
    
    private func textMessageView(_ msg: ExtendedMessage) -> some View {
        let isUser = msg.sender == .user
        let bubbleShape = isUser
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18)
            : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4, bottomTrailingRadius: 18, topTrailingRadius: 18)
        let isMultiLine = !isUser && isTextMultiLine(msg.text, font: .systemFont(ofSize: 17), maxWidthFraction: 0.8)

        return HStack {
            if isUser { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }
            Text(msg.text)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(isUser ? .white : AppColors.textPrimary)
                .frame(maxWidth: isMultiLine ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isUser {
                        bubbleShape.fill(Color(hex: "007AFF"))
                    } else if shouldShowAvatarChatBackground {
                        bubbleShape
                            .fill(.ultraThinMaterial)
                            .overlay {
                                bubbleShape.fill(Color.white.opacity(0.82))
                            }
                            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                            .overlay {
                                bubbleShape.stroke(Color.white.opacity(0.7), lineWidth: 0.5)
                            }
                    } else {
                        bubbleShape.fill(AppColors.surface)
                            .overlay {
                                bubbleShape.stroke(AppColors.border, lineWidth: 1)
                            }
                    }
                }
                .clipShape(bubbleShape)
            if !isUser { Spacer(minLength: UIScreen.main.bounds.width * 0.2) }
        }
        .modifier(ChatBubbleLongPressCopy(text: msg.text))
    }

    private func isTextMultiLine(_ text: String, font: UIFont, maxWidthFraction: CGFloat) -> Bool {
        if text.contains("\n") { return true }
        let screenWidth = UIScreen.main.bounds.width
        let availableWidth = (screenWidth - 40) * maxWidthFraction - 28
        let attrStr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrStr)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return textWidth > availableWidth
    }
    
    private func proposalMessageView(_ msg: ExtendedMessage) -> some View {
        let status = proposalDisplayStatus(for: msg)
        return VStack(alignment: .leading, spacing: 0) {
            if let proposal = msg.proposalData {
                ProposalGlassCard(
                    proposal: proposal,
                    status: status,
                    failureMessage: msg.proposalFailureMessage,
                    language: language,
                    onConfirm: { handleConfirmProposal(msgId: msg.id) },
                    onCancel: { handleCancelProposal(msgId: msg.id) },
                    onRetry: { handleRetryProposal(msgId: msg.id) }
                )
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func guideImageMessageView(_ msg: ExtendedMessage) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x1) {
            if let data = msg.guideImageData {
                VStack(alignment: .leading, spacing: DS.Spacing.x2) {
                    GuideImageCardContent(imageId: data.imageId, caption: data.caption, language: language)
                }
                .padding(DS.Spacing.x2)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(AppColors.border, lineWidth: 1))
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outboundConfirmationMessageView(_ msg: ExtendedMessage) -> some View {
        let status = proposalDisplayStatus(for: msg)
        return VStack(alignment: .leading, spacing: 0) {
            if let data = msg.outboundConfirmationData {
                InlineOutboundConfirmationCard(
                    data: data,
                    status: status,
                    failureMessage: msg.proposalFailureMessage,
                    language: language,
                    onConfirm: { handleConfirmOutbound(msgId: msg.id) },
                    onCancel: { handleCancelOutbound(msgId: msg.id) }
                )
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func successActionView(_ msg: ExtendedMessage) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            // 成功消息
            HStack(spacing: DS.Spacing.x1) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(msg.text)
                    .font(DS.Typography.body)
            }
            .padding(DS.Spacing.x2)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(AppColors.border, lineWidth: 1))
            .modifier(ChatBubbleLongPressCopy(text: msg.text))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - 输入栏
    
    private func inputBar(screenFrameInGlobal: CGRect) -> some View {
        VStack(spacing: 10) {
            if shouldShowAvatarQuickActions {
                avatarQuickActionsRow
            }

            ChatComposerBar(
                language: language,
                isRecording: $isRecording,
                onVoiceStart: {
                    beginVoiceMessage()
                },
                onVoiceSend: {
                    endVoiceMessage()
                },
                onVoiceCancel: {
                    endVoiceMessage(cancelled: true)
                },
                onSendText: { text in
                    sendTextMessage(text)
                },
                onVoiceCancelStateChanged: { next in
                    isVoiceCancelling = next
                },
                screenFrameForSemicircleCancel: screenFrameInGlobal.width > 0 && screenFrameInGlobal.height > 0 ? screenFrameInGlobal : nil,
                useGlassContainer: isEmbedded && shouldShowAvatarChatBackground
            )
        }
    }

    private var avatarQuickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(avatarQuickActions) { action in
                    avatarQuickActionChip(action)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
        }
    }

    private func avatarQuickActionChip(_ action: AvatarQuickAction) -> some View {
        Button {
            sendTextMessage(action.prompt)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(lightHex: "374151", darkHex: "D1D5DB"))
                Text(action.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(lightHex: "1F2937", darkHex: "D1D5DB"))
                    .lineLimit(1)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .background(avatarQuickActionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.82), lineWidth: 0.5)
            )
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.white.opacity(0.9), location: 0.28),
                        .init(color: .white, location: 0.5),
                        .init(color: Color.white.opacity(0.9), location: 0.72),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.5)
                .padding(.horizontal, 14)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var avatarQuickActionBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.68), Color.white.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: Color(hex: "59678C").opacity(0.06), radius: 10, y: 4)
    }
    
    // MARK: - 消息处理
    
    private func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        controller.sendListenText(text)
    }

    private func sessionInitMessages() -> [[String: String]]? {
        let fromMemory: [[String: String]]? = {
            let context = messages
                .filter { $0.msgType == .text }
                .compactMap { msg -> [String: String]? in
                    let content = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { return nil }
                    switch msg.sender {
                    case .user:
                        return ["role": "user", "content": content]
                    case .ai:
                        return ["role": "assistant", "content": content]
                    default:
                        return nil
                    }
                }
                .suffix(8)
            let arr = Array(context)
            return arr.isEmpty ? nil : arr
        }()

        let payload: [[String: String]]?
        if let key = messagesPersistenceKey {
            let ctx = CallMateApp.sharedModelContainer.mainContext
            if let dbPayload = try? AIChatHistoryService.recentTextInitPayload(threadKey: key, limit: 8, context: ctx),
               !dbPayload.isEmpty {
                payload = dbPayload
            } else {
                payload = fromMemory
            }
        } else {
            payload = fromMemory
        }

        guard let payload, !payload.isEmpty else {
            if let override = initMessagesOverride, !override.isEmpty {
                print("[AIChat][Context] using initMessagesOverride as base count=\(override.count)")
                return override
            }
            print("[AIChat][Context] current messages resolved empty, no override")
            return nil
        }

        if let override = initMessagesOverride, !override.isEmpty {
            if payload.count <= override.count {
                print("[AIChat][Context] using initMessagesOverride as base count=\(override.count)")
                return override
            }
            let extra = Array(payload.dropFirst(override.count))
            let merged = override + extra
            print("[AIChat][Context] merged override(\(override.count)) + extra(\(extra.count)) = \(merged.count)")
            return merged
        }

        print("[AIChat][Context] resolved count=\(payload.count) preview=\(debugInitMessagesPreview(payload))")
        return payload
    }

    private func debugInitMessagesPreview(_ initMessages: [[String: String]]?) -> String {
        guard let initMessages, !initMessages.isEmpty else { return "[]" }
        let parts = initMessages.enumerated().map { index, item in
            let role = item["role"] ?? "unknown"
            let content = (item["content"] ?? "").replacingOccurrences(of: "\n", with: " ")
            let short = String(content.prefix(24))
            return "#\(index){role=\(role),content=\(short)}"
        }
        return "[" + parts.joined(separator: ", ") + "]"
    }
    
    private func beginVoiceMessage() {
        if let lastStopAt, Date().timeIntervalSince(lastStopAt) < 0.15 {
            return
        }
        // 幂等：用 recordStartAt 作为"是否已按下"的唯一真源，不再依赖 UI 的 isRecording，
        // 避免 ChatComposerBar 同步改 Binding 和父侧 .onChange 之间的顺序抢跑。
        guard recordStartAt == nil else { return }
        recordStartAt = Date()
        isRecording = true
        voiceControl?.isRecording = true
        let ctrl = controller
        voiceGate.begin {
            ctrl.beginManualListen()
        }
    }

    private func endVoiceMessage(cancelled: Bool = false) {
        guard let start = recordStartAt else { return }
        let hadMeaningfulRecording = Date().timeIntervalSince(start) > 0.2
        recordStartAt = nil
        isRecording = false
        voiceControl?.isRecording = false
        if hadMeaningfulRecording {
            lastStopAt = Date()
        }
        isVoiceCancelling = false
        let ctrl = controller
        voiceGate.end(cancelled: cancelled) { wasCancelled in
            if wasCancelled {
                ctrl.cancelManualListen()
            } else {
                ctrl.endManualListen()
            }
        }
    }
    
    private func handleConfirmProposal(msgId: Int) {
        if let index = messages.firstIndex(where: { $0.id == msgId }) {
            messages[index].isConfirmed = true
            messages[index].proposalStatus = .applied
        }
        if let callId = controller.pendingRuleChange?.id {
            controller.sendToolResponse(callId: callId, operation: "confirm")
        }
    }
    
    private func handleCancelProposal(msgId: Int) {
        if let index = messages.firstIndex(where: { $0.id == msgId }) {
            messages[index].proposalStatus = .cancelled
        }
        let cancelMsg = ExtendedMessage(
            id: allocateMessageID(),
            sender: .ai,
            text: t("已取消修改。", "Cancelled."),
            msgType: .text
        )
        messages.append(cancelMsg)
        if let callId = controller.pendingRuleChange?.id {
            controller.sendToolResponse(callId: callId, operation: "cancel")
        }
    }

    private func appendOutboundConfirmationMessage(_ request: OutboundCallConfirmRequest) {
        let msgId = allocateMessageID()
        pendingOutboundConfirmations[msgId] = request
        let cardData = outboundConfirmationDataProvider?(
            request.phone,
            request.templateName,
            request.scheduledAt,
            request.timeDescription
        ) ?? OutboundConfirmationData(
            phone: request.phone,
            contactName: nil,
            goal: nil,
            keyPoints: nil,
            templateName: request.templateName,
            scheduledAt: request.scheduledAt,
            timeDescription: request.timeDescription
        )
        messages.append(
            ExtendedMessage(
                id: msgId,
                sender: .ai,
                text: "",
                msgType: .outboundConfirmation,
                outboundConfirmationData: cardData,
                proposalStatus: .pending,
                proposalCreatedAt: Date()
            )
        )
    }

    private func handleConfirmOutbound(msgId: Int) {
        guard let request = pendingOutboundConfirmations[msgId] else { return }
        if let scheduledAt = request.scheduledAt {
            onScheduleCall?(request.phone, request.templateName, scheduledAt, request.timeDescription ?? "") { confirmed, rejectionReason in
                updateOutboundConfirmationResult(
                    msgId: msgId,
                    confirmed: confirmed,
                    rejectionReason: rejectionReason
                )
                request.respond(confirmed, rejectionReason, false)
            }
        } else {
            onInitiateCall?(request.phone, request.templateName) { confirmed, rejectionReason in
                updateOutboundConfirmationResult(
                    msgId: msgId,
                    confirmed: confirmed,
                    rejectionReason: rejectionReason
                )
                request.respond(confirmed, rejectionReason, false)
            }
        }
        pendingOutboundConfirmations[msgId] = nil
    }

    private func handleCancelOutbound(msgId: Int) {
        guard let request = pendingOutboundConfirmations[msgId] else { return }
        if let index = messages.firstIndex(where: { $0.id == msgId }) {
            messages[index].proposalStatus = .cancelled
        }
        request.respond(false, language == .zh ? "用户取消了拨出" : "User cancelled", true)
        pendingOutboundConfirmations[msgId] = nil
    }

    private func updateOutboundConfirmationResult(msgId: Int, confirmed: Bool, rejectionReason: String?) {
        guard let index = messages.firstIndex(where: { $0.id == msgId }) else { return }
        if confirmed {
            messages[index].isConfirmed = true
            messages[index].proposalStatus = .applied
            messages[index].proposalFailureMessage = nil
        } else if let rejectionReason, !rejectionReason.isEmpty {
            messages[index].proposalStatus = .failed
            messages[index].proposalFailureMessage = rejectionReason
        } else {
            messages[index].proposalStatus = .cancelled
        }
    }

    private func scheduleDebouncedPersistAndReconnect() {
        guard let key = messagesPersistenceKey else {
            controller.updateReconnectInitMessages(sessionInitMessages())
            return
        }
        persistDebounceTask?.cancel()
        persistDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            var copy = messages
            do {
                try AIChatHistoryService.upsertMessages(threadKey: key, messages: &copy, context: CallMateApp.sharedModelContainer.mainContext)
                messages = copy
                Self.persistedMessagesCache.setObject(
                    PersistedMessagesBox(messages: copy),
                    forKey: key as NSString
                )
            } catch {
                print("[AIChatHistory] persist failed: \(error)")
            }
            controller.updateReconnectInitMessages(sessionInitMessages())
        }
    }

    private static func loadPersistedWindow(for key: String) -> (messages: [ExtendedMessage], hasMoreOlder: Bool)? {
        if let cached = persistedMessagesCache.object(forKey: key as NSString) {
            let msgs = cached.messages
            let hasMore = msgs.first?.storageSortIndex.map { $0 > 0 } ?? false
            let minS = msgs.first?.storageSortIndex
            let maxS = msgs.last?.storageSortIndex
            print(
                "[AIChatUI] loadPersistedWindow source=cache threadKey=\(key) count=\(msgs.count) sortIndexRange=[\(minS.map(String.init) ?? "?")..\(maxS.map(String.init) ?? "?")] hasMoreOlder=\(hasMore)"
            )
            return (msgs, hasMore)
        }
        let context = CallMateApp.sharedModelContainer.mainContext
        do {
            guard let loaded = try AIChatHistoryService.loadInitialWindow(threadKey: key, context: context),
                  !loaded.isEmpty else {
                return nil
            }
            let hasMore = loaded.first?.storageSortIndex.map { $0 > 0 } ?? false
            let minS = loaded.first?.storageSortIndex
            let maxS = loaded.last?.storageSortIndex
            print(
                "[AIChatUI] loadPersistedWindow source=swiftdata threadKey=\(key) uiWindowCount=\(loaded.count) sortIndexRange=[\(minS.map(String.init) ?? "?")..\(maxS.map(String.init) ?? "?")] hasMoreOlder=\(hasMore)"
            )
            persistedMessagesCache.setObject(
                PersistedMessagesBox(messages: loaded),
                forKey: key as NSString
            )
            return (loaded, hasMore)
        } catch {
            print("[AIChatHistory] load failed: \(error)")
            return nil
        }
    }

    private func loadOlderIfNeeded(proxy: ScrollViewProxy) {
        if let last = lastLoadOlderAt, Date().timeIntervalSince(last) < 0.35 { return }
        guard let key = messagesPersistenceKey,
              hasMoreOlder,
              !isLoadingOlder,
              let oldest = messages.first?.storageSortIndex else { return }
        isLoadingOlder = true
        lastLoadOlderAt = Date()
        let anchorId = messages.first?.id
        Task { @MainActor in
            defer { isLoadingOlder = false }
            do {
                let older = try AIChatHistoryService.fetchOlder(
                    threadKey: key,
                    cursorSortIndex: oldest,
                    pageSize: AIChatHistoryService.olderPageSize,
                    context: CallMateApp.sharedModelContainer.mainContext
                )
                guard !older.isEmpty else {
                    hasMoreOlder = false
                    print("[AIChatUI] loadOlderIfNeeded threadKey=\(key) cursor=\(oldest) returned=0 → hasMoreOlder=false")
                    return
                }
                let beforeCount = messages.count
                let oMin = older.first?.storageSortIndex
                let oMax = older.last?.storageSortIndex
                messages.insert(contentsOf: older, at: 0)
                hasMoreOlder = messages.first?.storageSortIndex.map { $0 > 0 } ?? false
                print(
                    "[AIChatUI] loadOlderIfNeeded threadKey=\(key) cursor<\(oldest) fetched=\(older.count) sortIndexRange=[\(oMin.map(String.init) ?? "?")..\(oMax.map(String.init) ?? "?")] uiCount \(beforeCount)→\(messages.count) hasMoreOlder=\(hasMoreOlder)"
                )
                if let anchorId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                    }
                }
            } catch {
                print("[AIChatHistory] fetchOlder failed: \(error)")
            }
        }
    }

    private static func logInitOnce(key: String, message: String) {
        let cacheKey = key as NSString
        guard initLogFlags.object(forKey: cacheKey) == nil else { return }
        initLogFlags.setObject(NSNumber(value: true), forKey: cacheKey)
        print(message)
    }

    private static func normalizeMessageIDs(_ messages: [ExtendedMessage]) -> [ExtendedMessage] {
        guard !messages.isEmpty else { return messages }
        var usedIDs = Set<Int>()
        var nextID = nextMessageIDSeed(from: messages)
        return messages.map { original in
            var msg = original
            let sortIdx = original.storageSortIndex
            if usedIDs.contains(msg.id) {
                msg.id = nextID
                nextID += 1
            }
            usedIDs.insert(msg.id)
            msg.storageSortIndex = sortIdx
            return msg
        }
    }

    private static func nextMessageIDSeed(from messages: [ExtendedMessage]) -> Int {
        (messages.map(\.id).max() ?? 9_999) + 1
    }

    private func allocateMessageID() -> Int {
        let id = nextMessageID
        nextMessageID += 1
        return id
    }

    private func handleRetryProposal(msgId: Int) {
        if let index = messages.firstIndex(where: { $0.id == msgId }) {
            messages[index].proposalStatus = .pending
            messages[index].proposalFailureMessage = nil
            messages[index].proposalCreatedAt = Date()
        }
        if let callId = controller.pendingRuleChange?.id {
            controller.sendToolResponse(callId: callId, operation: "confirm")
        }
    }

    private func proposalDisplayStatus(for msg: ExtendedMessage) -> ProposalCardStatus {
        if msg.proposalStatus == .failed {
            return .failed
        }
        if msg.proposalStatus == .cancelled {
            return .cancelled
        }
        if msg.proposalStatus == .applied || msg.isConfirmed {
            return .applied
        }
        if let createdAt = msg.proposalCreatedAt,
           now.timeIntervalSince(createdAt) >= 300 {
            return .expired
        }
        return .pending
    }

}

// MARK: - Proposal Glass Card (4 states)

private struct ProposalCategoryConfig {
    let displayTitle: String
    let tags: [String]
    let iconName: String
    let color: Color
}

private let proposalCategoryConfigs: [String: ProposalCategoryConfig] = [
    "快递": ProposalCategoryConfig(displayTitle: "快递服务", tags: ["快递", "驿站", "派件", "取件"], iconName: "shippingbox", color: Color(hex: "34C759")),
    "外卖": ProposalCategoryConfig(displayTitle: "外卖骑手", tags: ["外卖", "骑手"], iconName: "fork.knife", color: Color(hex: "FF9500")),
    "运营商": ProposalCategoryConfig(displayTitle: "运营商", tags: ["移动", "联通", "电信"], iconName: "wifi", color: Color(hex: "5856D6")),
    "银行": ProposalCategoryConfig(displayTitle: "银行保险", tags: ["银行", "保险", "贷款", "理财"], iconName: "building.columns", color: Color(hex: "5AC8FA")),
    "营销": ProposalCategoryConfig(displayTitle: "营销广告", tags: ["推销", "房产", "课程", "广告"], iconName: "megaphone", color: Color(hex: "A2845E")),
    "熟人": ProposalCategoryConfig(displayTitle: "熟人来电", tags: ["熟人", "朋友"], iconName: "person.2", color: Color(hex: "007AFF")),
    "未归类": ProposalCategoryConfig(displayTitle: "未归类来电", tags: ["未分类", "兜底"], iconName: "questionmark.circle", color: Color(hex: "8E8E93"))
]

private func proposalConfigFor(_ title: String) -> ProposalCategoryConfig {
    for (key, config) in proposalCategoryConfigs {
        if title.contains(key) { return config }
    }
    return ProposalCategoryConfig(displayTitle: title, tags: [], iconName: "questionmark.circle", color: Color(hex: "007AFF"))
}

private func resolveProposalRules(for change: CallSessionController.RuleChangeRequest) -> (before: String, after: String) {
    let primaryRule = change.updatedRules.first
    let title = primaryRule?.type ?? ""
    let action = primaryRule?.action.lowercased() ?? ""
    let localBefore = ProcessStrategyStore.loadRules()
        .first(where: { $0.type == title })?
        .rule
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let remoteBefore = change.originalRule.trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteAfter = (primaryRule?.rule ?? change.updatedRuleSummary).trimmingCharacters(in: .whitespacesAndNewlines)

    let before: String
    if !localBefore.isEmpty {
        before = localBefore
    } else if action == "add" || remoteBefore == "无" || remoteBefore == "无。" {
        before = ""
    } else {
        before = remoteBefore
    }

    let after = action == "delete" ? "" : remoteAfter
    return (before, after)
}

private enum PointDiffKind {
    case unchanged
    case removed
    case replaced
    case added
}

private struct DiffLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: PointDiffKind
}

private func normaliseDiffLine(_ line: String) -> String {
    var s = line.trimmingCharacters(in: .whitespaces)
    var idx = s.startIndex
    while idx < s.endIndex && s[idx].isNumber {
        idx = s.index(after: idx)
    }
    if idx > s.startIndex && idx < s.endIndex {
        let ch = s[idx]
        if ch == "\u{FF09}" || ch == ")" || ch == "\u{3001}" || ch == "." || ch == "\u{FF0E}" {
            s = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        }
    }
    return s
}

private func diffSimilarityScore(_ lhs: String, _ rhs: String) -> Double {
    let clean: (String) -> [Character] = { text in
        let punctuation = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
            .union(.symbols)
        return text.unicodeScalars
            .filter { !punctuation.contains($0) }
            .map(Character.init)
    }
    let leftChars = clean(lhs)
    let rightChars = clean(rhs)
    guard !leftChars.isEmpty, !rightChars.isEmpty else { return 0 }

    var leftCounts: [Character: Int] = [:]
    var rightCounts: [Character: Int] = [:]
    for ch in leftChars { leftCounts[ch, default: 0] += 1 }
    for ch in rightChars { rightCounts[ch, default: 0] += 1 }

    let overlap = leftCounts.reduce(into: 0) { partial, item in
        partial += min(item.value, rightCounts[item.key, default: 0])
    }
    return (2.0 * Double(overlap)) / Double(leftChars.count + rightChars.count)
}

private func computePointsDiff(oldText: String, newText: String) -> [DiffLine] {
    let parseLines: (String) -> [String] = { text in
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count == 1 {
            let parts = lines[0].components(separatedBy: "\u{FF1B}")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count > 1 { lines = parts }
        }
        return lines
    }
    let oldLines = parseLines(oldText)
    let newLines = parseLines(newText)

    let oldNorm = oldLines.map(normaliseDiffLine)
    let newNorm = newLines.map(normaliseDiffLine)

    var lcs = Array(
        repeating: Array(repeating: 0, count: newNorm.count + 1),
        count: oldNorm.count + 1
    )
    if !oldNorm.isEmpty && !newNorm.isEmpty {
        for i in stride(from: oldNorm.count - 1, through: 0, by: -1) {
            for j in stride(from: newNorm.count - 1, through: 0, by: -1) {
                if oldNorm[i] == newNorm[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
    }

    var matches: [(old: Int, new: Int)] = []
    var i = 0
    var j = 0
    while i < oldNorm.count && j < newNorm.count {
        if oldNorm[i] == newNorm[j] {
            matches.append((old: i, new: j))
            i += 1
            j += 1
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            i += 1
        } else {
            j += 1
        }
    }

    func appendSegment(
        oldRange: Range<Int>,
        newRange: Range<Int>,
        into result: inout [DiffLine]
    ) {
        let oldIndices = Array(oldRange)
        let newIndices = Array(newRange)
        var newCursor = 0

        for oldIndex in oldIndices {
            var bestMatch: Int?
            var bestScore = 0.0

            if newCursor < newIndices.count {
                for candidate in newCursor..<newIndices.count {
                    let score = diffSimilarityScore(oldNorm[oldIndex], newNorm[newIndices[candidate]])
                    if score > bestScore {
                        bestScore = score
                        bestMatch = candidate
                    }
                }
            }

            if let bestMatch, bestScore >= 0.45 {
                for pending in newCursor..<bestMatch {
                    result.append(DiffLine(text: newLines[newIndices[pending]], kind: .added))
                }
                result.append(DiffLine(text: oldLines[oldIndex], kind: .removed))
                result.append(DiffLine(text: newLines[newIndices[bestMatch]], kind: .replaced))
                newCursor = bestMatch + 1
            } else {
                result.append(DiffLine(text: oldLines[oldIndex], kind: .removed))
            }
        }

        if newCursor < newIndices.count {
            for pending in newCursor..<newIndices.count {
                result.append(DiffLine(text: newLines[newIndices[pending]], kind: .added))
            }
        }
    }

    var result: [DiffLine] = []
    var oldStart = 0
    var newStart = 0

    for match in matches {
        appendSegment(oldRange: oldStart..<match.old, newRange: newStart..<match.new, into: &result)
        result.append(DiffLine(text: newLines[match.new], kind: .unchanged))
        oldStart = match.old + 1
        newStart = match.new + 1
    }

    appendSegment(oldRange: oldStart..<oldLines.count, newRange: newStart..<newLines.count, into: &result)
    return result
}

private func parseProposalSections(_ text: String) -> (goal: String?, points: String?) {
    var goal: String?
    var points: String?
    let sectionTitles = ["处理目标", "处理要点", "处理原则", "处理策略", "处理步骤", "示例"]

    let remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)

    func findMarker(_ title: String) -> Range<String.Index>? {
        if let r = remaining.range(of: title + "：") { return r }
        if let r = remaining.range(of: title + ":") { return r }
        return nil
    }

    func extractContent(for title: String) -> String? {
        guard let range = findMarker(title) else { return nil }
        let start = range.upperBound
        var end = remaining.endIndex
        for other in sectionTitles where other != title {
            if let otherRange = findMarker(other), otherRange.lowerBound > range.lowerBound, otherRange.lowerBound < end {
                end = otherRange.lowerBound
            }
        }
        let content = String(remaining[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    goal = extractContent(for: "处理目标")
    points = extractContent(for: "处理要点") ?? extractContent(for: "处理原则") ?? extractContent(for: "处理策略") ?? extractContent(for: "处理步骤")

    if points == nil, let goalText = goal {
        let lines = goalText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let splitAt = lines.firstIndex(where: { $0.first?.isNumber == true }), lines.count > 1 {
            if splitAt == 0 {
                goal = nil
                points = lines.joined(separator: "\n")
            } else {
                goal = lines[..<splitAt].joined(separator: "\n")
                points = lines[splitAt...].joined(separator: "\n")
            }
        }
    }

    if goal == nil && points == nil {
        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return (nil, trimmed) }
    }
    return (goal, points)
}

private struct ProposalGlassCard: View {
    let proposal: ProposalData
    let status: ProposalCardStatus
    let failureMessage: String?
    let language: Language
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var config: ProposalCategoryConfig { proposalConfigFor(proposal.title) }
    private var isFailed: Bool { status == .failed }

    private var cardBgGradient: LinearGradient {
        switch status {
        case .applied:
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 220/255, green: 245/255, blue: 230/255).opacity(0.75), location: 0),
                    .init(color: Color.white.opacity(0.6), location: 0.4),
                    .init(color: Color.white.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        case .failed:
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 1, green: 235/255, blue: 235/255).opacity(0.75), location: 0),
                    .init(color: Color.white.opacity(0.6), location: 0.4),
                    .init(color: Color.white.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        default:
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 230/255, green: 240/255, blue: 1).opacity(0.75), location: 0),
                    .init(color: Color.white.opacity(0.6), location: 0.4),
                    .init(color: Color.white.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var topGradientColor: Color {
        switch status {
        case .applied: return Color(hex: "34C759")
        case .failed: return Color(hex: "FF3B30")
        default: return Color(hex: "007AFF")
        }
    }

    private var iconColor: Color {
        isFailed ? Color(hex: "FF3B30") : config.color
    }

    private var iconGradient: LinearGradient {
        let c = isFailed ? Color(hex: "FF3B30") : config.color
        return LinearGradient(
            colors: [c.opacity(0.18), c.opacity(0.12)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        ZStack(alignment: .top) {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(cardBgGradient))
                .overlay(shape.stroke(Color.white.opacity(0.5), lineWidth: 0.5))
                .shadow(color: Color.white.opacity(0.8), radius: 0, y: -0.5)
                .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                .shadow(color: Color.black.opacity(0.06), radius: 10, y: 6)

            LinearGradient(
                colors: [topGradientColor.opacity(0.06), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 80)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))

            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 0) {
                cardHeader.padding(.bottom, 18)
                cardContent
                cardFooter
            }
            .padding(18)
        }
        .clipShape(shape)
    }

    // MARK: Header
    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(iconGradient)
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                    .shadow(color: Color.white.opacity(0.7), radius: 0, y: -0.5)
                    .shadow(color: iconColor.opacity(0.18), radius: 3, y: 1)
                Image(systemName: config.iconName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                Text(config.displayTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: "1D1D1F"))
                    .tracking(-0.4)

                statusBadge
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .applied:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "34C759"))
                Text(language == .zh ? "修改已生效" : "Applied")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "34C759"))
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "FF3B30"))
                Text(language == .zh ? "修改失败" : "Failed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: "FF3B30"))
            }
        default:
            if !config.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(config.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: "3478F6"))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(hex: "007AFF").opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    // MARK: Content
    @ViewBuilder
    private var cardContent: some View {
        switch status {
        case .failed:
            failedInfoBlock
        case .applied:
            appliedContentBlock
        default:
            diffContentBlock
        }
    }

    private var failedInfoBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color(hex: "FF3B30"))
            VStack(alignment: .leading, spacing: 3) {
                Text(language == .zh ? "策略修改未能执行" : "Strategy update failed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "FF3B30"))
                Text(failureMessage ?? (language == .zh ? "网络请求超时，请检查网络后重试" : "Request timed out, please check network"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "8E8E93"))
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "FF3B30").opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "FF3B30").opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var appliedContentBlock: some View {
        let afterSections = parseProposalSections(proposal.after)
        let goal = afterSections.goal ?? ""
        let points = afterSections.points ?? ""
        let hasGoal = !goal.isEmpty
        let pointLines = points.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hasPoints = !pointLines.isEmpty
        let hasParsed = hasGoal || hasPoints
        let fallbackText = hasParsed ? "" : proposal.after.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 0) {
            if hasParsed {
                if hasGoal {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(language == .zh ? "处理目标" : "Goal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "86868B"))
                            .tracking(0.3)
                        Text(goal)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "3A3A3C"))
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if hasGoal && hasPoints {
                    Rectangle().fill(Color.black.opacity(0.05)).frame(height: 0.5).padding(.vertical, 14)
                }
                if hasPoints {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language == .zh ? "处理要点" : "Key Points")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "86868B"))
                            .tracking(0.3)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(pointLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(hex: "3A3A3C"))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else if !fallbackText.isEmpty {
                Text(fallbackText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.38))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.45), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var diffContentBlock: some View {
        let beforeSections = parseProposalSections(proposal.before)
        let afterSections = parseProposalSections(proposal.after)
        let oldGoal = (beforeSections.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newGoal = (afterSections.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGoal = !oldGoal.isEmpty || !newGoal.isEmpty
        let goalChanged = hasGoal && oldGoal != newGoal && !oldGoal.isEmpty && !newGoal.isEmpty
        let displayGoal = newGoal.isEmpty ? oldGoal : newGoal
        let oldPoints = beforeSections.points ?? ""
        let newPoints = afterSections.points ?? ""
        let hasParsedPoints = !oldPoints.isEmpty || !newPoints.isEmpty
        let beforeRaw = proposal.before.trimmingCharacters(in: .whitespacesAndNewlines)
        let diffLines: [DiffLine]
        if !hasParsedPoints {
            diffLines = []
        } else if beforeRaw.isEmpty {
            diffLines = newPoints.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { DiffLine(text: $0, kind: .added) }
        } else {
            diffLines = computePointsDiff(oldText: oldPoints, newText: newPoints)
        }
        let hasParsed = hasGoal || hasParsedPoints
        let fallbackBefore = proposal.before.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAfter = proposal.after.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 0) {
            if hasParsed {
                if hasGoal {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(language == .zh ? "处理目标" : "Goal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "86868B"))
                            .tracking(0.3)
                        if goalChanged {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(language == .zh ? "旧" : "Old")
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.3)
                                        .foregroundStyle(Color(hex: "8E8E93"))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color(hex: "8E8E93").opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(oldGoal)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(hex: "AEAEB2"))
                                        .strikethrough(color: Color(hex: "AEAEB2"))
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(alignment: .top, spacing: 6) {
                                    Text(language == .zh ? "改" : "Mod")
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.3)
                                        .foregroundStyle(Color(hex: "FF3B30"))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color(hex: "FF3B30").opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(newGoal)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(hex: "3A3A3C"))
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            Text(displayGoal)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "3A3A3C"))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if hasGoal && !diffLines.isEmpty {
                    Rectangle().fill(Color.black.opacity(0.05)).frame(height: 0.5).padding(.vertical, 14)
                }
                if !diffLines.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(language == .zh ? "处理要点" : "Key Points")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "86868B"))
                            .tracking(0.3)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(diffLines) { line in
                                diffLineRow(line)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !fallbackBefore.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text(language == .zh ? "旧" : "Old")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.3)
                                .foregroundStyle(Color(hex: "8E8E93"))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color(hex: "8E8E93").opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(fallbackBefore)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "AEAEB2"))
                                .strikethrough(color: Color(hex: "AEAEB2"))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        let isReplacement = !fallbackBefore.isEmpty
                        Text(language == .zh ? (isReplacement ? "改" : "新") : (isReplacement ? "Mod" : "New"))
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(Color(hex: "FF3B30"))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(hex: "FF3B30").opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(fallbackAfter)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "3A3A3C"))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.38))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.45), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func diffBadge(_ text: String, colorHex: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0)
            .foregroundStyle(Color(hex: colorHex))
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
        ZStack(alignment: .topLeading) {
            switch line.kind {
            case .unchanged:
                Text(line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            case .removed:
                Text(line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "AEAEB2"))
                    .strikethrough(color: Color(hex: "AEAEB2"))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                    .overlay(alignment: .topLeading) {
                        diffBadge(language == .zh ? "旧" : "Old", colorHex: "8E8E93")
                            .offset(x: -12, y: 3)
                    }
            case .replaced:
                Text(line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                    .overlay(alignment: .topLeading) {
                        diffBadge(language == .zh ? "改" : "Mod", colorHex: "FF3B30")
                            .offset(x: -12, y: 3)
                    }
            case .added:
                Text(line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                    .overlay(alignment: .topLeading) {
                        diffBadge(language == .zh ? "新" : "New", colorHex: "FF3B30")
                            .offset(x: -12, y: 3)
                    }
            }
        }
    }

    // MARK: Footer
    @ViewBuilder
    private var cardFooter: some View {
        switch status {
        case .pending:
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(language == .zh ? "取消修改" : "Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: "3A3A3C"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.white.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text(language == .zh ? "确认修改" : "Confirm")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "007AFF"), Color(hex: "5856D6")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)

        case .expired:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: "FF9500"))
                Text(language == .zh ? "修改确认已超时，本次修改自动取消" : "Confirmation timed out, change cancelled")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 142/255, green: 106/255, blue: 0))
                    .lineSpacing(4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "FF9500").opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "FF9500").opacity(0.15), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.top, 18)

        case .failed:
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(language == .zh ? "取消" : "Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: "3A3A3C"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.white.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button(action: onRetry) {
                    Text(language == .zh ? "重新修改" : "Retry")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "FF3B30"), Color(hex: "FF6961")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color(hex: "FF3B30").opacity(0.25), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)

        default:
            EmptyView()
        }
    }
}

private struct InlineOutboundConfirmationCard: View {
    let data: OutboundConfirmationData
    let status: ProposalCardStatus
    let failureMessage: String?
    let language: Language
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var isScheduled: Bool { data.scheduledAt != nil }

    private var titleText: String {
        isScheduled ? t("外呼确认", "Scheduled Call") : t("外呼确认", "Call Confirmation")
    }

    private var titleIcon: String {
        isScheduled ? "clock.badge.checkmark.fill" : "phone.arrow.up.right.fill"
    }

    private var confirmText: String {
        isScheduled ? t("确认定时", "Confirm") : t("确认拨打", "Call")
    }

    private var displayContactName: String {
        let trimmed = data.contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? data.templateName : trimmed
    }

    private var displayGoal: String {
        let trimmed = data.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? data.templateName : trimmed
    }

    private var keyPointLines: [String] {
        let raw = (data.keyPoints ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { line -> [String] in
                if line.contains("；") { return line.split(separator: "；").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } }
                return [line]
            }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•1234567890.、 ").union(.whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }

    private var statusText: String? {
        switch status {
        case .applied:
            return isScheduled ? t("已安排", "Scheduled") : t("已确认", "Confirmed")
        case .cancelled:
            return t("已取消", "Cancelled")
        case .expired:
            return t("已超时", "Expired")
        case .failed:
            return t("处理失败", "Failed")
        case .pending:
            return nil
        }
    }

    private var scheduledTimeText: String? {
        guard let scheduledAt = data.scheduledAt else { return nil }
        if let timeDescription = data.timeDescription,
           !timeDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return timeDescription
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: scheduledAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: isScheduled ? "FF9500" : "34C759").opacity(0.14))
                            .frame(width: 32, height: 32)
                        Image(systemName: titleIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: isScheduled ? "FF9500" : "34C759"))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(data.phone)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(hex: "111111"))
                        Text(displayContactName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(hex: "6E6E73"))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    confirmationSection(title: t("本次电话目标", "Call Goal")) {
                        Text(displayGoal)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: "1C1C1E"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    confirmationSection(title: t("处理要点", "Key Points")) {
                        VStack(alignment: .leading, spacing: 8) {
                            if keyPointLines.isEmpty {
                                Text(data.templateName)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color(hex: "3A3A3C"))
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(Array(keyPointLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color(hex: "3A3A3C"))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if let scheduledTimeText {
                        Divider()
                        confirmationSection(title: t("拨打时间", "Time")) {
                            Text(scheduledTimeText)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(hex: "1C1C1E"))
                        }
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.38))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.45), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let statusText {
                    HStack(spacing: 6) {
                        Image(systemName: status == .applied ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(status == .applied ? Color(hex: "34C759") : Color(hex: "8E8E93"))
                        Text(statusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: "6E6E73"))
                    }
                }

                if status == .failed, let failureMessage, !failureMessage.isEmpty {
                    Text(failureMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "C62828"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if status == .pending {
                    HStack(spacing: 10) {
                        Button(action: onCancel) {
                            Text(t("取消", "Cancel"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color(hex: "3A3A3C"))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color.white.opacity(0.5))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        Button(action: onConfirm) {
                            Text(confirmText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(
                                    LinearGradient(
                                        colors: isScheduled
                                            ? [Color(hex: "FF9500"), Color(hex: "FFB340")]
                                            : [Color(hex: "34C759"), Color(hex: "30D158")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(
                                    color: (isScheduled ? Color(hex: "FF9500") : Color(hex: "34C759")).opacity(0.22),
                                    radius: 5,
                                    y: 2
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private func confirmationRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "8E8E93"))
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: "1C1C1E"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmationSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "8E8E93"))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScreenFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - 引导图/视频卡片内容（need4：image_id → 资源，嵌入对话流；OnboardingView 复用）
struct GuideImageCardContent: View {
    let imageId: String
    let caption: String?
    let language: Language

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    /// need4：takeover_reminder=循环视频，ios_call_filter_setting=图，unknown_call_handling=图
    /// 先试 bundle 根，再试 Resources 子目录，最后试 resourcePath/Resources/ 直 path。
    private var resourceURL: (url: URL, isVideo: Bool)? {
        let bundle = Bundle.main
        switch imageId {
        case "takeover_reminder":
            var u = bundle.url(forResource: "takeover_reminder", withExtension: "mp4")
                ?? bundle.url(forResource: "takeover_reminder", withExtension: "mp4", subdirectory: "Resources")
            if u == nil, let base = bundle.resourcePath {
                let path = (base as NSString).appendingPathComponent("Resources/takeover_reminder.mp4")
                if FileManager.default.fileExists(atPath: path) { u = URL(fileURLWithPath: path) }
            }
            return u.map { (url: $0, isVideo: true) }
        case "ios_call_filter_setting":
            var u = bundle.url(forResource: "filter_call", withExtension: "jpeg")
                ?? bundle.url(forResource: "filter_call", withExtension: "jpg")
                ?? bundle.url(forResource: "filter_call", withExtension: "jpeg", subdirectory: "Resources")
                ?? bundle.url(forResource: "filter_call", withExtension: "jpg", subdirectory: "Resources")
            if u == nil, let base = bundle.resourcePath {
                for name in ["filter_call.jpeg", "filter_call.jpg"] {
                    let path = (base as NSString).appendingPathComponent("Resources/\(name)")
                    if FileManager.default.fileExists(atPath: path) { u = URL(fileURLWithPath: path); break }
                }
            }
            return u.map { (url: $0, isVideo: false) }
        case "unknown_call_handling":
            var u = bundle.url(forResource: "unknown_call", withExtension: "png")
                ?? bundle.url(forResource: "unknown_call", withExtension: "png", subdirectory: "Resources")
            if u == nil, let base = bundle.resourcePath {
                let path = (base as NSString).appendingPathComponent("Resources/unknown_call.png")
                if FileManager.default.fileExists(atPath: path) { u = URL(fileURLWithPath: path) }
            }
            return u.map { (url: $0, isVideo: false) }
        default:
            return nil
        }
    }

    /// 通过 Data 加载，避免部分 JPEG 触发 Image I/O plugin 报错 (-62)
    private static func loadImage(from url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let img = UIImage(data: data) { return img }
        return UIImage(contentsOfFile: url.path)
    }

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            if let res = resourceURL {
                if res.isVideo, let p = player {
                    VideoPlayer(player: p)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                        .onAppear { p.play() }
                } else if res.isVideo {
                    Color.gray.opacity(0.2)
                        .frame(height: 220)
                        .overlay(ProgressView())
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                        .onAppear {
                            let item = AVPlayerItem(url: res.url)
                            let queuePlayer = AVQueuePlayer(playerItem: item)
                            let loop = AVPlayerLooper(player: queuePlayer, templateItem: item)
                            player = queuePlayer
                            looper = loop
                            queuePlayer.play()
                        }
                } else {
                    let img = Self.loadImage(from: res.url)
                    if let img = img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                    } else {
                        Text(t("图片加载失败", "Image unavailable"))
                            .font(DS.Typography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(height: 100)
                    }
                }
            } else {
                Text(t("引导图", "Guide") + ": \(imageId)")
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(height: 60)
            }
            if let cap = caption, !cap.isEmpty {
                Text(cap)
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

private struct ChatBubbleLongPressCopy: ViewModifier {
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content
                .onLongPressGesture(minimumDuration: 0.45) {
                    UIPasteboard.general.string = text
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        }
    }
}

private struct FeedbackBottomVisibleKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

//
//  OnboardingView.swift
//  CallMate
//

import SwiftUI
import AVKit
import AVFoundation

// MARK: - Flow State
private enum OnboardingFlowState {
    case connecting
    case connectionFailed
    case speaking
    case waiting
    case processing
    case finished
}

private enum RuleChangeDecision {
    case confirm
    case cancel
}

struct OnboardingView: View {
    let language: Language
    let onComplete: () -> Void
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    @State private var messages: [ChatMessage] = []
    @State private var flowState: OnboardingFlowState = .connecting
    @State private var isRecording = false
    @State private var isVoiceCancelling = false
    @StateObject private var realtimeController: CallSessionController
    @State private var realtimeMessageIndex = 0
    @State private var ruleChangeDecisions: [String: RuleChangeDecision] = [:]
    @State private var ruleChanges: [String: CallSessionController.RuleChangeRequest] = [:]
    @State private var lastRuleChangeMessageId: Int?
    @State private var didShowCompletion = false
    @State private var showPostSetupReminder = false
    @State private var recordStartAt: Date?
    @State private var processingTimeoutTask: Task<Void, Never>?
    @State private var connectTimeoutTask: Task<Void, Never>?
    /// 串行化 realtimeController 的 begin/end/cancel 调用，UI 状态不等它。
    @State private var voiceGate = VoiceRecordingGate()
    @State private var hasEverConnected = false
    @State private var didInsertAuthCard = false
    @State private var screenFrameInGlobal: CGRect = .zero
    @State private var isNearBottom = true
    @State private var shouldAutoFollowCurrentTurn = true
    @State private var postSetupSheetHeight: CGFloat = 420
    @State private var showVoiceCloneSheet = false
    @State private var voiceCloneSheetDetent: PresentationDetent = .height(388)
    @State private var voiceCloneCallId = ""
    @State private var voiceCloneSpeakerId: String?

    private var progressIndex: Int {
        switch flowState {
        case .connecting, .connectionFailed:
            return 0
        case .finished:
            return 2
        default:
            return 1
        }
    }

    private var onboardingBackground: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: "F6F8FF"), location: 0),
                    .init(color: Color(hex: "F3F5FF"), location: 0.4),
                    .init(color: Color(hex: "F5F4FF"), location: 0.7),
                    .init(color: Color(hex: "F4F7FF"), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(hex: "DCE8FF").opacity(0.5), .clear],
                center: UnitPoint(x: 0.2, y: 0.1),
                startRadius: 0,
                endRadius: 400
            )
            RadialGradient(
                colors: [Color(hex: "E6E1FA").opacity(0.35), .clear],
                center: UnitPoint(x: 0.85, y: 0.6),
                startRadius: 0,
                endRadius: 350
            )
            RadialGradient(
                colors: [Color(hex: "D7E6FF").opacity(0.3), .clear],
                center: UnitPoint(x: 0.4, y: 0.9),
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
    
    init(language: Language, onComplete: @escaping () -> Void) {
        self.language = language
        self.onComplete = onComplete
        _realtimeController = StateObject(
            wrappedValue: CallSessionController(
                language: language,
                inputSource: .microphone,
                monitorTTSOnPhone: true,
                scene: .initConfig
            )
        )
    }

    var body: some View {
        NavigationStack {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.clear
                    .background(GeometryReader { g in
                        Color.clear.preference(key: OnboardingScreenFramePreferenceKey.self, value: g.frame(in: .global))
                    })
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                ScrollView {
                    if flowState == .connecting {
                        connectingView
                    } else if flowState == .connectionFailed {
                        connectionFailedView
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages, id: \.id) { msg in
                                if msg.sender == .system, let imageId = guideImageId(from: msg.text) {
                                    guideImageCard(imageId: imageId)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                } else if msg.sender == .system, let info = guideCardInfo(from: msg.text) {
                                    guideCardView(cardId: info.cardId, callId: info.callId)
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.95)),
                                            removal: .opacity
                                        ))
                                } else if msg.sender == .system, let ruleId = ruleChangeId(from: msg.text) {
                                    if let change = ruleChanges[ruleId] {
                                        ruleChangeCard(change)
                                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    }
                                } else if msg.sender == .system, msg.text == "__auth_request__" {
                                    AuthorizationRequestCard(
                                        language: language,
                                        onAccept: { sendAuthorizationAcceptedText() },
                                        onReject: { enterFinishedStateIfNeeded() }
                                    )
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.95)),
                                        removal: .opacity
                                    ))
                                } else if msg.sender == .system {
                                    strategyCard(from: msg.text)
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.95)),
                                            removal: .opacity
                                        ))
                                } else {
                                    messageBubble(msg)
                                }
                            }
                            OnboardingStreamingBubble(
                                state: realtimeController.ttsStreamingState,
                                proxy: proxy,
                                isNearBottom: isNearBottom,
                                shouldAutoFollow: shouldAutoFollowCurrentTurn
                            )
                            Color.clear.frame(height: 20)
                                .id("chat-bottom-anchor")
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: OnboardingBottomVisibleKey.self,
                                            value: geo.frame(in: .named("onboardingScroll")).minY
                                        )
                                    }
                                )
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                        .onPreferenceChange(OnboardingBottomVisibleKey.self) { minY in
                            let newNearBottom = minY < UIScreen.main.bounds.height + 150
                            isNearBottom = newNearBottom
                            if !newNearBottom {
                                shouldAutoFollowCurrentTurn = false
                            }
                        }
                    }
                }
                .coordinateSpace(name: "onboardingScroll")
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: flowState == .finished ? 240 : 72)
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
                    scrollToLatestOnboardingMessage(using: proxy, animated: false)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToLatestOnboardingMessage(using: proxy, animated: true)
                }
                .onChange(of: lastRuleChangeMessageId) { _, newValue in
                    guard let id = newValue else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                .onChange(of: flowState) { _, newState in
                    if newState == .finished {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            scrollToLatestOnboardingMessage(using: proxy, animated: true)
                        }
                    }
                }
            }
            bottomControls(screenFrameInGlobal: screenFrameInGlobal)
                .opacity(isRecording ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background(onboardingBackground)

        if isRecording {
            VoiceRecordingOverlay(language: language, isCancelling: isVoiceCancelling)
        }
            } // ZStack
            .onPreferenceChange(OnboardingScreenFramePreferenceKey.self) { screenFrameInGlobal = $0 }
        }
        .background(Color.clear)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(t("AI 配置向导", "AI Setup Wizard"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(t("内容由 AI 生成", "Content generated by AI"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onComplete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        .background(Color.clear)
                }
                .buttonStyle(.borderless)
            }
        }
        .toolbar(isRecording ? .hidden : .visible, for: .navigationBar)
        } // NavigationStack
        .background {
            onboardingBackground.ignoresSafeArea()
        }
        .onAppear {
            Task { await fetchVoiceCloneSpeakerId() }
            let onboardingInitMessages: [[String: String]] = [
                ["role": "user", "content": t("你好", "Hello")],
                [
                    "role": "assistant",
                    "content": t(
                        "你好！我是你的实习AI分身，可以帮你处理来电。在开始前，我需要你的授权。",
                        "Hi! I'm your trainee AI assistant. I can help the owner handle incoming calls. Before we begin, I need your authorization."
                    )
                ]
            ]
            let useDebugPrompt = realtimeController.ws.isInitConfigSendPromptEnabled()
            let initMessages: [[String: String]]? = useDebugPrompt ? nil : onboardingInitMessages
            realtimeController.latencyManualSceneLog(
                "view_on_appear",
                extra: "view=OnboardingView autoPlayIntro=true initConfigDebugPrompt=\(useDebugPrompt) initMessageCount=\(initMessages?.count ?? 0)"
            )
            realtimeController.start(
                initMessages: initMessages,
                autoPlayIntro: true
            )
            startConnectTimeout()
        }
        .onDisappear {
            realtimeController.end()
            isRecording = false
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
        }
        .onChange(of: realtimeController.messages.count) { _, newCount in
            // The controller can clear its message buffer when a session restarts.
            // Clamp cursor so new messages still flow into onboarding bubbles.
            realtimeMessageIndex = min(realtimeMessageIndex, newCount)
            var addedUserMessage = false
            while realtimeMessageIndex < newCount {
                let msg = realtimeController.messages[realtimeMessageIndex]
                let sender: ChatSender = msg.isAI ? .ai : .user
                messages.append(ChatMessage(id: Int.random(in: 10000...99999), sender: sender, text: msg.text, isAudio: true, duration: 3))
                if sender == .user { addedUserMessage = true }
                if msg.isAI, flowState != .finished {
                    processingTimeoutTask?.cancel()
                    processingTimeoutTask = nil
                    flowState = .waiting
                }
                realtimeMessageIndex += 1
            }
            if addedUserMessage {
                shouldAutoFollowCurrentTurn = true
                realtimeController.ttsStreamingState.startLoading()
            }
        }
        .onChange(of: realtimeController.pendingGuideImage?.id) { _, newValue in
            guard let req = realtimeController.pendingGuideImage, newValue != nil else { return }
            messages.append(ChatMessage(
                id: Int.random(in: 10000...99999),
                sender: .system,
                text: guideImageToken(req.imageId),
                isAudio: false,
                duration: 0
            ))
            realtimeController.clearPendingGuideImage()
        }
        .onChange(of: realtimeController.pendingGuideCard?.id) { _, newValue in
            guard let req = realtimeController.pendingGuideCard, newValue != nil else { return }
            realtimeController.pendingGuideCard = nil
            if req.cardId == "clone_start_reading" {
                // 声音录制是几乎全屏的弹窗，不插入内联卡片
                voiceCloneCallId = req.id
                showVoiceCloneSheet = true
            } else {
                // 其他卡片（如 clone_authorization）以内联卡片形式显示
                messages.append(ChatMessage(
                    id: Int.random(in: 10000...99999),
                    sender: .system,
                    text: guideCardToken(req.cardId, callId: req.id),
                    isAudio: false,
                    duration: 0
                ))
            }
        }
        .sheet(isPresented: $showVoiceCloneSheet) {
            VoiceCloneReaderSheet(
                language: language,
                speakerId: voiceCloneSpeakerId,
                onCloneSuccess: {
                    realtimeController.respondToGuideCard(callId: voiceCloneCallId, accepted: true)
                },
                onRecordingChanged: { recording in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        voiceCloneSheetDetent = recording ? .height(580) : .height(388)
                    }
                }
            )
            .presentationBackground(.ultraThinMaterial)
            .presentationDetents([.height(388), .height(580)], selection: $voiceCloneSheetDetent)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: showVoiceCloneSheet) { _, show in
            if show { voiceCloneSheetDetent = .height(388) }
        }
        .onChange(of: realtimeController.pendingRuleChange?.id) { _, newValue in
            guard let id = newValue, let change = realtimeController.pendingRuleChange else { return }
            if ruleChanges[id] == nil {
                ruleChanges[id] = change
                let msgId = Int.random(in: 10000...99999)
                messages.append(ChatMessage(id: msgId, sender: .system, text: ruleChangeToken(id)))
                lastRuleChangeMessageId = msgId
                if ruleChangeDecisions[id] == nil {
                    ruleChangeDecisions[id] = .confirm
                    realtimeController.sendToolResponse(callId: change.id, operation: "confirm")
                }
            } else {
                ruleChanges[id] = change
            }
        }
        .onChange(of: realtimeController.ttsStopCount) { _, count in
            guard count == 1, !didInsertAuthCard else { return }
            didInsertAuthCard = true
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                messages.append(ChatMessage(id: Int.random(in: 10000...99999), sender: .system, text: "__auth_request__", isAudio: false, duration: 0))
            }
        }
        .onChange(of: realtimeController.status) { _, newStatus in
            if newStatus == .connected, flowState != .finished, !isRecording {
                hasEverConnected = true
                connectTimeoutTask?.cancel()
                connectTimeoutTask = nil
                flowState = .waiting
                // 与 AI 分身一致：进入聊天后、首条 AI TTS 到来前显示三点 loading
                realtimeController.ttsStreamingState.startLoading()
            } else if newStatus == .ended {
                if hasEverConnected {
                    enterFinishedStateIfNeeded()
                } else {
                    connectTimeoutTask?.cancel()
                    connectTimeoutTask = nil
                    flowState = .connectionFailed
                }
            }
        }
        .sheet(isPresented: $showPostSetupReminder) {
            PostSetupReminderSheet(language: language) { measuredHeight in
                postSetupSheetHeight = measuredHeight
            } onStartNow: {
                showPostSetupReminder = false
                onComplete()
            }
            .presentationDetents([.height(max(320, postSetupSheetHeight))])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
            .interactiveDismissDisabled(true)
        }
    }
    
    // header is now provided by NavigationStack toolbar (matching AISecView style)
    
    private func messageBubble(_ msg: ChatMessage) -> some View {
        MessageBubbleContent(msg: msg, language: language)
    }

    private func scrollToLatestOnboardingMessage(using proxy: ScrollViewProxy, animated: Bool) {
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
    
    private func strategyCard(from jsonText: String) -> some View {
        guard let data = jsonText.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let trigger = dict["trigger"], let action = dict["action"] else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(alignment: .top, spacing: 0) {
                StrategyCardContent(trigger: trigger, action: action, language: language)
                Spacer(minLength: UIScreen.main.bounds.width * 0.2)
            }
        )
    }
    
    private func bottomControls(screenFrameInGlobal: CGRect) -> some View {
        OnboardingBottomControls(
            flowState: flowState,
            isRecording: $isRecording,
            isVoiceCancelling: $isVoiceCancelling,
            language: language,
            hideFinishedContent: showPostSetupReminder,
            onComplete: onComplete,
            onRecordStart: beginVoiceMessage,
            onRecordEnd: endVoiceMessage,
            onRecordCancel: cancelVoiceMessage,
            onSendText: sendTextMessage,
            screenFrameForSemicircleCancel: screenFrameInGlobal.width > 0 && screenFrameInGlobal.height > 0 ? screenFrameInGlobal : nil
        )
    }

    private func ruleChangeToken(_ id: String) -> String {
        "__rule_change__:\(id)"
    }

    private func guideImageToken(_ imageId: String) -> String {
        "__guide_image__:\(imageId)"
    }

    private func guideImageId(from text: String) -> String? {
        let prefix = "__guide_image__:"
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    private func guideCardToken(_ cardId: String, callId: String) -> String {
        "__guide_card__:\(cardId):\(callId)"
    }

    private func guideCardInfo(from text: String) -> (cardId: String, callId: String)? {
        let prefix = "__guide_card__:"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = String(text.dropFirst(prefix.count))
        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let cardId = String(rest[..<colonIdx])
        let callId = String(rest[rest.index(after: colonIdx)...])
        return (cardId, callId)
    }

    @ViewBuilder
    private func guideCardView(cardId: String, callId: String) -> some View {
        switch cardId {
        case "clone_authorization":
            CloneAuthorizationCard(language: language) { accepted in
                realtimeController.respondToGuideCard(callId: callId, accepted: accepted)
            }
        default:
            // clone_start_reading は全画面シートで処理するのでここには表示しない
            EmptyView()
        }
    }

    private func guideImageCard(imageId: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            GuideImageCardContent(imageId: imageId, caption: nil, language: language)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: UIScreen.main.bounds.width * 0.2)
        }
    }

    private func ruleChangeId(from text: String) -> String? {
        let prefix = "__rule_change__:"
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    private func ruleChangeCard(_ change: CallSessionController.RuleChangeRequest) -> some View {
        let primaryRule = change.updatedRules.first
        let trigger = primaryRule?.type ?? t("规则更新", "Rule Update")
        let action = primaryRule?.rule ?? change.updatedRuleSummary
        return HStack(alignment: .top, spacing: 0) {
            StrategyCardContent(trigger: trigger, action: action, language: language, isApplied: true)
            Spacer(minLength: UIScreen.main.bounds.width * 0.2)
        }
    }

    private func beginVoiceMessage() {
        guard flowState == .waiting else { return }
        // 幂等：`recordStartAt` 是"是否已按下"的唯一真源。
        // 不用 `isRecording` 判断，因为 ChatComposerBar 通过 Binding 同步写它，
        // 和父侧 @State 的 .onChange 可能顺序抢跑。
        guard recordStartAt == nil else { return }
        recordStartAt = Date()
        isRecording = true
        let ctrl = realtimeController
        voiceGate.begin {
            ctrl.beginManualListen()
        }
    }

    private func endVoiceMessage() {
        guard let start = recordStartAt else { return }
        let heldDuration = Date().timeIntervalSince(start)
        recordStartAt = nil
        isRecording = false
        if heldDuration >= 0.18 {
            flowState = .processing
            scheduleProcessingTimeout()
        } else {
            flowState = .waiting
        }
        let ctrl = realtimeController
        voiceGate.end(cancelled: false) { _ in
            ctrl.endManualListen()
        }
    }

    private func cancelVoiceMessage() {
        guard recordStartAt != nil else { return }
        recordStartAt = nil
        isRecording = false
        flowState = .waiting
        let ctrl = realtimeController
        voiceGate.end(cancelled: true) { _ in
            ctrl.cancelManualListen()
        }
    }

    private func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        realtimeController.sendListenText(text)
    }

    private func sendAuthorizationAcceptedText() {
        realtimeController.sendListenText(
            t(
                "我确认授权AI分身帮你处理来电。",
                "I confirm authorization for the AI assistant to handle incoming calls for the owner."
            )
        )
    }

    private func scheduleProcessingTimeout() {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            guard !Task.isCancelled else { return }
            if flowState == .processing {
                flowState = .waiting
            }
        }
    }

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            guard !Task.isCancelled else { return }
            if flowState == .connecting {
                flowState = .connectionFailed
            }
        }
    }

    // MARK: - Voice Clone Pre-fetch

    @MainActor
    private func fetchVoiceCloneSpeakerId() async {
        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else { return }
        let rawId = (CallMateBLEClient.shared.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawId.isEmpty else { return }
        guard let url = URL(string: AppConfig.voiceApiBaseURL + "/api/voice-clone/check-purchase") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": rawId])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONDecoder().decode(VoiceCloneCheckPurchaseAPIResponse.self, from: data) else { return }
        voiceCloneSpeakerId = json.data.speaker_id
    }

    private func retryConnection() {
        hasEverConnected = false
        flowState = .connecting
        let onboardingInitMessages: [[String: String]] = [
            ["role": "user", "content": t("你好", "Hello")],
            [
                "role": "assistant",
                "content": t(
                    "你好！我是你的实习AI分身，可以帮你处理来电。在开始前，我需要你的授权。",
                    "Hi! I'm your trainee AI assistant. I can help the owner handle incoming calls. Before we begin, I need your authorization."
                )
            ]
        ]
        let initMessages: [[String: String]]? = realtimeController.ws.isInitConfigSendPromptEnabled() ? nil : onboardingInitMessages
        realtimeController.start(
            initMessages: initMessages,
            autoPlayIntro: true
        )
        startConnectTimeout()
    }

    private var connectingView: some View {
        VStack(spacing: DS.Spacing.x3) {
            ProgressView()
                .scaleEffect(1.3)
                .tint(AppColors.primary)
            Text(t("正在连接 AI...", "Connecting to AI..."))
                .font(DS.Typography.body)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var connectionFailedView: some View {
        VStack(spacing: DS.Spacing.x3) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.textSecondary.opacity(0.5))
            VStack(spacing: DS.Spacing.x1) {
                Text(t("连接失败", "Connection Failed"))
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(t("无法连接到 AI，请检查网络后重试", "Could not connect to AI. Please check your network and try again."))
                    .font(DS.Typography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: retryConnection) {
                HStack(spacing: DS.Spacing.x1) {
                    Image(systemName: "arrow.clockwise")
                    Text(t("重试", "Retry"))
                }
                .font(DS.Typography.body.weight(.semibold))
                .padding(.horizontal, DS.Spacing.x4)
                .padding(.vertical, DS.Spacing.x2)
                .background(AppColors.primary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Spacing.x1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
        .padding(.horizontal, DS.Spacing.x4)
    }

    private func enterFinishedStateIfNeeded() {
        guard !didShowCompletion else { return }
        didShowCompletion = true
        isRecording = false
        recordStartAt = nil
        flowState = .finished
        // 不弹窗，底部“按住说话”会变为“立即体验”
    }

}

// MARK: - Onboarding Bottom Controls
private struct OnboardingBottomControls: View {
    let flowState: OnboardingFlowState
    @Binding var isRecording: Bool
    @Binding var isVoiceCancelling: Bool
    let language: Language
    let hideFinishedContent: Bool
    let onComplete: () -> Void
    let onRecordStart: () -> Void
    let onRecordEnd: () -> Void
    let onRecordCancel: () -> Void
    let onSendText: (String) -> Void
    var screenFrameForSemicircleCancel: CGRect? = nil

    @State private var finishAppeared = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        Group {
            if (flowState == .finished && hideFinishedContent) || flowState == .connectionFailed {
                EmptyView()
            } else {
                VStack(spacing: 0) {
                    if flowState == .finished {
                        ChatComposerBar(
                            language: language,
                            isRecording: .constant(false),
                            onVoiceStart: {},
                            onVoiceSend: {},
                            onVoiceCancel: {},
                            onSendText: { _ in },
                            useGlassContainer: true,
                            glassFooterContent: AnyView(finishedContent),
                            hideInnerBar: true
                        )
                        .onAppear {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                finishAppeared = true
                            }
                        }
                    } else {
                        ChatComposerBar(
                            language: language,
                            isRecording: $isRecording,
                            onVoiceStart: { onRecordStart() },
                            onVoiceSend: { onRecordEnd() },
                            onVoiceCancel: { onRecordCancel() },
                            onSendText: { text in onSendText(text) },
                            onVoiceCancelStateChanged: { next in isVoiceCancelling = next },
                            hintActive: flowState == .waiting && !isRecording,
                            screenFrameForSemicircleCancel: screenFrameForSemicircleCancel,
                            useGlassContainer: true
                        )
                        .allowsHitTesting(flowState == .waiting)
                        .opacity(flowState == .waiting ? 1.0 : 0.5)
                    }
                }
            }
        }
    }

    private var finishedContent: some View {
        VStack(spacing: DS.Spacing.x2) {
            ZStack {
                Circle()
                    .fill(AppColors.success.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppColors.success)
            }
            .scaleEffect(finishAppeared ? 1 : 0.5)
            .opacity(finishAppeared ? 1 : 0)

            VStack(spacing: DS.Spacing.x1) {
                Text(t("配置已完成", "Setup Complete"))
                    .font(.system(size: 16, weight: .bold))
                    .opacity(finishAppeared ? 1 : 0)
                    .offset(y: finishAppeared ? 0 : 10)
                Text(t("AI 已准备好为您接听电话", "AI is ready to take calls"))
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .opacity(finishAppeared ? 1 : 0)
            }

            Button {
                onComplete()
            } label: {
                HStack(spacing: DS.Spacing.x1) {
                    Text(t("立即体验", "Start Now"))
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(hex: "007AFF"))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 10, x: 0, y: 8)
            }
            .buttonStyle(OnboardingScaleButtonStyle())
            .opacity(finishAppeared ? 1 : 0)
            .offset(y: finishAppeared ? 0 : 20)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

// MARK: - Onboarding Scale Button Style
private struct OnboardingScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct OnboardingScreenFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct OnboardingBottomVisibleKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PostSetupReminderSheet: View {
    let language: Language
    let onHeightChange: (CGFloat) -> Void
    let onStartNow: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        VStack(spacing: DS.Spacing.x4) {
            // Checkmark Icon
            ZStack {
                Circle()
                    .fill(AppColors.success.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(AppColors.success)
            }
            .padding(.top, DS.Spacing.x2)

            // Title & Subtitle
            VStack(spacing: DS.Spacing.x1) {
                Text(t("配置已完成", "Setup Complete"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)

                Text(t("AI 已准备好为您接听电话", "AI is ready to take calls"))
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textSecondary)
            }

            // Settings Tips
            VStack(alignment: .leading, spacing: DS.Spacing.x3) {
                Text(t("💡 使用前请确认", "💡 Please confirm before use"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                VStack(alignment: .leading, spacing: DS.Spacing.x2) {
                    SettingTipRow(
                        icon: "phone.badge.plus",
                        color: .blue,
                        text: t("请把「筛选未知来电」改成「永不」", "Set 'Filter Unknown Callers' to 'Never'")
                    )
                    SettingTipRow(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        color: .orange,
                        text: t("请关闭「运营商骚扰拦截」", "Turn off carrier spam filtering")
                    )
                    SettingTipRow(
                        icon: "shield.slash",
                        color: .red,
                        text: t("请关闭其他 App 的拦截以免冲突", "Turn off spam filtering from other apps")
                    )
                    SettingTipRow(
                        icon: "moon.zzz",
                        color: .indigo,
                        text: t("「勿扰模式」下我们无法帮您接听", "Do Not Disturb prevents AI from answering")
                    )
                }
            }
            .padding(DS.Spacing.x3)
            .background(AppColors.backgroundSecondary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))

            Spacer(minLength: 0)

            Button {
                onStartNow()
            } label: {
                HStack(spacing: DS.Spacing.x1) {
                    Text(t("立即体验", "Start Now"))
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.x3)
                .background(AppColors.primary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                .shadow(color: AppColors.primary.opacity(0.3), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(OnboardingScaleButtonStyle())
        }
        .padding(DS.Spacing.x4)
        .frame(maxWidth: .infinity)
        .background(AppColors.background)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PostSetupSheetHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PostSetupSheetHeightPreferenceKey.self) { newHeight in
            onHeightChange(newHeight + 40)
        }
    }
}

private struct SettingTipRow: View {
    let icon: String
    let color: Color
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.x2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, alignment: .center)
            
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }
}

private struct PostSetupSheetHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Strategy Card with Animation
// MARK: - Strategy Card Category Config

private struct StrategyCategoryConfig {
    let displayTitle: String
    let tags: [String]
    let iconName: String
    let color: Color
}

private let strategyCategoryConfigs: [String: StrategyCategoryConfig] = [
    "快递": StrategyCategoryConfig(displayTitle: "快递服务", tags: ["快递", "驿站", "派件", "取件"], iconName: "shippingbox", color: Color(hex: "34C759")),
    "外卖": StrategyCategoryConfig(displayTitle: "外卖骑手", tags: ["外卖", "骑手"], iconName: "bicycle", color: Color(hex: "FF9500")),
    "运营商": StrategyCategoryConfig(displayTitle: "运营商", tags: ["移动", "联通", "电信"], iconName: "wifi", color: Color(hex: "5856D6")),
    "银行": StrategyCategoryConfig(displayTitle: "银行保险", tags: ["银行", "保险", "贷款", "理财"], iconName: "building.columns", color: Color(hex: "5AC8FA")),
    "营销": StrategyCategoryConfig(displayTitle: "营销广告", tags: ["推销", "房产", "课程", "广告"], iconName: "megaphone", color: Color(hex: "A2845E")),
    "熟人": StrategyCategoryConfig(displayTitle: "熟人来电", tags: ["熟人", "朋友"], iconName: "person.2", color: Color(hex: "007AFF")),
    "未归类": StrategyCategoryConfig(displayTitle: "未归类来电", tags: ["未分类", "兜底"], iconName: "questionmark.circle", color: Color(hex: "8E8E93"))
]

private func strategyConfigFor(_ trigger: String) -> StrategyCategoryConfig {
    for (key, config) in strategyCategoryConfigs {
        if trigger.contains(key) { return config }
    }
    return StrategyCategoryConfig(displayTitle: trigger, tags: [], iconName: "questionmark.circle", color: Color(hex: "007AFF"))
}

private struct StrategyParsedSections {
    var goal: String?
    var points: String?
}

private func parseStrategySections(_ rule: String) -> StrategyParsedSections {
    var goal: String?
    var points: String?
    let sectionPatterns: [(String, (String) -> Void)] = [
        ("处理目标", { goal = $0 }),
        ("处理要点", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("处理原则", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("处理策略", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("处理步骤", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("示例", { _ in })
    ]
    let remaining = rule.trimmingCharacters(in: .whitespacesAndNewlines)

    func findMarker(_ title: String) -> Range<String.Index>? {
        if let r = remaining.range(of: title + "：") { return r }
        if let r = remaining.range(of: title + ":") { return r }
        return nil
    }

    for (title, setter) in sectionPatterns {
        guard let range = findMarker(title) else { continue }
        let start = range.upperBound
        var end = remaining.endIndex
        for (otherTitle, _) in sectionPatterns where otherTitle != title {
            if let otherRange = findMarker(otherTitle),
               otherRange.lowerBound > range.lowerBound,
               otherRange.lowerBound < end {
                end = otherRange.lowerBound
            }
        }
        let content = String(remaining[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        setter(content)
    }
    return StrategyParsedSections(goal: goal, points: points)
}

private func strategyPointLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// MARK: - Strategy Card (glass design)

private struct StrategyCardContent: View {
    let trigger: String
    let action: String
    let language: Language
    var isApplied: Bool = false

    @State private var appeared = false

    private var config: StrategyCategoryConfig { strategyConfigFor(trigger) }
    private var sections: StrategyParsedSections { parseStrategySections(action) }

    private var bgGradient: LinearGradient {
        if isApplied {
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 220/255, green: 245/255, blue: 230/255).opacity(0.75), location: 0),
                    .init(color: Color.white.opacity(0.6), location: 0.4),
                    .init(color: Color.white.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            stops: [
                .init(color: Color(red: 230/255, green: 240/255, blue: 1).opacity(0.75), location: 0),
                .init(color: Color.white.opacity(0.6), location: 0.4),
                .init(color: Color.white.opacity(0.5), location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var topGradientColor: Color {
        isApplied ? Color(hex: "34C759") : Color(hex: "007AFF")
    }

    var body: some View {
        let outerShape = RoundedRectangle(cornerRadius: 20)
        ZStack(alignment: .top) {
            outerShape
                .fill(.ultraThinMaterial)
                .overlay(outerShape.fill(bgGradient))
                .overlay(outerShape.stroke(Color.white.opacity(0.5), lineWidth: 0.5))
                .shadow(color: Color.white.opacity(0.8), radius: 0, y: -0.5)
                .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                .shadow(color: Color.black.opacity(0.06), radius: 10, y: 6)

            LinearGradient(
                colors: [topGradientColor.opacity(0.06), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white, .white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                    .padding(.bottom, 18)
                goalAndPointsBlock
            }
            .padding(18)
        }
        .clipShape(outerShape)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        LinearGradient(
                            colors: [config.color.opacity(0.18), config.color.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    )
                    .shadow(color: Color.white.opacity(0.7), radius: 0, y: -0.5)
                    .shadow(color: config.color.opacity(0.18), radius: 3, y: 1)

                Image(systemName: config.iconName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(config.color)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                Text(config.displayTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(hex: "1D1D1F"))
                    .tracking(-0.4)

                if isApplied {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "34C759"))
                        Text(language == .zh ? "修改已生效" : "Applied")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "34C759"))
                    }
                } else if !config.tags.isEmpty {
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

            Spacer(minLength: 0)
        }
    }

    private var goalAndPointsBlock: some View {
        let goal = sections.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let points = sections.points?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasGoal = !goal.isEmpty
        let hasPoints = !points.isEmpty

        return Group {
            if hasGoal || hasPoints {
                VStack(alignment: .leading, spacing: 0) {
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
                        Rectangle()
                            .fill(Color.black.opacity(0.05))
                            .frame(height: 0.5)
                            .padding(.vertical, 14)
                    }

                    if hasPoints {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(language == .zh ? "处理要点" : "Key Points")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: "86868B"))
                                .tracking(0.3)

                            let lines = strategyPointLines(points)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(hex: "3A3A3C"))
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.38))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text(action)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.38))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Animated Message Bubble
private struct AnimatedMessageBubble: View {
    let msg: ChatMessage
    let language: Language
    let delay: Double
    
    @State private var appeared = false
    
    var body: some View {
        MessageBubbleContent(msg: msg, language: language)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 15)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(delay)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Onboarding Streaming Bubble
/// Mirrors FeedbackStreamingBubble: uses @ObservedObject so onChange fires per-character.
private struct OnboardingStreamingBubble: View {
    @ObservedObject var state: TTSStreamingBubbleState
    let proxy: ScrollViewProxy
    var isNearBottom: Bool = true
    var shouldAutoFollow: Bool = true

    var body: some View {
        StreamingTextBubble(
            state: state,
            uiFont: .systemFont(ofSize: 17),
            textColor: AppColors.textPrimary,
            bubbleColor: Color.white.opacity(0.82),
            cornerRadius: 18,
            borderColor: Color.white.opacity(0.7),
            borderWidth: 0.5,
            horizontalPadding: 14,
            verticalPadding: 10,
            useGlassMaterial: true,
            maxWidthFraction: 0.8,
            lineSpacing: 6
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("onboarding-streaming")
        .onChange(of: state.text) { _, newText in
            if !newText.isEmpty, isNearBottom && shouldAutoFollow {
                DispatchQueue.main.async {
                    proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Message Bubble Content
private struct MessageBubbleContent: View {
    let msg: ChatMessage
    let language: Language
    
    var body: some View {
        let isUser = msg.sender == .user
        let bubbleShape = isUser
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18)
            : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4, bottomTrailingRadius: 18, topTrailingRadius: 18)

        return HStack {
            if isUser { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }
            Text(msg.text)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(isUser ? .white : AppColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isUser {
                        bubbleShape.fill(Color(hex: "007AFF"))
                    } else {
                        bubbleShape
                            .fill(.ultraThinMaterial)
                            .overlay {
                                bubbleShape.fill(Color.white.opacity(0.82))
                            }
                            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                            .overlay {
                                bubbleShape.stroke(Color.white.opacity(0.7), lineWidth: 0.5)
                            }
                    }
                }
                .clipShape(bubbleShape)
            if !isUser { Spacer(minLength: UIScreen.main.bounds.width * 0.2) }
        }
    }
}

// MARK: - Bubble Shape (with tail)
private struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        var path = Path()
        
        if isUser {
            // User bubble - tail on right
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width - 4, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
        } else {
            // AI bubble - tail on left
            path.addRoundedRect(in: CGRect(x: 4, y: 0, width: rect.width - 4, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
        }
        
        return path
    }
}

// MARK: - Authorization Request Card
private struct AuthorizationRequestCard: View {
    let language: Language
    let onAccept: () -> Void
    let onReject: () -> Void

    @State private var appeared = false
    @State private var decision: Decision? = nil

    private enum Decision { case accepted, rejected }
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var isResolved: Bool { decision != nil }

    private var bgGradient: LinearGradient {
        if decision == .accepted {
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 220/255, green: 245/255, blue: 230/255).opacity(0.75), location: 0),
                    .init(color: Color.white.opacity(0.6), location: 0.4),
                    .init(color: Color.white.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            stops: [
                .init(color: Color(red: 230/255, green: 240/255, blue: 1).opacity(0.75), location: 0),
                .init(color: Color.white.opacity(0.6), location: 0.4),
                .init(color: Color.white.opacity(0.5), location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var topGradientColor: Color {
        decision == .accepted ? Color(hex: "34C759") : Color(hex: "007AFF")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(bgGradient))
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
                    // Header
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15)
                                .fill(LinearGradient(
                                    colors: [Color(hex: "007AFF").opacity(0.18), Color(hex: "007AFF").opacity(0.12)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                .shadow(color: Color.white.opacity(0.7), radius: 0, y: -0.5)
                                .shadow(color: Color(hex: "007AFF").opacity(0.18), radius: 3, y: 1)
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(Color(hex: "007AFF"))
                        }
                        .frame(width: 50, height: 50)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(t("需要您的授权", "Your Authorization Needed"))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color(hex: "1D1D1F"))
                                .tracking(-0.4)
                            if let decision {
                                HStack(spacing: 5) {
                                    Image(systemName: decision == .accepted ? "checkmark.circle" : "xmark.circle")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(decision == .accepted ? Color(hex: "34C759") : Color(hex: "8E8E93"))
                                    Text(decision == .accepted
                                         ? t("已授权", "Authorized")
                                         : t("已拒绝", "Declined"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(decision == .accepted ? Color(hex: "34C759") : Color(hex: "8E8E93"))
                                }
                            } else {
                                HStack(spacing: 4) {
                                    ForEach([t("隐私", "Privacy"), t("授权", "Auth")], id: \.self) { tag in
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
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 18)

                    // Content
                    Text(t(
                        "授权AI分身帮您接电话，获取您的个人信息，持续分析来电内容等。",
                        "Authorize your AI avatar to answer calls, access your personal information, and continuously analyze call content."
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(6)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.38))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.45), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Footer buttons
                    if decision == nil {
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { decision = .rejected }
                                onReject()
                            } label: {
                                Text(t("拒绝", "Decline"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color(hex: "3A3A3C"))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(Color.white.opacity(0.5))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { decision = .accepted }
                                onAccept()
                            } label: {
                                Text(t("接受", "Accept"))
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
                    }
                }
                .padding(18)
            }
            .clipShape(shape)
            Spacer(minLength: UIScreen.main.bounds.width * 0.2)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
    }
}

// MARK: - Clone Authorization Card

private struct CloneAuthorizationCard: View {
    let language: Language
    let onDecide: (Bool) -> Void

    @State private var decision: Decision? = nil
    @State private var appeared = false

    private enum Decision { case accepted, declined }
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var bgGradient: LinearGradient {
        if decision == .accepted {
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 220/255, green: 245/255, blue: 230/255).opacity(0.75), location: 0),
                    .init(color: Color.white.opacity(0.6), location: 0.4),
                    .init(color: Color.white.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        return LinearGradient(
            stops: [
                .init(color: Color(red: 230/255, green: 240/255, blue: 1).opacity(0.75), location: 0),
                .init(color: Color.white.opacity(0.6), location: 0.4),
                .init(color: Color.white.opacity(0.5), location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var topGradientColor: Color {
        decision == .accepted ? Color(hex: "34C759") : Color(hex: "007AFF")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(bgGradient))
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
                    // Header
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15)
                                .fill(LinearGradient(
                                    colors: [Color(hex: "AF52DE").opacity(0.18), Color(hex: "AF52DE").opacity(0.12)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                .shadow(color: Color.white.opacity(0.7), radius: 0, y: -0.5)
                                .shadow(color: Color(hex: "AF52DE").opacity(0.18), radius: 3, y: 1)
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(Color(hex: "AF52DE"))
                        }
                        .frame(width: 50, height: 50)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(t("声音克隆授权", "Voice Clone Authorization"))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Color(hex: "1D1D1F"))
                                .tracking(-0.4)
                            if let decision {
                                HStack(spacing: 5) {
                                    Image(systemName: decision == .accepted ? "checkmark.circle" : "xmark.circle")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(decision == .accepted ? Color(hex: "34C759") : Color(hex: "8E8E93"))
                                    Text(decision == .accepted
                                         ? t("已授权", "Authorized")
                                         : t("已拒绝", "Declined"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(decision == .accepted ? Color(hex: "34C759") : Color(hex: "8E8E93"))
                                }
                            } else {
                                HStack(spacing: 4) {
                                    ForEach([t("声音", "Voice"), t("克隆", "Clone")], id: \.self) { tag in
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
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 18)

                    // Content
                    Text(t(
                        "AI 需要克隆你的声音，用于接听电话时让对方感觉更自然。你的声音将加密存储，仅用于帮你接听电话，不会用于任何其他用途。",
                        "AI needs to clone your voice to make calls feel more natural. Your voice will be encrypted and used only to answer calls on your behalf."
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "3A3A3C"))
                    .lineSpacing(6)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.38))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.45), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Footer buttons
                    if decision == nil {
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { decision = .declined }
                                onDecide(false)
                            } label: {
                                Text(t("拒绝", "Decline"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color(hex: "3A3A3C"))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(Color.white.opacity(0.5))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { decision = .accepted }
                                onDecide(true)
                            } label: {
                                Text(t("授权", "Authorize"))
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
                    }
                }
                .padding(18)
            }
            .clipShape(shape)
            Spacer(minLength: UIScreen.main.bounds.width * 0.2)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
    }
}

// MARK: - Voice Clone Reader Sheet

private struct VoiceCloneReaderSheet: View {
    let language: Language
    let speakerId: String?
    let onCloneSuccess: () -> Void
    var onRecordingChanged: ((Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ble = CallMateBLEClient.shared

    @State private var isRecording = false
    @State private var cloneVoiceCancelling = false
    @State private var isSubmittingClone = false
    @State private var cloneTrainingProgress: Double = 0
    @State private var cloneTrainingSuccess: Bool? = nil
    @State private var cloneStatusText: String?
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var uploadTask: Task<Void, Never>?

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var scriptText: String {
        t(
            "福字要倒着贴，寓意福到，希望所有人新的一年福气满满，开开心心的。",
            "Read naturally: Wishing everyone happiness and good luck in the new year."
        )
    }

    private var hintIsError: Bool {
        if let text = cloneStatusText, !text.isEmpty { return true }
        return false
    }

    private var hintText: String {
        if let text = cloneStatusText, !text.isEmpty { return text }
        return t("建议在安静环境录制", "Record in a quiet place")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if isRecording { Spacer(minLength: 0) }

                if !isRecording {
                    ZStack(alignment: .trailing) {
                        VStack(spacing: 2) {
                            Text(t("声音克隆", "Voice Clone"))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(t("请朗读以下文字", "Please read the text below"))
                                .font(.system(size: 13))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        Button {
                            dismiss()
                            uploadTask?.cancel()
                            stopRecorder(discard: true)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppColors.textTertiary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                }

                Text(scriptText)
                    .font(.system(size: 18, weight: .regular))
                    .lineSpacing(8)
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.6))
                            )
                            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                    )
                    .padding(.bottom, 16)

                if !isSubmittingClone && !isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hintIsError ? Color.red : Color(hex: "FF9500"))
                            .frame(width: 6, height: 6)
                        Text(hintText)
                            .font(.system(size: 13))
                            .foregroundStyle(hintIsError ? Color.red : Color(hex: "FF9500"))
                    }
                    .padding(.bottom, 24)
                }

                if isSubmittingClone {
                    onboardingTrainingProgressView
                } else if !isRecording {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(t("按住录制", "Hold to Record"))
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "007AFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 10, x: 0, y: 8)
                }

                if isRecording { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, isRecording ? 0 : 32)
            .animation(.easeInOut(duration: 0.3), value: isRecording)

            if isRecording {
                VoiceRecordingOverlay(language: language, isCancelling: cloneVoiceCancelling)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, alignment: isRecording ? .center : .top)
        .contentShape(Rectangle())
        .gesture(cloneHoldGesture)
        .allowsHitTesting(!isSubmittingClone)
        .onDisappear {
            uploadTask?.cancel()
            stopRecorder(discard: true)
        }
    }

    // MARK: - Training Progress View

    private var onboardingTrainingProgressView: some View {
        VStack(spacing: 14) {
            if cloneTrainingSuccess == true {
                ZStack {
                    Circle()
                        .fill(AppColors.success.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColors.success)
                }
                Text(t("训练完成", "Training Complete"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.success)
            } else if cloneTrainingSuccess == false {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.error)
                if let cloneStatusText, !cloneStatusText.isEmpty {
                    Text(cloneStatusText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.center)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: "007AFF"))
                        .symbolEffect(.variableColor.iterative, options: .repeating, value: isSubmittingClone)
                    Text(t("声音训练中，请稍候…", "Training voice, please wait…"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppColors.textPrimary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: "E5E7EB")).frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Color(hex: "007AFF"), Color(hex: "34AAFF")], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * cloneTrainingProgress), height: 6)
                    }
                }
                .frame(height: 6)
                Text("\(Int(cloneTrainingProgress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.6)))
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        )
        .animation(.easeInOut(duration: 0.3), value: cloneTrainingSuccess)
    }

    // MARK: - Gesture

    private var cloneHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isRecording {
                    isRecording = true
                    cloneVoiceCancelling = false
                    onRecordingChanged?(true)
                    startRecording()
                } else {
                    cloneVoiceCancelling = value.translation.height < -60
                }
            }
            .onEnded { value in
                guard isRecording else { return }
                let cancelled = cloneVoiceCancelling || value.translation.height < -60
                isRecording = false
                cloneVoiceCancelling = false
                onRecordingChanged?(false)
                if cancelled {
                    stopRecorder(discard: true)
                } else {
                    stopRecordingAndSubmit()
                }
            }
    }

    // MARK: - Recording

    private func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }

    private func startRecording() {
        cloneStatusText = nil
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            guard await requestMicPermission() else {
                isRecording = false
                cloneStatusText = t("麦克风权限未开启", "Microphone permission denied")
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true, options: [])
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding_voice_clone.m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.prepareToRecord()
                recorder?.record()
                recordingURL = url
            } catch {
                isRecording = false
                cloneStatusText = t("录音启动失败", "Failed to start recording")
            }
        }
    }

    private func stopRecorder(discard: Bool) {
        recorder?.stop()
        recorder = nil
        if discard, let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func stopRecordingAndSubmit() {
        stopRecorder(discard: false)
        guard let audioURL = recordingURL else {
            cloneStatusText = t("未获取到录音文件", "No recording captured")
            return
        }
        guard let duration = audioDuration(at: audioURL), duration >= 3.0 else {
            cloneStatusText = t("提交的语音不能低于3秒", "Voice sample must be at least 3 seconds")
            try? FileManager.default.removeItem(at: audioURL)
            recordingURL = nil
            return
        }
        guard audioHasSignal(at: audioURL) else {
            cloneStatusText = t("提交的语音必须要有声音", "Voice sample must contain audible sound")
            try? FileManager.default.removeItem(at: audioURL)
            recordingURL = nil
            return
        }
        uploadTask?.cancel()
        uploadTask = Task { @MainActor in
            await submitAndRespond(audioURL: audioURL)
        }
    }

    // MARK: - Submission

    private func submitAndRespond(audioURL: URL) async {
        isSubmittingClone = true
        cloneTrainingProgress = 0.05
        cloneStatusText = nil
        defer { isSubmittingClone = false }

        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            onCloneSuccess()
            dismiss()
            return
        }

        let deviceId = runtimeMCUDeviceID()
        guard let deviceId else {
            onCloneSuccess()
            dismiss()
            return
        }

        do {
            let bluetoothId = WebSocketService.shared.runtimeBluetoothID
            try? await BackendAuthManager.shared.reportDevice(deviceId: deviceId, bluetoothId: bluetoothId, token: token)

            withAnimation(.easeInOut(duration: 0.4)) { cloneTrainingProgress = 0.15 }

            let resolvedSpeakerId = speakerId ?? deviceId
            let train = try await trainClone(
                token: token, deviceId: deviceId, speakerId: resolvedSpeakerId,
                text: scriptText, audioURL: audioURL
            )
            let status = try await pollOnboardingCloneStatus(token: token, deviceId: deviceId, speakerId: train.data.speaker_id)
            let terminal = (status.data.state ?? "").lowercased()
            guard terminal == "success" else {
                let reason = status.data.train_failed_reason ?? t("请稍后重试", "Please retry later")
                cloneTrainingSuccess = false
                cloneStatusText = t("训练失败：", "Training failed: ") + reason
                return
            }
            let resolvedSpeaker = status.data.speaker_id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedSpeaker.isEmpty else {
                cloneTrainingSuccess = false
                cloneStatusText = t("训练结果无效，请重试", "Invalid training result, please retry")
                return
            }
            // 10s后用与设置页相同的接口再查一次设备绑定 + status，再写入 `callmate.voiceId`（见 `applyDelayedCloneVoiceDefaultsUsingSettingsStyleQueries`）
            scheduleApplyCloneAsDefaultVoice(afterSeconds: 10)

            // Kick filler preload right now while we still have the speaker_id
            // in hand. If BLE isn't ready yet (common during first onboarding),
            // the coordinator will no-op; the delayed apply above will retry
            // once the device_id lands in UserDefaults 10s later as a safety net.
            triggerOnboardingFillerPreload(voiceId: resolvedSpeaker, source: "train_success")

            withAnimation { cloneTrainingProgress = 1.0 }
            cloneTrainingSuccess = true
            onCloneSuccess()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dismiss()
        } catch {
            cloneTrainingSuccess = false
            cloneStatusText = t("训练请求失败，请重试", "Training failed, please retry")
        }
    }

    private func runtimeMCUDeviceID() -> String? {
        let trimmed = (ble.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scheduleApplyCloneAsDefaultVoice(afterSeconds: UInt64) {
        let lang = language
        let snapshotVoiceId = UserDefaults.standard.string(forKey: "callmate.voiceId") ?? ""
        let snapshotDisplay = UserDefaults.standard.string(forKey: "callmate.voiceDisplayNameOverride") ?? ""
        let snapshotManual = UserDefaults.standard.bool(forKey: "callmate.userManuallySelectedVoice")
        Task.detached {
            try? await Task.sleep(nanoseconds: afterSeconds * 1_000_000_000)
            await applyDelayedCloneVoiceDefaultsUsingSettingsStyleQueries(
                lang: lang,
                snapshotVoiceId: snapshotVoiceId,
                snapshotDisplay: snapshotDisplay,
                snapshotManual: snapshotManual
            )
        }
    }

    private func pollOnboardingCloneStatus(token: String, deviceId: String, speakerId: String) async throws -> VoiceCloneStatusResponse {
        let maxAttempts = 20
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            let status = try await onboardingVoiceCloneStatusGET(token: token, deviceId: deviceId, speakerId: speakerId)
            let state = (status.data.state ?? "").lowercased()
            if state == "success" || state == "failed" || state == "expired" {
                return status
            }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) {
                    cloneTrainingProgress = Double(attempt + 1) / Double(maxAttempts)
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return try await onboardingVoiceCloneStatusGET(token: token, deviceId: deviceId, speakerId: speakerId)
    }

    // MARK: - Audio validation

    private func audioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        let seconds = Double(file.length) / rate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func audioHasSignal(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let cap: AVAudioFrameCount = 4096
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else { return false }
        let rmsThreshold: Float = 0.008
        let peakThreshold: Float = 0.05
        while (try? file.read(into: buf, frameCount: cap)) != nil, buf.frameLength > 0 {
            let frames = Int(buf.frameLength)
            let channels = Int(buf.format.channelCount)
            var sumSq: Float = 0; var peak: Float = 0
            switch buf.format.commonFormat {
            case .pcmFormatFloat32:
                guard let ch = buf.floatChannelData else { continue }
                for c in 0..<channels {
                    for i in 0..<frames { let v = abs(ch[c][i]); sumSq += v * v; if v > peak { peak = v } }
                }
            case .pcmFormatInt16:
                guard let ch = buf.int16ChannelData else { continue }
                for c in 0..<channels {
                    for i in 0..<frames {
                        let raw = Float(abs(Int32(ch[c][i])))
                        let v = raw / Float(Int16.max)
                        sumSq += v * v; if v > peak { peak = v }
                    }
                }
            case .pcmFormatInt32:
                guard let ch = buf.int32ChannelData else { continue }
                for c in 0..<channels {
                    for i in 0..<frames {
                        let raw = Float(abs(ch[c][i]))
                        let v = raw / Float(Int32.max)
                        sumSq += v * v; if v > peak { peak = v }
                    }
                }
            default: continue
            }
            let rms = sqrt(sumSq / Float(frames * channels))
            if rms >= rmsThreshold || peak >= peakThreshold { return true }
        }
        return false
    }

    // MARK: - API

    private func trainClone(token: String, deviceId: String, speakerId: String, text: String, audioURL: URL) async throws -> VoiceCloneTrainResponse {
        guard let url = URL(string: AppConfig.voiceApiBaseURL + "/api/voice-clone/train") else { throw URLError(.badURL) }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("device_id", deviceId)
        field("speaker_id", speakerId)
        field("text", text)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice_clone.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(VoiceCloneTrainResponse.self, from: data)
    }
}

// MARK: - Voice clone APIs (与 `SettingsVoiceRepository` / `SettingsVoiceToneSheet.refreshCloneStatus` 同源)

fileprivate func onboardingVoiceCloneStatusGET(token: String, deviceId: String, speakerId: String) async throws -> VoiceCloneStatusResponse {
    guard var components = URLComponents(string: AppConfig.voiceApiBaseURL + "/api/voice-clone/status") else {
        throw URLError(.badURL)
    }
    components.queryItems = [
        URLQueryItem(name: "device_id", value: deviceId),
        URLQueryItem(name: "speaker_id", value: speakerId)
    ]
    guard let url = components.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode(VoiceCloneStatusResponse.self, from: data)
}

/// 与设置页「声音」里 `queryDeviceClone` + `queryCloneStatus` 一致：先 `GET /api/device/{id}/voice-clone`，再 `GET /api/voice-clone/status`，仅当 `state == success` 时写入 `callmate.voiceId`。
fileprivate func applyDelayedCloneVoiceDefaultsUsingSettingsStyleQueries(
    lang: Language,
    snapshotVoiceId: String,
    snapshotDisplay: String,
    snapshotManual: Bool
) async {
    let stillMatches = await MainActor.run {
        let cur = UserDefaults.standard.string(forKey: "callmate.voiceId") ?? ""
        let curD = UserDefaults.standard.string(forKey: "callmate.voiceDisplayNameOverride") ?? ""
        let curM = UserDefaults.standard.bool(forKey: "callmate.userManuallySelectedVoice")
        return cur == snapshotVoiceId && curD == snapshotDisplay && curM == snapshotManual
    }
    guard stillMatches else { return }

    guard let token = await BackendAuthManager.shared.ensureToken(),
          BackendAuthManager.looksLikeJWT(token) else { return }

    let deviceId = await MainActor.run {
        let t = (CallMateBLEClient.shared.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    guard let deviceId else { return }

    do {
        let bound = try await SettingsVoiceRepository.fetchBoundCloneVoice(deviceId: deviceId, token: token)
        guard let info = bound.data.voice_clone else { return }
        let speakerId = info.speaker_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakerId.isEmpty else { return }

        let status = try await onboardingVoiceCloneStatusGET(token: token, deviceId: deviceId, speakerId: speakerId)
        let state = (status.data.state ?? "").lowercased()
        guard state == "success" else { return }

        let ttsVoiceId = status.data.speaker_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ttsVoiceId.isEmpty else { return }

        var didCommitVoiceId = false
        await MainActor.run {
            let cur = UserDefaults.standard.string(forKey: "callmate.voiceId") ?? ""
            let curD = UserDefaults.standard.string(forKey: "callmate.voiceDisplayNameOverride") ?? ""
            let curM = UserDefaults.standard.bool(forKey: "callmate.userManuallySelectedVoice")
            guard cur == snapshotVoiceId, curD == snapshotDisplay, curM == snapshotManual else { return }
            let display = lang == .zh ? "我的声音" : "My Voice"
            UserDefaults.standard.set(ttsVoiceId, forKey: "callmate.voiceId")
            UserDefaults.standard.set(display, forKey: "callmate.voiceDisplayNameOverride")
            UserDefaults.standard.set(true, forKey: "callmate.userManuallySelectedVoice")
            didCommitVoiceId = true
        }

        // Commit succeeded → ensure the MCU has the 6 fillers for this voice.
        // This is the safety net for the "train_success" path: if that one
        // was skipped due to BLE not being ready yet, by now (10s later) the
        // BLE connection has almost always converged.
        if didCommitVoiceId {
            await MainActor.run {
                triggerOnboardingFillerPreload(voiceId: ttsVoiceId, source: "delayed_apply")
            }
        }
    } catch {
        print("[OnboardingVoiceClone] delayed apply (device + status) failed: \(error)")
    }
}

/// Shared gate + dispatch so onboarding's two trigger points (train_success
/// and delayed_apply) don't diverge. Mirrors `triggerFillerPreloadIfPossible`
/// in `SettingsVoiceToneSheet.swift`.
@MainActor
fileprivate func triggerOnboardingFillerPreload(voiceId: String, source: String) {
    let trimmed = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        print("[OnboardingVoiceClone] skip preload (\(source)): empty voice_id")
        return
    }
    let deviceId = (CallMateBLEClient.shared.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !deviceId.isEmpty else {
        print("[OnboardingVoiceClone] skip preload (\(source)): no MCU device id")
        return
    }
    guard CallMateBLEClient.shared.isPreloadReady else {
        print("[OnboardingVoiceClone] skip preload (\(source)): preload char unavailable (legacy firmware?)")
        return
    }
    print("[OnboardingVoiceClone] trigger filler preload (\(source)) voice=\(trimmed) device=\(deviceId)")
    _ = TTSFillerSyncCoordinator.shared.preload(voiceId: trimmed, deviceId: deviceId)
}

// MARK: - Check-Purchase Response Models

private struct VoiceCloneCheckPurchaseAPIResponse: Decodable {
    let data: VoiceCloneCheckPurchaseData
}

private struct VoiceCloneCheckPurchaseData: Decodable {
    let speaker_id: String
    let state: String?
    let is_new: Bool?
}

#Preview {
    OnboardingView(language: .zh, onComplete: {})
}

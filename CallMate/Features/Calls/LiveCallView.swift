//
//  LiveCallView.swift
//  CallMate
//
//  Live BLE-driven call screen

import Foundation
import SwiftUI
import SwiftData
import UserNotifications

struct LiveCallView: View {
    let language: Language
    let incomingCall: CallMateIncomingCall
    let onClose: () -> Void

    @ObservedObject var controller: CallSessionController
    @ObservedObject private var liveTranscriptRouter: LiveTranscriptNotificationRouter
    @Environment(\.modelContext) private var modelContext

    @State private var startedAt: Date = Date()
    @State private var didPersist: Bool = false
    @State private var callId: UUID = UUID()
    @State private var isLeavingPage: Bool = false
    @State private var handoffSlideOffset: CGFloat = 0
    @State private var didSendLiveTranscriptNotification: Bool = false
    @State private var handoffHintSweep: CGFloat = -0.55
    @State private var handoffThumbGlow: Bool = false
    @State private var capturedOutboundTaskID: UUID? = nil

    @MainActor
    init(
        language: Language,
        incomingCall: CallMateIncomingCall,
        controller: CallSessionController,
        liveTranscriptRouter: LiveTranscriptNotificationRouter? = nil,
        onClose: @escaping () -> Void
    ) {
        self.language = language
        self.incomingCall = incomingCall
        _controller = ObservedObject(wrappedValue: controller)
        _liveTranscriptRouter = ObservedObject(wrappedValue: liveTranscriptRouter ?? .shared)
        self.onClose = onClose
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var isOutbound: Bool { incomingCall.title == "[OUTBOUND_TASK]" }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                messages

                sliderBar
                    .padding(.bottom, 16)

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
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, AppSpacing.sm)
                }
            }
            .background(AppColors.backgroundSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(incomingCall.number.isEmpty ? t("未知号码", "Unknown") : incomingCall.number)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(navSubtitleText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if controller.status == .connected {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: "34C759"))
                            Text(formatDuration(controller.duration))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color(hex: "34C759"))
                        }
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .accessibilityIdentifier("livecall-root")
        .onAppear {
            isLeavingPage = false
            didSendLiveTranscriptNotification = false
            handoffHintSweep = -0.55
            handoffThumbGlow = false
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) {
                handoffHintSweep = 1.2
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                handoffThumbGlow = true
            }
            // Outbound calls: recording was already started by the controller with outboundCallId.
            // Starting it again here would overwrite the conversationWriter and lose that recording.
            if incomingCall.title != "[OUTBOUND_TASK]" {
                callId = UUID()
                startedAt = Date()
                AudioService.shared.beginConversationRecording(callId: callId)
            } else {
                if let existingCallId = controller.outboundCallId {
                    callId = existingCallId
                }
                if let existingStartedAt = controller.outboundCallStartedAt {
                    startedAt = existingStartedAt
                }
                capturedOutboundTaskID = controller.activeOutboundTaskID
                // Claim ownership of outbound persistence immediately so that
                // persistOutboundCallIfNeeded() inside end() sees outboundCallId==nil and skips.
                // Without this, both paths write a CallLog and the count shows doubled.
                controller.markOutboundCallHandledByLiveView()
            }
            if !isOutbound && controller.status == .ended {
                controller.startFromIncomingCall(incomingCall)
            } else if isOutbound && controller.status == .ended {
                DispatchQueue.main.async {
                    onClose()
                }
            }
        }
        .onDisappear {
            isLeavingPage = true
            handoffHintSweep = -0.55
            handoffThumbGlow = false
            // Not a literal "user_interrupt": SwiftUI can fire onDisappear during
            // keyboard/sheet transitions or navigation. Default `end()` used `user_interrupt`.
            controller.end(abortReason: "live_call_disappear")
            if !didPersist {
                if let fileName = AudioService.shared.endConversationRecording(),
                   let url = try? CallAudioStore.url(forFileName: fileName) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        .onChange(of: controller.status) { _, newStatus in
            if newStatus == .ended {
                if !didPersist && !isLeavingPage {
                    persistCallIfNeeded()
                }
                onClose()
            }
            scheduleLiveTranscriptNotificationIfNeeded()
        }
        .onChange(of: controller.messages.count) { _, _ in
            scheduleLiveTranscriptNotificationIfNeeded()
        }
        .onChange(of: controller.toastMessage) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    controller.toastMessage = nil
                }
            }
        }
    }

    /// 备用：若 Controller 在发 answer 时已发过同一条通知（同 identifier），这里会覆盖为同一内容，不重复弹。
    private func scheduleLiveTranscriptNotificationIfNeeded() {
        guard controller.status == .connected,
              !isOutbound,
              !didSendLiveTranscriptNotification else { return }
        didSendLiveTranscriptNotification = true
        let identifier = "live_transcript_\(incomingCall.uid)"
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
            "call_id": callId.uuidString,
            "ws_session_id": controller.wsSessionId ?? ""
        ]
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[LiveCall] live transcript notification failed: \(error.localizedDescription)")
            } else {
                print("[LiveCall] live transcript notification sent uid=\(incomingCall.uid)")
            }
        }
    }

    private var sliderBar: some View {
        let screenWidth = UIScreen.main.bounds.width
        let trackHeight: CGFloat = 60
        let thumbInset: CGFloat = 5
        let thumbSize: CGFloat = trackHeight - thumbInset * 2
        let capsuleMaxWidth: CGFloat = screenWidth * 3 / 5
        let maxOffset: CGFloat = max(0, capsuleMaxWidth - thumbSize - thumbInset * 2)
        let progress: CGFloat = maxOffset > 0 ? min(1, handoffSlideOffset / maxOffset) : 0
        let movingTrackWidth: CGFloat = max(thumbSize + thumbInset * 2, capsuleMaxWidth - handoffSlideOffset)
        let isSlidToEnd: Bool = progress >= 0.72

        return ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(.thickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.78),
                                        Color.white.opacity(0.64)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .fill(Color(hex: "007AFF").opacity(0.06))
                            .padding(1.2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .stroke(Color.white.opacity(0.92), lineWidth: 0.8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .stroke(Color.black.opacity(0.06), lineWidth: 0.6)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.7),
                                        Color.white.opacity(0.18),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: trackHeight * 0.42)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                    .shadow(color: Color.white.opacity(0.5), radius: 1.5, y: -1)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .frame(width: movingTrackWidth, height: trackHeight)
                    .overlay {
                        if controller.status != .ended {
                            GeometryReader { geo in
                                let sweepWidth = max(44, geo.size.width * 0.34)
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                .clear,
                                                Color.white.opacity(0.02 + 0.02 * (1 - progress)),
                                                Color.white.opacity(0.18 + 0.10 * (1 - progress)),
                                                Color.white.opacity(0.42 + 0.08 * (1 - progress)),
                                                Color.white.opacity(0.18 + 0.10 * (1 - progress)),
                                                Color.white.opacity(0.02 + 0.02 * (1 - progress)),
                                                .clear
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: sweepWidth, height: geo.size.height * 1.22)
                                    .rotationEffect(.degrees(16))
                                    .blur(radius: 1.5)
                                    .offset(
                                        x: -sweepWidth + (geo.size.width + sweepWidth * 2) * handoffHintSweep,
                                        y: -geo.size.height * 0.06
                                    )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2))
                            .allowsHitTesting(false)
                        }
                    }

                let textAreaWidth = max(0, movingTrackWidth - thumbSize - thumbInset * 2)
                Text(t("右滑切换真人接听", "Slide for human"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary.opacity(0.9 - 0.5 * progress))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: textAreaWidth, alignment: .center)
                    .clipped()
                    .offset(x: thumbSize + thumbInset)
            }
            .frame(width: movingTrackWidth, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2))
            .frame(width: capsuleMaxWidth, alignment: .trailing)

            Circle()
                .fill(controller.status == .ended ? AppColors.textTertiary : Color(hex: "007AFF"))
                .frame(width: thumbSize, height: thumbSize)
                .overlay {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(handoffThumbGlow ? 0.42 : 0.18),
                                    Color.white.opacity(0.08),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay(
                    Image(systemName: isSlidToEnd ? "checkmark" : "chevron.right")
                        .font(isSlidToEnd ? .system(size: 12, weight: .bold) : .system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color(hex: "007AFF").opacity(handoffThumbGlow ? 0.36 : 0.22), radius: handoffThumbGlow ? 10 : 4, y: 2)
                .offset(x: thumbInset + handoffSlideOffset)
        }
        .frame(width: capsuleMaxWidth, height: trackHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard controller.status != .ended else { return }
                    handoffSlideOffset = min(max(0, value.translation.width), maxOffset)
                }
                .onEnded { _ in
                    guard controller.status != .ended else {
                        withAnimation(AppAnimations.easeOut) { handoffSlideOffset = 0 }
                        return
                    }
                    let shouldTrigger = handoffSlideOffset >= maxOffset * 0.72
                    withAnimation(AppAnimations.easeOut) {
                        handoffSlideOffset = shouldTrigger ? maxOffset : 0
                    }
                    if shouldTrigger {
                        controller.handoffToHuman()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(AppAnimations.easeOut) { handoffSlideOffset = 0 }
                    }
                }
        )
    }

    private var statusColor: Color {
        switch controller.status {
        case .connecting: return AppColors.warning
        case .ringing: return AppColors.warning
        case .connected: return AppColors.success
        case .ended: return AppColors.textSecondary
        }
    }

    private var statusText: String {
        switch controller.status {
        case .connecting: return t("连接中", "Connecting")
        case .ringing: return t("等待接通", "Ringing")
        case .connected: return t("通话中", "Connected")
        case .ended: return t("已结束", "Ended")
        }
    }
    
    private var navSubtitleText: String {
        switch controller.status {
        case .connecting:
            return isOutbound
                ? t("正在拨号，准备转写…", "Dialing, preparing…")
                : t("正在连接设备并准备转写…", "Preparing transcription…")
        case .ringing:
            return isOutbound
                ? t("等待对方接听…", "Waiting for answer…")
                : t("AI 将自动接听并开始转写", "AI will answer and transcribe")
        case .connected:
            return t("实时转写中，可随时转交真人接听", "Live transcribing; hand off anytime")
        case .ended:
            return t("通话已结束", "Call ended")
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var messages: some View {
        LiveTranscriptListView(
            messages: controller.messages,
            streamingState: controller.ttsStreamingState,
            language: language
        )
        .equatable()
        .accessibilityIdentifier("livecall-transcript")
    }

    // controls removed – replaced by glassSliderBar

    private func endCall() {
        if isOutbound { controller.markOutboundCallHandledByLiveView() }
        controller.end(abortReason: "live_call_slider_hangup")
        persistCallIfNeeded()
        onClose()
    }

    private func persistCallIfNeeded() {
        guard !didPersist else { return }
        didPersist = true

        let endedAt = Date()
        let wsSessionId = controller.wsSessionId

        let isOutbound = self.isOutbound
        let outboundTaskID: UUID? = isOutbound ? (capturedOutboundTaskID ?? controller.activeOutboundTaskID) : nil
        print("[LiveCallPersist] persistCallIfNeeded: isOutbound=\(isOutbound) outboundTaskID=\(outboundTaskID?.uuidString ?? "⚠️ NIL") captured=\(capturedOutboundTaskID?.uuidString ?? "nil") live=\(controller.activeOutboundTaskID?.uuidString ?? "nil") phone='\(incomingCall.number)' duration=\(controller.duration)s")

        let label: String
        if isOutbound {
            label = incomingCall.number.isEmpty ? t("外呼号码", "Outbound Call") : incomingCall.number
        } else {
            label = incomingCall.caller.isEmpty ? t("未知来电", "Unknown Caller") : incomingCall.caller
        }
        let phone: String = incomingCall.number.isEmpty ? t("未知号码", "Unknown") : incomingCall.number

        let recordingFileName = AudioService.shared.endConversationRecording()

        let summary: String
        if isOutbound {
            summary = "[OUTBOUND_TASK] " + t("通话录音已保存", "Call recording saved")
        } else {
            summary = t("通话录音已保存", "Call recording saved")
        }
        let fullSummary: String? = nil

        let call = CallLog(
            id: callId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: controller.duration,
            recordingFileName: recordingFileName,
            statusRaw: CallStatus.handled.rawValue,
            phone: phone,
            label: label,
            summary: summary,
            fullSummary: fullSummary,
            isSimulation: false,
            isImportant: (controller.emergencyNotifyAttemptCount > 0 || controller.didTriggerEmergencyNotifyInCurrentCall) ? true : nil,
            languageRaw: language.rawValue,
            outboundTaskID: outboundTaskID,
            wsSessionId: wsSessionId,
            errorMessage: controller.lastErrorMessage
        )

        // Insert before touching `transcript`: reading/appending the relationship on a model that
        // is not yet in the context can trap inside SwiftData (EXC_BREAKPOINT in getValue).
        modelContext.insert(call)

        for (idx, msg) in controller.messages.enumerated() {
            let senderRaw = msg.isAI ? ChatSender.ai.rawValue : ChatSender.caller.rawValue
            let offsetMs = Int(msg.time.timeIntervalSince(startedAt) * 1000)
            _ = TranscriptLine(
                index: idx,
                senderRaw: senderRaw,
                text: msg.text,
                timestamp: msg.time,
                startOffsetMs: max(0, offsetMs),
                endOffsetMs: nil,
                typeRaw: nil,
                call: call
            )
        }

        // Safety: if markOutboundCallHandledByLiveView() wasn't called earlier (e.g. onAppear
        // was skipped), clear it now before saving so end() can't create a duplicate.
        if isOutbound {
            controller.markOutboundCallHandledByLiveView()
        }
        do {
            try modelContext.save()
            liveTranscriptRouter.requestDismissTransientOverlays()
            liveTranscriptRouter.pendingOpenCallDetailId = callId
        } catch {
            call.errorMessage = error.localizedDescription
        }
        if let sid = wsSessionId, !sid.isEmpty {
            ChatSummaryService.pollAndUpdate(callId: callId, sessionId: sid, modelContext: modelContext)
        } else {
            print("[Summary] skip poll: missing session_id")
        }
    }
}

private struct LiveTranscriptListView: View, Equatable {
    let messages: [CallSessionController.DialogMessage]
    @ObservedObject var streamingState: TTSStreamingBubbleState
    let language: Language

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language &&
        lhs.messages == rhs.messages
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && streamingState.text.isEmpty && !streamingState.isLoading {
                        VStack(spacing: AppSpacing.sm) {
                            Image(systemName: "waveform.and.mic")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(AppColors.textTertiary)
                                .padding(.top, AppSpacing.xl)
                            Text(t("转写准备中", "Getting ready"))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary)
                            Text(t("接通后将显示双方对话内容", "Transcript will appear after connection"))
                                .font(.system(size: 15))
                                .foregroundColor(AppColors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, AppSpacing.xl)
                                .padding(.bottom, AppSpacing.xl)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(messages) { msg in
                        LiveMessageBubble(msg: msg, language: language)
                            .id(msg.id)
                    }
                    LiveStreamingBubble(state: streamingState, proxy: proxy)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 86)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(AppAnimations.easeOut) {
                        proxy.scrollTo(last.id, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Live Streaming Bubble
//
// 与 FeedbackChatModalView.FeedbackStreamingBubble 同理：
// 必须是独立的 View struct 且持有自己的 @ObservedObject，
// 才能在父视图被 .equatable() 拦截时仍然收到逐字更新并触发重绘。
// 内部使用 StreamingTextBubble（CoreText 锁行宽，杜绝 reflow 跳动）。
private struct LiveStreamingBubble: View {
    @ObservedObject var state: TTSStreamingBubbleState
    let proxy: ScrollViewProxy

    var body: some View {
        StreamingTextBubble(
            state: state,
            uiFont: .systemFont(ofSize: 17),
            textColor: .white,
            bubbleColor: Color(hex: "007AFF"),
            cornerRadius: 18,
            borderColor: .clear,
            borderWidth: 0,
            horizontalPadding: 14,
            verticalPadding: 10,
            trailingAligned: true,
            maxWidthFraction: 0.75,
            lineSpacing: 6
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .id("streaming-ai")
        .onChange(of: state.text) { _, _ in
            guard !state.text.isEmpty else { return }
            withAnimation(AppAnimations.easeOut) {
                proxy.scrollTo("streaming-ai", anchor: .center)
            }
        }
    }
}

// MARK: - Live Message Bubble
private struct LiveMessageBubble: View {
    let msg: CallSessionController.DialogMessage
    let language: Language

    var body: some View {
        let isAI = msg.isAI
        let bubbleShape = isAI
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18)
            : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4, bottomTrailingRadius: 18, topTrailingRadius: 18)

        HStack {
            if isAI { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }
            Text(msg.text)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(isAI ? .white : AppColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isAI {
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
            if !isAI { Spacer(minLength: UIScreen.main.bounds.width * 0.2) }
        }
    }
}

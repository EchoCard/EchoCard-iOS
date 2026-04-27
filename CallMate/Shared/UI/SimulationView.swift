//
//  SimulationView.swift
//  CallMate
//
//  模拟通话页面 - 与 prototype 一致的聊天界面风格
//

import SwiftUI
import SwiftData

struct SimulationView: View {
    let language: Language
    let onEnd: (CallLog) -> Void

    @StateObject private var controller: CallSessionController
    @Environment(\.modelContext) private var modelContext

    @State private var startedAt: Date = Date()
    @State private var didPersist: Bool = false
    @State private var callId: UUID = UUID()
    @State private var isLeavingPage: Bool = false
    @State private var startupTask: Task<Void, Never>?
    @State private var recordingStartupTask: Task<Void, Never>?

    init(language: Language, onEnd: @escaping (CallLog) -> Void) {
        self.language = language
        self.onEnd = onEnd
        _controller = StateObject(
            wrappedValue: CallSessionController(
                language: language,
                inputSource: .microphone,
                monitorTTSOnPhone: true,
                scene: .call,
                skipPickupDelay: true
            )
        )
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                chatContentView

                hangupGlassButton
                    .padding(.bottom, 16)

                if controller.status == .connecting || controller.status == .ringing {
                    processingIndicator
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .background(AppColors.backgroundSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(t("模拟来电", "Test Call"))
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
        .onAppear {
            isLeavingPage = false
            callId = UUID()
            startedAt = Date()
            let capturedCallId = callId
            logSimulationStartup("view_on_appear", extra: "callId=\(capturedCallId.uuidString)")
            startupTask?.cancel()
            recordingStartupTask?.cancel()
            startupTask = Task { @MainActor in
                // Let the simulation UI render before we start audio/session setup.
                await Task.yield()
                guard !Task.isCancelled else { return }

                let startupStartedAt = Date()
                self.logSimulationStartup("startup_begin", extra: "callId=\(capturedCallId.uuidString)")

                let controllerStartAt = Date()
                controller.start()
                self.logSimulationStartup(
                    "controller_start_requested",
                    extra: "duration=\(Int(Date().timeIntervalSince(controllerStartAt) * 1000))ms total=\(Int(Date().timeIntervalSince(startupStartedAt) * 1000))ms"
                )

                recordingStartupTask = Task { @MainActor in
                    // Recording file creation can take a few hundred ms on first hit.
                    // Keep it off the initial page-enter / connect path.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    let recordingStartedAt = Date()
                    self.logSimulationStartup("conversation_recording_begin")
                    AudioService.shared.beginConversationRecording(callId: capturedCallId, clockSource: .mic)
                    self.logSimulationStartup(
                        "conversation_recording_started",
                        extra: "duration=\(Int(Date().timeIntervalSince(recordingStartedAt) * 1000))ms"
                    )
                    recordingStartupTask = nil
                }

                self.logSimulationStartup("waiting_tone_skipped", extra: "reason=avoid_ui_hitch")
                startupTask = nil
            }
        }
        .onDisappear {
            startupTask?.cancel()
            startupTask = nil
            recordingStartupTask?.cancel()
            recordingStartupTask = nil
            logSimulationStartup("view_on_disappear")
            isLeavingPage = true
            controller.end()
            if !didPersist {
                if let fileName = AudioService.shared.endConversationRecording(),
                   let url = try? CallAudioStore.url(forFileName: fileName) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        .onChange(of: controller.status) { _, newStatus in
            logSimulationStartup("status_changed", extra: "status=\(String(describing: newStatus))")
            if newStatus == .ended && !didPersist && !isLeavingPage {
                persistCallIfNeeded()
            }
        }
        // Swipe-back handled by CallsView container
    }
    
    // MARK: - Chat Content

    private var chatContentView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.messages) { msg in
                        simulationBubble(for: msg)
                            .id(msg.id)
                    }
                    SimulationStreamingBubble(state: controller.ttsStreamingState, proxy: proxy)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 86)
            }
            .onAppear {
                scrollToLatestMessage(using: proxy, animated: false)
            }
            .onChange(of: controller.messages.count) { _, _ in
                scrollToLatestMessage(using: proxy, animated: true)
            }
        }
    }

    private func scrollToLatestMessage(using proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            if !controller.ttsStreamingState.text.isEmpty {
                proxy.scrollTo("streaming-ai", anchor: .center)
            } else if let last = controller.messages.last {
                proxy.scrollTo(last.id, anchor: .center)
            }
        }
        if animated {
            withAnimation(AppAnimations.easeOut, action)
        } else {
            action()
        }
    }

    private func simulationBubble(for msg: CallSessionController.DialogMessage) -> some View {
        let isAI = msg.isAI
        let bubbleShape = isAI
            ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4, bottomTrailingRadius: 18, topTrailingRadius: 18)
            : UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18)

        return HStack {
            if !isAI { Spacer(minLength: UIScreen.main.bounds.width * 0.25) }
            Text(msg.text)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(isAI ? AppColors.textPrimary : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if isAI {
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
                        bubbleShape.fill(Color(hex: "007AFF"))
                    }
                }
                .clipShape(bubbleShape)
            if isAI { Spacer(minLength: UIScreen.main.bounds.width * 0.2) }
        }
    }

    private var processingIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(AppColors.textTertiary)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var navSubtitleText: String {
        switch controller.status {
        case .connecting:
            return t("正在连接…", "Connecting…")
        case .ringing:
            return t("AI 正在接听…", "AI answering…")
        case .connected:
            return t("模拟通话中，可随时挂断", "Simulating; hang up anytime")
        case .ended:
            return controller.isAIHangup
                ? t("AI 已挂断", "AI Hung Up")
                : t("通话已结束", "Call ended")
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Hangup Button

    private var hangupGlassButton: some View {
        Button(action: endCall) {
            VStack(spacing: 4) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text(t("挂断", "Hang Up"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(AppColors.error)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
    }
    
    private func endCall() {
        controller.end()
        persistCallIfNeeded()
    }

    private func persistCallIfNeeded() {
        guard !didPersist else { return }
        didPersist = true

        let endedAt = Date()
        let wsSessionId = controller.wsSessionId
        let label = t("陌生号码", "Unknown")
        let phone = t("模拟测试", "Simulation")

        let recordingFileName = AudioService.shared.endConversationRecording()

        let summary = t("模拟通话已保存", "Simulation saved")
        let fullSummary = t("本次模拟通话的转写已保存到本地记录中。", "Transcript for this simulation has been saved locally.")

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
            isSimulation: true,
            languageRaw: language.rawValue,
            wsSessionId: wsSessionId,
            errorMessage: controller.lastErrorMessage
        )

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
        do {
            try modelContext.save()
        } catch {
            call.errorMessage = error.localizedDescription
        }
        if let sid = wsSessionId, !sid.isEmpty {
            ChatSummaryService.pollAndUpdate(callId: callId, sessionId: sid, modelContext: modelContext)
        } else {
            print("[Summary] skip poll: missing session_id")
        }

        onEnd(call)
    }

    private func logSimulationStartup(_ event: String, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print("[LAT][SimStartup] t=\(CallSessionController.logDateFormatter.string(from: Date())) event=\(event)\(suffix)")
    }
}

private struct SimulationStreamingBubble: View {
    @ObservedObject var state: TTSStreamingBubbleState
    let proxy: ScrollViewProxy

    @ViewBuilder
    var body: some View {
        if !state.text.isEmpty {
            HStack {
                StreamingTextBubble(
                    state: state,
                    uiFont: .systemFont(ofSize: 17, weight: .regular),
                    textColor: AppColors.textPrimary,
                    bubbleColor: Color.white.opacity(0.82),
                    cornerRadius: 18,
                    borderColor: Color.white.opacity(0.7),
                    borderWidth: 0.5,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    useGlassMaterial: true,
                    lineSpacing: 6
                )
                Spacer(minLength: UIScreen.main.bounds.width * 0.2)
            }
            .id("streaming-ai")
            .onChange(of: state.text) { _, _ in
                if !state.text.isEmpty {
                    withAnimation(AppAnimations.easeOut) {
                        proxy.scrollTo("streaming-ai", anchor: .center)
                    }
                }
            }
        }
    }
}

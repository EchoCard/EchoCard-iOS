//
//  LockScreenSimulationView.swift
//  CallMate
//
//  锁屏模拟界面 - 支持模拟对话和真实 WebSocket 对话
//

import SwiftUI

struct LockScreenSimulationView: View {
    let language: Language
    let onClose: () -> Void
    var useRealConnection: Bool = false

    @StateObject private var controller: CallSessionController

    init(language: Language, onClose: @escaping () -> Void, useRealConnection: Bool = false) {
        self.language = language
        self.onClose = onClose
        self.useRealConnection = useRealConnection
        _controller = StateObject(wrappedValue: CallSessionController(language: language))
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    struct LockMessage: Identifiable {
        let id: Int
        let text: String
        let type: String // "asr" | "tts"
    }

    @State private var messages: [LockMessage] = []
    @State private var nextMessageId = 100
    // Deferred content flag: show only the gradient during the slide-in transition,
    // then fade in the full UI after the animation completes to avoid jank.
    @State private var isContentReady = false

    private var initialText: String {
        t("正在为您接听通话...", "Screening call...")
    }

    private var displayMessages: [LockMessage] {
        if useRealConnection {
            var out: [LockMessage] = [LockMessage(id: 1, text: initialText, type: "tts")]
            for (idx, msg) in controller.messages.enumerated() {
                out.append(
                    LockMessage(
                        id: 1000 + idx,
                        text: msg.text,
                        type: msg.isAI ? "tts" : "asr"
                    )
                )
            }
            return out
        }
        return messages
    }

    var body: some View {
        ZStack {
            // Lightweight background rendered immediately during the slide-in animation.
            LinearGradient(colors: [AppColors.primary.opacity(0.6), AppColors.accent.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            // Heavy content deferred until after the transition animation completes.
            if isContentReady {
            VStack(spacing: 0) {
                HStack {
                    // 连接状态指示
                    if useRealConnection {
                        HStack(spacing: DS.Spacing.x1) {
                            Circle()
                                .fill(WebSocketService.shared.isConnected ? AppColors.success : AppColors.warning)
                                .frame(width: 8, height: 8)
                            Text(WebSocketService.shared.isConnected ? t("已连接", "Connected") : t("连接中", "Connecting"))
                                .font(DS.Typography.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, DS.Spacing.x1)
                        .padding(.vertical, AppSpacing.xxs)
                        .background(.black.opacity(0.3))
                        .clipShape(Capsule())
                        .padding(DS.Spacing.x2)
                    }
                    
                    Spacer()
                    
                    Button(action: handleClose) {
                        Image(systemName: "xmark")
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .padding(DS.Spacing.x2)
                }
                
                Spacer()
                
                Image(systemName: "lock.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.8))
                Text(timeString)
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(.white)
                Text(dateString)
                    .font(DS.Typography.body.weight(.semibold))
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, DS.Spacing.x4)
                
                VStack(spacing: DS.Spacing.x3) {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AppColors.primary)
                            .frame(width: 44, height: 44)
                            .background(AppColors.surface.opacity(0.5))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            HStack(spacing: AppSpacing.xs) {
                                Text(t("EchoCard 代接中", "EchoCard Screening"))
                                    .font(AppTypography.bodyEmphasized)
                                    .foregroundStyle(AppColors.textPrimary)
                                
                                if AudioService.shared.isRecording {
                                    Image(systemName: "waveform")
                                        .font(AppTypography.caption1)
                                        .foregroundStyle(AppColors.error)
                                        .symbolEffect(.variableColor.iterative)
                                } else if AudioService.shared.isPlaying {
                                    Image(systemName: "speaker.wave.2")
                                        .font(AppTypography.caption1)
                                        .foregroundStyle(AppColors.primary)
                                        .symbolEffect(.variableColor.iterative)
                                }
                            }
                            Text(t("陌生号码", "Unknown"))
                                .font(AppTypography.caption1)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        Spacer()
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(AppColors.success)
                                    .frame(width: 3, height: CGFloat([8, 16, 12][i]))
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.lg)
                    
                    // 简化的单行转写显示
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(displayMessages) { msg in
                                    Text(msg.text.isEmpty ? initialText : msg.text)
                                        .font(DS.Typography.body)
                                        .fontWeight(.medium)
                                        .foregroundStyle(msg.type == "tts" ? AppColors.primary : AppColors.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .id(msg.id)
                                }
                                if useRealConnection {
                                    LockStreamingTextRow(
                                        state: controller.ttsStreamingState,
                                        scrollProxy: proxy
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: displayMessages.count) { _, _ in
                            if let last = displayMessages.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(height: 32)
                    .padding(.horizontal, DS.Spacing.x2)
                    .padding(.bottom, DS.Spacing.x3)
                    
                    HStack(spacing: 24) {
                        // 挂断按钮
                        Button(action: handleClose) {
                            VStack(spacing: 6) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(AppColors.error)
                                    .clipShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        
                        // 接管通话按钮
                        Button { } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(AppColors.success)
                                    .clipShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DS.Spacing.x4)
                }
                .padding(DS.Spacing.x3)
                .background(.white.opacity(0.9))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .shadow(color: .black.opacity(0.2), radius: 20)
                .padding(.horizontal, DS.Spacing.x2)
                
                Spacer()
                
                HStack(spacing: 80) {
                    Image(systemName: "flashlight.on.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                    Image(systemName: "camera.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .padding(.bottom, 48)
            }
            .transition(.opacity)
            } // end if isContentReady
        }
        // Use .task (auto-cancelled on disappear) to defer all initialization until
        // after the 250ms slide-in animation completes, keeping that animation smooth.
        .task {
            try? await Task.sleep(nanoseconds: 280_000_000) // just after 250ms animation
            withAnimation(.easeIn(duration: 0.15)) {
                isContentReady = true
            }
            if useRealConnection {
                CallToneService.shared.startWaitingTone()
                controller.start()
            } else {
                messages = [LockMessage(id: 1, text: initialText, type: "tts")]
                runSimulation()
            }
        }
        .onDisappear {
            if useRealConnection {
                CallToneService.shared.stopWaitingTone()
                controller.end()
            }
        }
        .onChange(of: controller.status) { _, newStatus in
            if useRealConnection {
                switch newStatus {
                case .connecting, .ringing:
                    CallToneService.shared.startWaitingTone()
                case .connected:
                    CallToneService.shared.stopWaitingTone()
                    CallToneService.shared.playConnectedTone()
                case .ended:
                    CallToneService.shared.stopWaitingTone()
                }
            }
            // AI 主动挂断时自动关闭页面
            if useRealConnection && newStatus == .ended && controller.isAIHangup {
                onClose()
            }
        }
    }
    
    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
    
    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = language == .zh ? "M月d日 EEEE" : "EEE, MMM d"
        f.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        return f.string(from: Date())
    }
    
    // MARK: - 模拟模式
    
    private func runSimulation() {
        let items: [(String, String, Double)] = language == .zh ? [
            ("您好，我是送外卖的，到楼下了。", "asr", 2),
            ("好的，请直接放在门口的鞋柜上，谢谢。", "tts", 4),
            ("门口鞋柜是吧？好的。", "asr", 6.5),
            ("对的，放那里就行。", "tts", 8.5),
            ("行，那我挂了。", "asr", 10)
        ] : [
            ("Hello, delivery here. I'm downstairs.", "asr", 2),
            ("Okay, please leave it on the shoe cabinet at the door.", "tts", 4),
            ("Shoe cabinet, right? Okay.", "asr", 6.5),
            ("Yes, that's correct.", "tts", 8.5),
            ("Okay, bye.", "asr", 10)
        ]
        for (i, item) in items.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + item.2) {
                messages.append(LockMessage(id: 100 + i, text: item.0, type: item.1))
            }
        }
    }
    
    // MARK: - 真实 WebSocket 连接
    private func handleClose() {
        if useRealConnection {
            controller.end()
        }
        onClose()
    }
}

// MARK: - 流式逐字行（锁屏）
private struct LockStreamingTextRow: View {
    @ObservedObject var state: TTSStreamingBubbleState
    let scrollProxy: ScrollViewProxy

    @ViewBuilder
    var body: some View {
        if !state.text.isEmpty {
            Text(state.text)
                .font(DS.Typography.body)
                .fontWeight(.medium)
                .foregroundStyle(AppColors.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .id("lock-streaming")
                .onChange(of: state.text) { _, _ in
                    withAnimation {
                        scrollProxy.scrollTo("lock-streaming", anchor: .bottom)
                    }
                }
        }
    }
}

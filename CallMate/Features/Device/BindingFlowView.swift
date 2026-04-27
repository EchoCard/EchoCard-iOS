//
//  BindingFlowView.swift
//  CallMate
//

import SwiftUI
import AVFoundation
import AVKit
import CoreBluetooth
import Combine

struct BindingFlowView: View {
    let state: AppState
    let language: Language
    let onStateChange: (AppState) -> Void

    @AppStorage("callmate.show_after_factory_reset_bluetooth_tip") private var pendingBluetoothTip = false
    @State private var showAfterFactoryResetBluetoothTipAlert = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        Group {
            if state == .landing { landingView }
            else if state == .scanning { scanningView }
            else if state == .bound { boundView }
        }
        .animation(.easeInOut(duration: 0.4), value: state)
        .onAppear {
            if pendingBluetoothTip {
                showAfterFactoryResetBluetoothTipAlert = true
            }
        }
        .sheet(isPresented: $showAfterFactoryResetBluetoothTipAlert) {
            AfterFactoryResetBluetoothTipSheet(language: language) {
                showAfterFactoryResetBluetoothTipAlert = false
                pendingBluetoothTip = false
                UserDefaults.standard.set(false, forKey: "callmate.show_after_factory_reset_bluetooth_tip")
            }
        }
    }

    // MARK: - Landing
    private var landingView: some View {
        LandingContentView(language: language, onBind: { onStateChange(.scanning) }, onSkip: { onStateChange(.main) })
    }

    // MARK: - Scanning
    private var scanningView: some View {
        ScanningBindingView(language: language, onBack: { onStateChange(.landing) }, onBound: { onStateChange(.bound) })
    }

    // MARK: - Bound
    private var boundView: some View {
        BoundContentView(language: language, onContinue: { useDeviceStrategy in
            if useDeviceStrategy {
                onStateChange(.main)
            } else {
                onStateChange(.onboarding)
            }
        })
    }
}

// MARK: - After Factory Reset Bluetooth Tip (video sheet)
private struct AfterFactoryResetBluetoothTipSheet: View {
    let language: Language
    let onDismiss: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var videoURL: URL? {
        Bundle.main.url(forResource: "IgnoreBluetoothDevice", withExtension: "mp4", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: "IgnoreBluetoothDevice", withExtension: "mp4")
    }

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Success Icon
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(hex: "34C759"))
                    .padding(.top, 40)
                    .padding(.bottom, 16)

                // Title
                Text(t("恢复出厂完成", "Factory Reset Complete"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                // Video
                if let url = videoURL {
                    if let p = player {
                        VideoPlayer(player: p)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                            .padding(.horizontal, 20)
                            .onAppear { p.play() }
                    } else {
                        Color(lightHex: "F2F2F7", darkHex: "1C1C1E")
                            .frame(height: 300)
                            .overlay(ProgressView())
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                            .padding(.horizontal, 20)
                            .onAppear {
                                let item = AVPlayerItem(url: url)
                                let queuePlayer = AVQueuePlayer(playerItem: item)
                                let loop = AVPlayerLooper(player: queuePlayer, templateItem: item)
                                player = queuePlayer
                                looper = loop
                                queuePlayer.play()
                            }
                    }
                } else {
                    Text(t("视频加载失败", "Video unavailable"))
                        .font(.system(size: 15))
                        .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        .frame(height: 120)
                }

                // Tip Card
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(hex: "007AFF"))
                        .padding(.top, 2)

                    Text(t(
                        "请在手机设置的蓝牙列表里，忽略已连接的 EchoCard 设备。",
                        "Please go to your phone's Bluetooth settings and forget the connected EchoCard device."
                    ))
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "007AFF").opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)

                // CTA Button
                Button(action: onDismiss) {
                    Text(t("我知道了", "Got It"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "007AFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 10, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }
}

// MARK: - Bound Content (with animations)
private struct BoundContentView: View {
    let language: Language
    let onContinue: (Bool) -> Void

    @ObservedObject private var ble = CallMateBLEClient.shared
    @State private var iconAppear = false
    @State private var contentAppear = false
    @State private var cardsAppear = false
    @State private var showStrategySheet = false
    @Environment(\.colorScheme) private var colorScheme

    private var hasDeviceStrategy: Bool { ble.pendingDeviceStrategy != nil }
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color(hex: "F5F5F5"))
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Bot icon with checkmark badge
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 26)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "007AFF"), Color(hex: "5856D6")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 88, height: 88)
                            .shadow(color: Color(hex: "007AFF").opacity(0.3), radius: 16, x: 0, y: 12)
                            .overlay(
                                BoundBotIconView()
                                    .frame(width: 44, height: 44)
                            )

                        ZStack {
                            Circle()
                                .fill(Color(hex: "34C759"))
                                .frame(width: 32, height: 32)
                                .shadow(color: Color(hex: "34C759").opacity(0.4), radius: 6, x: 0, y: 4)

                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(
                            Circle()
                                .stroke(colorScheme == .dark ? .black : Color(hex: "F5F5F5"), lineWidth: 3)
                        )
                        .offset(x: 6, y: 6)
                    }
                    .padding(.top, 100)
                    .opacity(iconAppear ? 1 : 0)
                    .scaleEffect(iconAppear ? 1 : 0.5)

                    // Title
                    Text(t("AI 分身已就绪", "AI Agent Ready"))
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(.top, 16)
                        .opacity(contentAppear ? 1 : 0)
                        .offset(y: contentAppear ? 0 : 10)

                    // Status pills
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: "34C759"))
                                .frame(width: 6, height: 6)
                            Text(t("EchoCard 已连接", "EchoCard Connected"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(hex: "34C759"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "34C759").opacity(0.1))
                        .clipShape(Capsule())

                        Text(t("实习期", "Intern"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(lightHex: "4B5563", darkHex: "D1D5DB"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(lightHex: "F3F4F6", darkHex: "2C2C2E"))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color(lightHex: "E5E7EB", darkHex: "4B5563").opacity(0.6), lineWidth: 1)
                            )
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .opacity(contentAppear ? 1 : 0)
                    .offset(y: contentAppear ? 0 : 10)

                    // Feature grid 2x2
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ], spacing: 10) {
                        featureCard(
                            icon: "phone.fill",
                            iconColor: Color(hex: "007AFF"),
                            title: t("分身代接", "Auto Answer"),
                            desc: t("自动应答营销骚扰\n智能过滤无效来电", "Auto-answer spam calls\nSmart filtering")
                        )
                        featureCard(
                            icon: "shield.fill",
                            iconColor: Color(hex: "FF9500"),
                            title: t("重要来电", "Important Calls"),
                            desc: t("智能识别重要电话\n第一时间通知你", "Smart detection\nInstant notification")
                        )
                        featureCard(
                            icon: "graduationcap.fill",
                            iconColor: Color(hex: "AF52DE"),
                            title: t("指导学习", "Guided Learning"),
                            desc: t("指导越多越懂你\n持续优化处理策略", "More guidance, smarter\nContinuous optimization")
                        )
                        featureCard(
                            icon: "medal.fill",
                            iconColor: Color(hex: "FF2D55"),
                            title: t("转正条件", "Graduation"),
                            desc: t("实习满 3 个月\n满意评价后可转正", "3 months internship\nGood ratings to graduate")
                        )
                    }
                    .padding(.horizontal, 20)
                    .opacity(cardsAppear ? 1 : 0)
                    .offset(y: cardsAppear ? 0 : 20)

                    // Bottom hint
                    Text(t("AI 分身也需要你纠正学习，逐步提升\n来电识别准确度，为你提供更智能的服务",
                           "Your AI agent also needs your corrections to\nimprove accuracy and provide smarter service"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 120)
                        .opacity(cardsAppear ? 1 : 0)
                }
            }

            // Floating bottom button
            VStack {
                Spacer()
                ZStack {
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.clear, .black.opacity(0.9), .black]
                            : [.clear, Color(hex: "F5F5F5").opacity(0.9), Color(hex: "F5F5F5")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    .allowsHitTesting(false)

                    Button {
                        if hasDeviceStrategy {
                            showStrategySheet = true
                        } else {
                            onContinue(false)
                        }
                    } label: {
                        Text(t("开始体验", "Get Started"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(hex: "007AFF"))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color(hex: "007AFF").opacity(0.25), radius: 10, x: 0, y: 8)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                    .opacity(cardsAppear ? 1 : 0)
                    .offset(y: cardsAppear ? 0 : 20)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .sheet(isPresented: $showStrategySheet) {
            StrategyChoiceSheet(language: language, ble: ble, onContinue: { useDeviceStrategy in
                showStrategySheet = false
                onContinue(useDeviceStrategy)
            })
            .interactiveDismissDisabled()
        }
        .onChange(of: ble.pendingDeviceStrategy) { _, strategy in
            if strategy != nil, cardsAppear {
                showStrategySheet = true
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1)) {
                iconAppear = true
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                contentAppear = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.5)) {
                cardsAppear = true
            }
        }
    }

    private func featureCard(icon: String, iconColor: Color, title: String, desc: String) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 10)
                .fill(iconColor.opacity(0.1))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(iconColor)
                )
                .padding(.bottom, 8)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.bottom, 8)

            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(16)
        .background(colorScheme == .dark ? Color(hex: "1C1C1E") : .white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(lightHex: "F3F4F6", darkHex: "374151").opacity(0.8), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Bot Icon for Bound Page

private struct BoundBotIconView: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 24.0
            let stroke = StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round)

            var antenna = Path()
            antenna.move(to: CGPoint(x: 12 * s, y: 8 * s))
            antenna.addLine(to: CGPoint(x: 12 * s, y: 4 * s))
            antenna.addLine(to: CGPoint(x: 8 * s, y: 4 * s))
            context.stroke(antenna, with: .color(.white), style: stroke)

            let bodyRect = CGRect(x: 4 * s, y: 8 * s, width: 16 * s, height: 12 * s)
            var body = Path()
            body.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: 2 * s, height: 2 * s))
            context.stroke(body, with: .color(.white), style: stroke)

            var leftArm = Path()
            leftArm.move(to: CGPoint(x: 2 * s, y: 14 * s))
            leftArm.addLine(to: CGPoint(x: 4 * s, y: 14 * s))
            context.stroke(leftArm, with: .color(.white), style: stroke)

            var rightArm = Path()
            rightArm.move(to: CGPoint(x: 20 * s, y: 14 * s))
            rightArm.addLine(to: CGPoint(x: 22 * s, y: 14 * s))
            context.stroke(rightArm, with: .color(.white), style: stroke)

            var leftEye = Path()
            leftEye.move(to: CGPoint(x: 9 * s, y: 13 * s))
            leftEye.addLine(to: CGPoint(x: 9 * s, y: 15 * s))
            context.stroke(leftEye, with: .color(.white), style: stroke)

            var rightEye = Path()
            rightEye.move(to: CGPoint(x: 15 * s, y: 13 * s))
            rightEye.addLine(to: CGPoint(x: 15 * s, y: 15 * s))
            context.stroke(rightEye, with: .color(.white), style: stroke)
        }
    }
}

// MARK: - Strategy Choice Sheet
private struct StrategyChoiceSheet: View {
    let language: Language
    let ble: CallMateBLEClient
    let onContinue: (Bool) -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, DS.Spacing.x2)
                .padding(.bottom, DS.Spacing.x3)

            // Icon
            ZStack {
                Circle()
                    .fill(AppColors.primary.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 28))
                    .foregroundStyle(AppColors.primary)
            }
            .padding(.bottom, DS.Spacing.x2)

            // Title & description
            Text(t("检测到已有代接策略", "Existing Strategy Found"))
                .font(DS.Typography.title.weight(.bold))
                .multilineTextAlignment(.center)

            Text(t("该设备上已保存了一套代接策略，您可以直接沿用，也可以通过 AI 向导重新配置。", "This device already has a saved strategy. You can keep it or set up a new one with the AI wizard."))
                .font(DS.Typography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, DS.Spacing.x1)
                .padding(.horizontal, DS.Spacing.x3)

            // Options
            VStack(spacing: DS.Spacing.x2) {
                // Primary: use device strategy
                Button {
                    ble.adoptDeviceStrategy()
                    onContinue(true)
                } label: {
                    HStack(spacing: DS.Spacing.x2) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("使用设备已有策略", "Use Device Strategy"))
                                .font(DS.Typography.body.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(t("直接沿用，快速进入主界面", "Keep existing setup, go straight to home"))
                                .font(DS.Typography.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(DS.Spacing.x2)
                    .background(AppColors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .shadow(color: AppColors.primary.opacity(0.3), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())

                // Secondary: reconfigure with AI wizard (discard MCU strategy, reset to iOS defaults)
                Button {
                    ble.clearPendingDeviceStrategy()
                    ProcessStrategyStore.resetToDefault()
                    onContinue(false)
                } label: {
                    HStack(spacing: DS.Spacing.x2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 22))
                            .foregroundStyle(AppColors.textPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("重新配置 AI 向导", "Configure with AI Wizard"))
                                .font(DS.Typography.body.weight(.medium))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(t("放弃设备策略，从默认配置重新训练", "Discard device strategy and start from defaults"))
                                .font(DS.Typography.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(DS.Spacing.x2)
                    .background(AppColors.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(AppColors.border, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .padding(.horizontal, DS.Spacing.x3)
            .padding(.top, DS.Spacing.x3)
            .padding(.bottom, DS.Spacing.x4)
        }
        .presentationDetents([.height(420)])
        .presentationCornerRadius(24)
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - Landing (with animations)
private struct LandingContentView: View {
    let language: Language
    let onBind: () -> Void
    let onSkip: () -> Void

    @State private var floatPhase = false
    @State private var appearAnimation = false
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(hex: "0A0C10"), .black]
                    : [Color(hex: "F4F7FC"), .white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onSkip) {
                        Text(t("跳过", "Skip"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "D1D5DB"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                VStack(spacing: 0) {
                    illustrationView
                        .padding(.bottom, 40)
                        .opacity(appearAnimation ? 1 : 0)
                        .offset(y: appearAnimation ? 0 : 20)

                    Text(t("EchoCard · AI代接卡", "EchoCard · AI Call Agent"))
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 12)
                        .opacity(appearAnimation ? 1 : 0)
                        .offset(y: appearAnimation ? 0 : 10)

                    Text(t("陌生来电我处理，重要电话提醒你", "Strangers handled by AI, important calls reach you"))
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "8E8E93"))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 16)
                        .opacity(appearAnimation ? 1 : 0)
                        .offset(y: appearAnimation ? 0 : 10)
                }
                .padding(.top, 80)

                Spacer()

                VStack(spacing: 16) {
                    Button(action: onBind) {
                        Text(t("绑定设备", "Bind Device"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(hex: "007AFF"))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(
                                color: Color(hex: "007AFF").opacity(0.25),
                                radius: 10, x: 0, y: 8
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .opacity(appearAnimation ? 1 : 0)
                    .offset(y: appearAnimation ? 0 : 20)

                    Text(t("请确保设备已开机并开启蓝牙", "Ensure device is on & Bluetooth active"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                        .opacity(appearAnimation ? 1 : 0)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                appearAnimation = true
            }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                floatPhase = true
            }
        }
    }

    private var illustrationView: some View {
        ZStack {
            Circle()
                .fill(Color(lightHex: "F4F8FF", darkHex: "1A253C"))
                .frame(width: 200, height: 200)

            Circle()
                .fill(Color(lightHex: "E5EFFF", darkHex: "23355A"))
                .frame(width: 140, height: 140)

            Circle()
                .fill(colorScheme == .dark ? Color(hex: "2C2C2E") : .white)
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 8)
                .offset(x: -64, y: -49)
                .offset(y: floatPhase ? -8 : 8)

            Circle()
                .fill(colorScheme == .dark ? Color(hex: "2C2C2E") : .white)
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 8)
                .offset(x: 56, y: 51)
                .offset(y: floatPhase ? 10 : -6)

            PhoneDeviceIconView()
                .frame(width: 48, height: 84)

            LightningIconView()
                .offset(x: -99, y: -70)
                .offset(y: floatPhase ? -12 : 6)

            ShieldCheckIconView()
                .offset(x: 96, y: 82)
                .offset(y: floatPhase ? 8 : -6)
        }
        .frame(width: 240, height: 240)
    }
}

// MARK: - Custom SVG Icons for Landing

private struct PhoneDeviceIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Canvas { context, size in
            let s = size.width / 48.0
            let bodyRect = CGRect(x: 3 * s, y: 3 * s, width: 42 * s, height: 78 * s)
            var bodyPath = Path()
            bodyPath.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: 10 * s, height: 10 * s))
            context.fill(bodyPath, with: .color(colorScheme == .dark ? Color(hex: "4A5568") : Color(hex: "A8B4CB")))
            context.stroke(bodyPath, with: .color(colorScheme == .dark ? .white : .black),
                           style: StrokeStyle(lineWidth: 4.5 * s, lineJoin: .round))

            let notchRect = CGRect(x: 18 * s, y: 12 * s, width: 12 * s, height: 4.5 * s)
            var notchPath = Path()
            notchPath.addRoundedRect(in: notchRect, cornerSize: CGSize(width: 2.25 * s, height: 2.25 * s))
            context.fill(notchPath, with: .color(colorScheme == .dark ? .white : .black))

            let barRect = CGRect(x: 16.5 * s, y: 67.5 * s, width: 15 * s, height: 3 * s)
            var barPath = Path()
            barPath.addRoundedRect(in: barRect, cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
            context.fill(barPath, with: .color(colorScheme == .dark ? .white : .black))
        }
    }
}

private struct LightningIconView: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 24.0
            let sy = size.height / 36.0
            var path = Path()
            path.move(to: CGPoint(x: 12.5 * sx, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 20 * sy))
            path.addLine(to: CGPoint(x: 10.5 * sx, y: 20 * sy))
            path.addLine(to: CGPoint(x: 8.5 * sx, y: 36 * sy))
            path.addLine(to: CGPoint(x: 24 * sx, y: 14 * sy))
            path.addLine(to: CGPoint(x: 12.5 * sx, y: 14 * sy))
            path.closeSubpath()
            context.fill(path, with: .color(Color(hex: "3B82F6")))
        }
        .frame(width: 18, height: 27)
    }
}

private struct ShieldCheckIconView: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 32.0
            let sy = size.height / 38.0
            var shield = Path()
            shield.move(to: CGPoint(x: 16 * sx, y: 0))
            shield.addLine(to: CGPoint(x: 32 * sx, y: 7.5 * sy))
            shield.addLine(to: CGPoint(x: 32 * sx, y: 16.5 * sy))
            shield.addCurve(to: CGPoint(x: 16 * sx, y: 38 * sy),
                            control1: CGPoint(x: 32 * sx, y: 26.5 * sy),
                            control2: CGPoint(x: 25.5 * sx, y: 35 * sy))
            shield.addCurve(to: CGPoint(x: 0, y: 16.5 * sy),
                            control1: CGPoint(x: 6.5 * sx, y: 35 * sy),
                            control2: CGPoint(x: 0, y: 26.5 * sy))
            shield.addLine(to: CGPoint(x: 0, y: 7.5 * sy))
            shield.closeSubpath()
            context.fill(shield, with: .color(Color(hex: "4ADE80")))

            var check = Path()
            check.move(to: CGPoint(x: 9 * sx, y: 19 * sy))
            check.addLine(to: CGPoint(x: 14 * sx, y: 24 * sy))
            check.addLine(to: CGPoint(x: 23 * sx, y: 14 * sy))
            context.stroke(check, with: .color(.white),
                           style: StrokeStyle(lineWidth: 3.5 * sx, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 28)
    }
}

// Custom button style with scale effect
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Scanning (with auto transition)
private struct ScanningBindingView: View {
    let language: Language
    let onBack: () -> Void
    let onBound: () -> Void

    @State private var cardAppear = false
    @State private var showPairingRemovedToast = false
    @State private var pairingToastWorkItem: DispatchWorkItem?
    @State private var showConnectTimeoutToast = false
    @State private var connectTimeoutToastWorkItem: DispatchWorkItem?
    @ObservedObject private var scanner = CallMateBLEClient.shared
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var pairingRemovedToastMessage: String {
        t(
            "配对信息已失效。请打开「设置」→「蓝牙」，找到该设备，点击 ⓘ →「忽略此设备」，然后重新连接。",
            "Pairing info is invalid. Go to Settings → Bluetooth, tap ⓘ next to the device, choose \"Forget This Device\", then reconnect."
        )
    }

    private var isPairingRemovedError: Bool {
        guard let err = scanner.lastError, !err.isEmpty else { return false }
        return err.lowercased().contains("pairing") && err.lowercased().contains("removed")
            || err.contains("移除") && (err.contains("配对") || err.contains("配对信息"))
    }

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color(hex: "111111") : Color.white)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Radar illustration + status text
                VStack(spacing: 0) {
                    if isConnectedState {
                        successIllustration
                            .padding(.bottom, 20)

                        Text(t("连接完成，即将进入设置...", "Connected, entering setup..."))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color(hex: "34C759"))
                            .tracking(0.5)
                    } else {
                        radarIllustration
                            .padding(.bottom, 20)

                        Text(scanningStatusTitle)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color(hex: "007AFF"))
                            .tracking(0.5)
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 20)
                .animation(.easeInOut(duration: 0.4), value: isConnectedState)

                // Device list / BT error section
                VStack(alignment: .leading, spacing: 0) {
                    if scanner.bluetoothState != .poweredOn {
                        bluetoothOffSection
                    } else {
                        Text(t("以下为搜索到的 EchoCard 设备：", "Discovered EchoCard devices:"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                            .padding(.horizontal, 4)
                            .padding(.bottom, 12)

                        ScrollView {
                            VStack(spacing: 12) {
                                if scanner.devices.isEmpty && !isConnectedState {
                                    emptyDeviceCard
                                } else {
                                    ForEach(scanner.devices) { device in
                                        let isThisConnected = scanner.connectedPeripheralID == device.id
                                        Button {
                                            scanner.connect(to: device)
                                        } label: {
                                            deviceRow(device)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isConnectedState || (scanner.connectingPeripheralID != nil && scanner.connectingPeripheralID != device.id))
                                        .opacity(isConnectedState && !isThisConnected ? 0.4 : 1.0)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
                .padding(.horizontal, 24)
                .opacity(cardAppear ? 1 : 0)
                .offset(y: cardAppear ? 0 : 20)

                Spacer()
            }

            // Toast overlays
            if showPairingRemovedToast {
                toastOverlay(message: pairingRemovedToastMessage)
            }
            if showConnectTimeoutToast {
                toastOverlay(message: t(
                    "连接超时。若该设备曾与此手机配对，请打开「设置」→「蓝牙」→「忽略此设备」，然后重新连接。",
                    "Connection timed out. If previously paired, go to Settings → Bluetooth → Forget This Device, then retry."
                ))
            }
        }
        .onAppear {
            print("[Toast] ScanningView.onAppear: lastError=\(scanner.lastError ?? "nil") isPairingRemovedError=\(isPairingRemovedError)")
            if scanner.isReady {
                print("[BLE] ScanningView.onAppear: already ready, delaying 5s before bound")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard scanner.isReady else { return }
                    onBound()
                }
                return
            }

            if isPairingRemovedError {
                print("[Toast] onAppear: pairing error already set, showing toast immediately")
                pairingToastWorkItem?.cancel()
                showPairingRemovedToast = true
                let work = DispatchWorkItem { withAnimation { showPairingRemovedToast = false } }
                pairingToastWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }

            scanner.setBindingScanModeEnabled(true)

            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.3)) {
                cardAppear = true
            }

            scanner.autoConnectIfPossible()
            scanner.startScanning()
        }
        .onDisappear {
            scanner.setBindingScanModeEnabled(false)
        }
        .onChange(of: scanner.isReady) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard scanner.isReady else { return }
                    onBound()
                }
            }
        }
        .onChange(of: scanner.lastError) { _, newValue in
            print("[Toast] onChange lastError: \(newValue ?? "nil")")
            guard let err = newValue, !err.isEmpty else { return }
            let isPairing = (err.lowercased().contains("pairing") && err.lowercased().contains("removed"))
                || (err.contains("移除") && (err.contains("配对") || err.contains("配对信息")))
            print("[Toast] isPairing=\(isPairing) err=\(err)")
            guard isPairing else { return }
            pairingToastWorkItem?.cancel()
            withAnimation { showPairingRemovedToast = true }
            let work = DispatchWorkItem { withAnimation { showPairingRemovedToast = false } }
            pairingToastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
        .onChange(of: scanner.manualConnectTimeoutCount) { _, _ in
            connectTimeoutToastWorkItem?.cancel()
            withAnimation { showConnectTimeoutToast = true }
            let work = DispatchWorkItem { withAnimation { showConnectTimeoutToast = false } }
            connectTimeoutToastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private var isConnectedState: Bool {
        scanner.connectedPeripheralID != nil && scanner.isReady
    }

    // MARK: - Success Illustration (green checkmark with ripple)

    private var successIllustration: some View {
        ZStack {
            SuccessPulseView()

            Circle()
                .fill(Color(hex: "34C759"))
                .frame(width: 80, height: 80)
                .shadow(color: Color(hex: "34C759").opacity(0.3), radius: 20, x: 0, y: 8)

            Image(systemName: "checkmark")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 200, height: 200)
    }

    // MARK: - Radar Illustration

    private var radarIllustration: some View {
        ZStack {
            RadarPulseView()

            RadarSweepView()
                .frame(width: 200, height: 200)
                .clipShape(Circle())

            Circle()
                .fill(Color(hex: "007AFF"))
                .frame(width: 80, height: 80)
                .shadow(color: Color(hex: "007AFF").opacity(0.3), radius: 20, x: 0, y: 8)

            Canvas { context, size in
                let sx = size.width / 24.0
                let sy = size.height / 40.0
                var rect = Path()
                rect.addRoundedRect(
                    in: CGRect(x: 1.5 * sx, y: 1.5 * sy, width: 21 * sx, height: 37 * sy),
                    cornerSize: CGSize(width: 4.5 * sx, height: 4.5 * sy)
                )
                context.stroke(rect, with: .color(.white),
                               style: StrokeStyle(lineWidth: 2.5 * sx, lineJoin: .round))

                var bar = Path()
                bar.move(to: CGPoint(x: 9 * sx, y: 34 * sy))
                bar.addLine(to: CGPoint(x: 15 * sx, y: 34 * sy))
                context.stroke(bar, with: .color(.white),
                               style: StrokeStyle(lineWidth: 2.5 * sx, lineCap: .round))
            }
            .frame(width: 24, height: 40)
        }
        .frame(width: 200, height: 200)
    }

    private var scanningStatusTitle: String {
        if scanner.bluetoothState == .poweredOff || scanner.bluetoothState == .unauthorized {
            return t("等待开启蓝牙或授权...", "Waiting for Bluetooth...")
        } else if scanner.bluetoothState != .poweredOn {
            return t("正在准备...", "Preparing...")
        } else {
            return t("正在搜索设备...", "Searching for devices...")
        }
    }

    // MARK: - Empty Device Card

    private var emptyDeviceCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color(lightHex: "F9FAFB", darkHex: "1F2937"))
                    .frame(width: 48, height: 48)

                RadioIconView(size: 24, color: Color(lightHex: "D1D5DB", darkHex: "4B5563"))
            }
            .padding(.bottom, 12)

            Text(t("暂未发现附近设备", "No nearby devices found"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.bottom, 4)

            Text(t("请确保设备已开机并靠近手机", "Make sure the device is on and nearby"))
                .font(.system(size: 13))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(colorScheme == .dark ? Color(hex: "1C1C1E") : .white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(lightHex: "F3F4F6", darkHex: "374151"), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - Bluetooth Off Section

    private var bluetoothOffSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textPrimary)
                Text(t("蓝牙无法连接搜索设备", "Bluetooth cannot connect to scan"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                btStepRow(
                    number: "1",
                    title: t("开启系统蓝牙", "Enable System Bluetooth"),
                    subtitle: t("下滑打开控制中心开启，或前往「设置」>「蓝牙」开启", "Swipe down for Control Center, or go to Settings > Bluetooth"),
                    actionLabel: t("去开启", "Enable"),
                    action: { openBluetoothSettings() }
                )

                stepDivider

                btStepRow(
                    number: "2",
                    title: t("允许 App 访问蓝牙", "Allow App Bluetooth Access"),
                    subtitle: t("前往「设置」>「隐私与安全性」>「蓝牙」，确认本 App 已授权", "Go to Settings > Privacy > Bluetooth, ensure this app is authorized"),
                    actionLabel: t("去授权", "Authorize"),
                    action: { openAppSettings() }
                )

                stepDivider

                btStepRow(
                    number: "3",
                    title: t("重启 App", "Restart App"),
                    subtitle: t("蓝牙已开启并授权还无法识别，可先关闭 App 再重新打开试试", "If Bluetooth is on and authorized but still not working, try restarting the app"),
                    actionLabel: nil,
                    action: nil
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .background(colorScheme == .dark ? Color(hex: "1C1C1E") : .white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(lightHex: "F3F4F6", darkHex: "374151"), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        }
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(Color(lightHex: "F3F4F6", darkHex: "2C2C2E"))
            .frame(height: 1)
            .padding(.leading, 32)
    }

    private func btStepRow(number: String, title: String, subtitle: String, actionLabel: String?, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hex: "007AFF"))
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer()

                    if let label = actionLabel, let act = action {
                        Button(action: act) {
                            Text(label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(hex: "007AFF"))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color(hex: "007AFF").opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 16)
    }

    private func openBluetoothSettings() {
        if let url = URL(string: "App-Prefs:") {
            UIApplication.shared.open(url)
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Device Row

    private func deviceRow(_ device: CallMateBLEClient.DiscoveredDevice) -> some View {
        let isConnecting = scanner.connectingPeripheralID == device.id
        let isConnected = scanner.connectedPeripheralID == device.id
        let isFullyConnected = isConnected && scanner.isReady

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isFullyConnected
                          ? Color(hex: "34C759").opacity(0.1)
                          : Color(lightHex: "F9FAFB", darkHex: "1F2937"))
                    .frame(width: 44, height: 44)

                RadioIconView(size: 22, color: isFullyConnected
                              ? Color(hex: "34C759")
                              : Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text("ID: \(device.id.uuidString.prefix(8).uppercased())")
                    Text("RSSI: \(device.rssi)")
                }
                .font(.system(size: 12))
                .fontDesign(.monospaced)
                .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                .lineLimit(1)
            }

            Spacer()

            if isFullyConnected {
                ZStack {
                    Circle()
                        .fill(Color(hex: "34C759"))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
            } else if isConnected || isConnecting {
                ProgressView().tint(Color(hex: "007AFF"))
            } else {
                Text(t("连接", "Connect"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "007AFF"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "007AFF").opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(colorScheme == .dark ? Color(hex: "1C1C1E") : .white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isFullyConnected
                        ? Color(hex: "34C759").opacity(colorScheme == .dark ? 0.2 : 0.3)
                        : Color(lightHex: "F3F4F6", darkHex: "374151"),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - Toast

    private func toastOverlay(message: String) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(16)
                    .frame(maxWidth: 280)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            )
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - Success Pulse (green ripple)

private struct SuccessPulseView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            successCircle(delay: 0)
            successCircle(delay: 1.0)
            successCircle(delay: 2.0)
        }
        .onAppear { isAnimating = true }
    }

    private func successCircle(delay: Double) -> some View {
        Circle()
            .fill(Color(hex: "34C759"))
            .frame(width: 80, height: 80)
            .scaleEffect(isAnimating ? 2.8 : 0.8)
            .opacity(isAnimating ? 0 : 0.3)
            .animation(
                .easeOut(duration: 3.0)
                .repeatForever(autoreverses: false)
                .delay(delay),
                value: isAnimating
            )
    }
}

// MARK: - Radar Sweep (single sector)

private struct RadarSweepView: View {
    @State private var rotation: Double = 0

    var body: some View {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color(hex: "007AFF").opacity(0.22), location: 0.0),
                .init(color: Color(hex: "007AFF").opacity(0.10), location: 0.05),
                .init(color: Color(hex: "007AFF").opacity(0.03), location: 0.10),
                .init(color: .clear, location: 0.14),
                .init(color: .clear, location: 1.0),
            ]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Radar Pulse (background ripple)

private struct RadarPulseView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "007AFF").opacity(0.06))
                .frame(width: 80 * 2.5, height: 80 * 2.5)

            pulseCircle(delay: 0)
            pulseCircle(delay: 1.0)
            pulseCircle(delay: 2.0)
        }
        .onAppear {
            isAnimating = true
        }
    }

    private func pulseCircle(delay: Double) -> some View {
        Circle()
            .fill(Color(hex: "007AFF"))
            .frame(width: 80, height: 80)
            .scaleEffect(isAnimating ? 2.8 : 0.8)
            .opacity(isAnimating ? 0 : 0.3)
            .animation(
                .easeOut(duration: 3.0)
                .repeatForever(autoreverses: false)
                .delay(delay),
                value: isAnimating
            )
    }
}

// MARK: - Radio Icon (Lucide)

private struct RadioIconView: View {
    var size: CGFloat = 24
    var color: Color = .gray

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 24.0

            let strokeStyle = StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round)

            var arc1 = Path()
            arc1.addArc(center: CGPoint(x: 12 * s, y: 12 * s), radius: 6 * s,
                        startAngle: .degrees(-60), endAngle: .degrees(60), clockwise: false)
            context.stroke(arc1, with: .color(color), style: strokeStyle)

            var arc2 = Path()
            arc2.addArc(center: CGPoint(x: 12 * s, y: 12 * s), radius: 10 * s,
                        startAngle: .degrees(-65), endAngle: .degrees(65), clockwise: false)
            context.stroke(arc2, with: .color(color), style: strokeStyle)

            var arc3 = Path()
            arc3.addArc(center: CGPoint(x: 12 * s, y: 12 * s), radius: 6 * s,
                        startAngle: .degrees(120), endAngle: .degrees(240), clockwise: false)
            context.stroke(arc3, with: .color(color), style: strokeStyle)

            var arc4 = Path()
            arc4.addArc(center: CGPoint(x: 12 * s, y: 12 * s), radius: 10 * s,
                        startAngle: .degrees(115), endAngle: .degrees(245), clockwise: false)
            context.stroke(arc4, with: .color(color), style: strokeStyle)

            var dot = Path()
            dot.addEllipse(in: CGRect(x: 10 * s, y: 10 * s, width: 4 * s, height: 4 * s))
            context.fill(dot, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

#Preview("Landing") {
    BindingFlowView(state: .landing, language: .zh) { _ in }
}

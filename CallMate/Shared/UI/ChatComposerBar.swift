//
//  ChatComposerBar.swift
//  CallMate
//

import SwiftUI
import UIKit

struct ChatComposerBar: View {
    /// 当前 key window 的 bounds（与 SwiftUI .global 坐标系一致），用于半圆取消区域与屏幕底部对齐。
    private static var keyWindowBounds: CGRect {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow }) else { return .zero }
        return window.bounds
    }
    let language: Language
    @Binding var isRecording: Bool
    let onVoiceStart: () -> Void
    let onVoiceSend: () -> Void
    let onVoiceCancel: () -> Void
    let onSendText: (String) -> Void
    var onVoiceCancelStateChanged: (Bool) -> Void = { _ in }
    /// When true, pulses the voice button to guide the user to press it.
    var hintActive: Bool = false
    /// When non-nil, cancel = finger outside this semicircle (center at bottom of frame; radius 与 `VoiceRecordingOverlayLayout.gestureRadiusMultiplier` 一致). Frame in global coordinates.
    var screenFrameForSemicircleCancel: CGRect? = nil
    var useGlassContainer: Bool = false
    var glassFooterContent: AnyView? = nil
    var hideInnerBar: Bool = false

    @State private var inputMode: InputMode = .voice
    @State private var keyboardVisible: Bool = false
    @State private var gestureViewGlobalFrame: CGRect = .zero
    @State private var inputValue = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var willCancelVoice = false
    @State private var hintPulse = false

    private enum InputMode {
        case voice
        case text
    }

    private let voiceCancelThreshold: CGFloat = -56
    private var glassBottomVisualExtension: CGFloat {
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
        return safeBottom + 80
    }
    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    private func switchToTextInput() {
        willCancelVoice = false
        onVoiceCancelStateChanged(false)
        inputMode = .text
        keyboardVisible = true
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
    }

    var body: some View {
        Group {
            if useGlassContainer {
                glassBody
            } else {
                legacyBody
            }
        }
        // 让底部系统手势（Home Indicator / Control Center 等）延后仲裁，
        // 不然日志里会看到 "System gesture gate timed out." 把我们的 long-press
        // 强制 .cancelled，用户手指还没松 UI 却自己发送/取消了（USB 调试最易复现）。
        .defersSystemGestures(on: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: inputMode) { _, newMode in
            if newMode == .text {
                DispatchQueue.main.async {
                    isTextFieldFocused = true
                }
            } else {
                isTextFieldFocused = false
            }
        }
    }

    // MARK: - Glass Container Mode

    @ViewBuilder
    private var glassBody: some View {
        if keyboardVisible || inputMode == .text {
            glassKeyboardBar
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .padding(.top, 6)
        } else {
            glassCardContainer
        }
    }

    private var glassCardContainer: some View {
        let outerShape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 20
        )
        let hasFooter = glassFooterContent != nil
        let showBar = !hideInnerBar
        let extendedHeight: CGFloat = (hasFooter || hideInnerBar ? 220 : 72) + glassBottomVisualExtension
        return VStack(spacing: 0) {
            if showBar {
                glassInnerBar
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
            if let footer = glassFooterContent {
                footer
            }
            if !hasFooter && showBar {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: (hasFooter || hideInnerBar) ? nil : CGFloat(72))
        .background(alignment: .top) {
            ZStack {
                outerShape.fill(.ultraThinMaterial)
                outerShape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), Color(hex: "EDF3FF").opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .frame(height: extendedHeight)
            .shadow(color: Color(hex: "64748B").opacity(0.055), radius: 14, y: -5)
            .shadow(color: Color(hex: "64748B").opacity(0.04), radius: 24, y: -16)
            .shadow(color: .white.opacity(0.26), radius: 8, y: -7)
        }
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
            .padding(.horizontal, 28)
        }
        .overlay {
            outerShape.stroke(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.44), location: 0),
                        .init(color: Color.white.opacity(0.26), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
        }
        .padding(.horizontal, 16)
        .ignoresSafeArea(edges: .bottom)
    }

    private var glassInnerBar: some View {
        HStack(spacing: 0) {
            if inputMode == .voice {
                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(lightHex: "374151", darkHex: "D1D5DB"))
                    Text(
                        isRecording
                        ? (willCancelVoice ? t("松手取消", "Release to Cancel") : t("松开发送", "Release to Send"))
                        : t("按住说话", "Hold to Talk")
                    )
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isRecording ? .white : Color(lightHex: "1F2937", darkHex: "D1D5DB"))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(GeometryReader { g in
                    Color.clear.preference(key: VoiceBarFramePreferenceKey.self, value: g.frame(in: .global))
                })
                .onPreferenceChange(VoiceBarFramePreferenceKey.self) { gestureViewGlobalFrame = $0 }
                .overlay {
                    voicePressCapture()
                }
            } else {
                // Single-line only: multi-line `axis: .vertical` makes the keyboard Return/Send
                // insert `\n` instead of invoking `onSubmit`, so messages never send.
                TextField(
                    "",
                    text: $inputValue,
                    prompt: Text(t("请输入文字", "Enter text"))
                        .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                )
                .font(.system(size: 15))
                .lineLimit(1)
                .foregroundStyle(AppColors.textPrimary)
                .focused($isTextFieldFocused)
                .submitLabel(.send)
                .onSubmit { submitText() }
                .frame(maxWidth: .infinity)
            }

            if inputMode == .voice {
                Button {
                    switchToTextInput()
                } label: {
                    KeyboardIconView()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(Color(lightHex: "4B5563", darkHex: "9CA3AF"))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .zIndex(1)
            } else {
                Button {
                    inputMode = .voice
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(lightHex: "4B5563", darkHex: "9CA3AF"))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 50)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .background {
            if isRecording {
                RoundedRectangle(cornerRadius: 16)
                    .fill(willCancelVoice ? AppColors.error : AppColors.primary.opacity(0.85))
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.68), Color.white.opacity(0.42)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color(hex: "59678C").opacity(0.06), radius: 10, y: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            if !isRecording {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.82), lineWidth: 0.5)
            }
        }
        .overlay(alignment: .top) {
            if !isRecording {
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
                .padding(.horizontal, 16)
            }
        }
    }

    private var glassKeyboardBar: some View {
        HStack(spacing: 0) {
            TextField(
                "",
                text: $inputValue,
                prompt: Text(t("请输入文字", "Enter text"))
                    .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
            )
            .font(.system(size: 15))
            .lineLimit(1)
            .foregroundStyle(AppColors.textPrimary)
            .focused($isTextFieldFocused)
            .submitLabel(.send)
            .onSubmit { submitText() }
            .frame(maxWidth: .infinity)

            if !inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    submitText()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(hex: "007AFF")))
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                }
            } else {
                Button {
                    inputMode = .voice
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(lightHex: "4B5563", darkHex: "9CA3AF"))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 50)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .onAppear {
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(lightHex: "F5F5F7", darkHex: "2C2C2E").opacity(0.82))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.7), lineWidth: 0.5)
        }
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
            .padding(.horizontal, 16)
        }
        .shadow(color: Color(hex: "59678C").opacity(0.06), radius: 10, y: 4)
    }

    // MARK: - Keyboard Icon

    private struct KeyboardIconView: View {
        var body: some View {
            Image(systemName: "keyboard")
                .font(.system(size: 16))
        }
    }

    private func submitText() {
        let trimmed = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSendText(trimmed)
        inputValue = ""
        isTextFieldFocused = false
    }

    // MARK: - Legacy Mode
    private var legacyBody: some View {
        VStack(spacing: DS.Spacing.x2) {
            if inputMode == .voice {
                // Voice mode: keyboard + hold-to-talk in one container.
                // ZStack lets the mic+text be centered across the full width,
                // while the keyboard button sits pinned to the leading edge.
                // Mic icon + label centered in full width; keyboard button as overlay (no height impact)
                HStack(spacing: DS.Spacing.x1) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                    Text(
                        isRecording
                        ? (willCancelVoice ? t("松手取消", "Release to Cancel") : t("松开发送", "Release to Send"))
                        : t("按住 说话", "Hold to Talk")
                    )
                    .font(DS.Typography.body)
                    .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .foregroundStyle(isRecording ? .white : AppColors.textPrimary)
                .contentShape(Rectangle())
                .background(GeometryReader { g in
                    Color.clear.preference(key: VoiceBarFramePreferenceKey.self, value: g.frame(in: .global))
                })
                .onPreferenceChange(VoiceBarFramePreferenceKey.self) { gestureViewGlobalFrame = $0 }
                .overlay {
                    voicePressCapture()
                }
                .animation(.none, value: isRecording)
                .task(id: hintActive) {
                    guard hintActive && !isRecording else {
                        hintPulse = false
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    hintPulse = true
                    // Auto-stop after ~4 seconds
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    hintPulse = false
                }
                .onChange(of: isRecording) { _, recording in
                    if recording { hintPulse = false }
                }
                .overlay(alignment: .leading) {
                    Button {
                        inputMode = .text
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            isTextFieldFocused = true
                        }
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isRecording ? .white.opacity(0.8) : AppColors.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .background(
                    isRecording
                    ? (willCancelVoice ? AppColors.error : AppColors.primary.opacity(0.85))
                    : AppColors.backgroundSecondary
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card)
                        .stroke(
                            hintActive && !isRecording
                                ? AppColors.primary.opacity(hintPulse ? 0.9 : 0.15)
                                : AppColors.border,
                            lineWidth: hintActive && !isRecording ? 2 : (isRecording ? 0 : 1)
                        )
                        .animation(
                            hintPulse
                                ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                                : .easeInOut(duration: 0.3),
                            value: hintPulse
                        )
                )
                .scaleEffect(hintActive && !isRecording && hintPulse ? 1.022 : 1.0)
                .animation(
                    hintPulse
                        ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.3),
                    value: hintPulse
                )
            } else {
                // Text mode: mic + input + send, all in one container
                HStack(spacing: 0) {
                    Button {
                        inputMode = .voice
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }

                    HStack(spacing: DS.Spacing.x1) {
                        TextField(t("发消息", "Message"), text: $inputValue)
                            .font(DS.Typography.body)
                            .lineLimit(1)
                            .submitLabel(.send)
                            .focused($isTextFieldFocused)
                            .onSubmit {
                                submitText()
                            }

                        if !inputValue.isEmpty {
                            Button {
                                inputValue = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppColors.textSecondary.opacity(0.7))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)

                    Button {
                        submitText()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(inputValue.isEmpty ? .gray : AppColors.primary)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: .infinity)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card)
                        .stroke(AppColors.border, lineWidth: 1)
                )
            }
        }
        .padding(DS.Spacing.x2)
        .background(AppColors.background)
    }

    // MARK: - Voice Press Gesture (UIKit-backed)
    //
    // 为什么不用 SwiftUI `DragGesture(minimumDistance: 0)`：
    // 快速按+松时，`onChanged` 触发 `isRecording = true` 引起外层 ZStack
    // 重建 `VoiceRecordingOverlay`，SwiftUI 会把 DragGesture 的 onEnded
    // 静默吞掉，导致 UI 停在"半圆蓝色"上永远无法退出。USB 调试主循环更慢，
    // 窗口放大，极易复现。
    //
    // UIKit `UILongPressGestureRecognizer(minimumPressDuration: 0)` 的触摸
    // 生命周期由 UIKit 独立跟踪，不受 SwiftUI 视图树重建影响：`.began` 之后
    // 必然以 `.ended` / `.cancelled` / `.failed` 结束，状态不会丢。

    @ViewBuilder
    private func voicePressCapture() -> some View {
        VoicePressGesture(
            onBegan: { _ in
                willCancelVoice = false
                onVoiceCancelStateChanged(false)
                // 立即同步把 UI 状态顶起来，UI 跟手指，不等任何后台任务
                isRecording = true
                onVoiceStart()
            },
            onChanged: { current in
                let next = computeCancelState(globalPoint: current)
                if next != willCancelVoice {
                    willCancelVoice = next
                    onVoiceCancelStateChanged(next)
                }
            },
            onEnded: {
                finishVoicePress()
            },
            onCancelled: {
                // UIKit 取消（底部系统手势 gate 超时、电话呼入、其他手势抢走）不要粗暴 drop。
                // 按"当前 willCancelVoice"处理——手指在半圆内就发送，已移到半圆外才取消。
                // 这样即使真的是"手指还没松系统先切了我",也不会把用户已说的话扔掉。
                finishVoicePress()
            }
        )
    }

    private func finishVoicePress() {
        let shouldCancel = willCancelVoice
        isRecording = false
        willCancelVoice = false
        onVoiceCancelStateChanged(false)
        if shouldCancel {
            onVoiceCancel()
        } else {
            onVoiceSend()
        }
    }

    private func computeCancelState(globalPoint: CGPoint) -> Bool {
        let windowBounds = Self.keyWindowBounds
        if windowBounds.width > 0, windowBounds.height > 0 {
            return !insideCancelSemicircle(
                point: globalPoint,
                frame: windowBounds,
                currentlyCancelling: willCancelVoice
            )
        }
        if let frame = screenFrameForSemicircleCancel, frame.width > 0, frame.height > 0 {
            return !insideCancelSemicircle(
                point: globalPoint,
                frame: frame,
                currentlyCancelling: willCancelVoice
            )
        }
        // fallback：只看纵向位移，startY 未知时以 gestureViewGlobalFrame 底边为参考
        let startY = gestureViewGlobalFrame.maxY
        return (globalPoint.y - startY) <= voiceCancelThreshold
    }

    /// 半圆命中测试 + hysteresis
    /// - 圆心 = frame 底边中点；基础半径 = (frame.width / 2) × gestureRadiusMultiplier（已与视觉对齐）
    /// - 在 send（蓝）状态下，用 baseR + margin 的放大圆做"继续在内"判定，手指要明显越过视觉边界才翻成 cancel
    /// - 在 cancel（红）状态下，用 baseR - margin 的缩小圆做"回到内部"判定，手指要明显回到视觉区域中心才翻回 send
    /// - dy <= 0 保证只认上半圆；手指在屏幕外（y 异常）也不会误判
    private func insideCancelSemicircle(
        point: CGPoint,
        frame: CGRect,
        currentlyCancelling: Bool
    ) -> Bool {
        let cx = frame.midX
        let cy = frame.maxY
        let baseR = (frame.width / 2) * VoiceRecordingOverlayLayout.gestureRadiusMultiplier
        let margin = VoiceRecordingOverlayLayout.gestureHysteresisPoints
        let threshold: CGFloat = currentlyCancelling
            ? max(0, baseR - margin)
            : (baseR + margin)
        let dx = point.x - cx
        let dy = point.y - cy
        return (dx * dx + dy * dy <= threshold * threshold) && (dy <= 0)
    }
}

// MARK: - UIKit Raw-Touch Bridge

/// 直接用 `UIView.touchesBegan/Moved/Ended/Cancelled` 接管按住说话的触摸。
/// 不用 `UIGestureRecognizer` 的原因：
/// - SwiftUI `DragGesture(minimumDistance: 0)` 在视图树重建时会丢 onEnded（已知坑）。
/// - `UILongPressGestureRecognizer` 会被 iOS "system gesture gate" 拦截——触摸
///   落在屏幕底部（Home Indicator 区域）时，系统要做优先级仲裁；主线程慢一点
///   （USB 调试）就会 "System gesture gate timed out."，强制把我的 recognizer
///   置为 `.cancelled`，用户手指还没松 UI 就自己"松开"了。
/// - `UIView` 原生触摸回调不走 recognizer 仲裁，不会被 gate 超时切断。
private struct VoicePressGesture: UIViewRepresentable {
    /// 触摸开始，参数：起始位置（window 坐标）
    var onBegan: (CGPoint) -> Void
    /// 触摸移动，参数：当前位置（window 坐标）
    var onChanged: (_ current: CGPoint) -> Void
    /// 触摸正常抬起
    var onEnded: () -> Void
    /// 触摸被系统取消（来电、视图被销毁等；此时也当作抬起处理，上层按 willCancelVoice 决定发送/取消）
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> VoicePressRawTouchView {
        let v = VoicePressRawTouchView()
        v.callbacks = self
        return v
    }

    func updateUIView(_ uiView: VoicePressRawTouchView, context: Context) {
        uiView.callbacks = self
    }

    /// 自定义 `UIView`：只做原生触摸透传，没有任何 gesture recognizer。
    ///
    /// 关键细节：手指在 touchesBegan 之后只要离开 view 的 bounds，UIKit 默认仍会继续派发
    /// touchesMoved——**除非**祖先链上的某个 `UIGestureRecognizer`（典型：ScrollView 的 pan、
    /// NavigationStack 的 swipe-back、Sheet 的 interactive dismiss pan、`.scrollDismissesKeyboard`
    /// 的 interactive pan、父视图自己挂的 TapGesture/DragGesture）识别出手势，把触摸从我们这里
    /// "偷走"并触发 touchesCancelled。
    ///
    /// 本项目上屏点："按住说话" → 用户手指从矩形内向上滑到大蓝色半圆里时，恰好是 vertical pan
    /// 启动阈值（>10pt），所以祖先 pan 会把我们的触摸 cancel 掉，UI 上看起来就是"一离开矩形
    /// 整个半圆消失"。
    ///
    /// 解决：`touchesBegan` 时遍历 superview 链，把所有祖先的 gesture recognizer 临时禁用
    /// （UIKit 会把它们从 .possible 直接转 .cancelled，不会抢走我们的触摸），
    /// `touchesEnded/Cancelled` 时再原样恢复。
    /// 这不是新增 UIGestureRecognizer（CORE_MEMORY 红线仍成立），只是在活动触摸期间
    /// 把祖先 recognizer 冻住。
    final class VoicePressRawTouchView: UIView {
        var callbacks: VoicePressGesture?
        /// 绑定当前活动的触摸，忽略多指后来者以避免 "按一下又按一下" 把状态搅乱。
        private var trackedTouch: UITouch?
        /// 记录本次触摸期间我们禁用过的祖先 recognizer + 其原始 isEnabled，结束时一一恢复。
        private var disabledAncestorRecognizers: [(UIGestureRecognizer, Bool)] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = true
            isMultipleTouchEnabled = false
            // 其他 UIView 在追踪此视图的触摸期间不会收到触摸，进一步稳住状态。
            isExclusiveTouch = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard trackedTouch == nil, let t = touches.first else { return }
            trackedTouch = t
            freezeAncestorRecognizers()
            let global = convert(t.location(in: self), to: nil)
            callbacks?.onBegan(global)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            let current = convert(tracked.location(in: self), to: nil)
            callbacks?.onChanged(current)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            restoreAncestorRecognizers()
            callbacks?.onEnded()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            restoreAncestorRecognizers()
            callbacks?.onCancelled()
        }

        // MARK: - Ancestor recognizer freeze

        private func freezeAncestorRecognizers() {
            disabledAncestorRecognizers.removeAll(keepingCapacity: true)
            var cursor: UIView? = self.superview
            while let view = cursor {
                if let recognizers = view.gestureRecognizers {
                    for g in recognizers {
                        // 仅冻结当前 enabled 的，避免恢复时把业务逻辑自己禁用的又打开
                        guard g.isEnabled else { continue }
                        disabledAncestorRecognizers.append((g, true))
                        g.isEnabled = false
                    }
                }
                cursor = view.superview
            }
        }

        private func restoreAncestorRecognizers() {
            // 注意：即便 callback 在恢复过程中抛异常也要确保集合被清空
            let snapshot = disabledAncestorRecognizers
            disabledAncestorRecognizers.removeAll(keepingCapacity: true)
            for (g, original) in snapshot {
                g.isEnabled = original
            }
        }

        /// 从 window / 父视图移除时，原触摸必然被 cancel；这里做兜底清理，
        /// 避免 recognizer 被永远禁用。
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil, trackedTouch != nil {
                trackedTouch = nil
                restoreAncestorRecognizers()
            }
        }
    }
}

private struct VoiceBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

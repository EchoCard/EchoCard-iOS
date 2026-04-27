//
//  VoiceRecordingOverlay.swift
//  CallMate
//

import SwiftUI

/// 按住说话 / 上移取消 底部渐变与半圆取消区的共用尺寸。
enum VoiceRecordingOverlayLayout {
    /// 视觉渐变半圆半径 = (可用宽度 / 2) × visualRadiusMultiplier
    static let visualRadiusMultiplier: CGFloat = 2.08
    /// 手势判定半圆半径 = (可用宽度 / 2) × gestureRadiusMultiplier
    /// 必须与 `visualRadiusMultiplier` 对齐：用户看到的蓝色半圆 == "松开发送" 区域；
    /// 若 gesture 小于 visual，手指落在可见蓝色内却被判为"已离开"，导致颜色闪烁（红/蓝反复跳）。
    static let gestureRadiusMultiplier: CGFloat = 2.08
    /// 手势滞回（hysteresis）缓冲，单位 pt。
    /// 进入 cancel 时用 baseR + margin；退出 cancel 时用 baseR - margin。
    /// 手指停在边界附近时，sub-pixel 抖动 / 触摸压感变化 / 手指自然颤抖不会再让状态反复翻转。
    static let gestureHysteresisPoints: CGFloat = 18
    /// 背景层水平展开
    static let backgroundWidthMultiplier: CGFloat = 2.2
    /// 底部额外模糊光晕
    static let glowEllipseWidthFactor: CGFloat = 1.38
    static let glowEllipseHeightFactor: CGFloat = 1.08
    static let glowRadialEndRadiusFactor: CGFloat = 0.64
    static let glowBlur: CGFloat = 58
}

struct VoiceRecordingOverlay: View {
    let language: Language
    let isCancelling: Bool
    @State private var animateGlow = false
    @State private var animateDots = false

    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Spacer()
                    bottomCurvedArea(width: geo.size.width, safeBottom: geo.safeAreaInsets.bottom)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .onAppear {
            animateGlow = true
            animateDots = true
        }
        .onDisappear {
            animateGlow = false
            animateDots = false
        }
    }

    private func bottomCurvedArea(width: CGFloat, safeBottom: CGFloat) -> some View {
        let radius = (width / 2) * VoiceRecordingOverlayLayout.visualRadiusMultiplier
        let bottomInset = safeBottom + 56
        return VStack(spacing: 12) {
            Text(isCancelling ? t("松手取消", "Release to Cancel") : t("松手发送，上移取消", "Release to Send, Slide Up to Cancel"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .tracking(0.2)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(0.96))
                        .frame(width: index == 2 ? 18 : 14, height: index == 2 ? 18 : 14)
                        .scaleEffect(animateDots ? dotScale(for: index) : 0.9)
                        .opacity(animateDots ? dotOpacity(for: index) : 0.72)
                        .animation(
                            .easeInOut(duration: 0.72)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12),
                            value: animateDots
                        )
                }
            }
            .padding(.top, 8)

            EmptyView()
        }
        .padding(.top, 18)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                SemicircleShape()
                    .fill(baseGradient(radius: radius))

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: isCancelling
                                ? [
                                    Color(hex: "E03E3E").opacity(animateGlow ? 0.55 : 0.40),
                                    Color(hex: "EE5C5C").opacity(animateGlow ? 0.30 : 0.18),
                                    Color(hex: "EE5C5C").opacity(0.04),
                                    .clear
                                ]
                                : [
                                    Color(hex: "007AFF").opacity(animateGlow ? 0.55 : 0.40),
                                    Color(hex: "3395FF").opacity(animateGlow ? 0.30 : 0.18),
                                    Color(hex: "3395FF").opacity(0.04),
                                    .clear
                                ],
                            center: .center,
                            startRadius: 0,
                            endRadius: width * 0.46
                        )
                    )
                    .frame(
                        width: width * 0.96,
                        height: width * 0.76
                    )
                    .offset(y: width * 0.18)
                    .blur(radius: 32)
                    .mask(innerGlowMask(radius: radius))
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: animateGlow)
            }
            .frame(width: width * VoiceRecordingOverlayLayout.backgroundWidthMultiplier, height: radius)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func dotScale(for index: Int) -> CGFloat {
        [0.92, 1.02, 1.14][index % 3]
    }

    private func dotOpacity(for index: Int) -> CGFloat {
        [0.72, 0.84, 1.0][index % 3]
    }

    private func baseGradient(radius: CGFloat) -> RadialGradient {
        if isCancelling {
            return RadialGradient(
                stops: [
                    .init(color: Color(hex: "CC2D2D"), location: 0),
                    .init(color: Color(hex: "D43333"), location: 0.18),
                    .init(color: Color(hex: "E03E3E").opacity(0.96), location: 0.34),
                    .init(color: Color(hex: "E85050").opacity(0.88), location: 0.48),
                    .init(color: Color(hex: "EE5C5C").opacity(0.62), location: 0.60),
                    .init(color: Color(hex: "EE5C5C").opacity(0.34), location: 0.68),
                    .init(color: Color(hex: "EE5C5C").opacity(0.14), location: 0.74),
                    .init(color: Color(hex: "EE5C5C").opacity(0.035), location: 0.79),
                    .init(color: .clear, location: 0.84),
                    .init(color: .clear, location: 1.0)
                ],
                center: UnitPoint(x: 0.5, y: 1),
                startRadius: 0,
                endRadius: radius
            )
        }

        return RadialGradient(
            stops: [
                .init(color: Color(hex: "005ECB"), location: 0),
                .init(color: Color(hex: "006ADF"), location: 0.18),
                .init(color: Color(hex: "007AFF").opacity(0.96), location: 0.34),
                .init(color: Color(hex: "1A8AFF").opacity(0.88), location: 0.48),
                .init(color: Color(hex: "3395FF").opacity(0.62), location: 0.60),
                .init(color: Color(hex: "3395FF").opacity(0.34), location: 0.68),
                .init(color: Color(hex: "3395FF").opacity(0.14), location: 0.74),
                .init(color: Color(hex: "3395FF").opacity(0.035), location: 0.79),
                .init(color: .clear, location: 0.84),
                .init(color: .clear, location: 1.0)
            ],
            center: UnitPoint(x: 0.5, y: 1),
            startRadius: 0,
            endRadius: radius
        )
    }

    private func innerGlowMask(radius: CGFloat) -> some View {
        SemicircleShape()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.50),
                        .init(color: .white.opacity(0.92), location: 0.60),
                        .init(color: .white.opacity(0.55), location: 0.67),
                        .init(color: .white.opacity(0.24), location: 0.73),
                        .init(color: .white.opacity(0.08), location: 0.78),
                        .init(color: .clear, location: 0.84),
                        .init(color: .clear, location: 1.0)
                    ],
                    center: UnitPoint(x: 0.5, y: 1),
                    startRadius: 0,
                    endRadius: radius
                )
            )
    }
}

/// 以 rect 底边中点为圆心的上半圆（平边在底，弧在上）
private struct SemicircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let radius = min(rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addArc(center: center, radius: radius, startAngle: .radians(Double.pi), endAngle: .radians(0), clockwise: false)
        path.closeSubpath()
        return path
    }
}


//
//  StreamingTextBubble.swift
//  CallMate
//
//  流式文字气泡 — 手动分行，彻底杜绝回流。
//
//  核心原理：
//    不依赖 SwiftUI Text 的自动换行。
//    用 CoreText CTTypesetter 自行把文本切成行数组，每行用 .fixedSize() 渲染，
//    行宽一旦锁定就不再变化，后续字符只影响最后一行。
//
//  宽度测量：
//    ZStack 内放一个永远可见的 Color.clear（maxWidth:.infinity, 0 高度）作为测量锚，
//    通过 PreferenceKey 把可用宽度报给外层 State。
//    第一帧 availableWidth 可能还没到，用 UIScreen 粗估做 fallback，
//    避免"来了字但什么都不显示"。
//

import SwiftUI
import UIKit
import CoreText

// MARK: - PreferenceKey

private struct BubbleAvailableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - StreamingTextBubble

struct StreamingTextBubble: View {
    @ObservedObject var state: TTSStreamingBubbleState

    var uiFont: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: Color = AppColors.textPrimary
    var bubbleColor: Color = AppColors.surface
    var cornerRadius: CGFloat = DS.Radius.card
    var borderColor: Color = AppColors.border
    var borderWidth: CGFloat = 1
    var horizontalPadding: CGFloat = DS.Spacing.x2
    var verticalPadding: CGFloat = DS.Spacing.x2
    /// 设为 true 时气泡靠右（AI 发言在右侧，如 LiveCallView）
    var trailingAligned: Bool = false
    /// 设为 true 时使用 ultraThinMaterial + bubbleColor 叠加的玻璃效果
    var useGlassMaterial: Bool = false
    /// 气泡最大宽度占父容器的比例 (0...1)，默认 1.0（不限制）
    var maxWidthFraction: CGFloat = 1.0
    /// 行间距，默认 0（与 SwiftUI Text.lineSpacing 对应）
    var lineSpacing: CGFloat = 0
    /// 为 true 且流式文本非空时，长按气泡直接复制到剪贴板（AI 分身等场景）
    var enableLongPressCopy: Bool = false

    @State private var availableWidth: CGFloat = 0
    @State private var engine = StreamingTextLayoutEngine()

    private var textMaxWidth: CGFloat {
        let effectiveWidth = availableWidth * maxWidthFraction
        let measured = effectiveWidth > 1 ? effectiveWidth - horizontalPadding * 2 : 0
        if measured > 1 { return measured }
        return UIScreen.main.bounds.width * 0.65 - horizontalPadding * 2
    }

    var body: some View {
        ZStack(alignment: trailingAligned ? .topTrailing : .topLeading) {
            // ① 永远存在的宽度测量锚点：0 高度，full width
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: BubbleAvailableWidthKey.self,
                                        value: geo.size.width)
                    }
                )

            // ② Loading 三点动画（等待 AI 首字）
            if state.isLoading && state.text.isEmpty {
                TypingDotsView()
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .background {
                        if useGlassMaterial {
                            ZStack {
                                RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial)
                                RoundedRectangle(cornerRadius: cornerRadius).fill(bubbleColor)
                            }
                            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .stroke(borderColor, lineWidth: borderWidth)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: cornerRadius).fill(bubbleColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: cornerRadius)
                                        .stroke(borderColor, lineWidth: borderWidth)
                                )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }

            // ③ 流式文字气泡
            if !state.text.isEmpty {
                bubbleContent(maxWidth: textMaxWidth)
                    .transition(.identity)
            }
        }
        .animation(nil, value: state.text.isEmpty)
        .onPreferenceChange(BubbleAvailableWidthKey.self) { w in
            guard w > 1, abs(w - availableWidth) > 0.5 else { return }
            availableWidth = w
        }
        .frame(maxWidth: .infinity, alignment: trailingAligned ? .trailing : .leading)
        .modifier(StreamingBubbleLongPressCopy(text: state.text, enabled: enableLongPressCopy))
    }

    @ViewBuilder
    private func bubbleContent(maxWidth: CGFloat) -> some View {
        let layout = engine.layout(for: state.text, maxTextWidth: maxWidth, font: uiFont)

        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(layout.lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(Font(uiFont))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: layout.textWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            if useGlassMaterial {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius).fill(bubbleColor)
                }
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor, lineWidth: borderWidth)
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius).fill(bubbleColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(borderColor, lineWidth: borderWidth)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

private struct StreamingBubbleLongPressCopy: ViewModifier {
    let text: String
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, !text.isEmpty {
            content
                .onLongPressGesture(minimumDuration: 0.45) {
                    UIPasteboard.general.string = text
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        } else {
            content
        }
    }
}

// MARK: - Typing Dots

/// 三个圆点，依次在浅灰和深色之间波浪式切换，模拟 AI 正在思考。
private struct TypingDotsView: View {
    @State private var phase: Int = 0

    private let dotSize: CGFloat = 8
    private let activeDotColor: Color = AppColors.textPrimary
    private let idleDotColor: Color = AppColors.textTertiary
    private let stepNs: UInt64 = 380_000_000  // 0.38s / step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(phase == index ? activeDotColor : idleDotColor)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(phase == index ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.28), value: phase)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: stepNs)
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Layout Engine

private struct BubbleLayout {
    let textWidth: CGFloat
    let lines: [String]
}

private final class StreamingTextLayoutEngine {
    private var lockedWidth: CGFloat?
    private var prevText: String = ""
    private var prevSingleLineWidth: CGFloat = 0

    func layout(for text: String, maxTextWidth: CGFloat, font: UIFont) -> BubbleLayout {
        guard !text.isEmpty else {
            reset(); return BubbleLayout(textWidth: 0, lines: [])
        }

        // 文本缩短或不是追加 → 重置（新一轮流式）
        if text.count < prevText.count || !text.hasPrefix(prevText) {
            reset()
        }
        prevText = text

        let available = max(maxTextWidth, 1)

        // 已锁定
        if let locked = lockedWidth {
            let w = min(locked, available)
            return BubbleLayout(textWidth: w, lines: breakLines(text, width: w, font: font))
        }

        // 单行 & 没有显式换行 → 气泡随文字变宽
        let singleW = measureWidth(text, font: font)
        if singleW <= available && !text.contains("\n") {
            prevSingleLineWidth = singleW
            return BubbleLayout(textWidth: singleW, lines: [text])
        }

        // 进入多行 → 锁定到最大可用宽度，避免气泡宽度跳动
        lockedWidth = available
        return BubbleLayout(textWidth: available, lines: breakLines(text, width: available, font: font))
    }

    private func reset() {
        lockedWidth = nil
        prevText = ""
        prevSingleLineWidth = 0
    }

    // MARK: CoreText helpers

    private func attr(_ text: String, font: UIFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font])
    }

    private func measureWidth(_ text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(attr(text, font: font))
        return max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up), 1)
    }

    private func firstLineBreakCount(_ text: String, width: CGFloat, font: UIFont) -> Int {
        let ts = CTTypesetterCreateWithAttributedString(attr(text, font: font))
        return max(CTTypesetterSuggestLineBreak(ts, 0, Double(width)), 1)
    }

    private func breakLines(_ text: String, width: CGFloat, font: UIFont) -> [String] {
        let attributed = attr(text, font: font)
        let nsText = text as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let total = attributed.length

        var lines: [String] = []
        var loc = 0

        while loc < total {
            let ch = nsText.character(at: loc)
            if ch == 10 { // newline
                lines.append("")
                loc += 1
                continue
            }
            let count = max(CTTypesetterSuggestLineBreak(typesetter, loc, Double(width)), 1)
            let raw = nsText.substring(with: NSRange(location: loc, length: count))
            if let nlRange = raw.range(of: "\n") {
                let before = String(raw[..<nlRange.lowerBound])
                lines.append(before)
                loc += before.utf16.count + 1
            } else {
                lines.append(raw)
                loc += count
            }
        }

        return lines.isEmpty ? [""] : lines
    }
}

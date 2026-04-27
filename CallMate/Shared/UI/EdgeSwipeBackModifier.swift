import SwiftUI

private struct EdgeSwipeBackModifier<Background: View>: ViewModifier {
    let enabled: Bool
    let onBack: () -> Void
    let edgeStartThreshold: CGFloat
    let minTranslation: CGFloat
    let maxVerticalOffset: CGFloat
    /// 顶部排除高度：触摸起点在此高度以下才识别为边缘滑动，避免抢左上角返回按钮的点击
    let topExclusionHeight: CGFloat
    let background: Background?

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }
    private var progress: CGFloat { min(max(dragOffset / screenWidth, 0), 1) }

    /// 仅当触摸从「左边缘且低于导航栏」开始时才视为边缘滑动，不抢返回按钮区域
    private func isEdgeSwipeStart(_ location: CGPoint) -> Bool {
        location.x <= edgeStartThreshold && location.y > topExclusionHeight
    }

    func body(content: Content) -> some View {
        ZStack {
            if isDragging || dragOffset > 0, let background {
                background
                    .offset(x: -screenWidth * 0.3 * (1 - progress))
                    .overlay(Color.black.opacity(0.1 * (1 - progress)))
            }

            content
                .offset(x: dragOffset)
                .allowsHitTesting(!isDragging)
                .shadow(
                    color: (isDragging || dragOffset > 0) ? .black.opacity(0.15) : .clear,
                    radius: 10,
                    x: -5,
                    y: 0
                )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    guard enabled else { return }
                    guard isEdgeSwipeStart(value.startLocation) else { return }
                    let dx = value.translation.width
                    guard dx > 0 else { return }
                    isDragging = true
                    dragOffset = dx * 0.9
                }
                .onEnded { value in
                    guard isDragging else { return }
                    isDragging = false
                    let velocity = value.predictedEndTranslation.width - value.translation.width
                    let shouldCommit = dragOffset >= minTranslation || velocity > 200
                    if shouldCommit {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = screenWidth
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            dragOffset = 0
                            onBack()
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}

extension View {
    func edgeSwipeBack(
        enabled: Bool = true,
        edgeStartThreshold: CGFloat = 40,
        minTranslation: CGFloat = 80,
        maxVerticalOffset: CGFloat = 60,
        topExclusionHeight: CGFloat = 200,
        perform onBack: @escaping () -> Void
    ) -> some View {
        modifier(
            EdgeSwipeBackModifier<EmptyView>(
                enabled: enabled,
                onBack: onBack,
                edgeStartThreshold: edgeStartThreshold,
                minTranslation: minTranslation,
                maxVerticalOffset: maxVerticalOffset,
                topExclusionHeight: topExclusionHeight,
                background: nil
            )
        )
    }

    func edgeSwipeBack<Background: View>(
        enabled: Bool = true,
        edgeStartThreshold: CGFloat = 40,
        minTranslation: CGFloat = 80,
        maxVerticalOffset: CGFloat = 60,
        topExclusionHeight: CGFloat = 200,
        background: Background,
        perform onBack: @escaping () -> Void
    ) -> some View {
        modifier(
            EdgeSwipeBackModifier(
                enabled: enabled,
                onBack: onBack,
                edgeStartThreshold: edgeStartThreshold,
                minTranslation: minTranslation,
                maxVerticalOffset: maxVerticalOffset,
                topExclusionHeight: topExclusionHeight,
                background: background
            )
        )
    }
}

//
//  InternshipReportView.swift
//  CallMate
//

import SwiftUI

// MARK: - Internship Report

struct InternshipReportView: View {
    let language: Language
    let reportIndex: Int
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var data: ReportMockData {
        ReportMockData.forReport(reportIndex, language: language)
    }

    private var isGraduation: Bool { reportIndex == 3 }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            pageBackground

            ScrollView(showsIndicators: false) {
                VStack(spacing: AppSpacing.lg) {
                    heroCard
                    metricsSection
                    callProfileSection
                    featuredCallsSection
                    evaluationSection
                    suggestionsSection
                    footerSection
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.xxl)
                .padding(.bottom, AppSpacing.xxxl)
            }

            closeButton
        }
    }

    // MARK: - Page Background

    private var pageBackground: some View {
        ZStack {
            LinearGradient(
                stops: colorScheme == .dark
                    ? [
                        .init(color: Color(hex: "0C0A14"), location: 0),
                        .init(color: Color(hex: "080810"), location: 0.45),
                        .init(color: Color(hex: "000000"), location: 1)
                    ]
                    : [
                        .init(color: Color(hex: "F6F4FF"), location: 0),
                        .init(color: Color(hex: "F2F2F7"), location: 0.4),
                        .init(color: Color(hex: "F4F6FF"), location: 0.7),
                        .init(color: Color(hex: "F2F2F7"), location: 1)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    AppColors.accent.opacity(colorScheme == .dark ? 0.08 : 0.06),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 340
            )

            RadialGradient(
                colors: [
                    AppColors.primary.opacity(colorScheme == .dark ? 0.05 : 0.04),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 280
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        ZStack {
            heroGradientBackground

            Circle()
                .fill(AppColors.accent.opacity(colorScheme == .dark ? 0.18 : 0.10))
                .frame(width: 190, height: 190)
                .blur(radius: 50)
                .offset(x: 80, y: -55)

            Circle()
                .fill(AppColors.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                .frame(width: 130, height: 130)
                .blur(radius: 35)
                .offset(x: -50, y: 80)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(eyebrowText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppColors.accent.opacity(0.12))
                            .clipShape(Capsule())

                        Text(data.title)
                            .font(AppTypography.title1)
                            .foregroundStyle(AppColors.textPrimary)

                        Text(data.dateRange)
                            .font(AppTypography.footnoteEmphasized)
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: isGraduation ? "graduationcap.fill" : "doc.text.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.accent)
                        .frame(width: 44, height: 44)
                        .background(AppColors.accent.opacity(0.14))
                        .clipShape(Circle())
                }

                Text(data.summary)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(3)

                HStack(spacing: AppSpacing.sm) {
                    heroChip(icon: "waveform.path.ecg", text: data.heroHighlights.0)
                    heroChip(icon: "person.2.fill", text: data.heroHighlights.1)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.sm)
    }

    private var heroGradientBackground: LinearGradient {
        LinearGradient(
            stops: colorScheme == .dark
                ? [
                    .init(color: Color(hex: "1C1832"), location: 0),
                    .init(color: Color(hex: "201C36"), location: 0.35),
                    .init(color: Color(hex: "1E1A2E"), location: 0.7),
                    .init(color: Color(hex: "1A1A24"), location: 1)
                ]
                : [
                    .init(color: Color(hex: "F0ECFF"), location: 0),
                    .init(color: Color(hex: "EDE8FF"), location: 0.35),
                    .init(color: Color(hex: "F5F2FF"), location: 0.7),
                    .init(color: Color(hex: "FFFFFF"), location: 1)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var eyebrowText: String {
        isGraduation ? t("转正申请", "Graduation Review") : t("阶段汇报", "Progress Report")
    }

    private func heroChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(AppColors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        sectionShell(
            title: t("阶段概览", "Overview"),
            subtitle: t("这段时间的核心工作指标", "Core metrics at a glance")
        ) {
            HStack(spacing: 0) {
                metricItem(
                    icon: "phone.fill",
                    iconColor: AppColors.accent,
                    value: "\(data.totalCalls)",
                    label: t("有效代接", "Handled")
                )
                metricDivider
                metricItem(
                    icon: "calendar",
                    iconColor: AppColors.primary,
                    value: "\(data.serviceDays)",
                    label: t("服务天数", "Days")
                )
                metricDivider
                metricItem(
                    icon: "person.2.fill",
                    iconColor: AppColors.success,
                    value: "\(data.totalCallers)",
                    label: t("来电者", "Callers")
                )
            }
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(width: 1, height: 60)
    }

    private func metricItem(icon: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(spacing: AppSpacing.xs) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppColors.textPrimary)

            Text(label)
                .font(AppTypography.caption1)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Call Profile

    private var callProfileSection: some View {
        sectionShell(
            title: t("来电画像", "Call Profile"),
            subtitle: t("按识别类型划分的来电分布", "Breakdown by identified call type")
        ) {
            HStack(alignment: .center, spacing: AppSpacing.lg) {
                ringChart
                    .frame(width: 120, height: 120)

                VStack(spacing: AppSpacing.xs) {
                    ForEach(Array(data.callTypes.enumerated()), id: \.offset) { _, item in
                        legendItem(item)
                    }
                }
            }
        }
    }

    private func legendItem(_ item: ReportCallTypeItem) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Circle()
                .fill(item.color)
                .frame(width: 8, height: 8)

            Text(item.label)
                .font(AppTypography.footnote)
                .foregroundStyle(AppColors.textPrimary)

            Spacer()

            Text(item.percentText)
                .font(AppTypography.footnoteEmphasized)
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, 9)
        .background(AppColors.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous))
    }

    private var ringChart: some View {
        let gap: Double = 0.008
        let offsets = data.callTypeOffsets
        return ZStack {
            Circle()
                .stroke(AppColors.separator.opacity(0.5), lineWidth: 16)

            ForEach(Array(data.callTypes.enumerated()), id: \.offset) { idx, item in
                let start = offsets[idx] + gap / 2
                let end = max(start, offsets[idx + 1] - gap / 2)
                Circle()
                    .trim(from: start, to: end)
                    .stroke(item.color, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 2) {
                Text("\(data.totalCalls)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColors.textPrimary)
                Text(t("通话", "calls"))
                    .font(AppTypography.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    // MARK: - Featured Calls

    private var featuredCallsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionHeader(
                title: t("精选通话", "Featured Calls"),
                subtitle: t("几通有代表性的电话，方便你快速了解处理质感", "Representative calls from this phase")
            )

            ForEach(Array(data.featuredCalls.enumerated()), id: \.offset) { _, call in
                featuredCallCard(call)
            }
        }
    }

    private func featuredCallCard(_ call: ReportFeaturedCall) -> some View {
        HStack(spacing: 0) {
            call.accentColor
                .frame(width: 4)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .center) {
                    Text(call.label)
                        .font(AppTypography.calloutEmphasized)
                        .foregroundStyle(AppColors.textPrimary)

                    Text(call.resultTag)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(call.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(call.accentColor.opacity(0.10))
                        .clipShape(Capsule())

                    Spacer()

                    Text(call.duration)
                        .font(AppTypography.caption1)
                        .foregroundStyle(AppColors.textTertiary)
                }

                Text(call.phone)
                    .font(AppTypography.caption1)
                    .foregroundStyle(AppColors.textTertiary)

                Text(call.summary)
                    .font(AppTypography.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
        }
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.sm)
    }

    // MARK: - Self Evaluation

    private var evaluationSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionHeader(
                title: t("自我评价", "Self Evaluation"),
                subtitle: t("做得好的地方，以及还要继续补强的内容", "What went well and what still needs work")
            )

            ForEach(Array(data.evaluations.enumerated()), id: \.offset) { _, item in
                evaluationItemCard(item)
            }
        }
    }

    private func evaluationItemCard(_ item: ReportEvaluationItem) -> some View {
        HStack(spacing: 0) {
            item.tint
                .frame(width: 4)

            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: item.icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(width: 30, height: 30)
                    .background(item.tint.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(item.title)
                        .font(AppTypography.footnoteEmphasized)
                        .foregroundStyle(item.tint)

                    Text(item.text)
                        .font(AppTypography.footnote)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
        }
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.sm)
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionHeader(
                title: t("成长建议", "Next Actions"),
                subtitle: t("几个值得顺手调整的地方", "Quick improvements you can make")
            )

            ForEach(Array(data.suggestions.enumerated()), id: \.offset) { _, item in
                suggestionCard(item)
            }
        }
    }

    private func suggestionCard(_ item: ReportSuggestionItem) -> some View {
        Button(action: {}) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: item.icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.primary)
                    .frame(width: 40, height: 40)
                    .background(AppColors.primary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(item.title)
                        .font(AppTypography.subheadlineEmphasized)
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(item.detail)
                        .font(AppTypography.footnote)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 4) {
                        Text(item.action)
                            .font(AppTypography.footnoteEmphasized)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(AppColors.primary)
                    .padding(.top, AppSpacing.xxs)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .appShadow(AppShadow.sm)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(t("汇报结论", "Summary"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(isGraduation
                     ? t("综合表现评估与转正建议", "Overall assessment and graduation recommendation")
                     : t("这一阶段的总体判断", "Overall assessment for this phase"))
                    .font(AppTypography.footnote)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Text(data.footer)
                .font(AppTypography.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .lineSpacing(3)

            if isGraduation {
                VStack(spacing: AppSpacing.sm) {
                    Button(action: onConfirm) {
                        Text(t("批准转正", "Approve Graduation"))
                            .font(AppTypography.bodyEmphasized)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                LinearGradient(
                                    colors: [AppColors.accent, Color(hex: "7B5EE7")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onReject) {
                        Text(t("还需努力", "Needs Improvement"))
                            .font(AppTypography.subheadlineEmphasized)
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onConfirm) {
                    Text(t("已阅", "Acknowledged"))
                        .font(AppTypography.bodyEmphasized)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(AppColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.sm)
    }

    // MARK: - Shared Helpers

    private func sectionShell<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(subtitle)
                    .font(AppTypography.footnote)
                    .foregroundStyle(AppColors.textSecondary)
            }

            content()
        }
        .padding(AppSpacing.lg)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .appShadow(AppShadow.sm)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
            Text(subtitle)
                .font(AppTypography.footnote)
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, AppSpacing.xxs)
    }
}

// MARK: - Internship Report Banner

struct InternshipReportBanner: View {
    let language: Language
    let reportIndex: Int
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var isGraduation: Bool { reportIndex == 3 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: isGraduation ? "graduationcap.fill" : "doc.text.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 40, height: 40)
                    .background(AppColors.accent.opacity(0.14))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerTitle)
                        .font(AppTypography.subheadlineEmphasized)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(bannerSubtitle)
                        .font(AppTypography.footnote)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(t("查看", "View"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? AppColors.textPrimary : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        colorScheme == .dark
                            ? AppColors.surfaceElevated
                            : AppColors.accent
                    )
                    .clipShape(Capsule())
            }
            .padding(AppSpacing.lg)
            .background(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(hex: "241F33"), Color(hex: "1C1C24")]
                        : [Color(hex: "F8F4FF"), Color(hex: "F1ECFF")],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .appShadow(AppShadow.sm)
        }
        .buttonStyle(.plain)
    }

    private var bannerTitle: String {
        if isGraduation {
            return t("转正申请报告已生成", "Graduation Report Ready")
        }
        return t("第\(reportIndex)份实习汇报已生成", "Internship Report #\(reportIndex) Ready")
    }

    private var bannerSubtitle: String {
        if isGraduation {
            return t("这是一份更完整的阶段总结，方便你集中判断是否放开全接管", "A complete review to help you decide on full takeover")
        }
        return t("这份阶段汇报已经整理好了，点开就能快速看看我这段时间接电话的表现", "Your AI report is ready. Open it to review recent call performance")
    }
}

// MARK: - Data Models

private struct ReportCallTypeItem {
    let label: String
    let ratio: Double
    let color: Color

    var percentText: String { "\(Int(ratio * 100))%" }
}

private struct ReportFeaturedCall {
    let phone: String
    let label: String
    let summary: String
    let duration: String
    let isPositive: Bool
    let resultTag: String

    var accentColor: Color {
        isPositive ? AppColors.success : AppColors.warning
    }
}

private struct ReportEvaluationItem {
    let icon: String
    let title: String
    let text: String
    let tint: Color
}

private struct ReportSuggestionItem {
    let icon: String
    let title: String
    let detail: String
    let action: String
}

// MARK: - Mock Data

private struct ReportMockData {
    let title: String
    let dateRange: String
    let summary: String
    let heroHighlights: (String, String)
    let totalCalls: Int
    let serviceDays: Int
    let totalCallers: Int
    let callTypes: [ReportCallTypeItem]
    let featuredCalls: [ReportFeaturedCall]
    let evaluations: [ReportEvaluationItem]
    let suggestions: [ReportSuggestionItem]
    let footer: String

    var callTypeOffsets: [Double] {
        var values: [Double] = [0]
        for item in callTypes {
            values.append(values.last! + item.ratio)
        }
        return values
    }

    // MARK: Factory

    static func forReport(_ index: Int, language: Language) -> ReportMockData {
        let zh = language == .zh

        switch index {
        case 1:
            return ReportMockData(
                title: zh ? "第一份实习汇报" : "Internship Report #1",
                dateRange: zh ? "2026.03.01 — 2026.03.14" : "Mar 1 – Mar 14, 2026",
                summary: zh
                    ? "这是我的第一份阶段汇报。我把这段时间接到的电话类型、处理结果和需要继续练习的地方都整理在这里，方便你快速看完。"
                    : "This is my first phase report. I've organized the types of calls I handled, the results, and where I still need improvement.",
                heroHighlights: (
                    zh ? "初步建立接听节奏" : "Building rhythm",
                    zh ? "开始认识你的来电环境" : "Learning your callers"
                ),
                totalCalls: 20,
                serviceDays: 14,
                totalCallers: 12,
                callTypes: [
                    ReportCallTypeItem(label: zh ? "快递/外卖" : "Delivery", ratio: 0.30, color: AppColors.primary),
                    ReportCallTypeItem(label: zh ? "推销电话" : "Spam", ratio: 0.25, color: AppColors.warning),
                    ReportCallTypeItem(label: zh ? "骚扰电话" : "Harassment", ratio: 0.20, color: AppColors.error),
                    ReportCallTypeItem(label: zh ? "未识别" : "Unidentified", ratio: 0.25, color: AppColors.accent)
                ],
                featuredCalls: [
                    ReportFeaturedCall(
                        phone: "138****2201",
                        label: zh ? "快递员" : "Courier",
                        summary: zh
                            ? "顺利确认了取件码和放件位置，对方很快理解并结束通话。"
                            : "Confirmed pickup code and drop-off location. The caller understood quickly.",
                        duration: zh ? "1分12秒" : "1m 12s",
                        isPositive: true,
                        resultTag: zh ? "处理顺畅" : "Handled well"
                    ),
                    ReportFeaturedCall(
                        phone: "010-8234****",
                        label: zh ? "推销" : "Telemarketer",
                        summary: zh
                            ? "对方在我委婉拒绝后仍然追问，我的话术还不够果断，显得有些犹豫。"
                            : "The caller kept pushing after my polite decline. My rejection still felt hesitant.",
                        duration: zh ? "0分42秒" : "0m 42s",
                        isPositive: false,
                        resultTag: zh ? "有待补强" : "Needs work"
                    )
                ],
                evaluations: [
                    ReportEvaluationItem(
                        icon: "checkmark.circle.fill",
                        title: zh ? "做得比较稳" : "Strength",
                        text: zh
                            ? "快递和外卖类电话已经能稳定处理，回复比较清楚，取件码和放件位置也不会遗漏。"
                            : "Delivery-style calls are already handled steadily — pickup codes and locations are captured reliably.",
                        tint: AppColors.success
                    ),
                    ReportEvaluationItem(
                        icon: "exclamationmark.triangle.fill",
                        title: zh ? "还要补强" : "Needs Work",
                        text: zh
                            ? "遇到推销电话时，委婉拒绝的话术还不够果断，容易让对方继续追问。"
                            : "When declining spam calls, my rejection isn't firm enough yet — callers often keep pressing.",
                        tint: AppColors.warning
                    )
                ],
                suggestions: [
                    ReportSuggestionItem(
                        icon: "star.bubble.fill",
                        title: zh ? "有 8 通电话还没点评" : "8 calls still unrated",
                        detail: zh
                            ? "如果你顺手去点一下好坏，我后面会更清楚哪些地方需要继续往你的习惯上靠。"
                            : "A few ratings would help me learn your preferences faster.",
                        action: zh ? "去通话记录点评" : "Open call history"
                    ),
                    ReportSuggestionItem(
                        icon: "slider.horizontal.3",
                        title: zh ? "有 2 类场景还比较拿不准" : "2 uncertain scenarios",
                        detail: zh
                            ? "比如对方一上来就问你什么时候方便回电，这种场景还需要你给我更明确的处理规则。"
                            : "Some callback and ambiguous cases still need clearer rules from you.",
                        action: zh ? "去 AI 分身调规则" : "Adjust AI rules"
                    )
                ],
                footer: zh
                    ? "从第一阶段来看，我已经能把基础来电接稳，但遇到更需要社交感的通话时，还需要继续贴近你的表达方式。"
                    : "In this first phase, I can handle the basics steadily, but I still need to sound more like you in socially nuanced calls."
            )

        case 2:
            return ReportMockData(
                title: zh ? "第二份实习汇报" : "Internship Report #2",
                dateRange: zh ? "2026.03.15 — 2026.03.26" : "Mar 15 – Mar 26, 2026",
                summary: zh
                    ? "这份汇报更像一次中期复盘。我重点整理了处理质量、复杂场景和相较上一阶段的变化，让你更容易看出我是不是越来越像你。"
                    : "This is more of a mid-term review focused on quality, complexity, and progress over time.",
                heroHighlights: (
                    zh ? "开始处理更复杂来电" : "More complex calls",
                    zh ? "稳定度明显提升" : "Higher consistency"
                ),
                totalCalls: 40,
                serviceDays: 26,
                totalCallers: 23,
                callTypes: [
                    ReportCallTypeItem(label: zh ? "快递/外卖" : "Delivery", ratio: 0.30, color: AppColors.primary),
                    ReportCallTypeItem(label: zh ? "推销电话" : "Spam", ratio: 0.22, color: AppColors.warning),
                    ReportCallTypeItem(label: zh ? "骚扰电话" : "Harassment", ratio: 0.18, color: AppColors.error),
                    ReportCallTypeItem(label: zh ? "未识别" : "Unidentified", ratio: 0.30, color: AppColors.accent)
                ],
                featuredCalls: [
                    ReportFeaturedCall(
                        phone: "021-6543****",
                        label: zh ? "物业" : "Property Mgmt",
                        summary: zh
                            ? "停水通知涉及时间和处理建议，我已经能把关键信息整理得比较完整，方便你回头一眼看懂。"
                            : "The outage notice included time-sensitive details, and I summarized them clearly.",
                        duration: zh ? "2分05秒" : "2m 05s",
                        isPositive: true,
                        resultTag: zh ? "处理顺畅" : "Handled well"
                    ),
                    ReportFeaturedCall(
                        phone: "400-821-****",
                        label: zh ? "银行客服" : "Bank Service",
                        summary: zh
                            ? "这类来电需要记录数字和截止时间，我处理得比第一阶段更稳，也更少遗漏关键信息。"
                            : "These calls require exact numbers and deadlines, and I handled them more reliably this time.",
                        duration: zh ? "1分48秒" : "1m 48s",
                        isPositive: true,
                        resultTag: zh ? "处理顺畅" : "Handled well"
                    ),
                    ReportFeaturedCall(
                        phone: "157****3309",
                        label: zh ? "业务咨询" : "Business Inquiry",
                        summary: zh
                            ? "对方表示有合作意向想直接联系你，我的安抚和解释还不够像真人，对方有些不耐烦。"
                            : "The caller wanted to discuss a partnership directly with you. My response still felt too rigid.",
                        duration: zh ? "0分52秒" : "0m 52s",
                        isPositive: false,
                        resultTag: zh ? "有待补强" : "Needs work"
                    )
                ],
                evaluations: [
                    ReportEvaluationItem(
                        icon: "checkmark.circle.fill",
                        title: zh ? "做得比较稳" : "Strength",
                        text: zh
                            ? "涉及时间、金额、截止日期的来电，关键信息记录完整度已经明显提升。"
                            : "I'm much better at retaining deadlines, times, and amounts from calls.",
                        tint: AppColors.success
                    ),
                    ReportEvaluationItem(
                        icon: "exclamationmark.triangle.fill",
                        title: zh ? "还要补强" : "Needs Work",
                        text: zh
                            ? "骚扰电话的识别偶尔有误判，把正常的业务咨询当推销处理了。"
                            : "Harassment detection occasionally misfires — I mistook a legitimate inquiry for spam.",
                        tint: AppColors.warning
                    )
                ],
                suggestions: [
                    ReportSuggestionItem(
                        icon: "star.bubble.fill",
                        title: zh ? "有 5 通电话还没点评" : "5 unrated calls",
                        detail: zh
                            ? "中期阶段的点评尤其有价值，能帮助我判断哪些话术已经靠近你，哪些还差点味道。"
                            : "Mid-phase ratings help me understand what already feels like you and what doesn't.",
                        action: zh ? "去通话记录点评" : "Open call history"
                    ),
                    ReportSuggestionItem(
                        icon: "hand.thumbsdown.fill",
                        title: zh ? "有 1 通不太满意的来电" : "1 weaker call flagged",
                        detail: zh
                            ? "这类电话如果你告诉我更想怎么说，我后面处理类似场景时会更有把握。"
                            : "A bit more guidance here would help me improve similar calls in the future.",
                        action: zh ? "去看差评详情" : "Review details"
                    ),
                    ReportSuggestionItem(
                        icon: "slider.horizontal.3",
                        title: zh ? "转接场景可以更像你" : "Transfer behavior tuning",
                        detail: zh
                            ? "如果你愿意补一条规则，我会更清楚什么时候该坚持代接、什么时候该更快提醒你。"
                            : "A rule here would clarify when to hold the call and when to escalate to you.",
                        action: zh ? "去 AI 分身调规则" : "Adjust AI rules"
                    )
                ],
                footer: zh
                    ? "从第二阶段看，我已经不只是能接电话，而是开始能把更多通话接得像一次完整的替你处理。接下来重点是把「像你」这件事再拉近一点。"
                    : "At this point I'm not just answering calls — I'm starting to handle them as a complete proxy for you. The next step is feeling even more like you."
            )

        default:
            return ReportMockData(
                title: zh ? "转正申请报告" : "Graduation Report",
                dateRange: zh ? "2026.03.01 — 2026.03.26" : "Mar 1 – Mar 26, 2026",
                summary: zh
                    ? "这是一份更完整的转正申请。我把这段时间的稳定度、识别能力和处理质感整理在一起，方便你集中判断是不是可以把全接管交给我。"
                    : "This is the graduation review, summarizing stability, recognition, and handling quality in one place.",
                heroHighlights: (
                    zh ? "覆盖 60 通有效来电" : "60 effective calls",
                    zh ? "已形成稳定处理风格" : "Stable handling style"
                ),
                totalCalls: 60,
                serviceDays: 26,
                totalCallers: 35,
                callTypes: [
                    ReportCallTypeItem(label: zh ? "快递/外卖" : "Delivery", ratio: 0.28, color: AppColors.primary),
                    ReportCallTypeItem(label: zh ? "推销电话" : "Spam", ratio: 0.18, color: AppColors.warning),
                    ReportCallTypeItem(label: zh ? "骚扰电话" : "Harassment", ratio: 0.15, color: AppColors.error),
                    ReportCallTypeItem(label: zh ? "未识别" : "Unidentified", ratio: 0.27, color: AppColors.accent),
                    ReportCallTypeItem(label: zh ? "重要来电" : "Important", ratio: 0.12, color: AppColors.success)
                ],
                featuredCalls: [
                    ReportFeaturedCall(
                        phone: "139****7788",
                        label: zh ? "重要来电" : "Important",
                        summary: zh
                            ? "同事紧急来电时，我已经能比较快识别事情的重要程度，并及时把你拉回处理链路里。"
                            : "When a colleague called with urgency, I recognized the priority and escalated quickly.",
                        duration: zh ? "0分45秒" : "0m 45s",
                        isPositive: true,
                        resultTag: zh ? "处理顺畅" : "Handled well"
                    ),
                    ReportFeaturedCall(
                        phone: "138****2201",
                        label: zh ? "快递员" : "Courier",
                        summary: zh
                            ? "同一个来电者再次联系时，我已经能带着上次的上下文继续回应，体验更像你亲自处理。"
                            : "When the same caller returned, I responded with memory from the previous interaction.",
                        duration: zh ? "0分52秒" : "0m 52s",
                        isPositive: true,
                        resultTag: zh ? "处理顺畅" : "Handled well"
                    )
                ],
                evaluations: [
                    ReportEvaluationItem(
                        icon: "checkmark.circle.fill",
                        title: zh ? "做得比较稳" : "Strength",
                        text: zh
                            ? "60 通有效电话下来，整体表现已经比较稳定，不再只是偶尔接得好。"
                            : "Across 60 effective calls, my performance is now consistently solid.",
                        tint: AppColors.success
                    ),
                    ReportEvaluationItem(
                        icon: "exclamationmark.triangle.fill",
                        title: zh ? "还要补强" : "Needs Work",
                        text: zh
                            ? "熟人场景和个人风格表达还有提升空间，如果你继续补一些偏好规则，我在全接管下会更有你的味道。"
                            : "Personal style and close-contact scenarios still have room to grow — more preference rules would help me match you better.",
                        tint: AppColors.warning
                    )
                ],
                suggestions: [
                    ReportSuggestionItem(
                        icon: "star.bubble.fill",
                        title: zh ? "还有 3 通电话没点评" : "3 calls still unrated",
                        detail: zh
                            ? "如果你愿意把最后几通也顺手评价掉，这份转正结论会更完整。"
                            : "A final few ratings would make this graduation review more complete.",
                        action: zh ? "去通话记录点评" : "Open call history"
                    ),
                    ReportSuggestionItem(
                        icon: "person.2.fill",
                        title: zh ? "熟人来电规则还可以再补" : "Personal-call rules needed",
                        detail: zh
                            ? "如果后面你愿意告诉我亲友、同事、合作方分别该怎么回应，我会更接近真正的全接管状态。"
                            : "A few friend or colleague rules would get me even closer to full takeover.",
                        action: zh ? "去 AI 分身调规则" : "Adjust AI rules"
                    )
                ],
                footer: zh
                    ? "如果只看这一阶段的综合表现，我已经具备了进入全接管的基础能力。接下来更像是你决定，要不要把更多信任交给我。"
                    : "Based on this phase alone, I now have the baseline ability for full takeover. The remaining decision is really about your level of trust."
            )
        }
    }
}

// MARK: - Previews

#Preview("Report 1 — ZH") {
    InternshipReportView(language: .zh, reportIndex: 1, onConfirm: {}, onReject: {}, onClose: {})
}

#Preview("Report 2 — ZH") {
    InternshipReportView(language: .zh, reportIndex: 2, onConfirm: {}, onReject: {}, onClose: {})
}

#Preview("Report 3 — ZH") {
    InternshipReportView(language: .zh, reportIndex: 3, onConfirm: {}, onReject: {}, onClose: {})
}

#Preview("Report 1 — EN") {
    InternshipReportView(language: .en, reportIndex: 1, onConfirm: {}, onReject: {}, onClose: {})
}

#Preview("Banner") {
    VStack(spacing: 16) {
        InternshipReportBanner(language: .zh, reportIndex: 1, onTap: {})
        InternshipReportBanner(language: .zh, reportIndex: 3, onTap: {})
    }
    .padding()
    .background(AppColors.backgroundSecondary)
}

//
//  PromptModalView.swift
//  CallMate
//

import SwiftUI

// MARK: - Rule Parsed Sections (design: 处理目标 / 处理要点 / 示例)
private struct ParsedRuleSections {
    var goal: String?
    var points: String?
    var examples: String?
}

private func parseRuleSections(_ rule: String) -> ParsedRuleSections {
    var goal: String?
    var points: String?
    var examples: String?
    let sectionPatterns: [(String, (String) -> Void)] = [
        ("处理目标", { goal = $0 }),
        ("处理要点", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("处理原则", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("处理策略", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("处理步骤", { points = (points ?? "") + ($0.isEmpty ? "" : $0 + "\n") }),
        ("示例", { examples = $0 })
    ]
    let remaining = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    for (title, setter) in sectionPatterns {
        let marker = title + "："
        if let range = remaining.range(of: marker) {
            let start = range.upperBound
            var end = remaining.endIndex
            for (otherTitle, _) in sectionPatterns where otherTitle != title {
                let otherMarker = otherTitle + "："
                if let otherRange = remaining.range(of: otherMarker, range: start..<remaining.endIndex),
                   otherRange.lowerBound < end {
                    end = otherRange.lowerBound
                }
            }
            let content = String(remaining[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            setter(content)
        }
    }
    return ParsedRuleSections(goal: goal, points: points, examples: examples)
}

// MARK: - Category Visual Config

private struct RuleCategoryConfig {
    let displayTitle: String
    let subtitle: String
    let iconName: String
    let color: Color
    let colorHex: String
}

private let categoryConfigs: [String: RuleCategoryConfig] = [
    "快递": RuleCategoryConfig(
        displayTitle: "快递服务",
        subtitle: "快递/驿站/派件/取件",
        iconName: "shippingbox",
        color: Color(hex: "34C759"),
        colorHex: "34C759"
    ),
    "外卖": RuleCategoryConfig(
        displayTitle: "外卖骑手",
        subtitle: "外卖/骑手",
        iconName: "bicycle",
        color: Color(hex: "FF9500"),
        colorHex: "FF9500"
    ),
    "运营商": RuleCategoryConfig(
        displayTitle: "运营商",
        subtitle: "移动/联通/电信",
        iconName: "wifi",
        color: Color(hex: "5856D6"),
        colorHex: "5856D6"
    ),
    "银行": RuleCategoryConfig(
        displayTitle: "银行保险",
        subtitle: "银行/保险/贷款/理财",
        iconName: "building.columns",
        color: Color(hex: "5AC8FA"),
        colorHex: "5AC8FA"
    ),
    "营销": RuleCategoryConfig(
        displayTitle: "营销广告",
        subtitle: "推销/房产/课程/广告",
        iconName: "megaphone",
        color: Color(hex: "A2845E"),
        colorHex: "A2845E"
    ),
    "熟人": RuleCategoryConfig(
        displayTitle: "熟人来电",
        subtitle: "熟人/朋友",
        iconName: "person.2",
        color: Color(hex: "007AFF"),
        colorHex: "007AFF"
    ),
    "未归类": RuleCategoryConfig(
        displayTitle: "未归类来电",
        subtitle: "未分类/兜底",
        iconName: "questionmark.circle",
        color: Color(hex: "8E8E93"),
        colorHex: "8E8E93"
    )
]

private func configForRule(_ rule: ProcessStrategyRule) -> RuleCategoryConfig {
    let type = rule.type
    for (key, config) in categoryConfigs {
        if type.contains(key) { return config }
    }
    return RuleCategoryConfig(
        displayTitle: type,
        subtitle: "",
        iconName: "questionmark.circle",
        color: Color(hex: "8E8E93"),
        colorHex: "8E8E93"
    )
}

// MARK: - PromptModalView

struct PromptModalView: View {
    let language: Language
    let onClose: () -> Void
    @ObservedObject private var ble = CallMateBLEClient.shared

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    @State private var showRuleConfig = false
    @State private var rules: [ProcessStrategyRule] = ProcessStrategyStore.loadRules()
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    secBanner
                    rulesCardsSection
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 40, trailing: 16))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: "F2F2F7").ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(t("完整规则", "Rules"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard ble.isReady, ble.connectedPeripheralID != nil else {
                            toastMessage = t("请先连接 EchoCard", "Please connect EchoCard first")
                            return
                        }
                        showRuleConfig = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .medium))
                            Text(t("配置", "Configure"))
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(Color(hex: "007AFF"))
                    }
                }
            }
        }
        .onAppear {
            rules = ProcessStrategyStore.loadRules()
        }
        .onChange(of: toastMessage) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    toastMessage = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showRuleConfig) {
            OnboardingView(language: language) {
                showRuleConfig = false
            }
        }
        .overlay {
            if let message = toastMessage {
                Text(message)
                    .font(DS.Typography.body)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(AppSpacing.md)
                    .frame(maxWidth: 280)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            }
        }
    }

    // MARK: - Security Banner

    private var secBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "34C759").opacity(0.15), Color(hex: "34C759").opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: "34C759"))
            }

            Text(t("当前策略同步存储在 EchoCard 设备上，且仅限此手机（主机）可读取",
                    "Strategy synced to EchoCard; only this phone (host) can read it."))
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "3A3A3C"))
                .lineSpacing(4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "34C759").opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "34C759").opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Rule Category Cards

    private var sortedRules: [ProcessStrategyRule] {
        let displayOrder = ["快递", "外卖", "运营商", "银行", "营销", "熟人", "未归类"]
        return rules.sorted { a, b in
            let ai = displayOrder.firstIndex(where: { a.type.contains($0) }) ?? displayOrder.count
            let bi = displayOrder.firstIndex(where: { b.type.contains($0) }) ?? displayOrder.count
            return ai < bi
        }
    }

    private var rulesCardsSection: some View {
        VStack(spacing: 16) {
            ForEach(sortedRules) { rule in
                RuleExpandedCard(rule: rule, language: language)
            }
        }
    }
}

// MARK: - Rule Expanded Card (inline full detail)

private struct RuleExpandedCard: View {
    let rule: ProcessStrategyRule
    let language: Language

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    private var config: RuleCategoryConfig { configForRule(rule) }
    private var sections: ParsedRuleSections { parseRuleSections(rule.rule) }

    private var subtitleTags: [String] {
        config.subtitle
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        let outerShape = RoundedRectangle(cornerRadius: 20)
        ZStack(alignment: .top) {
            outerShape
                .fill(.ultraThinMaterial)
                .overlay(
                    outerShape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 230/255, green: 240/255, blue: 1).opacity(0.78), location: 0),
                                .init(color: Color.white.opacity(0.68), location: 0.4),
                                .init(color: Color.white.opacity(0.58), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .overlay(
                    outerShape.stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: Color.white.opacity(0.82), radius: 0, y: -0.5)
                .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                .shadow(color: Color.black.opacity(0.05), radius: 12, y: 8)

            LinearGradient(
                colors: [config.color.opacity(0.06), .clear],
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
                examplesBlock
            }
            .padding(18)
        }
        .clipShape(outerShape)
    }

    // MARK: - Header

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
                    .shadow(color: config.color.opacity(0.094), radius: 3, y: 1)

                Image(systemName: config.iconName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(config.color)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                Text(config.displayTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(hex: "1D1D1F"))
                    .tracking(-0.3)

                if !subtitleTags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(subtitleTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(config.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(config.color.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Goal + Key Points

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
                            Text(t("处理目标", "Goal"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: "86868B"))
                                .tracking(0.3)
                            Text(goal)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "3A3A3C"))
                                .lineSpacing(6)
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
                            Text(t("处理要点", "Key Points"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: "86868B"))
                                .tracking(0.3)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(pointLines(points), id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(hex: "3A3A3C"))
                                        .lineSpacing(4)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.48), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Examples (amber card)

    private var examplesBlock: some View {
        let examples = sections.examples?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Group {
            if !examples.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("示例", "Examples"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 184/255, green: 134/255, blue: 11/255))
                        .tracking(0.3)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(pointLines(examples), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 107/255, green: 91/255, blue: 62/255))
                                .lineSpacing(4)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 1, green: 179/255, blue: 64/255).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 1, green: 179/255, blue: 64/255).opacity(0.18), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 12)
            }
        }
    }

    private func pointLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Identifiable conformance for sheet

extension ProcessStrategyRule: Identifiable {}

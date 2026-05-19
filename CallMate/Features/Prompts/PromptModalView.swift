//
//  PromptModalView.swift
//  CallMate
//

import SwiftUI

// MARK: - Rule Parsed Sections（Skill 格式：条件→处理 / ## 禁止）

private struct ParsedRuleSections {
    var rules: [String] = []      // ## 禁止 之前的条件→处理行
    var forbidden: [String] = []  // ## 禁止 之后的行
}

private func parseRuleSections(_ body: String) -> ParsedRuleSections {
    var rules: [String] = []
    var forbidden: [String] = []
    var inForbidden = false
    for line in body.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("## 禁止") { inForbidden = true; continue }
        if trimmed.hasPrefix("##") { inForbidden = false; continue }
        guard !trimmed.isEmpty else { continue }
        if inForbidden { forbidden.append(trimmed) } else { rules.append(trimmed) }
    }
    return ParsedRuleSections(rules: rules, forbidden: forbidden)
}

// MARK: - Category Visual Config（key = SkillRule.tag）

private struct RuleCategoryConfig {
    let displayTitle: String
    let subtitle: String
    let iconName: String
    let color: Color
    let colorHex: String
}

private let categoryConfigs: [String: RuleCategoryConfig] = [
    "express": RuleCategoryConfig(
        displayTitle: "快递服务",
        subtitle: "快递/驿站/派件/取件",
        iconName: "shippingbox",
        color: Color(hex: "34C759"),
        colorHex: "34C759"
    ),
    "takeout": RuleCategoryConfig(
        displayTitle: "外卖骑手",
        subtitle: "外卖/骑手",
        iconName: "bicycle",
        color: Color(hex: "FF9500"),
        colorHex: "FF9500"
    ),
    "telecom": RuleCategoryConfig(
        displayTitle: "运营商",
        subtitle: "移动/联通/电信",
        iconName: "wifi",
        color: Color(hex: "5856D6"),
        colorHex: "5856D6"
    ),
    "finance": RuleCategoryConfig(
        displayTitle: "银行保险",
        subtitle: "银行/保险/贷款/理财",
        iconName: "building.columns",
        color: Color(hex: "5AC8FA"),
        colorHex: "5AC8FA"
    ),
    "marketing": RuleCategoryConfig(
        displayTitle: "营销广告",
        subtitle: "推销/房产/课程/广告",
        iconName: "megaphone",
        color: Color(hex: "A2845E"),
        colorHex: "A2845E"
    ),
    "acquaintance": RuleCategoryConfig(
        displayTitle: "熟人来电",
        subtitle: "通讯录联系人",
        iconName: "person.2",
        color: Color(hex: "007AFF"),
        colorHex: "007AFF"
    ),
    "unknown": RuleCategoryConfig(
        displayTitle: "未归类来电",
        subtitle: "未分类/兜底",
        iconName: "questionmark.circle",
        color: Color(hex: "8E8E93"),
        colorHex: "8E8E93"
    )
]

private func configForSkill(_ skill: SkillRule) -> RuleCategoryConfig {
    if let config = categoryConfigs[skill.tag] { return config }
    // 兜底：用 name 做简单匹配（用户自定义 skill）
    return RuleCategoryConfig(
        displayTitle: skill.name,
        subtitle: skill.description,
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
    @State private var skills: [SkillRule] = SkillStore.loadSkills()
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    secBanner
                    skillCardsSection
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
            skills = SkillStore.loadSkills()
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

    // MARK: - Skill Category Cards

    private let displayOrder = ["express", "takeout", "telecom", "finance", "marketing", "acquaintance", "unknown"]

    private var sortedSkills: [SkillRule] {
        skills.sorted { a, b in
            let ai = displayOrder.firstIndex(of: a.tag) ?? displayOrder.count
            let bi = displayOrder.firstIndex(of: b.tag) ?? displayOrder.count
            return ai < bi
        }
    }

    private var skillCardsSection: some View {
        VStack(spacing: 16) {
            ForEach(sortedSkills) { skill in
                SkillExpandedCard(skill: skill, language: language)
            }
        }
    }
}

// MARK: - Skill Expanded Card

private struct SkillExpandedCard: View {
    let skill: SkillRule
    let language: Language

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    private var config: RuleCategoryConfig { configForSkill(skill) }
    private var sections: ParsedRuleSections { parseRuleSections(skill.body) }

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
                rulesBlock
                forbiddenBlock
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

    // MARK: - 处理规则（条件 → 处理方式）

    private var rulesBlock: some View {
        let rules = sections.rules
        return Group {
            if !rules.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("处理规则", "Handling Rules"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "86868B"))
                        .tracking(0.3)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rules, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "3A3A3C"))
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - 禁止事项（红色卡片）

    private var forbiddenBlock: some View {
        let items = sections.forbidden
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("禁止", "Restrictions"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 200/255, green: 50/255, blue: 50/255))
                        .tracking(0.3)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 150/255, green: 40/255, blue: 40/255))
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 1, green: 59/255, blue: 48/255).opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 1, green: 59/255, blue: 48/255).opacity(0.15), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 12)
            }
        }
    }

}

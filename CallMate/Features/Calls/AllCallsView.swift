//
//  AllCallsView.swift
//  CallMate
//

import SwiftUI
import SwiftData

enum CallListMode {
    case regular
    case simulationOnly
}

struct AllCallsView: View {
    let language: Language
    let onBack: () -> Void
    let onCallClick: (CallLog) -> Void
    let mode: CallListMode
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    @State private var searchText = ""
    @State private var dateFilter = ""
    @State private var isFilterOpen = false

    @Query(sort: \CallLog.startedAt, order: .reverse) private var allCalls: [CallLog]

    init(
        language: Language,
        onBack: @escaping () -> Void,
        onCallClick: @escaping (CallLog) -> Void,
        mode: CallListMode = .regular
    ) {
        self.language = language
        self.onBack = onBack
        self.onCallClick = onCallClick
        self.mode = mode
    }

    private var supportsFilter: Bool { mode == .regular }

    private var visibleCalls: [CallLog] {
        allCalls.filter { call in
            switch mode {
            case .regular:
                return !call.isSimulation
            case .simulationOnly:
                return call.isSimulation
            }
        }
    }
    
    private var filteredCalls: [CallLog] {
        guard supportsFilter else { return visibleCalls }
        return visibleCalls.filter { call in
            let matchesSearch = searchText.isEmpty ||
                call.phone.contains(searchText) || call.label.contains(searchText) || (call.displaySummary ?? "").contains(searchText)
            let dateSearchTarget = "\(displayTime(call.startedAt)) \(searchDateTime(call.startedAt))"
            let matchesDate = dateFilter.isEmpty || dateSearchTarget.contains(dateFilter)
            return matchesSearch && matchesDate
        }
    }

    private var repeatCallCountByPhone: [String: Int] {
        Dictionary(grouping: visibleCalls, by: \.phone).mapValues(\.count)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if supportsFilter && isFilterOpen {
                    filterBar
                }
                if filteredCalls.isEmpty {
                    emptyState
                } else {
                    callList
                }
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(mode == .regular ? t("全部通话", "All Calls") : t("模拟测试通话", "Simulation Calls"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
                if supportsFilter {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                isFilterOpen.toggle()
                            }
                        } label: {
                            Image(systemName: isFilterOpen ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(isFilterOpen ? Color(hex: "007AFF") : AppColors.textSecondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            logStrangerTagDebug(reason: "all_calls_on_appear")
        }
        .onChange(of: visibleCalls.count) { _, _ in
            logStrangerTagDebug(reason: "visible_calls_changed")
        }
    }
    
    // MARK: - Filter Bar
    
    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textTertiary)
                TextField(t("搜索手机号、标签或摘要", "Search phone, label or summary"), text: $searchText)
                    .font(.system(size: 15))
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            .padding(12)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.border, lineWidth: 0.5)
            )
            
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textTertiary)
                TextField(t("日期 (例如: 2月3日)", "Date (e.g., Feb 3)"), text: $dateFilter)
                    .font(.system(size: 15))
                    .textFieldStyle(.plain)
                if !dateFilter.isEmpty {
                    Button {
                        dateFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            .padding(12)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.border, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.backgroundSecondary)
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(AppColors.textTertiary.opacity(0.5))
            Text(emptyStateTitle)
                .font(.system(size: 15))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            if supportsFilter && (!searchText.isEmpty || !dateFilter.isEmpty) {
                Button {
                    searchText = ""
                    dateFilter = ""
                } label: {
                    Text(t("清除筛选", "Clear Filters"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "007AFF"))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !supportsFilter || (searchText.isEmpty && dateFilter.isEmpty) {
            return mode == .regular ? t("暂无通话记录", "No calls yet") : t("暂无模拟测试通话", "No simulation calls yet")
        }
        return t("未找到相关通话记录", "No records found")
    }
    
    // MARK: - Call List
    
    private var callList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(filteredCalls) { call in
                    Button {
                        onCallClick(call)
                    } label: {
                        SimCallRowView(
                            call: call,
                            language: language,
                            repeatCallCount: repeatCallCountByPhone[call.phone] ?? 0,
                            showsRepeatTag: mode == .regular
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private func displayTime(_ date: Date) -> String {
        RelativeDateFormatter(language: language).string(from: date)
    }

    private func searchDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        formatter.dateFormat = language == .zh ? "yyyy-MM-dd M月d日 HH:mm" : "yyyy-MM-dd MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private func logStrangerTagDebug(reason: String) {
        let sample = visibleCalls.prefix(20).map { call in
            "phone=\(call.phone) label=\(call.label)"
        }
        print("[StrangerTag][AllCallsView] reason=\(reason) visible=\(visibleCalls.count) repeatByPhone=\(repeatCallCountByPhone) sample=\(sample)")
    }
}

// MARK: - Simulation Call Row (matches dashboard CallRowView design)

private struct SimCallRowView: View {
    let call: CallLog
    let language: Language
    let repeatCallCount: Int
    let showsRepeatTag: Bool

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var aiSummaryLine: String? {
        (call.fullSummary?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private var strangerRepeatTagText: String? {
        guard showsRepeatTag else { return nil }
        if repeatCallCount == 2 { return t("重复", "Repeat") }
        if repeatCallCount > 2 { return t("多次", "Multiple") }
        return nil
    }

    private enum CallerCategory {
        case personalContact, courier, rider, carrier, bank, marketing, uncategorized
    }

    private var trimmedLabel: String {
        call.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPlaceholderLabel: Bool {
        let lowered = trimmedLabel.lowercased()
        return trimmedLabel.isEmpty
            || lowered.contains("未知")
            || lowered.contains("unknown")
            || lowered.contains("陌生号码")
            || lowered.contains("未识别")
    }

    private var callerCategory: CallerCategory {
        let label = trimmedLabel
        if label.isEmpty { return .uncategorized }
        let lowered = label.lowercased()

        if lowered.contains("未知") || lowered.contains("unknown") || lowered.contains("陌生号码") || lowered.contains("未识别") {
            return .uncategorized
        }

        let riderKeywords = ["外卖", "骑手", "美团", "饿了么"]
        if riderKeywords.contains(where: { lowered.contains($0) }) { return .rider }

        let courierKeywords = ["快递", "驿站", "派件", "顺丰", "圆通", "中通", "韵达", "申通",
                               "极兔", "菜鸟", "courier", "express", "delivery"]
        if courierKeywords.contains(where: { lowered.contains($0) }) { return .courier }

        let carrierKeywords = ["移动", "联通", "电信", "10086", "10010", "10000",
                               "china mobile", "china unicom", "china telecom"]
        if carrierKeywords.contains(where: { lowered.contains($0) }) { return .carrier }

        let bankKeywords = ["银行", "保险", "贷款", "理财", "信用卡", "催收",
                            "bank", "insurance", "loan", "finance"]
        if bankKeywords.contains(where: { lowered.contains($0) }) { return .bank }

        let marketingKeywords = ["推广", "推销", "广告", "营销", "marketing"]
        if marketingKeywords.contains(where: { lowered.contains($0) }) { return .marketing }

        let digitsOnly = label.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || $0 == "+" || $0 == "-" || $0 == " " }
        if digitsOnly { return .uncategorized }

        return .personalContact
    }

    private var categoryColor: Color {
        switch callerCategory {
        case .personalContact: return Color(hex: "007AFF")
        case .courier:         return Color(hex: "34C759")
        case .rider:           return Color(hex: "FF9500")
        case .carrier:         return Color(hex: "5856D6")
        case .bank:            return Color(hex: "5AC8FA")
        case .marketing:       return Color(hex: "A2845E")
        case .uncategorized:   return Color(hex: "8E8E93")
        }
    }

    private var callDirectionIconName: String {
        call.isOutboundCall ? "arrow.up.right" : "arrow.down.left"
    }

    private var displayContactText: String {
        let trimmedPhone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if call.isOutboundCall {
            if !isPlaceholderLabel { return trimmedLabel }
            if !trimmedPhone.isEmpty { return trimmedPhone }
            return t("外呼电话", "Outbound Call")
        }
        return callerCategory == .uncategorized ? call.phone : trimmedLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Text(call.displaySummary ?? t("未识别内容", "Unrecognized"))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color(lightHex: "374151", darkHex: "D1D5DB"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Text(RelativeDateFormatter(language: language).string(from: call.startedAt))
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .padding(.bottom, 8)

            HStack(alignment: .center, spacing: 6) {
                BotIcon(size: 14, color: AppColors.textTertiary.opacity(0.6))
                Text(aiSummaryLine ?? t("通话内容识别失败", "Call content not recognized"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                let color = categoryColor

                Text(displayContactText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                HStack(spacing: 4) {
                    Image(systemName: callDirectionIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                    Text(formatCallDuration(call.durationSeconds))
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textTertiary)
                }

                if let tag = strangerRepeatTagText {
                    Text(tag)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(AppColors.backgroundGrouped)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private func formatCallDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return language == .zh ? "\(seconds)秒" : "\(seconds)s"
        }
        let m = seconds / 60
        let s = seconds % 60
        if language == .zh {
            return s > 0 ? "\(m)分\(s)秒" : "\(m)分"
        }
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}

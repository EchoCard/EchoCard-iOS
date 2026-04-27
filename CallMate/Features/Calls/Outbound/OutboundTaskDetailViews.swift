//
//  OutboundTaskDetailViews.swift
//  CallMate
//

import SwiftUI

struct OutboundAllHistoryTasksView: View {
    let language: Language
    let tasks: [OutboundTask]
    let onBack: () -> Void
    let onTaskClick: (OutboundTask) -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(t("全部历史任务", "All History Tasks"))
                    .font(DS.Typography.title)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(AppSpacing.lg)
            .background(AppColors.surface)

            if tasks.isEmpty {
                VStack(spacing: DS.Spacing.x2) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(AppColors.textTertiary.opacity(0.5))
                    Text(t("暂无历史任务。", "No history tasks yet."))
                        .font(DS.Typography.body)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DS.Spacing.x3)
                .background(AppColors.backgroundSecondary)
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.x2) {
                        ForEach(tasks) { task in
                            Button {
                                onTaskClick(task)
                            } label: {
                                HStack(spacing: AppSpacing.md) {
                                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                        Text(task.promptType)
                                            .font(DS.Typography.body.weight(.semibold))
                                            .foregroundColor(AppColors.textPrimary)
                                            .lineLimit(1)
                                        Text(t("呼叫 \(task.contacts.count) 人", "Called \(task.contacts.count) contacts"))
                                            .font(DS.Typography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                                        Text(task.status.title(language: language))
                                            .font(DS.Typography.caption.weight(.semibold))
                                            .foregroundColor(task.status.color)
                                        Text(dateTimeText(task.createdAt))
                                            .font(DS.Typography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(DS.Typography.caption.weight(.semibold))
                                        .foregroundColor(AppColors.textTertiary)
                                }
                                .padding(DS.Spacing.x2)
                                .dsCardStyle()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(AppSpacing.lg)
                }
                .background(AppColors.backgroundSecondary)
            }
        }
    }

    private func dateTimeText(_ date: Date) -> String {
        RelativeDateFormatter(language: language).string(from: date)
    }
}

struct OutboundTaskDetailView: View {
    let language: Language
    let task: OutboundTask
    let calls: [CallLog]
    let onBack: () -> Void
    let onCallClick: (CallLog) -> Void
    let onRunNow: () -> Void
    let onReuse: () -> Void
    let onDelete: () -> Void

    @State private var showPromptDetail = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var callByPhone: [String: CallLog] {
        let dict = Dictionary(calls.map { ($0.phone, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.startedAt > rhs.startedAt ? lhs : rhs
        })
        let contactPhones = task.contacts.map(\.phone)
        print("[OutboundDetail][CallByPhone] taskID=\(task.id) totalCalls=\(calls.count) contactCount=\(contactPhones.count)")
        for phone in contactPhones {
            if let call = dict[phone] {
                print("[OutboundDetail][CallByPhone]   ✅ phone='\(phone)' → callId=\(call.id) status=\(call.statusRaw) duration=\(call.durationSeconds)s outboundTaskID=\(call.outboundTaskID?.uuidString ?? "nil")")
            } else {
                print("[OutboundDetail][CallByPhone]   ⚠️ phone='\(phone)' → NO matching CallLog (shows 待呼叫)")
                // Log all call phones to detect format mismatches
                let callPhones = calls.map(\.phone)
                if !callPhones.isEmpty {
                    print("[OutboundDetail][CallByPhone]     available call phones: \(callPhones)")
                }
            }
        }
        return dict
    }

    private var attemptedCount: Int {
        task.dialSuccessCount + task.dialFailureCount
    }

    private var progress: Double {
        guard !task.contacts.isEmpty else { return 0 }
        return min(1.0, Double(attemptedCount) / Double(task.contacts.count))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.md) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(t("任务详情", "Task Detail"))
                    .font(DS.Typography.title)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(AppSpacing.lg)
            .background(AppColors.surface)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.x3) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        HStack {
                            Text(task.promptType)
                                .font(DS.Typography.body.weight(.semibold))
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(task.status.title(language: language))
                                .font(DS.Typography.caption.weight(.semibold))
                                .foregroundColor(task.status.color)
                                .padding(.horizontal, DS.Spacing.x1)
                                .padding(.vertical, 2)
                                .background(task.status.color.opacity(0.12))
                                .cornerRadius(DS.Radius.button)
                        }
                        Text(t("创建时间：\(dateTimeText(task.createdAt))", "Created: \(dateTimeText(task.createdAt))"))
                            .font(DS.Typography.caption)
                            .foregroundColor(AppColors.textSecondary)

                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            HStack {
                                Text(t("执行进度", "Progress"))
                                    .font(DS.Typography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                                Text("\(attemptedCount)/\(task.contacts.count)")
                                    .font(DS.Typography.caption.weight(.semibold))
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 999)
                                        .fill(AppColors.border.opacity(0.8))
                                    RoundedRectangle(cornerRadius: 999)
                                        .fill(AppColors.primary)
                                        .frame(width: max(4, proxy.size.width * progress))
                                }
                            }
                            .frame(height: 6)
                        }

                        Divider()

                        Button {
                            showPromptDetail = true
                        } label: {
                            HStack {
                                Text(t("查看策略详情", "View Strategy"))
                                    .font(DS.Typography.caption.weight(.semibold))
                                    .foregroundColor(AppColors.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(DS.Typography.caption.weight(.semibold))
                                    .foregroundColor(AppColors.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(DS.Spacing.x2)
                    .dsCardStyle()
                    .sheet(isPresented: $showPromptDetail) {
                        NavigationStack {
                            ScrollView {
                                Text(task.promptRule)
                                    .font(DS.Typography.body)
                                    .foregroundColor(AppColors.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(DS.Spacing.x2)
                            }
                            .background(AppColors.backgroundSecondary)
                            .navigationTitle(task.promptType)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(t("关闭", "Close")) {
                                        showPromptDetail = false
                                    }
                                }
                            }
                        }
                    }

                    VStack(spacing: AppSpacing.sm) {
                        if task.status == .scheduled {
                            Button(action: onRunNow) {
                                Text(t("立即执行", "Run Now"))
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(AppColors.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DS.Spacing.x1)
                                    .background(AppColors.primary.opacity(0.08))
                                    .cornerRadius(DS.Radius.button)
                            }
                            .buttonStyle(.plain)
                        } else if task.status == .completed || task.status == .failed || task.status == .partial {
                            Button(action: onReuse) {
                                Text(t("复用此策略", "Reuse Strategy"))
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(AppColors.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DS.Spacing.x1)
                                    .background(AppColors.primary.opacity(0.08))
                                    .cornerRadius(DS.Radius.button)
                            }
                            .buttonStyle(.plain)
                        }

                    }

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(t("通话记录", "Call Records"))
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundColor(AppColors.textPrimary)
                        VStack(spacing: DS.Spacing.x2) {
                            ForEach(task.contacts, id: \.id) { contact in
                                let call = callByPhone[contact.phone]
                                let isConnected = call?.statusRaw == CallStatus.handled.rawValue
                                let isFailed = call != nil && !isConnected
                                Button {
                                    if isConnected, let call { onCallClick(call) }
                                } label: {
                                    HStack(spacing: AppSpacing.md) {
                                        Circle()
                                            .fill(isConnected
                                                  ? AppColors.success.opacity(0.15)
                                                  : (isFailed ? AppColors.error.opacity(0.15) : AppColors.textTertiary.opacity(0.12)))
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Image(systemName: "phone.arrow.up.right")
                                                    .font(DS.Typography.body.weight(.semibold))
                                                    .foregroundColor(isConnected
                                                                     ? AppColors.success
                                                                     : (isFailed ? AppColors.error : AppColors.textTertiary))
                                            )
                                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                            Text(contact.name)
                                                .font(DS.Typography.body.weight(.semibold))
                                                .foregroundColor(AppColors.textPrimary)
                                            HStack(spacing: AppSpacing.xs) {
                                                Text(contact.phone)
                                                    .font(DS.Typography.caption)
                                                    .foregroundColor(AppColors.textSecondary)
                                                if let call, call.durationSeconds > 0 {
                                                    Text("•")
                                                        .font(DS.Typography.caption)
                                                        .foregroundColor(AppColors.textTertiary)
                                                    Text(formatDuration(call.durationSeconds))
                                                        .font(DS.Typography.caption)
                                                        .foregroundColor(AppColors.textSecondary)
                                                }
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Text(isConnected ? t("已接通", "Connected") : (isFailed ? t("未接通", "Failed") : t("待呼叫", "Pending")))
                                            .font(DS.Typography.caption.weight(.semibold))
                                            .foregroundColor(isConnected ? AppColors.success : (isFailed ? AppColors.error : AppColors.textSecondary))
                                        if isConnected {
                                            Image(systemName: "chevron.right")
                                                .font(DS.Typography.caption.weight(.semibold))
                                                .foregroundColor(AppColors.textTertiary)
                                        }
                                    }
                                    .padding(DS.Spacing.x2)
                                    .dsCardStyle()
                                }
                                .buttonStyle(.plain)
                                .disabled(!isConnected)
                            }
                        }
                    }
                }
                .padding(AppSpacing.lg)
            }
            .background(AppColors.backgroundSecondary)
        }
    }

    private func dateTimeText(_ date: Date) -> String {
        RelativeDateFormatter(language: language).string(from: date)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct OutboundHistoryCallRow: View {
    let call: CallLog
    let language: Language

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Circle()
                .fill(call.statusRaw == CallStatus.handled.rawValue ? AppColors.success.opacity(0.15) : AppColors.error.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "phone.arrow.up.right")
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundColor(call.statusRaw == CallStatus.handled.rawValue ? AppColors.success : AppColors.error)
                )

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(call.label.isEmpty ? call.phone : call.label)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: AppSpacing.xs) {
                    Text(call.phone)
                        .font(DS.Typography.caption)
                        .foregroundColor(AppColors.textSecondary)
                    if call.durationSeconds > 0 {
                        Text("•")
                            .font(DS.Typography.caption)
                            .foregroundColor(AppColors.textTertiary)
                        Text(formatDuration(call.durationSeconds))
                            .font(DS.Typography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(timeText(call.startedAt))
                .font(DS.Typography.caption)
                .foregroundColor(AppColors.textSecondary)
            Image(systemName: "chevron.right")
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundColor(AppColors.textTertiary)
        }
        .padding(DS.Spacing.x2)
        .dsCardStyle()
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func timeText(_ date: Date) -> String {
        RelativeDateFormatter(language: language).string(from: date)
    }
}

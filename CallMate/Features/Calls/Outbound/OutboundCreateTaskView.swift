//
//  OutboundCreateTaskView.swift
//  CallMate
//

import SwiftUI
import SwiftData

struct OutboundCreateTaskDraft {
    var promptID: UUID?
    var contactMode: ContactMode
    var selectedPhones: Set<String>
    var manualPhonesText: String
    var timingMode: TimingMode
    var scheduledTime: Date
    var callFrequency: Int
    var redialMissed: Bool

    static let empty = OutboundCreateTaskDraft(
        promptID: nil,
        contactMode: .existing,
        selectedPhones: [],
        manualPhonesText: "",
        timingMode: .immediate,
        scheduledTime: Date().addingTimeInterval(15 * 60),
        callFrequency: 30,
        redialMissed: false
    )
}

struct OutboundCreateTaskSubmission {
    let promptName: String
    let promptContent: String
    let contacts: [OutboundContact]
    let scheduledAt: Date?
    let status: OutboundTaskStatus
    let callFrequency: Int
    let redialMissed: Bool
}

struct OutboundCreateTaskView: View {
    let language: Language
    let templates: [OutboundPromptTemplate]
    let existingContacts: [OutboundContact]
    let initialDraft: OutboundCreateTaskDraft?
    let onOpenAI: (() -> Void)?
    let onClose: () -> Void
    let onCreate: (OutboundCreateTaskSubmission) -> Void

    @State private var step: Step = .main
    @State private var showPromptPicker = false
    @State private var promptSearchText = ""
    @State private var alertMessage: String?

    @State private var selectedPromptID: UUID?
    @State private var contactMode: ContactMode = .existing
    @State private var selectedPhones: Set<String> = []
    @State private var manualPhonesText = ""
    @State private var timingMode: TimingMode = .immediate
    @State private var scheduledTime: Date = Date().addingTimeInterval(15 * 60)
    @State private var callFrequency: Int = 30
    @State private var redialMissed: Bool = false

    private enum Step {
        case main
        case contacts
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private func riskReasonMessage(_ reason: OutboundDialRiskReason) -> String {
        switch reason {
        case .emergencyNumber:
            return t("包含紧急号码（如 110/112/911/999），默认禁止 AI 外呼。", "Emergency numbers (e.g. 110/112/911/999) are blocked by default.")
        case .deepNight:
            return t(
                "当前为当地深夜时段（\(OutboundDialRiskControl.deepNightStartHour):00-\(OutboundDialRiskControl.deepNightEndHour):00），默认禁止 AI 外呼。",
                "Local deep-night window (\(OutboundDialRiskControl.deepNightStartHour):00-\(OutboundDialRiskControl.deepNightEndHour):00), AI outbound calling is blocked by default."
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.x3) {
                    if step == .main {
                        taskConfigSection
                        timingSection
                        advancedOptionsSection
                    } else {
                        contactsStepSection
                    }
                }
                .padding(DS.Spacing.x2)
                .padding(.bottom, DS.Spacing.x6 * 2)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(step == .main ? t("创建批量任务", "Create Batch Task") : t("选择联系人", "Choose Contacts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if step == .contacts {
                            step = .main
                        } else {
                            onClose()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundStyle(AppColors.primary)
                    }
                }
                if step == .contacts {
                    ToolbarItem(placement: .primaryAction) {
                        Button(t("完成", "Done")) {
                            step = .main
                        }
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundColor(AppColors.primary)
                    }
                } else if let onOpenAI {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: onOpenAI) {
                            HStack(spacing: DS.Spacing.x1) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13, weight: .bold))
                                Text(t("AI智能创建", "AI Create"))
                                    .font(DS.Typography.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, DS.Spacing.x1 + 2)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(
                                    colors: [Color.purple, AppColors.primary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if step == .main {
                    Button(action: createAction) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(t("创建任务", "Create Task"))
                        }
                        .font(AppTypography.bodyEmphasized)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(AppColors.primary)
                        .cornerRadius(AppRadius.md)
                    }
                    .buttonStyle(.plain)
                    .padding(DS.Spacing.x2)
                    .background(AppColors.surface)
                }
            }
        }
        .sheet(isPresented: $showPromptPicker, onDismiss: {
            promptSearchText = ""
        }) {
            promptPickerSheet
        }
        .alert(t("提示", "Notice"), isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button(t("知道了", "OK"), role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear {
            applyInitialDraft()
        }
    }

    // Header is now provided by NavigationStack toolbar

    private var taskConfigSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            Text(t("话术与名单", "Prompt & Contacts"))
                .font(DS.Typography.body.weight(.semibold))

            VStack(spacing: 0) {
                Button {
                    showPromptPicker = true
                } label: {
                    HStack {
                        Text(t("话术配置", "Prompt"))
                            .font(DS.Typography.body)
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Text(selectedTemplate?.name ?? t("请选择", "Select"))
                            .font(DS.Typography.caption)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(DS.Typography.caption.weight(.semibold))
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .padding(DS.Spacing.x2)
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, DS.Spacing.x2)

                Button {
                    step = .contacts
                } label: {
                    HStack {
                        Text(t("外呼名单", "Contacts"))
                            .font(DS.Typography.body)
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Text(contactSummaryText)
                            .font(DS.Typography.caption)
                            .foregroundColor(AppColors.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(DS.Typography.caption.weight(.semibold))
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .padding(DS.Spacing.x2)
                }
                .buttonStyle(.plain)
            }
            .background(AppColors.surface)
            .cornerRadius(DS.Radius.button)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.button)
                    .stroke(AppColors.border, lineWidth: 1)
            )
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            Text(t("执行设置", "Execution"))
                .font(DS.Typography.body.weight(.semibold))
            VStack(spacing: 0) {
                HStack {
                    Text(t("执行时间", "Timing"))
                        .font(DS.Typography.body)
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    Picker("", selection: $timingMode) {
                        Text(t("立即外呼", "Immediate")).tag(TimingMode.immediate)
                        Text(t("定时外呼", "Scheduled")).tag(TimingMode.scheduled)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(AppColors.textSecondary)
                }
                .padding(DS.Spacing.x2)

                if timingMode == .scheduled {
                    Divider()
                        .padding(.leading, DS.Spacing.x2)
                    DatePicker(
                        t("选择时间", "Schedule Time"),
                        selection: $scheduledTime,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .padding(DS.Spacing.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                    .padding(.leading, DS.Spacing.x2)

                HStack {
                    Text(t("呼叫频率", "Call Frequency"))
                        .font(DS.Typography.body)
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    HStack(spacing: DS.Spacing.x1) {
                        Button {
                            callFrequency = max(5, callFrequency - 5)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(callFrequency <= 5 ? AppColors.textTertiary : AppColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(callFrequency <= 5)

                        Text(t("\(callFrequency) 通/时", "\(callFrequency)/h"))
                            .font(DS.Typography.caption.weight(.semibold))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(minWidth: 72)

                        Button {
                            callFrequency = min(120, callFrequency + 5)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(callFrequency >= 120 ? AppColors.textTertiary : AppColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(callFrequency >= 120)
                    }
                }
                .padding(DS.Spacing.x2)
            }
            .background(AppColors.surface)
            .cornerRadius(DS.Radius.button)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.button)
                    .stroke(AppColors.border, lineWidth: 1)
            )
        }
    }

    private var advancedOptionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            Text(t("高级选项", "Advanced"))
                .font(DS.Typography.body.weight(.semibold))

            HStack {
                Text(t("重拨未接通的号码", "Redial Missed Calls"))
                    .font(DS.Typography.body)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Toggle("", isOn: $redialMissed)
                    .labelsHidden()
            }
            .padding(DS.Spacing.x2)
            .background(AppColors.surface)
            .cornerRadius(DS.Radius.button)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.button)
                    .stroke(AppColors.border, lineWidth: 1)
            )

            Text(t("开启后，对未接通号码在任务结束后自动重拨一次。", "When enabled, unanswered numbers are redialed once after task completion."))
                .font(DS.Typography.caption)
                .foregroundColor(AppColors.textSecondary)
        }
    }

    private var contactsStepSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            Picker("", selection: $contactMode) {
                Text(t("从列表选择", "From List")).tag(ContactMode.existing)
                Text(t("手动输入", "Manual Input")).tag(ContactMode.manual)
            }
            .pickerStyle(.segmented)

            if contactMode == .existing {
                if existingContacts.isEmpty {
                    Text(t("暂无可选联系人，请切换手动输入。", "No contacts found. Switch to manual input."))
                        .font(DS.Typography.body)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(DS.Spacing.x2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsCardStyle()
                } else {
                    VStack(spacing: AppSpacing.xs) {
                        ForEach(existingContacts) { item in
                            Button {
                                togglePhoneSelection(item.phone)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: AppSpacing.xxxs) {
                                        Text(item.name)
                                            .font(DS.Typography.body)
                                            .foregroundColor(AppColors.textPrimary)
                                        Text(item.phone)
                                            .font(DS.Typography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedPhones.contains(item.phone) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedPhones.contains(item.phone) ? AppColors.primary : AppColors.textTertiary)
                                }
                                .padding(DS.Spacing.x2)
                                .background(AppColors.surface)
                                .cornerRadius(DS.Radius.button)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.button)
                                        .stroke(AppColors.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                TextEditor(text: $manualPhonesText)
                    .font(DS.Typography.body)
                    .frame(minHeight: 140)
                    .padding(DS.Spacing.x2)
                    .background(AppColors.surface)
                    .cornerRadius(DS.Radius.button)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.button)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
                Text(t("可输入多个号码，使用逗号或换行分隔。", "Enter multiple numbers separated by commas or new lines."))
                    .font(DS.Typography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }

    private var promptPickerSheet: some View {
        NavigationStack {
            List {
                if filteredTemplates.isEmpty {
                    Text(t("没有匹配的模版。", "No matching templates found."))
                        .font(DS.Typography.body)
                        .foregroundColor(AppColors.textSecondary)
                } else {
                    ForEach(filteredTemplates, id: \.id) { template in
                        Button {
                            selectedPromptID = template.id
                            showPromptPicker = false
                        } label: {
                            HStack(alignment: .top, spacing: AppSpacing.sm) {
                                VStack(alignment: .leading, spacing: AppSpacing.xxxs) {
                                    Text(template.name)
                                        .font(AppTypography.body)
                                        .foregroundColor(AppColors.textPrimary)
                                    Text(template.content.replacingOccurrences(of: "\n", with: " "))
                                        .font(DS.Typography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if selectedPromptID == template.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppColors.primary)
                                }
                            }
                            .padding(.vertical, AppSpacing.xxxs)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $promptSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(t("搜索模版名称或内容", "Search name or content"))
            )
            .navigationTitle(t("选择模版", "Select Template"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("完成", "Done")) { showPromptPicker = false }
                }
            }
        }
    }

    private var selectedTemplate: OutboundPromptTemplate? {
        templates.first(where: { $0.id == selectedPromptID }) ?? templates.first
    }

    private var filteredTemplates: [OutboundPromptTemplate] {
        let keyword = promptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return templates }
        return templates.filter { template in
            template.name.localizedCaseInsensitiveContains(keyword)
            || template.content.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var contactSummaryText: String {
        if contactMode == .existing {
            if selectedPhones.isEmpty {
                return t("请选择", "Select")
            }
            return t("已选 \(selectedPhones.count) 人", "\(selectedPhones.count) selected")
        }
        let count = parseManualContacts(from: manualPhonesText).count
        return count == 0 ? t("手动输入", "Manual input") : t("已输入 \(count) 个号码", "\(count) numbers")
    }

    private func applyInitialDraft() {
        let draft = initialDraft ?? .empty
        selectedPromptID = draft.promptID ?? templates.first?.id
        contactMode = draft.contactMode
        selectedPhones = draft.selectedPhones
        manualPhonesText = draft.manualPhonesText
        timingMode = draft.timingMode
        scheduledTime = draft.scheduledTime
        callFrequency = draft.callFrequency
        redialMissed = draft.redialMissed
        step = .main
    }

    private func togglePhoneSelection(_ phone: String) {
        if selectedPhones.contains(phone) {
            selectedPhones.remove(phone)
        } else {
            selectedPhones.insert(phone)
        }
    }

    private func createAction() {
        guard let prompt = selectedTemplate else {
            alertMessage = t("请选择话术。", "Please select a prompt.")
            return
        }

        let contacts: [OutboundContact] = {
            if contactMode == .existing {
                return existingContacts.filter { selectedPhones.contains($0.phone) }
            }
            return parseManualContacts(from: manualPhonesText)
        }()

        guard !contacts.isEmpty else {
            alertMessage = t("请至少选择/输入一个号码。", "Please select or input at least one number.")
            return
        }

        if let blocked = contacts.first(where: { OutboundDialRiskControl.isEmergencyNumber($0.phone) }) {
            let normalized = OutboundDialRiskControl.normalizePhone(blocked.phone)
            alertMessage = t(
                "检测到紧急号码 \(normalized)。\(riskReasonMessage(.emergencyNumber))",
                "Detected emergency number \(normalized). \(riskReasonMessage(.emergencyNumber))"
            )
            return
        }

        let executeAt = timingMode == .scheduled ? scheduledTime : Date()
        if OutboundDialRiskControl.enforceDeepNightOutboundBlock,
           OutboundDialRiskControl.isDeepNight(at: executeAt) {
            alertMessage = riskReasonMessage(.deepNight)
            return
        }

        let submission = OutboundCreateTaskSubmission(
            promptName: prompt.name,
            promptContent: prompt.content,
            contacts: contacts,
            scheduledAt: timingMode == .scheduled ? scheduledTime : nil,
            status: timingMode == .scheduled ? .scheduled : .running,
            callFrequency: callFrequency,
            redialMissed: redialMissed
        )
        onCreate(submission)
    }

    private func parseManualContacts(from text: String) -> [OutboundContact] {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: ",，\n\r\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen: Set<String> = []
        return parts.compactMap { raw in
            let phone = raw.replacingOccurrences(of: "-", with: "")
            guard !seen.contains(phone) else { return nil }
            seen.insert(phone)
            return OutboundContact(phone: phone, name: t("手动号码", "Manual Contact"))
        }
    }
}

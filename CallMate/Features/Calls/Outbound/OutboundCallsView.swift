//
//  OutboundCallsView.swift
//  CallMate
//

import SwiftUI
import SwiftData
import Combine
import CoreBluetooth

struct OutboundCallsView: View {
    let language: Language
    let onBack: (() -> Void)?
    let onDisconnect: () -> Void
    let onFactoryReset: () -> Void
    let onRebind: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CallLog.startedAt, order: .reverse) private var allCalls: [CallLog]
    @Query(sort: \OutboundContactBookEntry.updatedAt, order: .reverse) private var contactBookEntries: [OutboundContactBookEntry]
    @Query(sort: \OutboundPromptTemplate.updatedAt, order: .reverse) private var promptTemplates: [OutboundPromptTemplate]
    private let ble = CallMateBLEClient.shared
    @StateObject private var bleState = OutboundBLEViewState()
    @ObservedObject private var fw = FirmwareUpdateService.shared

    @State private var showCreateTaskSheet = false
    @State private var showCreateTaskAI = false
    @State private var showCallSettings = false
    @State private var tasks: [OutboundTask] = []
    @State private var nextAlertMessage: String?
    /// Avoid alert spam when scheduled-task timer retries every 15s during deep-night block.
    @State private var lastOutboundRiskAlertAt: Date?
    @State private var selectedCallDetail: CallLog?
    @State private var selectedTaskDetail: OutboundTask?
    @State private var showAllHistoryTasks = false
    @State private var createTaskDraft: OutboundCreateTaskDraft?
    @ObservedObject private var queueService = OutboundTaskQueueService.shared
    @State private var taskToDelete: OutboundTask?
    @State private var showDeviceModal = false

    private let schedulerTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private let outboundSummaryPrefix = "[OUTBOUND_TASK]"

    private var bleSnapshot: OutboundBLEViewSnapshot {
        bleState.snapshot
    }

    init(
        language: Language,
        onBack: (() -> Void)? = nil,
        onDisconnect: @escaping () -> Void = {},
        onFactoryReset: @escaping () -> Void = {},
        onRebind: @escaping () -> Void = {}
    ) {
        self.language = language
        self.onBack = onBack
        self.onDisconnect = onDisconnect
        self.onFactoryReset = onFactoryReset
        self.onRebind = onRebind
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private func riskReasonMessage(_ reason: OutboundDialRiskReason) -> String {
        switch reason {
        case .emergencyNumber:
            return t("命中紧急号码风控，默认禁止 AI 外呼。", "Blocked by emergency-number risk control.")
        case .deepNight:
            return t(
                "当前处于当地深夜时段（\(OutboundDialRiskControl.deepNightStartHour):00-\(OutboundDialRiskControl.deepNightEndHour):00），默认禁止 AI 外呼。",
                "Blocked by local deep-night window (\(OutboundDialRiskControl.deepNightStartHour):00-\(OutboundDialRiskControl.deepNightEndHour):00)."
            )
        }
    }

    private func riskSummaryTag(_ reason: OutboundDialRiskReason) -> String {
        switch reason {
        case .emergencyNumber: return "RISK_BLOCK_EMERGENCY"
        case .deepNight: return "RISK_BLOCK_DEEP_NIGHT"
        }
    }

    private var outboundDashboard: some View {
        VStack(spacing: 0) {
            fixedHeader
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Spacing.x3) {
                    statsSection
                    if !activeTasks.isEmpty {
                        currentTasksSection
                    }
                    quickActionSection
                    historyTasksSection
                }
                .padding(.horizontal, DS.Spacing.x2)
                .padding(.top, DS.Spacing.x2)
                .padding(.bottom, DS.Spacing.x3)
            }
        }
        .background(AppColors.backgroundSecondary)
        .alert(t("删除任务", "Delete Task"), isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } })) {
            Button(t("取消", "Cancel"), role: .cancel) {
                taskToDelete = nil
            }
            Button(t("删除", "Delete"), role: .destructive) {
                if let task = taskToDelete {
                    deleteTask(task)
                }
                taskToDelete = nil
            }
        } message: {
            Text(t("确定要删除这个任务吗？", "Are you sure you want to delete this task?"))
        }
    }

    private var isShowingDetail: Bool {
        selectedCallDetail != nil || selectedTaskDetail != nil || showAllHistoryTasks || showCreateTaskSheet || showCreateTaskAI || showCallSettings || showDeviceModal
    }

    var body: some View {
        ZStack {
            outboundDashboard
                .allowsHitTesting(!isShowingDetail)

            if let task = selectedTaskDetail {
                OutboundTaskDetailView(
                    language: language,
                    task: task,
                    calls: outboundCalls(for: task),
                    onBack: { selectedTaskDetail = nil },
                    onCallClick: { call in
                        selectedCallDetail = call
                    },
                    onRunNow: {
                        executeTask(taskID: task.id, triggeredByTimer: false)
                    },
                    onReuse: {
                        selectedTaskDetail = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            reuseTask(task)
                        }
                    },
                    onDelete: {
                        selectedTaskDetail = nil
                        deleteTask(task)
                    }
                )
                .edgeSwipeBack(perform: { selectedTaskDetail = nil })
                .transition(.move(edge: .trailing))
            }

            if let call = selectedCallDetail {
                CallDetailView(call: call, language: language, isTest: false, onBack: {
                    selectedCallDetail = nil
                })
                .edgeSwipeBack(perform: { selectedCallDetail = nil })
                .transition(.move(edge: .trailing))
            }

            if showAllHistoryTasks {
                OutboundAllHistoryTasksView(
                    language: language,
                    tasks: finishedTasks,
                    onBack: { showAllHistoryTasks = false },
                    onTaskClick: { task in
                        showAllHistoryTasks = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            selectedTaskDetail = task
                        }
                    }
                )
                .edgeSwipeBack(perform: { showAllHistoryTasks = false })
                .transition(.move(edge: .trailing))
            }

            if showCreateTaskSheet {
                OutboundCreateTaskView(
                    language: language,
                    templates: promptTemplates,
                    existingContacts: existingContacts,
                    initialDraft: createTaskDraft,
                    onOpenAI: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showCreateTaskSheet = false
                            showCreateTaskAI = true
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showCreateTaskSheet = false }
                    },
                    onCreate: { submission in
                        createTask(from: submission)
                    }
                )
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showCreateTaskSheet = false }
                })
                .transition(.move(edge: .trailing))
            }

            if showCreateTaskAI {
                OutboundCreateTaskAIView(
                    language: language,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) { showCreateTaskAI = false }
                    },
                    onOpenCreateTask: {
                        guard !showCreateTaskSheet else { return }
                        createTaskDraft = .empty
                        withAnimation(.easeInOut(duration: 0.25)) {
                            // Open create page and close AI page in one transaction
                            // to avoid the "jump twice" effect.
                            showCreateTaskSheet = true
                            showCreateTaskAI = false
                        }
                    },
                    promptTemplates: promptTemplates,
                    onCreateTemplate: { name, content in
                        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedName.isEmpty, !normalizedContent.isEmpty else {
                            print("[OutboundAI] create_template skipped: empty name/content")
                            return
                        }
                        let now = Date()
                        if let existing = promptTemplates.first(where: {
                            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName
                        }) {
                            existing.content = normalizedContent
                            existing.updatedAt = now
                            do {
                                try modelContext.save()
                                print("[OutboundAI] create_template updated existing: name=\(normalizedName) contentLen=\(normalizedContent.count)")
                            } catch {
                                print("[OutboundAI] create_template update failed: name=\(normalizedName) error=\(error)")
                            }
                        } else {
                            let template = OutboundPromptTemplate(
                                name: normalizedName,
                                content: normalizedContent,
                                createdAt: now,
                                updatedAt: now
                            )
                            modelContext.insert(template)
                            do {
                                try modelContext.save()
                                print("[OutboundAI] create_template inserted: name=\(normalizedName) contentLen=\(normalizedContent.count)")
                            } catch {
                                print("[OutboundAI] create_template insert failed: name=\(normalizedName) error=\(error)")
                            }
                        }
                    },
                    onCallConfirmed: { phone, templateName, templateContent, scheduledAt in
                        // End the outbound_chat AI session immediately before starting the call.
                        // This stops any playing TTS audio (the AI's "okay, dialing..." response)
                        // and sends WS abort so the server stops generating new TTS frames,
                        // preventing them from bleeding into the actual outbound call audio.
                        CallSessionController.activeController?.end()
                        // Also dismiss the AI chat view so its onDisappear lifecycle is clean.
                        showCreateTaskAI = false
                        let contact = OutboundContact(phone: phone, name: templateName)
                        let isScheduled = scheduledAt != nil
                        let submission = OutboundCreateTaskSubmission(
                            promptName: templateName,
                            promptContent: templateContent,
                            contacts: [contact],
                            scheduledAt: scheduledAt,
                            status: isScheduled ? .scheduled : .running,
                            callFrequency: 60,
                            redialMissed: false
                        )
                        createTask(from: submission)
                        print("[OutboundAI] call confirmed: phone=\(phone) template=\(templateName) scheduled=\(scheduledAt?.description ?? "immediate")")
                    }
                )
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showCreateTaskAI = false }
                })
                .transition(.move(edge: .trailing))
            }

            if showCallSettings {
                OutboundCallSettingsView(
                    language: language,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) { showCallSettings = false }
                    }
                )
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showCallSettings = false }
                })
                .transition(.move(edge: .trailing))
            }

            if showDeviceModal {
                DeviceModalView(
                    language: language,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showDeviceModal = false }
                    },
                    onDisconnect: {
                        showDeviceModal = false
                        DispatchQueue.main.async { onDisconnect() }
                    },
                    onFactoryReset: {
                        showDeviceModal = false
                        DispatchQueue.main.async { onFactoryReset() }
                    },
                    onRebind: {
                        showDeviceModal = false
                        DispatchQueue.main.async { onRebind() }
                    }
                )
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showDeviceModal = false }
                })
                .transition(.move(edge: .trailing))
                .zIndex(10)
            }
        }
        .accessibilityIdentifier("outbound-root")
        .animation(.easeInOut(duration: 0.25), value: selectedCallDetail?.id)
        .animation(.easeInOut(duration: 0.25), value: selectedTaskDetail?.id)
        .animation(.easeInOut(duration: 0.25), value: showAllHistoryTasks)
        .animation(.easeInOut(duration: 0.25), value: showCreateTaskSheet)
        .animation(.easeInOut(duration: 0.25), value: showCreateTaskAI)
        .animation(.easeInOut(duration: 0.25), value: showCallSettings)
        .animation(.easeInOut(duration: 0.25), value: showDeviceModal)
        .toolbar(isShowingDetail ? .hidden : .visible, for: .tabBar)
        .alert(t("提示", "Notice"), isPresented: alertIsPresentedBinding) {
            Button(t("知道了", "OK"), role: .cancel) {
                nextAlertMessage = nil
            }
        } message: {
            Text(nextAlertMessage ?? "")
        }
        .onAppear {
            ensurePromptTemplatesIfNeeded()
            if tasks.isEmpty {
                tasks = OutboundTaskStore.load()
                executeDueScheduledTasks()
            }
        }
        .onReceive(schedulerTimer) { _ in
            executeDueScheduledTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .outboundTaskDue)) { _ in
            executeDueScheduledTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .outboundTasksSummaryUpdated)) { _ in
            tasks = OutboundTaskStore.load()
            if let sel = selectedTaskDetail,
               let fresh = OutboundTaskStore.load().first(where: { $0.id == sel.id }) {
                selectedTaskDetail = fresh
            }
        }
        .onChange(of: queueService.runningTaskIds.count) { _, _ in
            tasks = OutboundTaskStore.load()
        }
        .onChange(of: queueService.outboundDialBlockedMessage) { _, msg in
            guard let msg, !msg.isEmpty else { return }
            let now = Date()
            if let last = lastOutboundRiskAlertAt, now.timeIntervalSince(last) < 30 {
                queueService.clearOutboundDialBlockedMessage()
                return
            }
            lastOutboundRiskAlertAt = now
            nextAlertMessage = msg
            queueService.clearOutboundDialBlockedMessage()
        }
    }

    private var fixedHeader: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundColor(AppColors.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("outbound-device-button")
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(t("AI打电话", "Call Out"))
                    .font(AppTypography.title1)
                    .foregroundColor(AppColors.textPrimary)
                    .accessibilityIdentifier("outbound-title")

                Button {
                    showDeviceModal = true
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Circle()
                            .fill(connectionStatusColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: connectionStatusColor.opacity(0.4), radius: 3, x: 0, y: 0)
                        Text(connectionStatusText)
                            .font(AppTypography.caption1)
                            .foregroundColor(connectionStatusColor == AppColors.success ? AppColors.success : AppColors.textSecondary)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                            .font(DS.Typography.caption.weight(.bold))
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xs)
                    .background(
                        Capsule()
                            .fill(connectionStatusColor.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .stroke(connectionStatusColor.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                showCallSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(AppColors.surface)
                    .clipShape(Circle())
                    .appShadow(AppShadow.sm)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("outbound-settings-button")
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
    }

    private var connectionStatusText: String {
        switch bleSnapshot.bluetoothState {
        case .poweredOff:
            return t("蓝牙未开启", "Bluetooth Off")
        case .unauthorized:
            return t("蓝牙权限未授权", "Bluetooth Permission Denied")
        case .unsupported:
            return t("未连接", "Disconnected")
        case .resetting:
            return t("蓝牙重置中", "Bluetooth Resetting")
        case .unknown:
            return t("未连接", "Disconnected")
        case .poweredOn:
            break
        @unknown default:
            return t("未连接", "Disconnected")
        }
        if bleSnapshot.isReady && bleSnapshot.connectedPeripheralID != nil {
            if fw.isUpdating || fw.updateStage != .idle {
                return t("EchoCard 已连接 · 固件升级中", "EchoCard Connected · Updating")
            }
            return t("EchoCard 已连接", "EchoCard Connected")
        }
        if bleSnapshot.connectingPeripheralID != nil || bleSnapshot.connectedPeripheralID != nil {
            return t("EchoCard 连接中", "EchoCard Connecting")
        }
        return t("EchoCard 未连接", "EchoCard Disconnected")
    }

    private var connectionStatusColor: Color {
        if bleSnapshot.bluetoothState == .poweredOff || bleSnapshot.bluetoothState == .unauthorized {
            return AppColors.warning
        }
        if bleSnapshot.bluetoothState != .poweredOn {
            return AppColors.textSecondary
        }
        if bleSnapshot.isReady && bleSnapshot.connectedPeripheralID != nil {
            return AppColors.success
        }
        if bleSnapshot.connectingPeripheralID != nil || bleSnapshot.connectedPeripheralID != nil {
            return AppColors.warning
        }
        return AppColors.textSecondary
    }

    private var statsSection: some View {
        HStack(spacing: AppSpacing.md) {
            statCard(
                title: t("今日呼出", "Calls Today"),
                value: "\(todayOutboundCount)",
                suffix: t("通", "")
            )
            statCard(
                title: t("接通率", "Connection Rate"),
                value: executionRateValueText,
                suffix: executionRateSuffixText
            )
        }
    }

    private func statCard(title: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(DS.Typography.caption)
                .foregroundColor(AppColors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xxxs) {
                Text(value)
                    .font(AppTypography.title1)
                    .foregroundColor(AppColors.textPrimary)
                Text(suffix)
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.x2)
        .dsCardStyle()
    }

    private var currentTasksSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(t("当前任务", "Current Tasks"))
                    .font(DS.Typography.title)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
            }

            if activeTasks.isEmpty {
                Text(t("当前没有正在执行的任务。", "No active tasks right now."))
                    .font(DS.Typography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(DS.Spacing.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCardStyle()
            } else {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(activeTasks) { task in
                        SwipeToDeleteRow(onDelete: { taskToDelete = task }) {
                            Button {
                                selectedTaskDetail = task
                            } label: {
                                activeTaskRow(task)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var quickActionSection: some View {
        Button {
            showCreateTaskAI = true
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                Text(t("创建新任务", "Create New Task"))
                    .font(DS.Typography.body.weight(.bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.x2)
            .background(AppColors.primary)
            .cornerRadius(DS.Radius.card)
            .shadow(color: AppColors.primary.opacity(0.35), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var historyTasksSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(t("历史任务", "History Tasks"))
                    .font(DS.Typography.title)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                if finishedTasks.count > 5 {
                    Button {
                        showAllHistoryTasks = true
                    } label: {
                        HStack(spacing: AppSpacing.xxs) {
                            Text(t("全部任务", "All Tasks"))
                                .font(DS.Typography.caption.weight(.semibold))
                                .foregroundColor(AppColors.primary)
                            Image(systemName: "chevron.right")
                                .font(DS.Typography.caption.weight(.semibold))
                                .foregroundColor(AppColors.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if finishedTasks.isEmpty {
                Text(t("暂无历史任务。", "No history tasks yet."))
                    .font(DS.Typography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(DS.Spacing.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCardStyle()
            } else {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(finishedTasks.prefix(5)) { task in
                        SwipeToDeleteRow(onDelete: { taskToDelete = task }) {
                            Button {
                                selectedTaskDetail = task
                            } label: {
                                historyTaskRow(task)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func activeTaskRow(_ task: OutboundTask) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Text(task.promptType)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(task.status.title(language: language))
                    .font(DS.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(task.status.color)
                    .padding(.horizontal, DS.Spacing.x1)
                    .padding(.vertical, 2)
                    .background(task.status.color.opacity(0.12))
                    .cornerRadius(DS.Radius.button)
            }

            Text(task.scheduledAt == nil
                 ? t("立即执行 • \(task.contacts.count) 人", "Immediate • \(task.contacts.count) contacts")
                 : t("定时：\(dateTimeText(task.scheduledAt!)) • \(task.contacts.count) 人", "Scheduled: \(dateTimeText(task.scheduledAt!)) • \(task.contacts.count) contacts")
            )
            .font(DS.Typography.caption)
            .foregroundColor(AppColors.textSecondary)

            let progress = taskProgress(task)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack {
                    Text(t("进度", "Progress"))
                        .font(DS.Typography.caption)
                        .foregroundColor(AppColors.textSecondary)
                    Spacer()
                    Text("\(taskAttemptedCount(task))/\(task.contacts.count)")
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
            .padding(.top, AppSpacing.xxs)

            if task.status == .scheduled {
                Button {
                    executeTask(taskID: task.id, triggeredByTimer: false)
                } label: {
                    Text(t("立即执行", "Run Now"))
                        .font(DS.Typography.caption.weight(.semibold))
                        .foregroundColor(AppColors.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.x2)
        .dsCardStyle()
    }

    private func historyTaskRow(_ task: OutboundTask) -> some View {
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

    private var outboundCalls: [CallLog] {
        allCalls.filter { call in
            guard let summary = call.summary else { return false }
            return summary.contains(outboundSummaryPrefix) && !call.isSimulation
        }
    }

    private func outboundCallRow(_ call: CallLog) -> some View {
        HStack(spacing: AppSpacing.md) {
            Circle()
                .fill(call.statusRaw == CallStatus.handled.rawValue ? AppColors.success.opacity(0.15) : AppColors.error.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "phone.arrow.up.right")
                        .font(.system(size: 18))
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

            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                Text(dateTimeText(call.startedAt))
                    .font(DS.Typography.caption)
                    .foregroundColor(AppColors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .padding(DS.Spacing.x2)
        .dsCardStyle()
    }

    private func outboundCalls(for task: OutboundTask) -> [CallLog] {
        let allOutbound = outboundCalls
        let exact = allOutbound
            .filter { $0.outboundTaskID == task.id }
            .sorted { $0.startedAt > $1.startedAt }
        print("[OutboundHistory] outboundCalls(for:) taskID=\(task.id) promptType='\(task.promptType)' totalOutboundCalls=\(allOutbound.count) exactMatches=\(exact.count)")
        if !exact.isEmpty {
            for call in exact {
                print("[OutboundHistory]   exact match: callId=\(call.id) phone='\(call.phone)' status=\(call.statusRaw) duration=\(call.durationSeconds)s outboundTaskID=\(call.outboundTaskID?.uuidString ?? "nil")")
            }
            return exact
        }

        // Backward compatibility for legacy records without outboundTaskID.
        let nextCreatedAt = tasks.filter { $0.createdAt > task.createdAt }.map(\.createdAt).min()
        let byWindow = allOutbound.filter { call in
            guard call.outboundTaskID == nil else { return false }
            guard call.startedAt >= task.createdAt else { return false }
            if let nextCreatedAt { return call.startedAt < nextCreatedAt }
            return true
        }
        let fallback = byWindow.filter { call in
            let summary = call.summary ?? ""
            let fullSummary = call.fullSummary ?? ""
            return summary.contains(task.promptType)
                || fullSummary.contains(task.promptRule)
                || summary.contains(task.id.uuidString)
        }.sorted { $0.startedAt > $1.startedAt }
        print("[OutboundHistory]   no exact matches; fallback(compat) count=\(fallback.count) windowCandidates=\(byWindow.count)")
        for call in fallback {
            print("[OutboundHistory]   compat match: callId=\(call.id) phone='\(call.phone)' status=\(call.statusRaw) summary='\(call.summary ?? "nil")'")
        }
        // Log orphaned outbound calls (outboundTaskID != nil but != task.id) to catch ID mismatches
        let orphaned = allOutbound.filter { $0.outboundTaskID != nil && $0.outboundTaskID != task.id }
        if !orphaned.isEmpty {
            print("[OutboundHistory]   ⚠️ \(orphaned.count) outbound calls belong to OTHER tasks (possible taskID mismatch?)")
            for call in orphaned.prefix(3) {
                print("[OutboundHistory]   orphaned: callId=\(call.id) phone='\(call.phone)' outboundTaskID=\(call.outboundTaskID!.uuidString)")
            }
        }
        return fallback
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }


    private var existingContacts: [OutboundContact] {
        var seen: Set<String> = []
        var result: [OutboundContact] = []
        for entry in contactBookEntries where !entry.phone.isEmpty {
            let phone = entry.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty else { continue }
            guard !seen.contains(phone) else { continue }
            seen.insert(phone)
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t("名单联系人", "Address Book Contact") : entry.name
            result.append(OutboundContact(phone: phone, name: name))
            if result.count >= 60 { return result }
        }
        for call in allCalls where !call.phone.isEmpty && !call.isSimulation {
            let phone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty else { continue }
            guard !seen.contains(phone) else { continue }
            seen.insert(phone)
            let name = call.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t("历史号码", "History Contact") : call.label
            result.append(OutboundContact(phone: phone, name: name))
            if result.count >= 30 { break }
        }
        return result
    }

    private var todayOutboundCount: Int {
        todayOutboundCalls.count
    }

    /// 今日呼出：仅统计有号码的外呼（排除 phone 为空的误标/测试记录）。
    private var todayOutboundCalls: [CallLog] {
        let calendar = Calendar.current
        return outboundCalls.filter { call in
            calendar.isDateInToday(call.startedAt) && !call.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var executionRateValueText: String {
        let total = todayOutboundCalls.count
        guard total > 0 else { return t("暂无", "N/A") }
        let connected = todayOutboundCalls.filter { $0.statusRaw == CallStatus.handled.rawValue }.count
        return String(Int((Double(connected) / Double(total)) * 100.0))
    }

    private var executionRateSuffixText: String {
        todayOutboundCalls.isEmpty ? "" : "%"
    }

    private var activeTasks: [OutboundTask] {
        tasks
            .filter { $0.status == .running || $0.status == .scheduled }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var finishedTasks: [OutboundTask] {
        tasks
            .filter { $0.status == .completed || $0.status == .partial || $0.status == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func taskAttemptedCount(_ task: OutboundTask) -> Int {
        min(task.contacts.count, task.dialSuccessCount + task.dialFailureCount)
    }

    private func taskProgress(_ task: OutboundTask) -> Double {
        guard !task.contacts.isEmpty else { return 0 }
        return Double(taskAttemptedCount(task)) / Double(task.contacts.count)
    }

    private var alertIsPresentedBinding: Binding<Bool> {
        Binding(
            get: { nextAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    nextAlertMessage = nil
                }
            }
        )
    }

    private func ensurePromptTemplatesIfNeeded() {
        let targetTemplates = defaultOutboundTemplates()
        if promptTemplates.isEmpty {
            let now = Date()
            for item in targetTemplates {
                let template = OutboundPromptTemplate(
                    name: item.name,
                    content: item.content,
                    createdAt: now,
                    updatedAt: now
                )
                modelContext.insert(template)
            }
            do {
                try modelContext.save()
            } catch {
                print("[OutboundTemplate] seed failed: \(error.localizedDescription)")
            }
            return
        }

        // One-time compatibility: replace legacy ProcessStrategy-derived templates
        // with the 2 templates aligned to echocard-config.
        let legacyRuleNames = Set(ProcessStrategyStore.loadRules().map(\.type))
        let isLegacyImported = promptTemplates.allSatisfy { legacyRuleNames.contains($0.name) }
        if isLegacyImported {
            let now = Date()
            for template in promptTemplates {
                modelContext.delete(template)
            }
            for item in targetTemplates {
                let template = OutboundPromptTemplate(
                    name: item.name,
                    content: item.content,
                    createdAt: now,
                    updatedAt: now
                )
                modelContext.insert(template)
            }
            do {
                try modelContext.save()
            } catch {
                print("[OutboundTemplate] seed failed: \(error.localizedDescription)")
            }
            return
        }

        // Upgrade only the old short starter texts to richer AI prompts.
        let oldShortTexts: [String: String] = [
            "房产推销_v2": "你好，我是XX房产的AI助手，请问您最近有购房需求吗？",
            "满意度回访": "您好，这里是售后服务中心，想耽误您一分钟做个回访..."
        ]
        var didUpgrade = false
        for item in targetTemplates {
            guard let template = promptTemplates.first(where: { $0.name == item.name }) else { continue }
            let current = template.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let old = oldShortTexts[item.name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let old, current == old {
                template.content = item.content
                template.updatedAt = Date()
                didUpgrade = true
            }
        }
        if didUpgrade {
            do {
                try modelContext.save()
            } catch {
                print("[OutboundTemplate] upgrade failed: \(error.localizedDescription)")
            }
        }
    }

    private func defaultOutboundTemplates() -> [(name: String, content: String)] {
        [
            (
                name: "房产推销_v2",
                content: """
你是“XX房产外呼顾问（AI）”，现在进行一通房产意向筛选电话。

【通话目标】
1) 快速确认客户是否有购房/换房/投资需求。
2) 收集关键信息：预算区间、意向区域、时间计划、决策角色。
3) 给出明确下一步动作（预约顾问回访/发送资料/结束跟进）。

【对话风格】
- 语气自然、礼貌、简洁，像真人销售顾问，不要机械背稿。
- 每次只问一个问题，避免连续追问。
- 对方明确拒绝时，立即礼貌结束，不纠缠。

【推荐流程】
1) 开场身份说明（10秒内）
   - “您好，我是XX房产顾问，想简单了解下您近期有没有购房计划，不耽误您太久。”
2) 意向判断
   - 有意向：进入需求收集
   - 暂无意向/反感：礼貌结束
3) 需求收集（按优先级）
   - 预算（如：200-300万/300-500万）
   - 区域（工作地附近/学区/通勤）
   - 时间（近期3个月/半年内/长期）
   - 决策角色（本人决定/与家人共同决定）
4) 下一步引导
   - 高意向：建议预约置业顾问回访时间
   - 中意向：发送项目资料并约定回访节点
   - 低意向：记录后礼貌结束

【约束】
- 不承诺“最低价/保值收益/学位保证”等不可控内容。
- 不主动索要身份证、银行卡、验证码等敏感信息。
- 对价格问题仅给区间描述，明确“以实际户型和政策为准”。

【结束语模板】
- 高意向：“好的，我先为您安排顾问在您方便的时间联系，给您做一对一匹配。”
- 中意向：“我先把资料发您，您方便时看看，我们再约个时间细聊。”
- 低意向：“明白了，感谢您接听，后续有需要随时联系，祝您生活愉快。”
"""
            ),
            (
                name: "满意度回访",
                content: """
你是“客户服务中心回访专员（AI）”。你要完成一次专业、克制、可落地的满意度回访。

【核心目标】
1) 在 60-120 秒内完成回访主流程，不打扰客户。
2) 获取清晰结论：满意度等级 + 核心原因 + 是否需要继续跟进。
3) 对负向反馈形成可执行闭环：问题分类、优先级、回访承诺时间窗口。

【服务口径】
- 角色定位：你是“记录和协调者”，不是“拍板决策者”。
- 沟通顺序：先同意意愿 -> 再提问 -> 再确认 -> 再给下一步。
- 语言要求：一句只表达一个意思，避免长句和术语。
- 情绪处理：先共情再收集信息，禁止先解释先辩解。

【标准流程（必须遵守）】
阶段 A：开场征询（10-15 秒）
- 参考话术：
  “您好，这里是售后服务中心，想占用您 1 分钟做个服务回访，现在方便吗？”
- 若客户说不方便：询问可回拨时间；若拒绝回访，礼貌结束并标记“拒访”。

阶段 B：满意度判定（15-20 秒）
- 提问：
  “整体体验您更偏向：满意、一般，还是不满意？”
- 允许自由表达，自动归并到三档：
  - 满意（正向）
  - 一般（中性）
  - 不满意（负向）

阶段 C：原因采集（20-45 秒）
- 满意：追问 1 个亮点即可
  “最让您满意的一点是什么？”
- 一般/不满意：最多追问 2 个关键原因，优先问“影响最大的问题”
  “这次最影响您体验的是哪一项？是时效、沟通、处理结果，还是服务态度？”

阶段 D：闭环确认（20-30 秒）
- 复述客户核心诉求（不新增解释）：
  “我确认一下，您主要反馈的是……，希望我们……，对吗？”
- 给处理路径（不越权承诺）：
  “我会为您升级给对应团队处理，预计在 X 小时内给您反馈进展。”

阶段 E：结束（5-10 秒）
- 根据满意度使用对应结束语，保持礼貌、简洁。

【问题分类与优先级】
- 分类：
  1) 时效问题（响应慢、等待久、超时）
  2) 沟通问题（解释不清、信息不一致、重复沟通）
  3) 结果问题（未解决、方案不符合预期）
  4) 态度问题（语气生硬、体验不佳）
  5) 其他（客户自定义）
- 优先级建议：
  - P1：投诉升级/强烈不满/影响继续使用
  - P2：明显不满意但可继续沟通
  - P3：一般建议类优化

【异常场景处理】
- 客户情绪激动：
  先说“非常理解您的感受，给您添麻烦了”，再进入“我先准确记录两个关键点”。
- 客户追问责任归属：
  不争辩，统一回应“先帮您推进解决，后续由专员同步处理结果”。
- 客户要求立即解决：
  不能承诺“马上解决”，改为“马上升级处理并在 X 小时内反馈进展”。
- 客户沉默/简短回答：
  使用封闭式问题帮助选择，不连续追问超过 2 次。

【禁止事项】
- 禁止诱导性提问（例如“您应该是满意的吧？”）。
- 禁止让客户重复叙述已表达信息。
- 禁止收集无关隐私（身份证、银行卡、验证码、住址等）。
- 禁止超权限承诺（赔偿金额、具体审批结果、立即办结）。

【结果输出（供系统记录，非对客朗读）】
请在内部形成结构化结果：
- satisfaction_level: satisfied | neutral | dissatisfied
- main_issue_type: timeliness | communication | outcome | attitude | other
- key_reason: 一句话总结
- need_followup: yes | no
- followup_window: 例如“24小时内”
- priority: P1 | P2 | P3

【结束语模板】
- 满意：
  “感谢您的肯定，我们会继续保持服务质量，祝您生活愉快。”
- 一般：
  “感谢您的反馈，我们已记录您的建议，后续会持续优化体验。”
- 不满意：
  “非常抱歉给您带来不便，我已为您升级跟进，会在约定时间内向您反馈进展。”
"""
            )
        ]
    }

    private func deleteTask(_ task: OutboundTask) {
        _ = queueService.deleteTask(taskId: task.id)
        tasks = OutboundTaskStore.load()
    }

    private func reuseTask(_ task: OutboundTask) {
        let matchedTemplateID = promptTemplates.first(where: { $0.name == task.promptType })?.id
        createTaskDraft = OutboundCreateTaskDraft(
            promptID: matchedTemplateID,
            contactMode: .existing,
            selectedPhones: Set(task.contacts.map(\.phone)),
            manualPhonesText: "",
            timingMode: .immediate,
            scheduledTime: Date().addingTimeInterval(15 * 60),
            callFrequency: task.callFrequency,
            redialMissed: task.redialMissed
        )
        showCreateTaskSheet = true
    }

    private func createTask(from submission: OutboundCreateTaskSubmission) {
        guard let _ = queueService.createTask(
            promptType: submission.promptName,
            prompt: submission.promptContent,
            contacts: submission.contacts,
            scheduledAt: submission.scheduledAt,
            callFrequency: submission.callFrequency,
            redialMissed: submission.redialMissed
        ) else {
            nextAlertMessage = t("创建任务失败", "Failed to create task")
            return
        }
        tasks = OutboundTaskStore.load()
        showCreateTaskSheet = false
        if submission.scheduledAt != nil {
            nextAlertMessage = t("任务已创建并定时。", "Scheduled task has been created.")
        }
    }

    private func executeDueScheduledTasks() {
        let dueIds = tasks
            .filter { task in
                guard task.status == .scheduled, let scheduledAt = task.scheduledAt else { return false }
                return scheduledAt <= Date()
            }
            .map(\.id)
        dueIds.forEach { executeTask(taskID: $0, triggeredByTimer: true) }
    }

    private func executeTask(taskID: UUID, triggeredByTimer: Bool) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        guard !queueService.runningTaskIds.contains(taskID) else { return }
        queueService.executeTask(taskID: taskID)
        tasks = OutboundTaskStore.load()
    }

    private func dateTimeText(_ date: Date) -> String {
        RelativeDateFormatter(language: language).string(from: date)
    }
}

// MARK: - OutboundCallConfirmRequest

struct OutboundCallConfirmRequest: Identifiable {
    let id = UUID()
    let phone: String
    let templateName: String
    /// nil = immediate call; non-nil = scheduled
    let scheduledAt: Date?
    /// Human-readable time label from AI (e.g. "今天下午 3:30")
    let timeDescription: String?
    /// Outcome callback. `wasUserCancel` distinguishes the user-pressed-cancel
    /// path (→ v1 `result.success=false, reason=user_cancelled`) from a
    /// system/host failure (→ `error: <reasonText>`).
    let respond: (_ confirmed: Bool, _ reasonText: String?, _ wasUserCancel: Bool) -> Void
}

// MARK: - OutboundCreateTaskAIView

struct OutboundCreateTaskAIView: View {
    let language: Language
    let onBack: () -> Void
    let onOpenCreateTask: () -> Void
    let promptTemplates: [OutboundPromptTemplate]
    let onCreateTemplate: (_ name: String, _ content: String) -> Void
    /// scheduledAt: nil = immediate, non-nil = scheduled task
    let onCallConfirmed: (_ phone: String, _ templateName: String, _ templateContent: String, _ scheduledAt: Date?) -> Void

    @StateObject private var voiceControl = FeedbackVoiceControl()
    @State private var pendingCallConfirm: OutboundCallConfirmRequest?

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    private func normalizedTemplateKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noWhitespace = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)
        return noWhitespace.components(separatedBy: punctuationAndSymbols).joined()
    }

    private func resolveTemplateContent(name: String) -> String? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        // 1) Exact (trimmed) match
        if let exact = promptTemplates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            print("[OutboundAI] template matched exact: input=\(target) matched=\(exact.name)")
            return exact.content
        }

        // 2) Case-insensitive exact match
        if let ciExact = promptTemplates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(target) == .orderedSame
        }) {
            print("[OutboundAI] template matched case-insensitive: input=\(target) matched=\(ciExact.name)")
            return ciExact.content
        }

        // 3) Normalized exact match (ignore spaces/punctuations/symbols)
        let normalizedTarget = normalizedTemplateKey(target)
        if let normalizedExact = promptTemplates.first(where: {
            normalizedTemplateKey($0.name) == normalizedTarget
        }) {
            print("[OutboundAI] template matched normalized: input=\(target) matched=\(normalizedExact.name)")
            return normalizedExact.content
        }

        // 4) Fuzzy unique match by containment on normalized names
        let fuzzyCandidates = promptTemplates.filter {
            let key = normalizedTemplateKey($0.name)
            return !key.isEmpty && (key.contains(normalizedTarget) || normalizedTarget.contains(key))
        }
        if fuzzyCandidates.count == 1, let only = fuzzyCandidates.first {
            print("[OutboundAI] template matched fuzzy-unique: input=\(target) matched=\(only.name)")
            return only.content
        }
        if fuzzyCandidates.count > 1 {
            let names = fuzzyCandidates.map(\.name).joined(separator: ",")
            print("[OutboundAI] template fuzzy ambiguous: input=\(target) candidates=\(names)")
        } else {
            print("[OutboundAI] template not found: input=\(target)")
        }
        return nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                FeedbackChatModalView(
                    language: language,
                    feedbackType: "none",
                    scene: .outboundChat,
                    onClose: { },
                    isEmbedded: true,
                    voiceControl: voiceControl,
                    showCloseButton: false,
                    initialMessages: [
                        ExtendedMessage(
                            id: Int.random(in: 10000...99999),
                            sender: .ai,
                            text: t(
                                "你好，我是 AI 外呼助手。我可以帮你创建话术模板，或给某个号码发起 AI 外呼。你想做什么？",
                                "Hi, I'm your AI outbound assistant. I can help create call templates or initiate an AI call. What would you like to do?"
                            ),
                            msgType: .text
                        )
                    ],
                    showInitialMessage: false,
                    initMessagesOverride: buildInitMessagesOverride(),
                    autoPlayIntro: false,
                    messagesPersistenceKey: "callmate.outbound.ai_create.persisted_messages.v2",
                    onCreateTemplate: { name, content, respond in
                        onCreateTemplate(name, content)
                        respond(true)
                    },
                    onInitiateCall: { phone, templateName, respond in
                        pendingCallConfirm = OutboundCallConfirmRequest(
                            phone: phone,
                            templateName: templateName,
                            scheduledAt: nil,
                            timeDescription: nil,
                            respond: { confirmed, reasonText, _ in respond(confirmed, reasonText) }
                        )
                    },
                    onScheduleCall: { phone, templateName, scheduledAt, timeDescription, respond in
                        pendingCallConfirm = OutboundCallConfirmRequest(
                            phone: phone,
                            templateName: templateName,
                            scheduledAt: scheduledAt,
                            timeDescription: timeDescription,
                            respond: { confirmed, reasonText, _ in respond(confirmed, reasonText) }
                        )
                    }
                )
                .navigationBarHidden(true)
                .background(AppColors.backgroundSecondary)
            }
            .background(AppColors.backgroundSecondary)

            if let confirm = pendingCallConfirm {
                OutboundCallConfirmationCard(
                    language: language,
                    phone: confirm.phone,
                    templateName: confirm.templateName,
                    scheduledAt: confirm.scheduledAt,
                    timeDescription: confirm.timeDescription,
                    onConfirm: {
                        pendingCallConfirm = nil
                        guard let resolvedTemplateContent = resolveTemplateContent(name: confirm.templateName),
                              !resolvedTemplateContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            print("[OutboundAI] call confirm failed: template not found locally, name=\(confirm.templateName)")
                            confirm.respond(
                                false,
                                "未找到本地模板：\(confirm.templateName)。请先创建模板，再发起外呼。",
                                false
                            )
                            return
                        }
                        confirm.respond(true, nil, false)
                        onCallConfirmed(
                            confirm.phone,
                            confirm.templateName,
                            resolvedTemplateContent,
                            confirm.scheduledAt
                        )
                    },
                    onCancel: {
                        pendingCallConfirm = nil
                        confirm.respond(false, nil, true)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pendingCallConfirm?.id)
    }

    private func buildInitMessagesOverride() -> [[String: String]] {
        let templateSummaries: [[String: String]] = promptTemplates.map { tmpl in
            ["name": tmpl.name, "preview": String(tmpl.content.prefix(80))]
        }
        let templatesText: String
        if templateSummaries.isEmpty {
            templatesText = "（暂无已保存的话术模板）"
        } else if let jsonData = try? JSONSerialization.data(withJSONObject: templateSummaries),
                  let jsonStr = String(data: jsonData, encoding: .utf8) {
            templatesText = jsonStr
        } else {
            templatesText = templateSummaries.map { "- \($0["name"] ?? "")" }.joined(separator: "\n")
        }
        let systemContext = t(
            "你好，我当前已有的外呼话术模板是：\(templatesText)",
            "Hi, my current outbound templates are: \(templatesText)"
        )
        let greeting = t(
            "你好，我是 AI 外呼助手。我可以帮你创建话术模板，或给某个号码发起 AI 外呼。你想做什么？",
            "Hi, I'm your AI outbound assistant. I can help create call templates or initiate an AI call. What would you like to do?"
        )
        return [
            ["role": "user", "content": systemContext],
            ["role": "assistant", "content": greeting]
        ]
    }

    private var header: some View {
        HStack(spacing: AppSpacing.sm) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(AppColors.primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Text(t("AI 外呼助手", "AI Outbound"))
                .font(DS.Typography.title)
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            Button(action: onOpenCreateTask) {
                Text(t("创建批量任务", "Create Batch"))
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(AppColors.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.95)
                    .padding(.horizontal, DS.Spacing.x2 + DS.Spacing.x1)
                    .padding(.vertical, DS.Spacing.x1)
                    .frame(minWidth: 106)
                    .background(AppColors.surface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
        .background(AppColors.background)
    }
}

// MARK: - OutboundTemplateConfirmationCard

private struct OutboundTemplateConfirmationCard: View {
    let language: Language
    let name: String
    let content: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var isExpanded = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    /// First ~3 lines of content for the preview
    private var contentPreview: String {
        let lines = content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.prefix(4).joined(separator: "\n")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                // Header
                VStack(spacing: DS.Spacing.x3) {
                    HStack(spacing: DS.Spacing.x1) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(AppColors.success)
                        Text(t("确认保存话术模板", "Confirm Save Template"))
                            .font(DS.Typography.title)
                            .foregroundColor(AppColors.textPrimary)
                            .fontWeight(.bold)
                    }

                    // Template info card
                    VStack(alignment: .leading, spacing: DS.Spacing.x2) {
                        // Name row
                        HStack(alignment: .center, spacing: DS.Spacing.x2) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.success)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("模板名称", "Template Name"))
                                    .font(DS.Typography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                                Text(name)
                                    .font(DS.Typography.body.weight(.bold))
                                    .foregroundColor(AppColors.textPrimary)
                            }
                            Spacer(minLength: 0)
                        }

                        Divider()

                        // Content section with expand/collapse
                        VStack(alignment: .leading, spacing: DS.Spacing.x1) {
                            HStack {
                                HStack(spacing: DS.Spacing.x1) {
                                    Image(systemName: "text.alignleft")
                                        .font(.system(size: 13))
                                        .foregroundColor(AppColors.primary)
                                        .frame(width: 20)
                                    Text(t("话术内容", "Prompt Content"))
                                        .font(DS.Typography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isExpanded.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 2) {
                                        Text(isExpanded ? t("收起", "Collapse") : t("展开全文", "Expand"))
                                            .font(DS.Typography.caption.weight(.semibold))
                                            .foregroundColor(AppColors.primary)
                                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(AppColors.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            if isExpanded {
                                ScrollView {
                                    Text(content)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(AppColors.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 220)
                            } else {
                                Text(contentPreview)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(AppColors.textSecondary)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(DS.Spacing.x2)
                    .background(AppColors.backgroundSecondary)
                    .cornerRadius(DS.Radius.card)

                    Text(t(
                        "确认后话术将保存到模板库，可在创建外呼任务时使用。",
                        "Once confirmed, the template will be saved and available when creating outbound tasks."
                    ))
                    .font(DS.Typography.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                }
                .padding(DS.Spacing.x3)

                Divider()

                HStack(spacing: 0) {
                    Button(action: onCancel) {
                        Text(t("取消", "Cancel"))
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.x2)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 44)

                    Button(action: onConfirm) {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(t("保存模板", "Save Template"))
                                .font(DS.Typography.body.weight(.bold))
                        }
                        .foregroundColor(AppColors.success)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.x2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(AppColors.surface)
            .cornerRadius(DS.Radius.card * 1.5)
            .shadow(color: .black.opacity(0.15), radius: 24, x: 0, y: 8)
            .padding(.horizontal, DS.Spacing.x3)
        }
    }
}

// MARK: - OutboundCallConfirmationCard

struct OutboundCallConfirmationCard: View {
    let language: Language
    let phone: String
    let templateName: String
    /// nil = immediate call; non-nil = show as scheduled card
    let scheduledAt: Date?
    let timeDescription: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var isScheduled: Bool { scheduledAt != nil }

    private var cardTitle: String {
        isScheduled
            ? t("确认定时 AI 外呼", "Confirm Scheduled AI Call")
            : t("确认发起 AI 外呼", "Confirm AI Call")
    }

    private var titleIcon: String {
        isScheduled ? "clock.badge.checkmark.fill" : "phone.arrow.up.right.fill"
    }

    private var confirmButtonLabel: String {
        isScheduled
            ? t("确认定时", "Schedule Call")
            : t("确认拨出", "Confirm & Call")
    }

    private var confirmButtonIcon: String {
        isScheduled ? "clock.badge.checkmark" : "phone.arrow.up.right"
    }

    private var hintText: String {
        isScheduled
            ? t(
                "系统将在指定时间自动发起外呼。请确保届时手机已连接 EchoCard。",
                "The system will auto-dial at the scheduled time. Make sure EchoCard is connected."
              )
            : t(
                "AI 将使用上述话术自动拨出并与对方通话。确认前请仔细核对号码和话术。",
                "AI will dial and conduct the call using the above template. Please verify before confirming."
              )
    }

    /// Formatted display of scheduled time
    private var scheduledTimeDisplay: String {
        guard let date = scheduledAt else { return "" }
        if let desc = timeDescription, !desc.isEmpty { return desc }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zh ? "zh_CN" : "en_US")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 0) {
                VStack(spacing: DS.Spacing.x3) {
                    HStack(spacing: DS.Spacing.x1) {
                        Image(systemName: titleIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(isScheduled ? AppColors.warning : AppColors.primary)
                        Text(cardTitle)
                            .font(DS.Typography.title)
                            .foregroundColor(AppColors.textPrimary)
                            .fontWeight(.bold)
                    }

                    VStack(spacing: DS.Spacing.x2) {
                        infoRow(
                            icon: "phone.fill",
                            label: t("拨号号码", "Call Number"),
                            value: phone
                        )
                        infoRow(
                            icon: "doc.text.fill",
                            label: t("使用话术", "Template"),
                            value: templateName
                        )
                        if isScheduled {
                            infoRow(
                                icon: "clock.fill",
                                label: t("拨出时间", "Scheduled At"),
                                value: scheduledTimeDisplay,
                                valueColor: AppColors.warning
                            )
                        }
                    }
                    .padding(DS.Spacing.x2)
                    .background(AppColors.backgroundSecondary)
                    .cornerRadius(DS.Radius.card)

                    Text(hintText)
                        .font(DS.Typography.caption)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .padding(DS.Spacing.x3)

                Divider()

                HStack(spacing: 0) {
                    Button(action: onCancel) {
                        Text(t("取消", "Cancel"))
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.x2)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 44)

                    Button(action: onConfirm) {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: confirmButtonIcon)
                                .font(.system(size: 14, weight: .bold))
                            Text(confirmButtonLabel)
                                .font(DS.Typography.body.weight(.bold))
                        }
                        .foregroundColor(isScheduled ? AppColors.warning : AppColors.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.x2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(AppColors.surface)
            .cornerRadius(DS.Radius.card * 1.5)
            .shadow(color: .black.opacity(0.15), radius: 24, x: 0, y: 8)
            .padding(.horizontal, DS.Spacing.x3)
        }
    }

    private func infoRow(icon: String, label: String, value: String, valueColor: Color = AppColors.textPrimary) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.x2) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(AppColors.primary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS.Typography.caption)
                    .foregroundColor(AppColors.textSecondary)
                Text(value)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundColor(valueColor)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OutboundCallsView(language: .zh)
}

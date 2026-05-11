//
//  CallsView.swift
//  CallMate
//

import SwiftUI
import SwiftData
import CoreBluetooth
import Combine

struct CallsView: View {
    let language: Language
    let setLanguage: (Language) -> Void
    let onDisconnect: () -> Void
    let onFactoryReset: () -> Void
    let onDeleteAllLocalData: () -> Void
    let onRebind: () -> Void
    let showsSettingsShortcut: Bool
    let showsAIFab: Bool
    let onHomeVisibilityChange: ((Bool) -> Void)?

    @ObservedObject private var liveTranscriptRouter: LiveTranscriptNotificationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    private let ble = CallMateBLEClient.shared
    @StateObject private var bleState = CallsBLEViewState()
    @StateObject private var fw = FirmwareUpdateService.shared
    
    @State private var showDeviceModal = false
    @State private var showAiChat = false
    @State private var showMcuUpdateSheet = false
    @State private var didCheckMcuUpdate = false
    @State private var dismissedMcuVersionsInSession: Set<String> = []
    @State private var pendingMcuVersionForSheet: String?
    @State private var suppressMcuPopupAfterUpdateSent = false
    @State private var pendingMcuCheckWhenCtrlReady = false
    @State private var pendingMcuRecheckWhenDeviceVersionReady = false
    @AppStorage("callmate.mcu_update_last_check_ts") private var mcuLastCheckTimestamp: Double = 0
    @AppStorage("callmate.mcu_update_prompted_versions") private var mcuPromptedVersionsRaw: String = ""
    @AppStorage("callmate.mcu_silent_update_enabled") private var mcuSilentUpdateEnabled: Bool = true
    @State private var activeMode: ActiveMode = .semi
    @State private var lastActiveNonStandbyMode: ActiveMode = .semi
    @State private var showANCSGuide = false
    @State private var showInternshipReport = false
    // TODO: 测试完成后恢复为 @AppStorage
    @State private var internshipReportDismissed: Bool = false
    @State private var toastMessage: String?
    @State private var takeoverSegmentControlHeight: CGFloat = 100
    private let activeModeKey = "callmate_active_mode"
    private let limitMcuCheckOncePerDay = false
    private let debugIgnoreMcuPromptedVersionLimit = true
    
    private enum ActiveMode: String {
        case standby
        case semi
        case full
    }

    private enum CallListFilter {
        case all, important
    }

    private struct RecentCallCacheKey: Equatable {
        let id: UUID
        let startedAt: Date
        let phone: String
        let summary: String?
        let isImportant: Bool
        let tokenCount: Int?
    }

    private struct DerivedCallsData {
        let recentCalls: [CallLog]
        let importantCalls: [CallLog]
        let repeatCallCountByPhone: [String: Int]
        let totalTokenCount: Int

        static let empty = DerivedCallsData(
            recentCalls: [],
            importantCalls: [],
            repeatCallCountByPhone: [:],
            totalTokenCount: 0
        )
    }
    
    @Query private var recentCalls: [CallLog]

    private static let appEntryTime = Date()
    @State private var viewedCallIDs: Set<UUID> = []

    @State private var derivedCallsData: DerivedCallsData = .empty

    private var recentCallsCacheKey: [RecentCallCacheKey] {
        recentCalls.map { call in
            RecentCallCacheKey(
                id: call.id,
                startedAt: call.startedAt,
                phone: call.phone,
                summary: call.summary,
                isImportant: call.isImportant == true,
                tokenCount: call.tokenCount
            )
        }
    }

    private var inboundRecentCalls: [CallLog] {
        derivedCallsData.recentCalls
    }

    private var importantInboundCalls: [CallLog] {
        derivedCallsData.importantCalls
    }

    private var filteredCallList: [CallLog] {
        callListFilter == .important ? derivedCallsData.importantCalls : derivedCallsData.recentCalls
    }

    private var repeatCallCountByPhone: [String: Int] {
        derivedCallsData.repeatCallCountByPhone
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 100_000_000 {
            return String(format: "%.1fy", Double(count) / 100_000_000.0)
        } else if count >= 10_000 {
            return String(format: "%.1fw", Double(count) / 10_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func isNewCallInCurrentSession(_ call: CallLog) -> Bool {
        call.startedAt >= Self.appEntryTime && !viewedCallIDs.contains(call.id)
    }

    private var shouldHideTabBar: Bool {
        isShowingSubView || showDeviceModal || isConnectingEchoCard
    }

    private var isOTAPerfSensitiveState: Bool {
        showDeviceModal || showMcuUpdateSheet || fw.isUpdating || fw.updateStage != .idle
    }

    private var bleSnapshot: CallsBLEViewSnapshot {
        bleState.snapshot
    }

    @MainActor
    init(
        language: Language,
        setLanguage: @escaping (Language) -> Void,
        onDisconnect: @escaping () -> Void,
        onFactoryReset: @escaping () -> Void,
        onDeleteAllLocalData: @escaping () -> Void,
        onRebind: @escaping () -> Void,
        showsSettingsShortcut: Bool = true,
        showsAIFab: Bool = true,
        liveTranscriptRouter: LiveTranscriptNotificationRouter? = nil,
        onHomeVisibilityChange: ((Bool) -> Void)? = nil
    ) {
        self.language = language
        self.setLanguage = setLanguage
        self.onDisconnect = onDisconnect
        self.onFactoryReset = onFactoryReset
        self.onDeleteAllLocalData = onDeleteAllLocalData
        self.onRebind = onRebind
        self.showsSettingsShortcut = showsSettingsShortcut
        self.showsAIFab = showsAIFab
        self.onHomeVisibilityChange = onHomeVisibilityChange
        _liveTranscriptRouter = ObservedObject(wrappedValue: liveTranscriptRouter ?? .shared)

        if let saved = UserDefaults.standard.string(forKey: activeModeKey),
           let m = ActiveMode(rawValue: saved) {
            _activeMode = State(initialValue: m)
            _lastActiveNonStandbyMode = State(initialValue: m == .standby ? .semi : m)
        } else {
            _activeMode = State(initialValue: .semi)
            _lastActiveNonStandbyMode = State(initialValue: .semi)
        }

        var descriptor = FetchDescriptor<CallLog>(
            predicate: #Predicate<CallLog> { call in
                !call.isSimulation
            },
            sortBy: [SortDescriptor(\CallLog.startedAt, order: .reverse)]
        )
        // Limit loaded records to avoid expensive main-thread work (transcript lazy-loads,
        // repeated in-memory filtering) while FirmwareUpdateService publishes OTA progress
        // updates and triggers CallsView re-renders every ~0.25s.
        descriptor.fetchLimit = 200
        _recentCalls = Query(descriptor)
    }
    
    @State private var showSettings = false
    @State private var showVoiceToneInSettings = false
    @State private var showPromptRulesInSettings = false
    @State private var showSimulationView = false
    @State private var showSimulationCalls = false
    @State private var isConnectingEchoCard = false
    @State private var echoCardConnectDeadline: Date?
    @State private var echoCardConnectTask: Task<Void, Never>?
    @State private var selectedDetail: CallLog?
    @State private var selectedTestReport: CallLog?
    @State private var simulationCallDetail: CallLog?
    @State private var recentCallsVisibleCount = 10
    private let recentCallsPageSize = 10
    @State private var callListFilter: CallListFilter = .all
    @State private var isLoadingMoreCalls = false
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var callToDelete: CallLog?

    private var isShowingSubView: Bool {
        showSettings || showSimulationView || showSimulationCalls || selectedDetail != nil || selectedTestReport != nil || simulationCallDetail != nil
    }

    private var isOnHomePage: Bool {
        !isShowingSubView && !showDeviceModal
    }

    private func refreshDerivedCallsData() {
        var visibleCalls: [CallLog] = []
        visibleCalls.reserveCapacity(recentCalls.count)

        var important: [CallLog] = []
        var repeatCountByPhone: [String: Int] = [:]
        var totalTokenCount = 0

        for call in recentCalls {
            visibleCalls.append(call)
            if call.isImportant == true {
                important.append(call)
            }
            repeatCountByPhone[call.phone, default: 0] += 1
            totalTokenCount += call.tokenCount ?? 0
        }

        derivedCallsData = DerivedCallsData(
            recentCalls: visibleCalls,
            importantCalls: important,
            repeatCallCountByPhone: repeatCountByPhone,
            totalTokenCount: totalTokenCount
        )
    }

    private func closeSettings() {
        showSimulationView = false
        showSimulationCalls = false
        selectedTestReport = nil
        simulationCallDetail = nil
        showSettings = false
    }

    private var settingsLayerView: some View {
        SettingsView(
            language: language,
            setLanguage: setLanguage,
            showBackButton: true,
            onBack: { withAnimation(.easeInOut(duration: 0.25)) { closeSettings() } },
            onTest: {
                guard guardMCUReadyOrToast() else { return }
                withAnimation(.easeInOut(duration: 0.25)) { showSimulationView = true }
            },
            onSimulationCalls: {
                guard guardMCUReadyOrToast() else { return }
                withAnimation(.easeInOut(duration: 0.25)) { simulationCallDetail = nil; showSimulationCalls = true }
            },
            onDeviceManage: { withAnimation(.easeInOut(duration: 0.25)) { showDeviceModal = true } },
            onRebind: onRebind,
            onDeleteAllLocalData: onDeleteAllLocalData,
            onVoiceToneVisibilityChange: { showVoiceToneInSettings = $0 },
            onPromptRulesVisibilityChange: { showPromptRulesInSettings = $0 }
        )
    }

    private var contentLayer: some View {
        ZStack(alignment: .bottomTrailing) {
            dashboardView
                .allowsHitTesting(!isShowingSubView)

            if showSettings {
                // Overlays rendered outside settingsLayerView — disable its hit testing entirely
                let hasExternalChildLayer = showSimulationView || showSimulationCalls || selectedTestReport != nil || simulationCallDetail != nil || showDeviceModal
                // Any sub-page open (including voice tone / prompt rules rendered inside settings) — disable swipe-back
                let hasAnyChildLayer = hasExternalChildLayer || showVoiceToneInSettings || showPromptRulesInSettings
                settingsLayerView
                    .allowsHitTesting(!hasExternalChildLayer)
                    .edgeSwipeBack(
                        enabled: !hasAnyChildLayer,
                        perform: { closeSettings() }
                    )
                    .transition(.move(edge: .trailing))
            }

            if showSimulationView {
                SimulationView(language: language) { savedCall in
                    showSimulationView = false
                    selectedTestReport = savedCall
                }
                .allowsHitTesting(selectedTestReport == nil)
                .edgeSwipeBack(perform: { showSimulationView = false })
                .transition(.move(edge: .trailing))
            }

            if showSimulationCalls {
                AllCallsView(
                    language: language,
                    onBack: { withAnimation(.easeInOut(duration: 0.25)) { showSimulationCalls = false } },
                    onCallClick: { call in withAnimation(.easeInOut(duration: 0.25)) { simulationCallDetail = call } },
                    mode: .simulationOnly
                )
                .allowsHitTesting(simulationCallDetail == nil)
                .edgeSwipeBack(perform: { showSimulationCalls = false })
                .transition(.move(edge: .trailing))
            }

            if let call = selectedTestReport {
                CallDetailView(call: call, language: language, isTest: true, onBack: {
                    withAnimation(.easeInOut(duration: 0.25)) { selectedTestReport = nil }
                })
                .edgeSwipeBack(perform: { selectedTestReport = nil })
                .transition(.move(edge: .trailing))
            }

            if let call = simulationCallDetail {
                CallDetailView(call: call, language: language, isTest: true, onBack: {
                    withAnimation(.easeInOut(duration: 0.25)) { simulationCallDetail = nil }
                })
                .edgeSwipeBack(perform: { simulationCallDetail = nil })
                .transition(.move(edge: .trailing))
            }

            if let call = selectedDetail {
                CallDetailView(call: call, language: language, isTest: false, onBack: {
                    withAnimation(.easeInOut(duration: 0.25)) { selectedDetail = nil }
                })
                .edgeSwipeBack(perform: { selectedDetail = nil })
                .transition(.move(edge: .trailing))
            }
            
            if !isShowingSubView, showsAIFab {
                floatingAiButton
            }
            
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(AppTypography.subheadline)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(AppSpacing.md)
                        .frame(maxWidth: 280)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            if showInternshipReport {
                InternshipReportView(
                    language: language,
                    reportIndex: 1,
                    onConfirm: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showInternshipReport = false
                            internshipReportDismissed = true
                        }
                    },
                    onReject: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showInternshipReport = false
                            internshipReportDismissed = true
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showInternshipReport = false }
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(9)
            }

            if showDeviceModal {
                DeviceModalView(language: language, onClose: {
                    withAnimation(.easeInOut(duration: 0.25)) { showDeviceModal = false }
                }, onDisconnect: {
                    showDeviceModal = false
                    DispatchQueue.main.async { onDisconnect() }
                }, onFactoryReset: {
                    showDeviceModal = false
                    DispatchQueue.main.async { onFactoryReset() }
                }, onRebind: {
                    showDeviceModal = false
                    DispatchQueue.main.async { onRebind() }
                })
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showDeviceModal = false }
                })
                .transition(.move(edge: .trailing))
                .zIndex(10)
            }

            if isConnectingEchoCard {
                connectingEchoCardOverlay
                    .zIndex(20)
            }
        }
    }

    private var animatedContentLayer: some View {
        contentLayer
            .animation(.easeInOut(duration: 0.25), value: showSettings)
            .animation(.easeInOut(duration: 0.25), value: showSimulationView)
            .animation(.easeInOut(duration: 0.25), value: showSimulationCalls)
            .animation(.easeInOut(duration: 0.25), value: selectedDetail?.id)
            .animation(.easeInOut(duration: 0.25), value: selectedTestReport?.id)
            .animation(.easeInOut(duration: 0.25), value: simulationCallDetail?.id)
            .animation(.easeInOut(duration: 0.25), value: showDeviceModal)
    }

    private var contentLayerWithSheets: some View {
        animatedContentLayer
            .sheet(isPresented: $showAiChat) {
                FeedbackChatModalView(
                    language: language,
                    feedbackType: "none",
                    onClose: { showAiChat = false },
                    onTest: {
                        guard guardMCUReadyOrToast() else { return }
                        CallSessionController.sharedStopCurrentSession()
                        showAiChat = false
                        showSimulationView = true
                    },
                    showInitialMessage: false,
                    initMessagesOverride: [
                        ["role": "user", "content": "你好"],
                        ["role": "assistant", "content": "你好，我是你的专属AI分身。你可以直接告诉我需要查询的数据，或者想调整的接听策略。"]
                    ]
                )
            }
            .sheet(isPresented: $showMcuUpdateSheet) {
                mcuUpdateSheet
                    .interactiveDismissDisabled(fw.isUpdating)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showANCSGuide) {
                if AppFeatureFlags.ancsAuthorizationEnabled {
                    ANCSPermissionGuideView(language: language, onDismiss: { showANCSGuide = false })
                }
            }
    }

    var body: some View {
        contentLayerWithSheets
        .accessibilityIdentifier("calls-root")
        .onAppear {
            onHomeVisibilityChange?(isOnHomePage)
            checkMcuUpdateIfNeeded(force: false)
            openPendingCallDetailIfNeeded()
        }
        .onChange(of: isShowingSubView) { _, showing in
            onHomeVisibilityChange?(!showing && !showDeviceModal)
            if !showing {
                checkMcuUpdateIfNeeded(force: false)
            }
        }
        .onChange(of: showDeviceModal) { _, showing in
            onHomeVisibilityChange?(!isShowingSubView && !showing)
        }
        .onChange(of: ble.isCtrlReady) { _, ready in
            if ready {
                if pendingMcuCheckWhenCtrlReady {
                    logMcuPopup("ctrl ready: run deferred check")
                    pendingMcuCheckWhenCtrlReady = false
                }
                checkMcuUpdateIfNeeded(force: true)
            }
        }
        .onChange(of: ble.deviceFirmwareVersion) { _, newValue in
            let normalized = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty else { return }
            guard pendingMcuRecheckWhenDeviceVersionReady else { return }
            guard bleSnapshot.isCtrlReady else { return }
            pendingMcuRecheckWhenDeviceVersionReady = false
            logMcuPopup("device fw ready=\(normalized), run deferred recheck")
            checkMcuUpdateIfNeeded(force: true)
        }
        .onChange(of: fw.isUpdating) { _, _ in
            dismissMcuSheetIfUpdateCompleted()
        }
        .onChange(of: fw.updateStage) { _, _ in
            if fw.updateStage == .rebooting {
                suppressMcuPopupAfterUpdateSent = true
                showMcuUpdateSheet = false
                pendingMcuVersionForSheet = nil
                logMcuPopup("close sheet: update sent, rebooting")
            }
            dismissMcuSheetIfUpdateCompleted()
        }
        .onChange(of: fw.statusText) { _, _ in
            dismissMcuSheetIfUpdateCompleted()
        }
        .onChange(of: toastMessage) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    toastMessage = nil
                }
            }
        }
        .onChange(of: liveTranscriptRouter.pendingOpenCallDetailId) { _, callId in
            guard callId != nil else { return }
            openPendingCallDetailIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            openPendingCallDetailIfNeeded()
        }
        .onReceive(ble.$isReady.removeDuplicates()) { _ in
            completeEchoCardConnectIfReady()
        }
        .onReceive(ble.$connectedPeripheralID.removeDuplicates(by: ==)) { _ in
            completeEchoCardConnectIfReady()
        }
        .onDisappear {
            stopEchoCardConnectAttempt(shouldDisconnect: false)
            loadMoreTask?.cancel()
            loadMoreTask = nil
        }
        .toolbar(shouldHideTabBar ? .hidden : .visible, for: .tabBar)
        .alert(
            t("删除通话记录", "Delete Call Record"),
            isPresented: Binding(
                get: { callToDelete != nil },
                set: { if !$0 { callToDelete = nil } }
            )
        ) {
            Button(t("取消", "Cancel"), role: .cancel) {
                callToDelete = nil
            }
            Button(t("删除", "Delete"), role: .destructive) {
                if let call = callToDelete {
                    deleteCall(call)
                }
                callToDelete = nil
            }
        } message: {
            Text(t("确定要删除这条通话记录吗？", "Are you sure you want to delete this call record?"))
        }
    }

    private var mcuUpdateSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text(t("检测到新的 MCU 固件版本，建议立即升级以获得更稳定的通话体验。", "A new MCU firmware version is available. Update now for better call stability."))
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)

                HStack {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(t("当前版本", "Current"))
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textSecondary)
                        Text(bleSnapshot.deviceFirmwareVersion ?? "--")
                            .font(AppTypography.bodyEmphasized)
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(t("最新版本", "Latest"))
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textSecondary)
                        Text(fw.latestMetadata?.version ?? "--")
                            .font(AppTypography.bodyEmphasized)
                            .foregroundColor(AppColors.primary)
                    }
                }
                .padding(AppSpacing.md)
                .dsCardStyle()

                if fw.isUpdating || fw.updateStage != .idle {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(t("升级进度", "Update Progress"))
                            .font(AppTypography.subheadline)
                            .foregroundColor(AppColors.textPrimary)
                        ProgressView(value: fw.progress)
                            .tint(AppColors.primary)
                        Text(fw.statusText.isEmpty ? t("正在升级...", "Updating...") : fw.statusText)
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .padding(AppSpacing.md)
                    .dsCardStyle()
                }

                if let err = fw.lastError, !err.isEmpty {
                    Text(err)
                        .font(AppTypography.caption1)
                        .foregroundColor(AppColors.error)
                }

                Spacer()
            }
            .padding(AppSpacing.lg)
            .navigationTitle(t("MCU 固件更新", "MCU Firmware Update"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(t("稍后", "Later")) {
                        if let version = pendingMcuVersionForSheet, !version.isEmpty {
                            dismissedMcuVersionsInSession.insert(version)
                        }
                        showMcuUpdateSheet = false
                    }
                    .disabled(fw.isUpdating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await startMcuUpdateWithRecheck() }
                    } label: {
                        Text(fw.isUpdating ? t("更新中", "Updating") : t("立即更新", "Update Now"))
                    }
                    .disabled(fw.isUpdating || fw.latestMetadata == nil)
                }
            }
        }
    }

    private func checkMcuUpdateIfNeeded(force: Bool) {
        guard !isShowingSubView else {
            logMcuPopup("skip: not dashboard")
            return
        }
        guard !showMcuUpdateSheet else {
            logMcuPopup("skip: sheet already showing")
            return
        }
        guard ble.isCtrlReady else {
            pendingMcuCheckWhenCtrlReady = true
            logMcuPopup("skip: ble.isCtrlReady=false")
            return
        }
        pendingMcuCheckWhenCtrlReady = false
        guard !fw.isChecking, !fw.isUpdating else {
            logMcuPopup("skip: fw busy checking=\(fw.isChecking) updating=\(fw.isUpdating)")
            return
        }
        guard fw.updateStage == .idle else {
            logMcuPopup("skip: fw updateStage=\(fw.updateStage)")
            return
        }
        guard !suppressMcuPopupAfterUpdateSent else {
            logMcuPopup("skip: suppressed after update sent in this session")
            return
        }
        if limitMcuCheckOncePerDay {
            guard !hasCheckedMcuUpdateToday() else {
                logMcuPopup("skip: already checked today")
                return
            }
        }
        if didCheckMcuUpdate && !force {
            logMcuPopup("skip: already checked in this view lifecycle")
            return
        }
        didCheckMcuUpdate = true
        if limitMcuCheckOncePerDay {
            mcuLastCheckTimestamp = Date().timeIntervalSince1970
        }
        logMcuPopup("start checkForUpdate force=\(force)")
        Task {
            await fw.checkForUpdate()
            let currentVersion = ble.deviceFirmwareVersion ?? "nil"
            let latestVersionRaw = fw.latestMetadata?.version ?? "nil"
            logMcuPopup("check done current=\(currentVersion) latest=\(latestVersionRaw)")
            let normalizedCurrent = (ble.deviceFirmwareVersion ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedCurrent.isEmpty {
                pendingMcuRecheckWhenDeviceVersionReady = true
                logMcuPopup("skip: device fw not ready, wait for first device_info then recheck")
                return
            }
            pendingMcuRecheckWhenDeviceVersionReady = false
            guard isUpdateAvailable(current: ble.deviceFirmwareVersion, latest: fw.latestMetadata?.version) else {
                logMcuPopup("skip: no newer version")
                return
            }
            guard let latestVersion = fw.latestMetadata?.version, !latestVersion.isEmpty else {
                logMcuPopup("skip: latest version empty")
                return
            }
            guard !dismissedMcuVersionsInSession.contains(latestVersion) else {
                logMcuPopup("skip: dismissed in current session version=\(latestVersion)")
                return
            }
            if !debugIgnoreMcuPromptedVersionLimit {
                guard !mcuPromptedVersions.contains(latestVersion) else {
                    logMcuPopup("skip: prompted before version=\(latestVersion) prompted=\(Array(mcuPromptedVersions).sorted())")
                    return
                }
            } else {
                logMcuPopup("debug bypass: ignore prompted-version-once limit")
            }
            pendingMcuVersionForSheet = latestVersion
            markMcuVersionPrompted(latestVersion)
            if mcuSilentUpdateEnabled {
                logMcuPopup("silent mode: start update directly, no sheet version=\(latestVersion)")
                await fw.startUpdateIfAvailable()
            } else {
                logMcuPopup("show sheet version=\(latestVersion)")
                showMcuUpdateSheet = true
            }
        }
    }

    private var mcuPromptedVersions: Set<String> {
        Set(
            mcuPromptedVersionsRaw
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func markMcuVersionPrompted(_ version: String) {
        var versions = mcuPromptedVersions
        versions.insert(version)
        mcuPromptedVersionsRaw = versions.sorted().joined(separator: ",")
    }

    private func hasCheckedMcuUpdateToday() -> Bool {
        guard mcuLastCheckTimestamp > 0 else { return false }
        let last = Date(timeIntervalSince1970: mcuLastCheckTimestamp)
        return Calendar.current.isDateInToday(last)
    }

    private func dismissMcuSheetIfUpdateCompleted() {
        guard showMcuUpdateSheet else { return }
        guard !fw.isUpdating else { return }
        guard fw.updateStage == .idle else { return }
        guard fw.lastError == nil else { return }
        // FirmwareUpdateService clears transient status text when device reconnects
        // after a successful reboot; use that as completion signal.
        guard fw.statusText.isEmpty else { return }
        showMcuUpdateSheet = false
        pendingMcuVersionForSheet = nil
    }

    private func startMcuUpdateWithRecheck() async {
        guard !fw.isUpdating, !fw.isChecking else { return }
        logMcuPopup("update tapped -> recheck latest")
        await fw.checkForUpdate()
        guard isUpdateAvailable(current: ble.deviceFirmwareVersion, latest: fw.latestMetadata?.version) else {
            logMcuPopup("recheck says no update, close sheet")
            toastMessage = t("已是最新版本", "Already up to date")
            showMcuUpdateSheet = false
            pendingMcuVersionForSheet = nil
            return
        }
        logMcuPopup("recheck says update available, start update")
        await fw.startUpdateIfAvailable()
    }

    private func logMcuPopup(_ message: String) {
        print("[MCU_POPUP] \(message)")
    }

    private func isUpdateAvailable(current: String?, latest: String?) -> Bool {
        guard let latest, !latest.isEmpty else { return false }
        guard let current, !current.isEmpty else { return false }
        let cParts = current.split(separator: ".").compactMap { Int($0) }
        let lParts = latest.split(separator: ".").compactMap { Int($0) }
        if cParts.isEmpty || lParts.isEmpty { return current != latest }
        let count = max(cParts.count, lParts.count)
        for i in 0..<count {
            let c = i < cParts.count ? cParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    // Navigation is now handled per-layer via individual edgeSwipeBack modifiers
    
    private var dashboardView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                header
                
                if !internshipReportDismissed {
                    InternshipReportBanner(language: language, reportIndex: 1, onTap: {
                        withAnimation(.easeInOut(duration: 0.25)) { showInternshipReport = true }
                    })
                }
                
                EchoCardPermissionsCard(language: language)
                if AppFeatureFlags.ancsAuthorizationEnabled && bleSnapshot.deviceANCSEnabled == false {
                    ANCSWarningBanner(language: language, onTap: { showANCSGuide = true })
                }
                modeSelector
                recentCallsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("calls-dashboard-scroll")
        .background(AppColors.backgroundSecondary)
        .onAppear {
            if !isOTAPerfSensitiveState { logStrangerTagDebug(reason: "dashboard_on_appear") }
        }
        .modifier(DashboardInboundCountChange(
            showOTABlockingUI: isOTAPerfSensitiveState,
            getCount: { inboundRecentCalls.count },
            action: { logStrangerTagDebug(reason: "inbound_count_changed") }
        ))
    }

    private func logStrangerTagDebug(reason: String) {
        let sample = inboundRecentCalls.prefix(20).map { call in
            "phone=\(call.phone) label=\(call.label)"
        }
        print("[StrangerTag][CallsView] reason=\(reason) inbound=\(inboundRecentCalls.count) repeatByPhone=\(repeatCallCountByPhone) sample=\(sample)")
    }

    
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("EchoCard")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .foregroundColor(AppColors.textPrimary)
                    .frame(height: 40)

                Spacer()

                if showsSettingsShortcut {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { showSettings = true }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20))
                            .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calls-settings-button")
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }

            Button {
                showDeviceModal = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 8, height: 8)
                    Text(connectionStatusText)
                        .font(.system(size: 13, weight: .medium))
                        .tracking(0.3)
                        .foregroundColor(connectionStatusColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(connectionStatusColor.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(connectionStatusColor.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("calls-device-button")
        }
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
                return t("已连接 · 固件升级中", "Connected · Updating")
            }
            return t("已连接", "Connected")
        }
        if bleSnapshot.connectingPeripheralID != nil || bleSnapshot.connectedPeripheralID != nil {
            return t("连接中", "Connecting")
        }
        return t("未连接", "Disconnected")
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
    
    private var isDeviceConnected: Bool {
        bleSnapshot.bluetoothState == .poweredOn && bleSnapshot.isReady && bleSnapshot.connectedPeripheralID != nil
    }

    private var isMCUReadyForRealtimeFeatures: Bool {
        guard isDeviceConnected else { return false }
        let deviceId = (ble.runtimeMCUDeviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !deviceId.isEmpty
    }

    private func guardMCUReadyOrToast() -> Bool {
        guard isMCUReadyForRealtimeFeatures else {
            toastMessage = t("请先连接 EchoCard", "Please connect EchoCard first")
            return false
        }
        return true
    }

    private static let takeoverTrackInset: CGFloat = 6
    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("接管模式", "Call Mode"))
                .font(AppTypography.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)

            segmentControlTrack
                .padding(.top, 16)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(AppColors.textTertiary)
                    .font(.system(size: 14))
                Text(modeHint)
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textTertiary)
            }
            .padding(.top, 16)
        }
        .padding(AppSpacing.lg)
        .dsCardStyle()
        .opacity(isDeviceConnected ? 1 : 0.92)
        .overlay {
            if shouldShowModeConnectBlocker {
                modeConnectBlocker
            }
        }
    }

    /// Segment control track — GeometryReader is confined to `.overlay` / `.background`
    /// so it cannot interfere with VStack spacing calculations.
    private var segmentControlTrack: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: takeoverSegmentControlHeight)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TakeoverWidthPreferenceKey.self, value: g.size.width)
                }
            )
            .onPreferenceChange(TakeoverWidthPreferenceKey.self) { w in
                if w > 0 {
                    takeoverSegmentControlHeight = (w - Self.takeoverTrackInset * 2) / 3 + Self.takeoverTrackInset * 2
                }
            }
            .overlay {
                GeometryReader { geo in
                    let segmentSide = (geo.size.width - Self.takeoverTrackInset * 2) / 3
                    let selectedIndex = activeModeIndex
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                            .fill(AppColors.backgroundGrouped)
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .fill(AppColors.primary)
                            .shadow(color: AppColors.primary.opacity(0.3), radius: 12, x: 0, y: 4)
                            .frame(width: segmentSide, height: segmentSide)
                            .offset(x: Self.takeoverTrackInset + CGFloat(selectedIndex) * segmentSide, y: Self.takeoverTrackInset)
                            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: selectedIndex)
                        HStack(spacing: 0) {
                            modeButton(.standby, label: t("待机", "Standby"), segmentSide: segmentSide)
                            modeButton(.semi, label: t("智能", "Smart"), segmentSide: segmentSide)
                            modeButton(.full, label: t("全接管", "Full"), segmentSide: segmentSide)
                        }
                        .padding(Self.takeoverTrackInset)
                    }
                }
            }
    }
    
    private var activeModeIndex: Int {
        switch activeMode {
        case .standby: return 0
        case .semi: return 1
        case .full: return 2
        }
    }
    
    private func modeButton(_ mode: ActiveMode, label: String, segmentSide: CGFloat) -> some View {
        let isSelected = activeMode == mode
        return Button {
            if mode == .full {
                toastMessage = t("转正后才能开启此模式，请多多使用AI分身接电话", "Full mode unlocks after graduation. Keep using your AI assistant!")
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                activeMode = mode
                if mode != .standby {
                    lastActiveNonStandbyMode = mode
                }
            }
            UserDefaults.standard.set(mode.rawValue, forKey: activeModeKey)
        } label: {
            modeSegmentContent(mode: mode, label: label, isSelected: isSelected)
        }
        .frame(width: segmentSide, height: segmentSide)
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func modeSegmentContent(mode: ActiveMode, label: String, isSelected: Bool) -> some View {
        let iconColor: Color = isSelected ? .white : AppColors.textSecondary
        VStack(spacing: 6) {
            ZStack {
                switch mode {
                case .standby:
                    Image(systemName: "moon.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .foregroundColor(iconColor)
                case .semi:
                    MagicSparkleIcon()
                        .fill(iconColor)
                        .frame(width: 22, height: 26.6)
                case .full:
                    BrainHandsIcon()
                        .fill(iconColor)
                        .frame(width: 24, height: 23)
                }
            }
            .frame(width: 30, height: 30)
            Text(label)
                .font(AppTypography.footnote)
                .fontWeight(.medium)
                .foregroundColor(isSelected ? .white : AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    
    private var modeHint: String {
        switch activeMode {
        case .standby:
            return t("蓝牙待机中，不会监听来电", "Bluetooth standby, not monitoring calls.")
        case .semi:
            return t("蓝牙工作中，持续监听陌生来电", "Bluetooth active, monitoring unknown calls.")
        case .full:
            return t("全程代接，智能沟通并妥善处理", "Full takeover. AI handles and summarizes.")
        }
    }

    private var shouldShowModeConnectBlocker: Bool {
        ble.hasSavedPeripheral && !isDeviceConnected && !isConnectingEchoCard
    }

    private var modeConnectBlocker: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .fill(AppColors.surface.opacity(0.96))

            VStack(spacing: 14) {
                Text(t("请先连接 EchoCard", "Please connect EchoCard first"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "1D1D1F"))

                Button {
                    startEchoCardConnectAttempt()
                } label: {
                    Text(t("立即连接", "Connect Now"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color(hex: "007AFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectingEchoCardOverlay: some View {
        ZStack {
            AppColors.backgroundSecondary
                .opacity(0.95)
                .ignoresSafeArea()
            VStack(spacing: AppSpacing.lg) {
                ProgressView()
                    .scaleEffect(1.15)
                    .tint(AppColors.primary)
                Text(t("正在连接 EchoCard", "Connecting EchoCard"))
                    .font(AppTypography.title3)
                    .foregroundColor(AppColors.textPrimary)
                Button {
                    stopEchoCardConnectAttempt(shouldDisconnect: true)
                } label: {
                    Text(t("取消", "Cancel"))
                        .font(AppTypography.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.sm)
                        .background(AppColors.surface)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(AppSpacing.xl)
        }
        .transition(.opacity)
    }

    private func startEchoCardConnectAttempt() {
        guard !isConnectingEchoCard else { return }
        isConnectingEchoCard = true
        let deadline = Date().addingTimeInterval(60)
        echoCardConnectDeadline = deadline
        echoCardConnectTask?.cancel()
        ble.resumeAutoReconnect(reason: "calls_mode_connect_button")
        ble.autoConnectIfPossible()
        ble.ensureConnectionRecovered(reason: "calls_mode_connect_button")
        echoCardConnectTask = Task { @MainActor in
            var loopCount = 0
            while !Task.isCancelled {
                if isDeviceConnected {
                    stopEchoCardConnectAttempt(shouldDisconnect: false)
                    return
                }
                guard let timeoutAt = echoCardConnectDeadline, Date() < timeoutAt else {
                    stopEchoCardConnectAttempt(shouldDisconnect: true)
                    return
                }
                loopCount += 1
                if loopCount == 5 {
                    // ~15s without success: BLE stack may be stale (overnight idle, etc).
                    // Rebuild CBCentralManager and actively re-issue connect.
                    ble.forceReconnect()
                } else {
                    ble.ensureConnectionRecovered(reason: "calls_mode_connect_retry")
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopEchoCardConnectAttempt(shouldDisconnect: Bool) {
        echoCardConnectTask?.cancel()
        echoCardConnectTask = nil
        echoCardConnectDeadline = nil
        isConnectingEchoCard = false
        if shouldDisconnect {
            ble.stopScanning()
            if ble.connectingPeripheralID != nil || (!ble.isReady && ble.connectedPeripheralID != nil) {
                ble.disconnect(userInitiated: true)
            }
        }
    }

    private func completeEchoCardConnectIfReady() {
        guard isConnectingEchoCard else { return }
        if isDeviceConnected {
            stopEchoCardConnectAttempt(shouldDisconnect: false)
        }
    }
    
    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            callStatsBar

            if filteredCallList.isEmpty {
                emptyCallsView
            } else {
                let visibleCalls = Array(filteredCallList.prefix(recentCallsVisibleCount))
                VStack(spacing: AppSpacing.sm) {
                    ForEach(visibleCalls) { call in
                        SwipeToDeleteRow(onDelete: { callToDelete = call }) {
                            Button {
                                viewedCallIDs.insert(call.id)
                                withAnimation(.easeInOut(duration: 0.25)) { selectedDetail = call }
                            } label: {
                                CallRowView(
                                    call: call,
                                    language: language,
                                    isNewInCurrentSession: isNewCallInCurrentSession(call),
                                    repeatCallCount: repeatCallCountByPhone[call.phone] ?? 0
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("calls-row-\(call.phone)")
                        }
                        .onAppear {
                            guard call.id == visibleCalls.last?.id else { return }
                            guard recentCallsVisibleCount < filteredCallList.count else { return }
                            guard !isLoadingMoreCalls else { return }
                            loadMoreCalls()
                        }
                    }

                    if isLoadingMoreCalls {
                        loadMoreSpinner
                    }
                }
            }
        }
        .onAppear {
            recentCallsVisibleCount = recentCallsPageSize
            refreshDerivedCallsData()
        }
        .onChange(of: recentCallsCacheKey) { _, _ in
            refreshDerivedCallsData()
        }
        .onChange(of: filteredCallList.count) { _, newCount in
            if newCount <= recentCallsPageSize {
                recentCallsVisibleCount = recentCallsPageSize
            } else if recentCallsVisibleCount > newCount {
                recentCallsVisibleCount = newCount
            }
        }
        .onChange(of: callListFilter) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                recentCallsVisibleCount = recentCallsPageSize
                isLoadingMoreCalls = false
            }
        }
    }

    private func loadMoreCalls() {
        let totalCount = filteredCallList.count
        loadMoreTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            isLoadingMoreCalls = true
        }
        loadMoreTask = Task {
            // Let the spinner show for a clear moment
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Add items without animation so they just appear (no slide effect)
                recentCallsVisibleCount = min(
                    recentCallsVisibleCount + recentCallsPageSize,
                    totalCount
                )
            }
            // Brief pause so the spinner doesn't vanish at the same frame as new items
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    isLoadingMoreCalls = false
                }
            }
        }
    }

    private var loadMoreSpinner: some View {
        HStack(spacing: AppSpacing.sm) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.8)
                .tint(AppColors.primary)
            Text(t("加载更多…", "Loading more…"))
                .font(AppTypography.caption1)
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.md)
        .transition(.opacity)
    }

    /// newui: 单卡三列、rounded-[20px] p-5、divide-x；数值 28pt bold，标签 12pt
    private var callStatsBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { callListFilter = .all }
            } label: {
                callStatItem(
                    value: "\(inboundRecentCalls.count)",
                    label: t("累计通话数", "Total Calls"),
                    isSelected: callListFilter == .all
                )
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(lightHex: "E5E5EA", darkHex: "38383A"))
                .frame(width: 1)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { callListFilter = .important }
            } label: {
                callStatItem(
                    value: "\(importantInboundCalls.count)",
                    label: t("重要来电数", "Important"),
                    isSelected: callListFilter == .important
                )
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(lightHex: "E5E5EA", darkHex: "38383A"))
                .frame(width: 1)

            callStatItem(
                value: formatTokenCount(derivedCallsData.totalTokenCount),
                label: t("累计token数", "Total Tokens"),
                isSelected: false,
                isClickable: false
            )
        }
        .padding(AppSpacing.lg)
        .background(AppColors.surface)
        .cornerRadius(AppRadius.xl)
        .appShadow(AppShadow.sm)
    }

    @ViewBuilder
    private func callStatItem(value: String, label: String, isSelected: Bool, isClickable: Bool = true) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(
                    isSelected ? AppColors.primary :
                    isClickable ? AppColors.textPrimary : AppColors.textSecondary
                )
            Text(label)
                .font(AppTypography.caption1)
                .foregroundColor(isSelected ? AppColors.primary : AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var emptyCallsView: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "phone.badge.checkmark")
                .font(.system(size: 48, weight: .regular))
                .foregroundColor(AppColors.textTertiary)
                .padding(.top, AppSpacing.xxl)
            
            VStack(spacing: AppSpacing.xs) {
                Text(t("暂无通话记录", "No Calls Yet"))
                    .font(AppTypography.bodyEmphasized)
                    .foregroundColor(AppColors.textPrimary)
                
                Text(
                    callListFilter == .important
                    ? t("AI分身会提醒你本人接听重要电话", "Your AI avatar will remind you to take over important calls")
                    : t("AI 会自动接听并记录所有来电", "AI will answer and log all calls")
                )
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                guard guardMCUReadyOrToast() else { return }
                withAnimation(.easeInOut(duration: 0.25)) { showSimulationView = true }
            } label: {
                Text(t("模拟通话测试", "Try Simulation"))
                    .font(AppTypography.bodyEmphasized)
                    .foregroundColor(AppColors.primary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, AppSpacing.xxl)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xl)
        .background(AppColors.surface)
        .cornerRadius(AppRadius.xl)
        .appShadow(AppShadow.sm)
    }
    
    private var floatingAiButton: some View {
        Button {
            guard guardMCUReadyOrToast() else { return }
            showAiChat = true
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(
                        colors: [AppColors.primary, AppColors.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .shadow(color: AppColors.primary.opacity(0.4), radius: 12, x: 0, y: 6)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        }
        .padding(AppSpacing.xl)
    }

    private func deleteCall(_ call: CallLog) {
        if selectedDetail?.id == call.id {
            selectedDetail = nil
        }
        viewedCallIDs.remove(call.id)
        modelContext.delete(call)
        do {
            try modelContext.save()
        } catch {
            print("[CallsView] delete call failed: \(error.localizedDescription)")
        }
    }

    private func openCallDetail(callId: UUID) {
        do {
            var descriptor = FetchDescriptor<CallLog>(
                predicate: #Predicate<CallLog> { $0.id == callId }
            )
            descriptor.fetchLimit = 1
            if let call = try modelContext.fetch(descriptor).first {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedDetail = call
                }
            }
        } catch {
            print("[CallsView] fetch call for detail route failed: \(error.localizedDescription)")
        }
    }

    private func openPendingCallDetailIfNeeded() {
        guard let callId = liveTranscriptRouter.pendingOpenCallDetailId else { return }
        liveTranscriptRouter.requestDismissTransientOverlays()
        defer { liveTranscriptRouter.clearOpenCallDetail() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openCallDetail(callId: callId)
        }
    }
}

// MARK: - Call Row Component（与 newui 一致：三行布局、20pt 圆角、p4、无边框、shadow-sm）
private struct CallRowView: View {
    let call: CallLog
    let language: Language
    let isNewInCurrentSession: Bool
    let repeatCallCount: Int
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    private var isUnread: Bool { isNewInCurrentSession }
    
    private var aiSummaryLine: String? {
        (call.displayFullSummary?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private var strangerRepeatTagText: String? {
        if repeatCallCount == 2 { return t("重复", "Repeat") }
        if repeatCallCount > 2 { return t("多次", "Multiple") }
        return nil
    }

    private enum CallerCategory {
        case personalContact
        case courier
        case rider
        case carrier
        case bank
        case marketing
        case uncategorized
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

    private var callDurationLabelText: String {
        switch call.status {
        case .handled:
            return formatCallDuration(call.durationSeconds)
        case .missed:
            return t("未接通", "Missed")
        case .blocked, .passed:
            return t("已挂断", "Hung Up")
        }
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
                    .font(.system(size: 16, weight: isUnread ? .bold : .regular))
                    .foregroundColor(isUnread ? AppColors.textPrimary : Color(lightHex: "374151", darkHex: "D1D5DB"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Text(RelativeDateFormatter(language: language).string(from: call.startedAt))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColors.textTertiary)
                }
            }
            .padding(.bottom, 8)

            HStack(alignment: .center, spacing: 6) {
                BotIcon(size: 14, color: AppColors.textTertiary.opacity(0.6))
                Text(aiSummaryLine ?? t("通话内容识别失败", "Call content not recognized"))
                    .font(.system(size: 13, weight: isUnread ? .medium : .regular))
                    .foregroundColor(isUnread ? AppColors.textSecondary : Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                let _ = callerCategory
                let color = categoryColor

                Text(displayContactText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.1))
                    .cornerRadius(4)

                HStack(spacing: 4) {
                    Image(systemName: callDirectionIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary)
                    Text(callDurationLabelText)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                }

                if let tag = strangerRepeatTagText {
                    Text(tag)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(AppColors.backgroundGrouped)
                        .cornerRadius(4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .cornerRadius(AppRadius.xl)
        .appShadow(AppShadow.sm)
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

// MARK: - Swipe-to-delete helper (works inside ScrollView unlike .swipeActions)

struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    private let deleteWidth: CGFloat = 80

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete button revealed behind content
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { offset = 0 }
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: deleteWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                    .cornerRadius(AppRadius.md)
            }
            .buttonStyle(.plain)
            .opacity(offset < -4 ? 1 : 0)

            content
                // When the delete button is revealed, block the row's tap and let the
                // overlay below handle "tap to close" instead.
                .allowsHitTesting(offset == 0)
                .overlay(
                    Group {
                        if offset != 0 {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        offset = 0
                                    }
                                }
                        }
                    }
                )
                .offset(x: offset)
                // highPriorityGesture wins over the child Button's tap recognizer when
                // the finger moves ≥20 pt, so the button never fires after a swipe.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { val in
                            let tx = val.translation.width
                            let ty = val.translation.height
                            guard abs(tx) > abs(ty) else { return }
                            offset = tx < 0 ? max(tx, -deleteWidth) : min(0, tx)
                        }
                        .onEnded { val in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                offset = val.translation.width < -(deleteWidth / 2) ? -deleteWidth : 0
                            }
                        }
                )
        }
        .clipped()
    }
}

// MARK: - Takeover segment control: height from width so each button can be square
private struct TakeoverWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - OTA Performance: avoid evaluating inboundRecentCalls while OTA is active
private struct DashboardInboundCountChange: ViewModifier {
    let showOTABlockingUI: Bool
    let getCount: () -> Int
    let action: () -> Void

    func body(content: Content) -> some View {
        if showOTABlockingUI {
            content
        } else {
            content.onChange(of: getCount()) { _, _ in action() }
        }
    }
}

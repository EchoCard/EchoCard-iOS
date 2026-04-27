//
//  ContentView.swift
//  CallMate
//

import SwiftUI
import SwiftData

struct ContentView: View {
    private let appServices: AppServices
    private let appRouter: AppRouter

    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState = .landing
    @AppStorage("callmate_has_accepted_legal_docs") private var hasAcceptedLegalDocs: Bool = false
    @State private var language: Language = {
        if let preferredLanguage = AppAutomation.preferredLanguage {
            return preferredLanguage
        }
        if let raw = UserDefaults.standard.string(forKey: "callmate.language"),
           let lang = Language(rawValue: raw) {
            return lang
        }
        return .zh
    }()
    @State private var showingLegalDocument: LegalDocumentType?
    @State private var showANCSGuide: Bool = false
    @Environment(\.modelContext) private var modelContext
    /// Non-observed reference for method calls (`autoConnectIfPossible`, `clearSavedPeripheral`, ...).
    /// SwiftUI re-evaluation is driven by `contentBLEState.snapshot` instead of the whole BLE runtime,
    /// so that unrelated mutations (battery, RSSI, speed-test counters, ...) do not force
    /// ContentView's body tree to recompute.
    private let ble: any CallMateBLELibraryClient
    @StateObject private var contentBLEState: ContentViewBLEViewState
    @ObservedObject private var liveBLEController: CallSessionController
    @ObservedObject private var liveTranscriptRouter: LiveTranscriptNotificationRouter
    @ObservedObject private var liveCallPresentation: LiveCallPresentationCoordinator
    @State private var showLocalTestCall: Bool = false
    @State private var localTestCall: CallMateIncomingCall?
    @StateObject private var localTestController = LocalPlaybackTestController()
    @Query private var allCalls: [CallLog]
    private static let sessionDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()
    @AppStorage("ble_local_uplink_test_armed") private var isLocalUplinkTestArmed: Bool = false
    @AppStorage("callmate.live_activity_resident_enabled") private var isResidentLiveActivityEnabled: Bool = false
    private let activeModeKey = "callmate_active_mode"
    private let hasCompletedOnboardingKey = "callmate_has_completed_onboarding"

    @MainActor
    init(appServices: AppServices? = nil, appRouter: AppRouter? = nil) {
        let resolvedServices = appServices ?? .preview
        self.appServices = resolvedServices
        let resolvedRouter = appRouter ?? AppRouter(services: resolvedServices)
        self.appRouter = resolvedRouter
        self.ble = resolvedServices.ble
        _contentBLEState = StateObject(wrappedValue: ContentViewBLEViewState(ble: resolvedServices.ble))
        _liveBLEController = ObservedObject(wrappedValue: resolvedServices.liveBLEController)
        _liveTranscriptRouter = ObservedObject(wrappedValue: resolvedServices.liveTranscriptNotificationRouter)
        _liveCallPresentation = ObservedObject(wrappedValue: resolvedRouter.liveCallPresentation)
    }

    var body: some View {
        containerWithCallCovers
    }

    // Stage 3: fullScreenCover + onOpenURL
    private var containerWithCallCovers: some View {
        containerWithObservers
            .fullScreenCover(isPresented: $showLocalTestCall) {
                localTestCoverContent
            }
            .fullScreenCover(isPresented: isShowingLiveCall) {
                liveCallCoverContent
            }
            .onOpenURL { url in
                appRouter.handleOpenURL(url)
            }
    }

    // Stage 2b: call-routing observers
    private var containerWithObservers: some View {
        containerWithAppObservers
            .onChange(of: contentBLEState.snapshot.lastIncomingCall) { _, newValue in
                guard let call = newValue, appState == .main else { return }
                guard isLocalUplinkTestArmed else { return }
                isLocalUplinkTestArmed = false
                UserDefaults.standard.set(true, forKey: "ble_local_uplink_test_in_progress")
                localTestCall = call
                showLocalTestCall = true
            }
            .onChange(of: liveBLEController.liveCallRequest) { _, newValue in
                liveCallPresentation.handleLiveCallRequest(newValue, appState: appState)
            }
            .onChange(of: liveTranscriptRouter.pendingShowLiveCall) { _, newValue in
                guard newValue else { return }
                liveCallPresentation.handlePendingShowLiveCall(appState: appState)
            }
    }

    // Stage 2a: app-lifecycle + BLE strategy observers
    private var containerWithAppObservers: some View {
        containerWithBLEObservers
            .onAppear {
                print("[ContentView] onAppear")
                guard hasAcceptedLegalDocs else { return }
                bootstrapAfterLegalConsent(reason: "content_on_appear")
                if appState == .main {
                    appServices.controlChannel.activate()
                }
            }
            .onChange(of: hasAcceptedLegalDocs) { _, newValue in
                guard newValue else { return }
                bootstrapAfterLegalConsent(reason: "legal_accepted")
            }
            .onChange(of: isResidentLiveActivityEnabled) { _, newValue in
                appServices.liveActivityManager.setResidentModeEnabled(newValue)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, hasAcceptedLegalDocs else { return }
                ble.ensureConnectionRecovered(reason: "scene_active")
                liveCallPresentation.syncForActiveScene(appState: appState)
            }
            .onChange(of: appState) { _, newValue in
                if newValue == .main {
                    appServices.controlChannel.activate()
                    liveCallPresentation.syncForActiveScene(appState: newValue)
                }
            }
    }

    // Stage 2: BLE state observers
    private var containerWithBLEObservers: some View {
        containerWithSheets
            .onChange(of: contentBLEState.snapshot.runtimeMCUDeviceID) { _, mcuDeviceId in
                // 控制通道上报 MCU device-id + APNs 注册；BLE 断开时停用。
                if mcuDeviceId == nil || mcuDeviceId?.isEmpty == true {
                    appServices.controlChannel.deactivate()
                } else if appState == .main {
                    appServices.controlChannel.activate()
                }
            }
            .onChange(of: contentBLEState.snapshot.deviceANCSEnabled) { _, enabled in
                guard AppFeatureFlags.ancsAuthorizationEnabled else { return }
                guard let enabled, !enabled else { return }
                let isBindingFlow = (appState == .bound || appState == .onboarding || appState == .main)
                if isBindingFlow { showANCSGuide = true }
            }
            .onChange(of: contentBLEState.snapshot.pendingDeviceStrategy) { _, strategy in
                // When reconnecting in the main view, silently discard the pending device
                // strategy — the binding-flow UI already handled the one-time choice.
                guard strategy != nil, appState == .main else { return }
                ble.clearPendingDeviceStrategy()
            }
    }

    // Stage 1: base container + sheets
    private var containerWithSheets: some View {
        mainContainer
            .preferredColorScheme(.light)
            .sheet(item: $showingLegalDocument) { document in
                LegalDocumentView(language: language, document: document)
            }
            .sheet(isPresented: $showANCSGuide) {
                ANCSPermissionGuideView(language: language, onDismiss: { showANCSGuide = false })
            }
    }
    
    private var mainContainer: some View {
        ZStack(alignment: .top) {
            AppColors.backgroundPage
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Group {
                    switch appState {
                    case .landing, .scanning, .bound:
                        BindingFlowView(state: appState, language: language) { newState in
                            withAnimation(.easeInOut(duration: 0.3)) {
                                appState = newState
                                if newState == .main {
                                    UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        ble.verifyANCSPermission()
                                    }
                                }
                            }
                        }
                    case .onboarding:
                        OnboardingView(language: language) {
                            // Push the final configured strategy to the device.
                            // Rule changes during the wizard already push incrementally via the
                            // strategy observer; this call is a safety-net for the case where
                            // the user exits the wizard without making any changes.
                            ble.pushLocalStrategyToDevice()
                            withAnimation(.easeInOut(duration: 0.3)) {
                                appState = .main
                                UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
                            }
                        }
                    case .main:
                        MainTabView(
                            language: language,
                            setLanguage: { newLang in
                                language = newLang
                                UserDefaults.standard.set(newLang.rawValue, forKey: "callmate.language")
                            },
                            onDisconnect: performDisconnect,
                            onFactoryReset: performFactoryReset,
                            onRebind: performRebind
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if appState == .main {
                    homeIndicator
                }
            }
            .ignoresSafeArea(edges: .bottom)

            if !hasAcceptedLegalDocs {
                LegalConsentOverlay(
                    language: language,
                    onConfirm: {
                        hasAcceptedLegalDocs = true
                    },
                    onExit: {
                        AppTermination.exitApplication()
                    },
                    onOpenUserAgreement: {
                        showingLegalDocument = .userAgreement
                    },
                    onOpenPrivacyPolicy: {
                        showingLegalDocument = .privacyPolicy
                    }
                )
                .zIndex(1)
                .transition(.opacity)
            }
        }
    }
    
    @ViewBuilder
    private var localTestCoverContent: some View {
        if let call = localTestCall {
            LocalPlaybackTestCallView(
                language: language,
                incomingCall: call,
                onClose: {
                    showLocalTestCall = false
                    localTestCall = nil
                    UserDefaults.standard.set(false, forKey: "ble_local_uplink_test_in_progress")
                },
                controller: localTestController
            )
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder
    private var liveCallCoverContent: some View {
        if let call = liveCallPresentation.presentedLiveCall {
            LiveCallView(
                language: language,
                incomingCall: call,
                controller: liveBLEController,
                liveTranscriptRouter: liveTranscriptRouter
            ) {
                liveCallPresentation.dismissLiveCall()
            }
        } else {
            EmptyView()
        }
    }

    private var isShowingLiveCall: Binding<Bool> {
        Binding(
            get: { liveCallPresentation.presentedLiveCall != nil },
            set: { shouldShow in
                if !shouldShow {
                    liveCallPresentation.dismissLiveCall()
                }
            }
        )
    }
    
    private var homeIndicator: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(AppColors.textTertiary)
            .frame(width: 128, height: 4)
            .padding(.bottom, 8)
    }

    private func performDisconnect() {
        // Disconnect only: keep local call history, chats, and user settings intact.
    }

    private func performRebind() {
        withAnimation(.easeInOut(duration: 0.3)) {
            appState = .scanning
        }
    }

    private func performFactoryReset() {
        UserDefaults.standard.removeObject(forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: "callmate.voiceId")
        UserDefaults.standard.removeObject(forKey: "callmate.voiceDisplayNameOverride")
        UserDefaults.standard.removeObject(forKey: "callmate.voiceTone")
        UserDefaults.standard.removeObject(forKey: "callmate.userManuallySelectedVoice")
        UserDefaults.standard.removeObject(forKey: "callmate.ai_secretary.persisted_messages.v1")
        UserDefaults.standard.removeObject(forKey: "callmate.ai_secretary.persisted_messages.v2")
        UserDefaults.standard.removeObject(forKey: "callmate.outbound.ai_create.persisted_messages.v2")
        UserDefaults.standard.removeObject(forKey: "callmate.userAppellation")
        UserDefaults.standard.removeObject(forKey: "callmate.ai_calls_total")
        UserDefaults.standard.removeObject(forKey: "callmate.hfp_pairing_needed")

        ProcessStrategyStore.resetToDefault()
        OutboundTaskStore.clearAll()

        try? AIChatHistoryService.deleteAllThreads(context: modelContext)

        for call in allCalls {
            UserDefaults.standard.removeObject(forKey: "callmate.call_detail.feedback.\(call.id.uuidString)")
            if let fileName = call.recordingFileName,
               let url = try? CallAudioStore.url(forFileName: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.delete(call)
        }
        try? modelContext.save()

        ble.clearSavedPeripheral()

        withAnimation(.easeInOut(duration: 0.3)) {
            appState = .landing
        }
    }
    
    /// Restore app state on launch if device was previously bound.
    private func restoreAppStateIfNeeded() {
        if AppAutomation.forceMainState {
            appState = .main
            print("[App] Automation restored to .main state")
            return
        }
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
        let hasSavedDevice = ble.hasSavedPeripheral
        let bleIsReady = ble.runtimeSnapshot.isReady
        
        print("[App] Restore check: onboarding=\(hasCompletedOnboarding), savedDevice=\(hasSavedDevice), bleReady=\(bleIsReady)")
        
        if hasCompletedOnboarding && hasSavedDevice {
            // 已完成引导且已绑定设备 -> 直接进首页
            appState = .main
            print("[App] Restored to .main state")
        } else if hasSavedDevice || bleIsReady {
            // Device was bound but onboarding not completed - skip to bound page
            // This handles: 1) App killed mid-onboarding, 2) willRestoreState connected before this check
            appState = .bound
            print("[App] Restored to .bound state (device bound, onboarding incomplete)")
        }
    }

    private func bootstrapAfterLegalConsent(reason: String) {
        appServices.liveActivityManager.setResidentModeEnabled(isResidentLiveActivityEnabled)
        restoreAppStateIfNeeded()
        AIChatHistoryService.migrateAllLegacyThreadsIfNeeded(context: modelContext)
        if AppAutomation.shouldSkipExternalBootstrap {
            print("[App] Automation bootstrap: skip external startup work")
            return
        }
        ble.autoConnectIfPossible()
        ble.ensureConnectionRecovered(reason: reason)
        let deviceId = ble.runtimeSnapshot.runtimeMCUDeviceID ?? "nil"
        let sessions = allCalls.compactMap { call -> String? in
            guard let sid = call.wsSessionId, !sid.isEmpty else { return nil }
            let ts = Self.sessionDateFormatter.string(from: call.startedAt)
            return "\(sid) @ \(ts)"
        }
        print("[Home] device_id=\(deviceId) sessions=\(sessions)")
        // Bootstrap HTTP auth on first app launch.
        // Flow: register (first install) -> get_token -> persist JWT.
        Task {
            let token = await appServices.backendAuth.bootstrap()
            if let token {
                print("[App] Auth bootstrap OK token prefix=\(String(token.prefix(12)))...")
            } else {
                print("[App] Auth bootstrap FAILED token=nil")
            }
        }
        liveCallPresentation.syncForActiveScene(appState: appState)
    }
}

#Preview {
    ContentView()
}

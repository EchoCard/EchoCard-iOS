//
//  SettingsView.swift
//  CallMate
//

import SwiftUI
import AVFoundation
import CoreBluetooth

struct SettingsView: View {
    let language: Language
    let setLanguage: (Language) -> Void
    let showBackButton: Bool
    let onBack: () -> Void
    let onDeviceManage: (() -> Void)?
    let onRebind: (() -> Void)?
    let onPromptRules: (() -> Void)?
    let onVoiceToneVisibilityChange: ((Bool) -> Void)?
    let onPromptRulesVisibilityChange: ((Bool) -> Void)?

    @ObservedObject private var ble = CallMateBLEClient.shared
    @StateObject private var viewModel = SettingsViewModel()
    @AppStorage("ble_local_uplink_test_armed") private var isLocalUplinkTestArmed: Bool = false
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }
    
    @AppStorage("callmate.pickup_delay") private var pickupDelay: Int = 5
    @AppStorage("callmate.ble_audio_codec") private var bleAudioCodec: String = "opus"
    @AppStorage("callmate.live_activity_resident_enabled") private var isResidentLiveActivityEnabled: Bool = false
    @AppStorage("callmate.mcu_silent_update_enabled") private var mcuSilentUpdateEnabled: Bool = true
    @State private var showPromptModal = false
    @State private var showAiChat = false
    @State private var showVoiceToneSheet = false
    @State private var showDeviceModal = false
    @State private var navigationRoute: SettingsRoute?

    @AppStorage("callmate.voiceTone") private var voiceToneRaw: String = VoiceTone.taiwan.rawValue
    @AppStorage("callmate.voiceId") private var voiceId: String = ""
    @AppStorage("callmate.voiceDisplayNameOverride") private var voiceDisplayNameOverride: String = ""

    private enum SettingsRoute: Hashable, Identifiable {
        case outboundContacts
        case outboundTemplates

        var id: Self { self }
    }

    init(
        language: Language,
        setLanguage: @escaping (Language) -> Void,
        showBackButton: Bool,
        onBack: @escaping () -> Void,
        onDeviceManage: (() -> Void)? = nil,
        onRebind: (() -> Void)? = nil,
        onPromptRules: (() -> Void)? = nil,
        onVoiceToneVisibilityChange: ((Bool) -> Void)? = nil,
        onPromptRulesVisibilityChange: ((Bool) -> Void)? = nil
    ) {
        self.language = language
        self.setLanguage = setLanguage
        self.showBackButton = showBackButton
        self.onBack = onBack
        self.onDeviceManage = onDeviceManage
        self.onRebind = onRebind
        self.onPromptRules = onPromptRules
        self.onVoiceToneVisibilityChange = onVoiceToneVisibilityChange
        self.onPromptRulesVisibilityChange = onPromptRulesVisibilityChange
    }
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    SettingsGeneralSectionView(
                        language: language,
                        setLanguage: setLanguage,
                        onDeviceTap: {
                            if let onDeviceManage {
                                onDeviceManage()
                            } else {
                                showDeviceModal = true
                            }
                        },
                        onVoiceToneTap: {
                            // Refuse to open the voice picker during an active call:
                            // changing voice kicks a ~70 KB preload over BLE that
                            // would steal bandwidth from the live conversation.
                            if CallMateBLEClient.shared.currentCallSID != nil {
                                print("[Settings] voice picker blocked: call in progress")
                                return
                            }
                            showVoiceToneSheet = true
                        },
                        deviceConnectionColor: viewModel.deviceConnectionColor(ble: ble),
                        deviceConnectionText: viewModel.deviceConnectionText(ble: ble, language: language),
                        currentVoiceLabel: currentVoiceLabel,
                        appVersionLabel: appVersionLabel,
                        pickupDelay: $pickupDelay,
                        isResidentLiveActivityEnabled: $isResidentLiveActivityEnabled,
                        mcuSilentUpdateEnabled: $mcuSilentUpdateEnabled
                    )
                    SettingsAIConfigSectionView(
                        language: language,
                        onPromptRulesTap: {
                            if let onPromptRules {
                                onPromptRules()
                            } else {
                                showPromptModal = true
                            }
                        },
                        onOutboundContactsTap: {
                            navigationRoute = .outboundContacts
                        },
                        onOutboundTemplatesTap: {
                            navigationRoute = .outboundTemplates
                        }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(t("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $navigationRoute) { route in
                switch route {
                case .outboundContacts:
                    OutboundContactsManagementView(language: language)
                case .outboundTemplates:
                    OutboundTemplateSettingsView(language: language)
                }
            }
            .toolbar {
                if showBackButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAiChat) {
            FeedbackChatModalView(
                language: language,
                feedbackType: "none",
                onClose: { showAiChat = false },
                initialMessages: nil,
                showInitialMessage: false,
                initMessagesOverride: [
                    ["role": "user", "content": "你好"],
                    ["role": "assistant", "content": "你好，我是你的专属AI分身。你可以直接告诉我需要查询的数据，或者想调整的接听策略。"]
                ]
            )
        }
        .overlay {
            if showPromptModal {
                PromptModalView(language: language, onClose: {
                    withAnimation(.easeInOut(duration: 0.25)) { showPromptModal = false }
                })
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showPromptModal = false }
                })
                .transition(.move(edge: .trailing))
                .zIndex(12)
            }

            if showVoiceToneSheet {
                VoiceToneSelectionSheet(
                    language: language,
                    voices: viewModel.voices,
                    selectedVoiceId: $voiceId,
                    selectedToneRaw: $voiceToneRaw,
                    selectedVoiceDisplayName: $voiceDisplayNameOverride,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showVoiceToneSheet = false }
                    }
                )
                .edgeSwipeBack(perform: {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { showVoiceToneSheet = false }
                })
                .transition(.move(edge: .trailing))
                .zIndex(11)
            }

            if showDeviceModal, onDeviceManage == nil {
                DeviceModalView(
                    language: language,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showDeviceModal = false }
                    },
                    onDisconnect: {
                        showDeviceModal = false
                        onBack()
                    },
                    onFactoryReset: {
                        showDeviceModal = false
                        onBack()
                    },
                    onRebind: onRebind.map { rebind in
                        {
                            showDeviceModal = false
                            rebind()
                        }
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
        .animation(.easeInOut(duration: 0.25), value: showVoiceToneSheet)
        .animation(.easeInOut(duration: 0.25), value: showDeviceModal)
        .animation(.easeInOut(duration: 0.25), value: showPromptModal)
        .toolbar((showVoiceToneSheet || showDeviceModal || showPromptModal) ? .hidden : .visible, for: .tabBar)
        .onChange(of: showVoiceToneSheet) { _, newValue in
            onVoiceToneVisibilityChange?(newValue)
        }
        .onChange(of: showPromptModal) { _, newValue in
            onPromptRulesVisibilityChange?(newValue)
        }
        .onDisappear {
            onVoiceToneVisibilityChange?(false)
            onPromptRulesVisibilityChange?(false)
        }
        .task {
            await fetchVoicesIfNeeded()
            await syncBoundCloneVoiceIfNeeded()
        }
        // Swipe-back handled by CallsView container when showBackButton is true
    }
    
    private var currentVoiceLabel: String {
        viewModel.currentVoiceLabel(
            language: language,
            voiceDisplayNameOverride: voiceDisplayNameOverride,
            voiceId: voiceId,
            voiceToneRaw: voiceToneRaw
        )
    }

    private var appVersionLabel: String {
        let shortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let buildNumber = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(shortVersion) (\(buildNumber))"
    }
    
    // MARK: - Voice Fetch

    private func fetchVoicesIfNeeded() async {
        if let defaultVoiceId = await viewModel.fetchVoicesIfNeeded(currentVoiceId: voiceId) {
            voiceId = defaultVoiceId
        }
    }

    private func syncBoundCloneVoiceIfNeeded() async {
        // Only auto-sync bound clone voice if the user has never manually chosen a voice.
        // Once the user explicitly selects any voice, respect that choice unconditionally.
        guard !UserDefaults.standard.bool(forKey: "callmate.userManuallySelectedVoice") else { return }
        if let selection = await viewModel.syncBoundCloneVoiceIfNeeded(wsDeviceId: ble.runtimeMCUDeviceID ?? "") {
            voiceId = selection.voiceId
            voiceDisplayNameOverride = selection.isCloneVoice ? t("我的声音", "My Voice") : ""
        }
    }

    private var floatingAiButton: some View {
        Button {
            showAiChat = true
        } label: {
            Image(systemName: "sparkles")
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(
                        colors: [AppColors.primary, AppColors.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .appShadow(AppShadow.lg)
        }
        .padding(AppSpacing.xl)
    }
}

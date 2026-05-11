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
    let onTest: () -> Void
    let onSimulationCalls: (() -> Void)?
    let onDeviceManage: (() -> Void)?
    let onRebind: (() -> Void)?
    let onDeleteAllLocalData: () -> Void
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
    @State private var showDeleteAllLocalDataConfirm = false

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
        onTest: @escaping () -> Void,
        onSimulationCalls: (() -> Void)? = nil,
        onDeviceManage: (() -> Void)? = nil,
        onRebind: (() -> Void)? = nil,
        onDeleteAllLocalData: @escaping () -> Void,
        onPromptRules: (() -> Void)? = nil,
        onVoiceToneVisibilityChange: ((Bool) -> Void)? = nil,
        onPromptRulesVisibilityChange: ((Bool) -> Void)? = nil
    ) {
        self.language = language
        self.setLanguage = setLanguage
        self.showBackButton = showBackButton
        self.onBack = onBack
        self.onTest = onTest
        self.onSimulationCalls = onSimulationCalls
        self.onDeviceManage = onDeviceManage
        self.onRebind = onRebind
        self.onDeleteAllLocalData = onDeleteAllLocalData
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
                    SettingsTestingSectionView(
                        language: language,
                        onTest: onTest,
                        onSimulationCalls: onSimulationCalls
                    )
                    deleteAllLocalDataSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(t("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                t("确认删除所有本地数据？", "Delete all local data?"),
                isPresented: $showDeleteAllLocalDataConfirm,
                titleVisibility: .visible
            ) {
                Button(t("删除", "Delete"), role: .destructive) {
                    onDeleteAllLocalData()
                }
                Button(t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(
                    t(
                        "将删除通话记录与录音、外呼任务、外呼名单与话术模板、AI 分身对话，并将接听策略恢复为默认。不会解绑设备。",
                        "Removes call logs and recordings, outbound tasks, contacts, templates, AI chat history, and resets call rules to defaults. Your device stays paired."
                    )
                )
            }
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
                onTest: nil,
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

    private var isCallActive: Bool {
        CallMateBLEClient.shared.currentCallSID != nil
    }

    private var deleteAllLocalDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("数据管理", "Data"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .textCase(.uppercase)
                .tracking(1.2)
                .padding(.leading, 16)

            Button {
                showDeleteAllLocalDataConfirm = true
            } label: {
                HStack {
                    HStack(spacing: 12) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color(hex: "FF3B30"))
                            .cornerRadius(8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("删除所有本地数据", "Delete All Local Data"))
                                .font(.system(size: 17))
                                .foregroundColor(AppColors.textPrimary)
                            Text(t("通话记录、外呼与 AI 对话等（通话中不可用）", "Call logs, outbound data, AI chats… (disabled during a call)"))
                                .font(.system(size: 13))
                                .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(lightHex: "D1D5DB", darkHex: "4B5563"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(isCallActive)
            .opacity(isCallActive ? 0.5 : 1)
        }
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

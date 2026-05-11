import SwiftUI

// MARK: - Header

struct SettingsHeaderView: View {
    let language: Language
    let showBackButton: Bool
    let onBack: () -> Void

    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var body: some View {
        HStack {
            if showBackButton {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer()

            Text(t("设置", "Settings"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - General Section

struct SettingsGeneralSectionView: View {
    let language: Language
    let setLanguage: (Language) -> Void
    let onDeviceTap: () -> Void
    let onVoiceToneTap: () -> Void
    let deviceConnectionColor: Color
    let deviceConnectionText: String
    let currentVoiceLabel: String
    let appVersionLabel: String
    @Binding var pickupDelay: Int
    @Binding var isResidentLiveActivityEnabled: Bool
    @Binding var mcuSilentUpdateEnabled: Bool

    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. 设备管理 — icon: radio (blue), chevron, clickable
            SettingRow(
                icon: "antenna.radiowaves.left.and.right",
                iconColor: Color(hex: "007AFF"),
                title: t("设备管理", "Device"),
                showChevron: true,
                action: onDeviceTap
            ) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(deviceConnectionColor)
                        .frame(width: 6, height: 6)
                    Text(deviceConnectionText)
                        .font(.system(size: 15))
                        .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                }
            }

            // 2. 界面语言 — icon: globe (purple #5856D6), pill toggle
            SettingRow(
                icon: "globe",
                iconColor: Color(hex: "5856D6"),
                title: t("界面语言", "Language")
            ) {
                LanguagePillToggle(
                    language: language,
                    setLanguage: setLanguage
                )
            }

            // 3. AI 音色 — icon: audio-lines (purple #5856D6), chevron, clickable
            SettingRow(
                icon: "waveform",
                iconColor: Color(hex: "5856D6"),
                title: t("AI 音色", "Voice"),
                showChevron: true,
                action: onVoiceToneTap
            ) {
                Text(currentVoiceLabel)
                    .font(.system(size: 15))
                    .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            }

            // 4. 响铃延迟 — icon: clock (blue), stepper
            SettingRow(
                icon: "clock",
                iconColor: Color(hex: "007AFF"),
                title: t("响铃延迟", "Pickup Delay"),
                titleLineLimit: 1,
                titleMinimumScaleFactor: 0.85
            ) {
                HStack(spacing: 12) {
                    Button {
                        pickupDelay = max(1, pickupDelay - 1)
                    } label: {
                        Text("\u{2212}")
                            .font(.system(size: 18))
                            .foregroundColor(Color(hex: "007AFF"))
                            .frame(width: 28, height: 28)
                            .background(Color(hex: "007AFF").opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Text("\(pickupDelay)s")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                        .frame(width: 20, alignment: .center)

                    Button {
                        pickupDelay = min(60, pickupDelay + 1)
                    } label: {
                        Text("+")
                            .font(.system(size: 18))
                            .foregroundColor(Color(hex: "007AFF"))
                            .frame(width: 28, height: 28)
                            .background(Color(hex: "007AFF").opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // 5. 待机时显示灵动岛 — icon: cast (blue), toggle
            SettingRow(
                icon: "airplayvideo",
                iconColor: Color(hex: "007AFF"),
                title: t("待机时显示灵动岛", "Show Dynamic Island in Standby")
            ) {
                Toggle("", isOn: $isResidentLiveActivityEnabled)
                    .labelsHidden()
                    .onChange(of: isResidentLiveActivityEnabled) { _, newValue in
                        CallLiveActivityManager.shared.setResidentModeEnabled(newValue)
                    }
            }

            // 6. MCU 静默升级 — icon: circle-arrow-down (blue), toggle
            SettingRow(
                icon: "arrow.down.circle",
                iconColor: Color(hex: "007AFF"),
                title: t("MCU 静默升级", "MCU Silent Update")
            ) {
                Toggle("", isOn: $mcuSilentUpdateEnabled)
                    .labelsHidden()
            }

            // 7. 版本号 — icon: info (gray-400), version text
            SettingRow(
                icon: "info.circle",
                iconColor: Color(lightHex: "9CA3AF", darkHex: "6B7280"),
                title: t("版本号", "Version")
            ) {
                Text(appVersionLabel)
                    .font(.system(size: 15))
                    .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            }
        }
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

// MARK: - AI Config Section

struct SettingsAIConfigSectionView: View {
    let language: Language
    let onPromptRulesTap: () -> Void
    let onOutboundTemplatesTap: () -> Void

    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("AI 配置", "AI Settings"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .textCase(.uppercase)
                .tracking(1.2)
                .padding(.leading, 16)

            VStack(spacing: 12) {
                aiConfigRow(
                    icon: "doc.text",
                    iconColor: Color(hex: "007AFF"),
                    title: t("接听规则", "Call Rules"),
                    subtitle: t("查看完整的 AI 指令", "View full AI instructions"),
                    action: onPromptRulesTap
                )

                aiConfigRow(
                    icon: "text.quote",
                    iconColor: AppColors.warning,
                    title: t("话术配置", "Prompt Config"),
                    subtitle: t("管理 AI 打电话话术模板", "Manage AI calling prompt templates"),
                    action: onOutboundTemplatesTap
                )
            }
        }
    }

    private func aiConfigRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(iconColor)
                        .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 17))
                            .foregroundColor(AppColors.textPrimary)
                        Text(subtitle)
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
    }
}

// MARK: - Testing Section

struct SettingsTestingSectionView: View {
    let language: Language
    let onTest: () -> Void
    let onSimulationCalls: (() -> Void)?

    private func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("测试工具", "Testing"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .textCase(.uppercase)
                .tracking(1.2)
                .padding(.leading, 16)

            VStack(spacing: 12) {
                Button(action: onTest) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18))
                        Text(t("模拟陌生来电", "Simulate Call"))
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "007AFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                }
                .buttonStyle(.plain)

                if let onSimulationCalls {
                    Button(action: onSimulationCalls) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16))
                            Text(t("模拟测试通话记录", "Simulation Call History"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

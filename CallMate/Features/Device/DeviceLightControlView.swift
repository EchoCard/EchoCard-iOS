//
//  DeviceLightControlView.swift
//  CallMate
//

import SwiftUI

struct DeviceLightControlView: View {
    let language: Language

    @ObservedObject private var ble = CallMateBLEClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var indicatorEnabled = true
    @State private var brightness: Double = 48
    @State private var isDraggingBrightness = false
    @State private var selectedColor: String = "off"
    @State private var pa20High = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var roundedBrightness: Int {
        Int(brightness.rounded())
    }

    private func syncFromDevice() {
        if let enabled = ble.deviceLEDEnabled {
            indicatorEnabled = enabled
        }
        if let currentBrightness = ble.deviceLEDBrightness {
            brightness = Double(currentBrightness)
        }
        if let levelHigh = ble.devicePA20LevelHigh {
            pa20High = levelHigh
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // MARK: - Toggle Section
                    VStack(spacing: 0) {
                        toggleRow(
                            icon: "lightbulb.fill",
                            iconColor: Color(hex: "FF9500"),
                            title: t("指示灯开关", "Indicator Light"),
                            subtitle: t("关闭后设备状态灯将保持熄灭", "When disabled, the status light stays off"),
                            isOn: Binding(
                                get: { indicatorEnabled },
                                set: { newValue in
                                    indicatorEnabled = newValue
                                    ble.setIndicatorLight(enabled: newValue)
                                }
                            ),
                            disabled: !ble.isCtrlReady
                        )

                        cardDivider

                        toggleRow(
                            icon: "bolt.fill",
                            iconColor: Color(hex: "007AFF"),
                            title: t("PA20 输出", "PA20 Output"),
                            subtitle: t("开启为高电平，关闭为低电平", "On = HIGH, Off = LOW"),
                            isOn: Binding(
                                get: { pa20High },
                                set: { newValue in
                                    pa20High = newValue
                                    ble.setPA20Level(high: newValue)
                                }
                            ),
                            disabled: !ble.isCtrlReady
                        )
                    }
                    .background(AppColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                    // MARK: - Brightness Section
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("亮度", "Brightness"))

                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                HStack(spacing: 12) {
                                    Image(systemName: "sun.max.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Color(hex: "FF9500"))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Text(t("当前亮度", "Current Brightness"))
                                        .font(.system(size: 17))
                                        .foregroundStyle(AppColors.textPrimary)
                                }

                                Spacer()

                                Text("\(roundedBrightness)")
                                    .font(.system(size: 15, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Color(hex: "007AFF"))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: "007AFF").opacity(0.1))
                                    .clipShape(Capsule())
                            }

                            Slider(
                                value: $brightness,
                                in: 0...255,
                                step: 1,
                                onEditingChanged: { editing in
                                    isDraggingBrightness = editing
                                    guard !editing else { return }
                                    ble.setIndicatorLight(brightness: roundedBrightness)
                                }
                            )
                            .tint(Color(hex: "007AFF"))
                            .disabled(!ble.isCtrlReady || !indicatorEnabled)

                            Text(t("范围 0-255，数值越大越亮", "Range 0-255. Higher values mean brighter light"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        }
                        .padding(16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - Color Section
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(t("颜色", "Color"))

                        HStack(spacing: 0) {
                            colorButton(title: t("红", "Red"), fill: Color(hex: "FF3B30"), value: "red")
                            colorButton(title: t("绿", "Green"), fill: Color(hex: "34C759"), value: "green")
                            colorButton(title: t("蓝", "Blue"), fill: Color(hex: "007AFF"), value: "blue")
                        }
                        .padding(.vertical, 16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }

                    // MARK: - Restore Default
                    Button {
                        ble.resetIndicatorLightToDefault()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .semibold))
                            Text(t("恢复默认灯配置", "Restore Default Light Settings"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: "007AFF"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ble.isCtrlReady)
                    .opacity(ble.isCtrlReady ? 1 : 0.5)

                    // MARK: - Disconnected Warning
                    if !ble.isCtrlReady {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "FF9500"))
                            Text(t("设备未连接，暂时无法修改指示灯设置。", "Device is not connected, indicator settings cannot be changed right now."))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "FF9500").opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(t("灯光控制", "Light Control"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("关闭", "Close")) { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(Color(hex: "007AFF"))
                }
            }
        }
        .onAppear {
            syncFromDevice()
            if ble.isCtrlReady {
                ble.requestDeviceInfo()
            }
        }
        .onChange(of: ble.deviceLEDEnabled) { _, _ in
            syncFromDevice()
        }
        .onChange(of: ble.deviceLEDBrightness) { _, _ in
            guard !isDraggingBrightness else { return }
            syncFromDevice()
        }
        .onChange(of: ble.devicePA20LevelHigh) { _, _ in
            syncFromDevice()
        }
        .onChange(of: ble.isCtrlReady) { _, ready in
            guard ready else { return }
            ble.requestDeviceInfo()
        }
        .edgeSwipeBack(
            background: AppColors.backgroundSecondary.ignoresSafeArea(),
            perform: { dismiss() }
        )
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            .textCase(.uppercase)
            .tracking(1.2)
            .padding(.leading, 16)
            .padding(.bottom, 8)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    private func toggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        disabled: Bool
    ) -> some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(disabled ? 0.5 : 1)
    }

    private func colorButton(title: String, fill: Color, value: String) -> some View {
        Button {
            selectedColor = value
            ble.setIndicatorColor(value)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .frame(width: 44, height: 44)

                    if selectedColor == value {
                        Circle()
                            .stroke(Color(hex: "007AFF"), lineWidth: 3)
                            .frame(width: 50, height: 50)
                    }
                }

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(selectedColor == value ? Color(hex: "007AFF") : Color(lightHex: "6B7280", darkHex: "9CA3AF"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!ble.isCtrlReady || !indicatorEnabled)
        .opacity(!ble.isCtrlReady || !indicatorEnabled ? 0.5 : 1)
    }
}

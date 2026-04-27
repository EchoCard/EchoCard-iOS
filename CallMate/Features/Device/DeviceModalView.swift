//
//  DeviceModalView.swift
//  CallMate
//

import SwiftUI
import CoreBluetooth
import Network
import Combine
import UIKit

struct DeviceModalView: View {
    let language: Language
    let onClose: () -> Void
    let onDisconnect: () -> Void
    let onFactoryReset: () -> Void
    /// When non-nil, show "重新绑定" button; on confirm rebind: disconnect + clear saved peripheral + call this (e.g. navigate to binding page).
    var onRebind: (() -> Void)? = nil
    
    private let ble = CallMateBLEClient.shared
    @StateObject private var bleState = DeviceModalBLEViewState()
    @StateObject private var fw = FirmwareUpdateService.shared
    @StateObject private var perms = PermissionsCenter.shared
    @AppStorage("callmate.ai_calls_total") private var aiCallsTotal: Int = 0
    @State private var showRebootConfirm = false
    @State private var showRebindConfirm = false
    @State private var showFactoryResetConfirm = false
    @State private var factoryResetCheckboxChecked = false
    @State private var showFactoryResetCheckboxToast = false
    @State private var factoryResetCheckboxToastWorkItem: DispatchWorkItem?
    @State private var isRebootingDevice = false
    @State private var isFactoryResetting = false
    @State private var factoryResetStatusText: String?
    @State private var rebootStatusText: String?
    @State private var waitingForRebootReconnect = false
    @State private var isManualReconnectInFlight = false
    @State private var showDeviceDiagnostics = false
    @State private var showDeviceLightControl = false
    @State private var showDesktopQRScan = false
    @ObservedObject private var desktopLink = DesktopLinkService.shared
    @State private var deviceInfoPollTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    /// Poll interval for device info (battery, etc.) while device management page is visible.
    private static let deviceInfoPollIntervalSeconds: UInt64 = 5
    
    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var bleSnapshot: DeviceModalBLEViewSnapshot {
        bleState.snapshot
    }

    private func handleDisconnect() {
        ble.disconnect(userInitiated: true)
        onDisconnect()
    }

    /// Same as disconnect (BLE disconnect), then clear saved peripheral so binding flow can scan again, then call onRebind (e.g. navigate to binding page).
    private func handleRebind() {
        ble.disconnect(userInitiated: true)
        ble.clearSavedPeripheral()
        onRebind?()
    }

    private func requestFactoryReset() {
        guard ble.isCtrlReady else {
            factoryResetStatusText = t(
                "设备未连接，无法发送恢复出厂指令。",
                "Device is not connected. Unable to send factory reset."
            )
            return
        }
        showFactoryResetConfirm = false
        factoryResetCheckboxChecked = false
        factoryResetStatusText = t("正在发送恢复出厂指令...", "Sending factory reset command...")
        isFactoryResetting = true
        ble.sendCommand("factory_reset")
    }

    private var factoryResetConfirmSheet: some View {
        ZStack {
            VStack(spacing: 0) {
                // Icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color(hex: "FF3B30"))
                    .padding(.top, 32)
                    .padding(.bottom, 16)

                // Title
                Text(t("恢复出厂设置", "Factory Reset"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.bottom, 12)

                // Description
                Text(t(
                    "EchoCard 将会抹去 APP 和硬件上的所有数据，通话记录、AI 应答策略、克隆声音和相关设置均会清空，同时该手机也不再是关联主机。",
                    "EchoCard will erase all data on the app and device: call history, AI response strategies, cloned voice and related settings will be cleared, and this phone will no longer be the linked host."
                ))
                .font(.system(size: 15))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                // Checkbox
                Button {
                    factoryResetCheckboxChecked.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: factoryResetCheckboxChecked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 22))
                            .foregroundStyle(factoryResetCheckboxChecked ? Color(hex: "FF3B30") : AppColors.textTertiary)
                        Text(t("我已了解此操作会清空数据！", "I understand this will clear all data!"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)

                // Buttons
                HStack(spacing: 12) {
                    Button {
                        showFactoryResetConfirm = false
                        factoryResetCheckboxChecked = false
                    } label: {
                        Text(t("取消", "Cancel"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(lightHex: "F2F2F7", darkHex: "2C2C2E"))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if factoryResetCheckboxChecked {
                            requestFactoryReset()
                        } else {
                            factoryResetCheckboxToastWorkItem?.cancel()
                            showFactoryResetCheckboxToast = true
                            let work = DispatchWorkItem { withAnimation { showFactoryResetCheckboxToast = false } }
                            factoryResetCheckboxToastWorkItem = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
                        }
                    } label: {
                        Text(t("确认重置", "Confirm Reset"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(factoryResetCheckboxChecked ? Color(hex: "FF3B30") : AppColors.textTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)

            if showFactoryResetCheckboxToast {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        Text(t("请先勾选「我已了解此操作会清空数据！」", "Please check \"I understand this will clear all data!\" first."))
                            .font(.system(size: 15, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(16)
                            .frame(maxWidth: 280)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            factoryResetCheckboxChecked = false
        }
    }

    private var rebootConfirmSheet: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color(hex: "FF9500"))
                .frame(width: 72, height: 72)
                .background(Color(hex: "FF9500").opacity(0.12))
                .clipShape(Circle())
                .padding(.top, 32)
                .padding(.bottom, 16)

            Text(t("重启设备", "Reboot Device"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.bottom, 8)

            Text(t("设备将立即重启，约 5-10 秒后恢复连接。", "Device will reboot immediately and reconnect in about 5-10 seconds."))
                .font(.system(size: 15))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

            HStack(spacing: 12) {
                Button {
                    showRebootConfirm = false
                } label: {
                    Text(t("取消", "Cancel"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(lightHex: "F2F2F7", darkHex: "2C2C2E"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)

                Button {
                    showRebootConfirm = false
                    rebootStatusText = t("正在发送重启指令...", "Sending reboot command...")
                    isRebootingDevice = true
                    waitingForRebootReconnect = true
                    ble.sendCommand("reboot")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if isRebootingDevice {
                            rebootStatusText = t("重启进行中，请等待设备重新连接。", "Reboot in progress. Please wait for reconnect.")
                            isRebootingDevice = false
                            waitingForRebootReconnect = true
                        }
                    }
                } label: {
                    Text(t("确认重启", "Confirm Reboot"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "FF9500"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    private var rebindConfirmSheet: some View {
        VStack(spacing: 0) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color(hex: "5856D6"))
                .frame(width: 72, height: 72)
                .background(Color(hex: "5856D6").opacity(0.12))
                .clipShape(Circle())
                .padding(.top, 32)
                .padding(.bottom, 16)

            Text(t("重新绑定", "Rebind Device"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.bottom, 8)

            Text(t("将断开当前设备并进入绑定页面，可重新扫描并连接设备。", "This will disconnect the current device and open the binding page to scan and connect again."))
                .font(.system(size: 15))
                .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

            HStack(spacing: 12) {
                Button {
                    showRebindConfirm = false
                } label: {
                    Text(t("取消", "Cancel"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(lightHex: "F2F2F7", darkHex: "2C2C2E"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)

                Button {
                    showRebindConfirm = false
                    handleRebind()
                } label: {
                    Text(t("确认绑定", "Confirm Rebind"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "5856D6"))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    private var connectionStatus: (text: String, color: Color) {
        // Prefer real link state over central manager transient state.
        if bleSnapshot.isCtrlReady {
            return (t("已连接", "Connected"), AppColors.success)
        }
        if bleSnapshot.connectingPeripheralID != nil || bleSnapshot.connectedPeripheralID != nil {
            return (t("连接中", "Connecting"), AppColors.warning)
        }

        if bleSnapshot.bluetoothState == .poweredOff {
            return (t("蓝牙未开启", "Bluetooth Off"), .gray)
        }
        if bleSnapshot.bluetoothState == .unauthorized {
            return (t("蓝牙权限未授权", "Bluetooth Unauthorized"), .gray)
        }
        if bleSnapshot.bluetoothState == .unsupported {
            // Avoid alarming false-positive wording in production devices.
            return (t("未连接", "Disconnected"), .gray)
        }
        if bleSnapshot.bluetoothState == .resetting {
            return (t("蓝牙重置中", "Bluetooth Resetting"), AppColors.warning)
        }
        if bleSnapshot.bluetoothState == .unknown {
            return (t("未连接", "Disconnected"), .gray)
        }
        return (t("未连接", "Disconnected"), .gray)
    }
    
    @ViewBuilder
    private var desktopLinkCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20))
                    .foregroundStyle(AppColors.primary)
                    .frame(width: 40, height: 40)
                    .background(AppColors.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("桌面端", "Desktop"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(desktopLink.status == .connected ? AppColors.success : Color.gray.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(desktopStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                    }
                }
                
                Spacer()
                
                if desktopLink.status == .connected {
                    Button {
                        desktopLink.disconnect()
                    } label: {
                        Text(t("断开", "Disconnect"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.error)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AppColors.error.opacity(0.12))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showDesktopQRScan = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 14))
                            Text(t("扫码登录", "Scan to Login"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AppColors.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppColors.primary.opacity(0.12))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            
            if desktopLink.status == .connected, !desktopLink.desktopIP.isEmpty {
                Divider()
                    .padding(.horizontal, 20)
                
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("\(desktopLink.desktopIP):\(desktopLink.desktopPort)")
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                    Spacer()
                    Text(t("局域网直连", "LAN Direct"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppColors.success.opacity(0.12))
                        .cornerRadius(6)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(AppColors.surface)
        .cornerRadius(AppRadius.xl)
        .appShadow(AppShadow.sm)
        .sheet(isPresented: $showDesktopQRScan) {
            DesktopQRScanView()
        }
    }
    
    private var desktopStatusText: String {
        switch desktopLink.status {
        case .disconnected: return t("未连接", "Disconnected")
        case .connecting: return t("连接中...", "Connecting...")
        case .connected: return t("已连接", "Connected")
        case .failed(let msg): return t("连接失败", "Failed") + ": \(msg)"
        }
    }
    
    private var deviceIdSuffix: String {
        let id = bleSnapshot.connectedPeripheralID?.uuidString ?? ""
        if id.isEmpty { return "--" }
        return String(id.suffix(8))
    }
    
    private var deviceNameText: String {
        bleSnapshot.connectedDeviceName ?? t("未命名设备", "Unnamed Device")
    }
    
    private var bleBondText: String {
        bleSnapshot.deviceBLEBondState ?? "--"
    }

    private var hfpStateText: String {
        bleSnapshot.deviceHFPState ?? "--"
    }

    private var firmwareVersionText: String {
        bleSnapshot.deviceFirmwareVersion ?? "--"
    }

    private func isUpdateAvailable(current: String?, latest: String?) -> Bool {
        guard let current, let latest else { return false }
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
    
    private var shouldShowDownloadStage: Bool {
        fw.isUpdating || fw.updateStage != .idle
    }

    private var shouldShowUpgradeStage: Bool {
        fw.updateStage == .upgrading || fw.updateStage == .rebooting
    }

    private var internshipRocketSymbolName: String {
        if UIImage(systemName: "rocket.fill") != nil { return "rocket.fill" }
        return "paperplane.fill"
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    EchoCardPermissionsCard(language: language)
                    
                    // 设备信息卡片
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 32))
                            .frame(width: 60, height: 60)
                            .background(AppColors.primary)
                            .foregroundStyle(.white)
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(deviceNameText)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(connectionStatus.color)
                                    .frame(width: 8, height: 8)
                                Text(connectionStatus.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                                if bleSnapshot.isCtrlReady, let level = bleSnapshot.deviceBattery {
                                    DeviceBatteryView(level: level, isCharging: bleSnapshot.deviceCharging ?? false)
                                }
                            }
                            .padding(.top, 6)
                            .padding(.bottom, 4)
                            Text("ID: \(deviceIdSuffix) · BLE: \(bleBondText)")
                                .font(.system(size: 12).monospaced())
                                .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .overlay(alignment: .topTrailing) {
                        if bleSnapshot.isCtrlReady {
                            Button(action: handleDisconnect) {
                                Text(t("断开", "Disconnect"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.error)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(AppColors.error.opacity(0.12))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isFactoryResetting)
                            .padding(20)
                        } else if bleSnapshot.connectedPeripheralID == nil && bleSnapshot.bluetoothState == .poweredOn {
                            Button {
                                isManualReconnectInFlight = true
                                ble.forceReconnect()
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                                    if !ble.isCtrlReady {
                                        ble.forceReconnect()
                                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                                    }
                                    if !ble.isCtrlReady {
                                        isManualReconnectInFlight = false
                                    }
                                }
                            } label: {
                                Text(isManualReconnectInFlight ? t("连接中...", "Connecting...") : t("连接", "Connect"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(AppColors.primary.opacity(0.12))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(bleSnapshot.connectingPeripheralID != nil)
                            .padding(20)
                        }
                    }
                    .background(AppColors.surface)
                    .cornerRadius(AppRadius.xl)
                    .appShadow(AppShadow.sm)

                    // 桌面端连接
                    desktopLinkCard

                    // 固件信息 — newui: 24pt 圆角 p5 shadow-sm，标题行 Info 18 + 固件信息 16pt semibold，右侧刷新/升级，版本行 13pt 标签 + 24pt bold 数值
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(AppColors.primary)
                            Text(t("固件信息", "Firmware Info"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            let canUpgrade = isUpdateAvailable(current: bleSnapshot.deviceFirmwareVersion, latest: fw.latestMetadata?.version)
                            if canUpgrade {
                                Button {
                                    Task { await fw.startUpdateIfAvailable() }
                                } label: {
                                    Text(t("升级", "Upgrade"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, AppSpacing.md)
                                        .padding(.vertical, AppSpacing.xs)
                                        .background(AppColors.primary)
                                        .cornerRadius(AppRadius.sm)
                                }
                                .buttonStyle(.plain)
                                .disabled(fw.isUpdating || fw.isChecking)
                            } else {
                                Button {
                                    Task {
                                        await fw.checkForUpdate()
                                        if isUpdateAvailable(current: bleSnapshot.deviceFirmwareVersion, latest: fw.latestMetadata?.version) {
                                            await fw.startUpdateIfAvailable()
                                        }
                                    }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(AppColors.primary)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .disabled(fw.isChecking)
                            }
                        }
                        .padding(.bottom, 12)

                        HStack(alignment: .bottom, spacing: 0) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("当前版本", "Current"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppColors.textSecondary)
                                Text(firmwareVersionText)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(AppColors.textPrimary)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(t("最新版本", "Latest"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppColors.textSecondary)
                                Text(fw.latestMetadata?.version ?? "--")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(AppColors.textPrimary)
                            }
                        }

                        if shouldShowDownloadStage {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                HStack {
                                    Text(t("1/2 下载固件", "1/2 Download Firmware"))
                                        .font(AppTypography.footnote)
                                        .foregroundStyle(AppColors.textSecondary)
                                    Spacer()
                                    Text("\(Int(fw.downloadProgress * 100))%")
                                        .font(AppTypography.footnote)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                ProgressView(value: fw.downloadProgress)
                                    .progressViewStyle(.linear)
                                    .tint(AppColors.primary)
                            }
                            .padding(.top, AppSpacing.md)
                        }
                        if shouldShowUpgradeStage {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                HStack {
                                    Text(t("2/2 发送并安装", "2/2 Send & Install"))
                                        .font(AppTypography.footnote)
                                        .foregroundStyle(AppColors.textSecondary)
                                    Spacer()
                                    Text("\(Int(fw.upgradeProgress * 100))%")
                                        .font(AppTypography.footnote)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                ProgressView(value: fw.upgradeProgress)
                                    .progressViewStyle(.linear)
                                    .tint(AppColors.primary)
                                if !fw.statusText.isEmpty {
                                    if fw.updateStage == .rebooting || fw.transferSpeedKBps <= 0 {
                                        Text(fw.statusText)
                                            .font(AppTypography.footnote)
                                            .foregroundStyle(AppColors.textSecondary)
                                    } else {
                                        Text("\(fw.statusText) · \(String(format: t("速度：%.1f KB/s", "Speed: %.1f KB/s"), fw.transferSpeedKBps))")
                                            .font(AppTypography.footnote)
                                            .foregroundStyle(AppColors.textSecondary)
                                    }
                                }
                            }
                            .padding(.top, AppSpacing.md)
                        } else if !fw.statusText.isEmpty {
                            Text(fw.statusText)
                                .font(AppTypography.footnote)
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.top, AppSpacing.xs)
                        }
                        if let rebootStatusText {
                            Text(rebootStatusText)
                                .font(AppTypography.footnote)
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.top, AppSpacing.xs)
                        }
                        if let err = fw.lastError {
                            Text(err)
                                .font(AppTypography.footnote)
                                .foregroundStyle(AppColors.error)
                                .padding(.top, AppSpacing.xs)
                        }
                    }
                    .padding(AppSpacing.lg)
                    .background(AppColors.surface)
                    .cornerRadius(AppRadius.xl)
                    .appShadow(AppShadow.sm)

                    // 实习期进度卡片 (newui 顺序: 3，与 newui 卡片一致)
                    let callsGoal = 100
                    let totalCalls = max(0, aiCallsTotal)
                    let callsProgress = min(Double(totalCalls) / Double(callsGoal), 1.0)
                    let reportsGoal = 3
                    let reportsDone = min(totalCalls / 30, reportsGoal)
                    let reportsProgress = min(Double(reportsDone) / Double(reportsGoal), 1.0)
                    let internshipAccent = AppColors.accent
                    let internshipAccentBg = AppColors.accent.opacity(0.15)
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(spacing: 10) {
                                Image(systemName: internshipRocketSymbolName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .symbolRenderingMode(.monochrome)
                                .foregroundStyle(internshipAccent)
                                .frame(width: 32, height: 32)
                                .background(internshipAccentBg)
                                .clipShape(Circle())
                                Text(t("实习期转正", "Internship"))
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                Text(t("进行中", "Active"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(internshipAccent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(internshipAccentBg)
                                    .clipShape(Capsule())
                            }
                            VStack(alignment: .leading, spacing: 20) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(t("累计代接电话", "Total Calls"))
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color(lightHex: "374151", darkHex: "D1D5DB"))
                                        Spacer()
                                        Text("\(totalCalls) ")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(internshipAccent)
                                        + Text("\(t("/ \(callsGoal) 次", "/ \(callsGoal)"))")
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                                    }
                                    GeometryReader { g in
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(lightHex: "F3F4F6", darkHex: "1F2937"))
                                            .frame(height: 8)
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(internshipAccent)
                                                    .frame(width: max(0, g.size.width * callsProgress), height: 8)
                                            }
                                    }
                                    .frame(height: 8)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(t("工作汇报", "Reports"))
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color(lightHex: "374151", darkHex: "D1D5DB"))
                                        Spacer()
                                        Text("\(reportsDone) ")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(internshipAccent)
                                        + Text("\(t("/ \(reportsGoal) 份", "/ \(reportsGoal)"))")
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                                    }
                                    GeometryReader { g in
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(lightHex: "F3F4F6", darkHex: "1F2937"))
                                            .frame(height: 8)
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(internshipAccent)
                                                    .frame(width: max(0, g.size.width * reportsProgress), height: 8)
                                            }
                                    }
                                    .frame(height: 8)
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.backgroundCard)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [internshipAccent.opacity(0.1), Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 128, height: 128)
                            .clipShape(UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(bottomLeading: 128)))
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))

                    // 高级订阅 (newui 顺序: 4，与 newui 卡片一致)
                    HStack(spacing: 14) {
                        Image(systemName: "crown")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppColors.warning)
                            .frame(width: 40, height: 40)
                            .background(colorScheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.6))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("高级订阅", "Premium"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(colorScheme == .dark ? Color(hex: "FFD699") : Color(hex: "8C5000"))
                            Text(t("转正后解锁专属特权", "Unlock exclusive benefits after graduation"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle((colorScheme == .dark ? Color(hex: "FFD699") : Color(hex: "8C5000")).opacity(0.6))
                        }
                        Spacer()
                        Text(t("即将推出", "Coming"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(colorScheme == .dark ? Color(hex: "FFD699") : Color(hex: "8C5000"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(colorScheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.5))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
                            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
                    }
                    .padding(20)
                    .background(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color(hex: "2A241C"), Color(hex: "362815")]
                                : [Color(hex: "FFF9F0"), Color(hex: "FFF0D9")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.xl)
                            .stroke(AppColors.warning.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                    // 高级设置 (newui 顺序: 5，收拢至最底部)
                    NavigationLink {
                        DeviceAdvancedSettingsView(
                            language: language,
                            showRebootConfirm: $showRebootConfirm,
                            showDeviceLightControl: $showDeviceLightControl,
                            showDeviceDiagnostics: $showDeviceDiagnostics,
                            showFactoryResetConfirm: $showFactoryResetConfirm,
                            showRebindConfirm: $showRebindConfirm,
                            hasRebind: onRebind != nil,
                            isRebootingDevice: isRebootingDevice,
                            isFactoryResetting: isFactoryResetting,
                            isCtrlReady: bleSnapshot.isCtrlReady,
                            isReady: bleSnapshot.isReady,
                            fwIsUpdating: fw.isUpdating,
                            rebootStatusText: $rebootStatusText,
                            factoryResetStatusText: $factoryResetStatusText
                        )
                    } label: {
                        HStack {
                            HStack(spacing: 12) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(AppColors.primary)
                                    .cornerRadius(8)
                                Text(t("高级设置", "Advanced Settings"))
                                    .font(.system(size: 17))
                                    .foregroundStyle(AppColors.textPrimary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color(lightHex: "D1D5DB", darkHex: "4B5563"))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(AppColors.surface)
                        .cornerRadius(AppRadius.xl)
                        .appShadow(AppShadow.sm)
                    }
                    .buttonStyle(.plain)

                }
                .padding(DS.Spacing.x2)
                .padding(.bottom, DS.Spacing.x6 * 2)
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(t("设备管理", "Device"))
            .accessibilityIdentifier("device-modal-root")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .accessibilityIdentifier("device-modal-close-button")
                }
            }
        }
        .onAppear {
            if ble.isCtrlReady { ble.requestDeviceInfo() }
            deviceInfoPollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.deviceInfoPollIntervalSeconds * 1_000_000_000)
                    if Task.isCancelled { break }
                    if ble.isCtrlReady { ble.requestDeviceInfo() }
                }
            }
        }
        .onDisappear {
            deviceInfoPollTask?.cancel()
            deviceInfoPollTask = nil
        }
        .sheet(isPresented: $showRebindConfirm) {
            rebindConfirmSheet
        }
        .sheet(isPresented: $showFactoryResetConfirm) {
            factoryResetConfirmSheet
        }
        .sheet(isPresented: $showRebootConfirm) {
            rebootConfirmSheet
        }
        .sheet(isPresented: $showDeviceDiagnostics) {
            DeviceDiagnosticsView(language: language)
        }
        .sheet(isPresented: $showDeviceLightControl) {
            DeviceLightControlView(language: language)
        }
        .onReceive(ble.events) { evt in
            guard case let .ack(cmd, result) = evt, cmd == "reboot" else { return }
            if result == 0 {
                rebootStatusText = t("重启指令已发送，等待设备重连。", "Reboot command sent. Waiting for reconnect.")
                waitingForRebootReconnect = true
            } else {
                rebootStatusText = t("重启失败，请重试。", "Reboot failed. Please try again.")
                waitingForRebootReconnect = false
            }
            isRebootingDevice = false
        }
        .onReceive(ble.events) { evt in
            guard case let .ack(cmd, result) = evt, cmd == "factory_reset" else { return }
            if result == 0 {
                factoryResetStatusText = t("恢复出厂指令已发送。", "Factory reset command sent.")
                isFactoryResetting = false
                UserDefaults.standard.set(true, forKey: "callmate.show_after_factory_reset_bluetooth_tip")
                onFactoryReset()
            } else {
                factoryResetStatusText = t("恢复出厂失败，请重试。", "Factory reset failed. Please try again.")
                isFactoryResetting = false
            }
        }
        .onChange(of: ble.isCtrlReady) { _, isReady in
            // Clear transient reboot status once control channel is back.
            guard isReady, waitingForRebootReconnect else { return }
            waitingForRebootReconnect = false
            isRebootingDevice = false
            rebootStatusText = nil
            isManualReconnectInFlight = false
        }
        .onAppear {
            guard perms.networkStatus == .satisfied else { return }
            guard !fw.isChecking, !fw.isUpdating else { return }
            Task { await fw.checkForUpdate() }
            if bleSnapshot.isKVReady {
                ble.requestFlashDBUsage()
            }
        }
        .onChange(of: ble.isKVReady) { _, ready in
            if ready {
                ble.requestFlashDBUsage()
            }
        }
        .onReceive(ble.events) { evt in
            guard case let .flashdbResponse(cmd, result, _, _, _) = evt else { return }
            guard result == 0 else { return }
            if cmd == "kv_set" || cmd == "kv_del" || cmd == "kv_get" {
                ble.requestFlashDBUsage()
            }
        }
        // Swipe-back handled by presenting container
    }
}

// MARK: - Advanced Settings (sub-page)

struct DeviceAdvancedSettingsView: View {
    let language: Language
    @Binding var showRebootConfirm: Bool
    @Binding var showDeviceLightControl: Bool
    @Binding var showDeviceDiagnostics: Bool
    @Binding var showFactoryResetConfirm: Bool
    @Binding var showRebindConfirm: Bool
    let hasRebind: Bool
    let isRebootingDevice: Bool
    let isFactoryResetting: Bool
    let isCtrlReady: Bool
    let isReady: Bool
    let fwIsUpdating: Bool
    @Binding var rebootStatusText: String?
    @Binding var factoryResetStatusText: String?

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private struct AdvancedRow: Identifiable {
        let id = UUID()
        let icon: String
        let iconColor: Color
        let title: String
        let action: () -> Void
        let disabled: Bool
    }

    private var advancedRows: [AdvancedRow] {
        var rows: [AdvancedRow] = [
            AdvancedRow(icon: "arrow.clockwise", iconColor: AppColors.warning, title: t("重启设备", "Reboot Device"), action: { showRebootConfirm = true }, disabled: !isCtrlReady || fwIsUpdating || isRebootingDevice),
            AdvancedRow(icon: "lightbulb.fill", iconColor: Color(hex: "FF9500"), title: t("灯光控制", "Light Control"), action: { showDeviceLightControl = true }, disabled: !isCtrlReady || fwIsUpdating),
            AdvancedRow(icon: "stethoscope", iconColor: Color(hex: "007AFF"), title: t("设备诊断", "Device Diagnostics"), action: { showDeviceDiagnostics = true }, disabled: !isReady),
            AdvancedRow(icon: "arrow.counterclockwise", iconColor: Color(hex: "FF3B30"), title: t("恢复出厂设置", "Factory Reset"), action: { showFactoryResetConfirm = true }, disabled: !isCtrlReady || isFactoryResetting || fwIsUpdating),
        ]
        if hasRebind {
            rows.append(AdvancedRow(icon: "link.badge.plus", iconColor: Color(hex: "5856D6"), title: t("重新绑定", "Rebind Device"), action: { showRebindConfirm = true }, disabled: isFactoryResetting))
        }
        return rows
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    ForEach(advancedRows) { row in
                        Button(action: row.action) {
                            HStack {
                                HStack(spacing: 12) {
                                    Image(systemName: row.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(row.iconColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Text(row.title)
                                        .font(.system(size: 17))
                                        .foregroundStyle(row.disabled ? AppColors.textTertiary : AppColors.textPrimary)
                                }

                                Spacer(minLength: 8)

                                if !row.disabled {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(lightHex: "D1D5DB", darkHex: "4B5563"))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(row.disabled)
                        .opacity(row.disabled ? 0.5 : 1)
                    }
                }
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                if let text = rebootStatusText ?? factoryResetStatusText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(AppColors.backgroundSecondary)
        .navigationTitle(t("高级设置", "Advanced Settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Battery Indicator

private struct DeviceBatteryView: View {
    let level: Int
    let isCharging: Bool

    private var clampedLevel: Int {
        min(max(level, 0), 100)
    }

    private var tintColor: Color {
        if isCharging { return .green }
        switch clampedLevel {
        case 60...100: return .green
        case 20...59: return .orange
        default:    return .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            BatteryIcon(level: clampedLevel, tintColor: tintColor, isCharging: isCharging)
            Text("\(clampedLevel)%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tintColor)
        }
    }
}

private struct BatteryIcon: View {
    let level: Int
    let tintColor: Color
    let isCharging: Bool

    private var fillWidth: CGFloat {
        let inner = 14.0
        return max(0, min(inner, (CGFloat(level) / 100.0) * inner))
    }

    private var fillColor: Color {
        if isCharging { return .green }
        switch level {
        case 60...100: return .green
        case 20...59: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(tintColor, lineWidth: 1)
                    .frame(width: 18, height: 10)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fillColor)
                    .frame(width: fillWidth, height: 6)
                    .padding(.leading, 2)
                    .padding(.vertical, 2)
            }
            .frame(width: 18, height: 10)
            .overlay {
                if isCharging {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.95))
                            .frame(width: 8, height: 8)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
            }

            RoundedRectangle(cornerRadius: 1)
                .fill(tintColor)
                .frame(width: 2, height: 5)
        }
        .frame(height: 10)
    }
}

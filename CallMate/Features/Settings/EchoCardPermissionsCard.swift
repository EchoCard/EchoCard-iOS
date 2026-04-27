//
//  EchoCardPermissionsCard.swift
//  CallMate
//

import SwiftUI
import UIKit
import CoreBluetooth
import Network
import AVFoundation
import UserNotifications

private enum EchoPermissionItem: Identifiable, Equatable {
    case bluetoothOff
    case bluetoothDenied
    case microphoneNotGranted
    case notificationNotGranted
    case networkUnavailable
    case classicBTNotPaired

    var id: String {
        switch self {
        case .bluetoothOff: return "bluetoothOff"
        case .bluetoothDenied: return "bluetoothDenied"
        case .microphoneNotGranted: return "microphone"
        case .notificationNotGranted: return "notification"
        case .networkUnavailable: return "network"
        case .classicBTNotPaired: return "classicBTNotPaired"
        }
    }
}

struct EchoCardPermissionsCard: View {
    let language: Language

    @ObservedObject private var ble = CallMateBLEClient.shared
    @ObservedObject private var perms = PermissionsCenter.shared

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var bluetoothAuth: CBManagerAuthorization {
        if #available(iOS 13.1, *) {
            return CBManager.authorization
        } else {
            return .allowedAlways
        }
    }

    private var missing: [EchoPermissionItem] {
        var items: [EchoPermissionItem] = []

        if bluetoothAuth == .denied || bluetoothAuth == .restricted {
            items.append(.bluetoothDenied)
        } else if ble.bluetoothState == .poweredOff {
            items.append(.bluetoothOff)
        }

        if perms.networkStatus != .satisfied {
            items.append(.networkUnavailable)
        }

        if perms.microphoneAuth != .granted {
            items.append(.microphoneNotGranted)
        }
        if perms.notificationAuth != .authorized &&
            perms.notificationAuth != .provisional &&
            perms.notificationAuth != .ephemeral {
            items.append(.notificationNotGranted)
        }

        if ble.deviceHFPPairingNeeded && ble.isReady {
            items.append(.classicBTNotPaired)
        }

        return items
    }

    var body: some View {
        if missing.isEmpty {
            EmptyView()
        } else {
            let onlyNetwork = missing.count == 1 && missing.first == .networkUnavailable
            let onlyBluetoothOff = missing.count == 1 && missing.first == .bluetoothOff
            let onlyBluetoothDenied = missing.count == 1 && missing.first == .bluetoothDenied
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "FF9500"))
                    Text(onlyNetwork
                         ? t("网络未连接，EchoCard 暂时不可用", "No internet connection — EchoCard is temporarily unavailable")
                         : onlyBluetoothOff
                         ? t("蓝牙未开启，EchoCard 暂时不可用", "Bluetooth is off — EchoCard is temporarily unavailable")
                         : onlyBluetoothDenied
                         ? t("蓝牙权限未授权，EchoCard 暂时不可用", "Bluetooth permission denied — EchoCard is temporarily unavailable")
                         : t("需要开启权限才能正常使用 EchoCard", "Enable permissions for EchoCard"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "1D1D1F"))
                    Spacer(minLength: 0)
                }

                VStack(spacing: 10) {
                    ForEach(missing) { item in
                        permissionRow(item)
                    }
                }

                Text(onlyNetwork
                     ? t("请打开 Wi‑Fi 或蜂窝数据后再试。", "Turn on Wi‑Fi or Cellular Data and try again.")
                     : onlyBluetoothOff
                     ? t("请在系统设置中开启蓝牙。", "Turn on Bluetooth in Settings.")
                     : onlyBluetoothDenied
                     ? t("请在系统设置中允许蓝牙访问。", "Allow Bluetooth access in Settings.")
                     : t("若你刚刚点了\u{201C}不允许\u{201D}，请到系统设置中重新开启。", "If you tapped \"Don't Allow\", re-enable it in Settings."))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "8E8E93"))
            }
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.black.opacity(0.04), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.02), radius: 6, y: 4)
            .task {
                await perms.refresh()
            }
        }
    }

    @ViewBuilder
    private func permissionRow(_ item: EchoPermissionItem) -> some View {
        switch item {
        case .classicBTNotPaired:
            row(
                icon: "antenna.radiowaves.left.and.right.slash",
                title: t("来电接听异常：需重新配对", "Call answering failed: re-pairing required"),
                subtitle: t(
                    "经典蓝牙未与 iPhone 配对，导致来电无法接听。请打开 iPhone「设置」→「蓝牙」，找到该设备，点击右侧 ⓘ →「忽略此设备」，然后重新在本 App 中连接。",
                    "Classic Bluetooth isn't paired with iPhone, preventing call answering. Go to iPhone Settings → Bluetooth, tap ⓘ next to the device, choose \"Forget This Device\", then reconnect in this app."
                )
            )
        case .bluetoothDenied:
            row(
                icon: "bolt.horizontal.circle.fill",
                title: t("蓝牙权限被拒绝", "Bluetooth permission denied"),
                subtitle: t("请在系统设置中允许蓝牙访问。", "Allow Bluetooth access in Settings."),
                actionTitle: t("打开设置", "Open Settings"),
                action: { perms.openAppSettings() }
            )
        case .bluetoothOff:
            row(
                icon: "bolt.horizontal.circle",
                title: t("蓝牙已关闭", "Bluetooth is off"),
                subtitle: t("请在控制中心或系统设置中打开蓝牙。", "Turn on Bluetooth in Control Center or Settings.")
            )
        case .networkUnavailable:
            row(
                icon: "wifi.exclamationmark",
                title: t("网络未连接", "No internet connection"),
                subtitle: t("请开启 Wi‑Fi 或蜂窝数据。", "Enable Wi‑Fi or Cellular Data.")
            )
        case .microphoneNotGranted:
            let status = perms.microphoneAuth
            if status == .undetermined {
                row(
                    icon: "mic",
                    title: t("允许麦克风", "Allow microphone"),
                    subtitle: t("用于通话录音/语音交互。", "For call recording/voice input."),
                    actionTitle: t("允许", "Allow"),
                    action: {
                        Task { _ = await perms.requestMicrophone() }
                    }
                )
            } else {
                row(
                    icon: "mic.slash",
                    title: t("麦克风权限被关闭", "Microphone denied"),
                    subtitle: t("请在系统设置中开启麦克风。", "Enable microphone in Settings."),
                    actionTitle: t("去设置", "Open Settings"),
                    action: { perms.openAppSettings() }
                )
            }
        case .notificationNotGranted:
            let status = perms.notificationAuth
            if status == .notDetermined {
                row(
                    icon: "bell.badge",
                    title: t("允许通知", "Allow notifications"),
                    subtitle: t("用于紧急来电提醒。", "Used for urgent call alerts."),
                    actionTitle: t("允许", "Allow"),
                    action: {
                        Task { _ = await perms.requestNotification() }
                    }
                )
            } else {
                row(
                    icon: "bell.slash",
                    title: t("通知权限被关闭", "Notifications denied"),
                    subtitle: t("请在系统设置中开启通知。", "Enable notifications in Settings."),
                    actionTitle: t("去设置", "Open Settings"),
                    action: { perms.openAppSettings() }
                )
            }
        }
    }

    private func row(icon: String, title: String, subtitle: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: "007AFF"))
                .frame(width: 36, height: 36)
                .background(Color(hex: "007AFF").opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "1D1D1F"))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "8E8E93"))
            }

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "007AFF"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "007AFF").opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(hex: "F2F2F7"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

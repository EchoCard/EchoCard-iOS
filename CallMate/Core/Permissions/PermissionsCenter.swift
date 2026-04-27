//
//  PermissionsCenter.swift
//  CallMate
//
//  Centralized permission + connectivity state for EchoCard.
//

import Foundation
import SwiftUI
import Combine
import CoreBluetooth
import AVFoundation
import Network
import UIKit
import UserNotifications

@MainActor
final class PermissionsCenter: ObservableObject {
    static let shared = PermissionsCenter()

    @Published private(set) var microphoneAuth: AVAudioApplication.recordPermission = .undetermined
    @Published private(set) var networkStatus: NWPath.Status = .satisfied
    @Published private(set) var notificationAuth: UNAuthorizationStatus = .notDetermined

    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "CallMate.NetworkMonitor")

    private init() {
        startNetworkMonitorIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    func refresh() async {
        refreshMicrophone()
        await refreshNotification()
    }

    func requestMicrophone() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            microphoneAuth = AVAudioApplication.recordPermission.granted
            return true
        case .denied:
            microphoneAuth = AVAudioApplication.recordPermission.denied
            return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            microphoneAuth = granted ? AVAudioApplication.recordPermission.granted : AVAudioApplication.recordPermission.denied
            return granted
        @unknown default:
            microphoneAuth = AVAudioApplication.recordPermission.denied
            return false
        }
    }

    func requestNotification() async -> Bool {
        let granted: Bool = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        await refreshNotification()
        return granted
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func openBluetoothSettings() {
        // App Store safe: use app settings as the only destination.
        openAppSettings()
    }

    func openNetworkSettings() {
        // App Store safe: use app settings as the only destination.
        openAppSettings()
    }

    // MARK: - Private

    private func refreshMicrophone() {
        microphoneAuth = AVAudioApplication.shared.recordPermission
    }

    private func refreshNotification() async {
        let status: UNAuthorizationStatus = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        notificationAuth = status
    }

    private func startNetworkMonitorIfNeeded() {
        if pathMonitor != nil { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self, status = path.status] in
                self?.networkStatus = status
            }
        }
        monitor.start(queue: pathQueue)
    }
}

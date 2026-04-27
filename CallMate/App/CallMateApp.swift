//
//  CallMateApp.swift
//  CallMate
//
//  Created by apple on 2026/2/1.
//

import SwiftUI
import SwiftData
import UserNotifications
import UIKit
import os

/// 完整打印 APNs `userInfo`（JSON 或 fallback）。开关：`UserDefaults` key `callmate.apns_log_full_payload`；
/// **仅当用 Xcode「Debug」配置编译时** `#if DEBUG` 为真：未设置该 key 则默认打印。
/// **Release / TestFlight / App Store 包没有 DEBUG**：默认不打印，必须在运行时执行
/// `UserDefaults.standard.set(true, forKey: "callmate.apns_log_full_payload")`（或改代码临时打开）。
private enum APNSPayloadDebug {
    private static let defaultsKey = "callmate.apns_log_full_payload"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CallMate", category: "APNSPayload")

    static func isEnabled() -> Bool {
        #if DEBUG
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
        #else
        return UserDefaults.standard.bool(forKey: defaultsKey)
        #endif
    }

    static func dumpIfNeeded(userInfo: [AnyHashable: Any], source: String) {
        guard isEnabled() else { return }
        let body = serialize(userInfo)
        print("[APNS][payload] source=\(source)\n\(body)")
        log.debug("source=\(source, privacy: .public) payload=\(body, privacy: .public)")
    }

    private static func serialize(_ userInfo: [AnyHashable: Any]) -> String {
        var dict: [String: Any] = [:]
        for (k, v) in userInfo {
            guard let ks = k as? String else { continue }
            dict[ks] = v
        }
        if JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: userInfo)
    }
}

@MainActor
private final class AppNotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    private var appServices: AppServices?
    private var appRouter: AppRouter?

    func configure(appServices: AppServices, appRouter: AppRouter) {
        self.appServices = appServices
        self.appRouter = appRouter
    }

    /// 仅处理服务端静默推送 `event: command`；旧版来电 / BLE 转发 / 拨号等远程 payload 已移除。
    func handleRemoteNotification(userInfo: [AnyHashable: Any], source: String) -> Bool {
        guard let event = userInfo["event"] as? String, event == "command" else {
            return false
        }
        guard let appServices else {
            assertionFailure("AppNotificationDelegate used before AppServices was configured")
            return false
        }
        print("[APNS] command push source=\(source)")
        Task {
            await appServices.controlChannel.handleRemoteNotificationPayload(userInfo)
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        APNSPayloadDebug.dumpIfNeeded(userInfo: userInfo, source: "foreground_willPresent")
        _ = handleRemoteNotification(userInfo: userInfo, source: "foreground_willPresent")

        // Suppress banner/sound for "live transcript" notification when the call is still active:
        // the user is already watching the live call, showing the banner is redundant.
        if userInfo["live_transcript_call"] as? String == "1",
           appServices?.liveBLEController.status != .ended {
            completionHandler([.list])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        APNSPayloadDebug.dumpIfNeeded(userInfo: userInfo, source: "notification_tap")
        _ = handleRemoteNotification(userInfo: userInfo, source: "notification_tap")

        // Local "live transcript" notification: open live call sheet or call detail by call id.
        if userInfo["live_transcript_call"] as? String == "1",
           let callIdStr = userInfo["call_id"] as? String {
            appRouter?.routeLiveTranscriptNotificationTap(callIdString: callIdStr)
        }
        completionHandler()
    }
}

@MainActor
private final class RemoteNotificationAppDelegate: NSObject, UIApplicationDelegate {
    private static var configuredServices: AppServices?
    private let apnsDeviceTokenKey = "callmate.apns_device_token"

    static func configure(appServices: AppServices) {
        configuredServices = appServices
    }

    private var appServices: AppServices? { Self.configuredServices }

    fileprivate func registerForRemoteNotificationsIfAuthorized(reason: String) {
        guard !AppAutomation.shouldSkipExternalBootstrap else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            print("[Notify] \(reason) auth status=\(settings.authorizationStatus.rawValue) granted=\(granted)")
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        registerForRemoteNotificationsIfAuthorized(reason: "didBecomeActive")
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: apnsDeviceTokenKey)
        print("[APNS] didRegister token.len=\(token.count) token=\(token)")
        guard let appServices else { return }
        Task {
            _ = await appServices.backendAuth.syncPushRegistration(apnsTokenHex: token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNS] register failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        APNSPayloadDebug.dumpIfNeeded(userInfo: userInfo, source: "UIApplication.didReceiveRemoteNotification")
        guard let appServices else {
            completionHandler(.noData)
            return
        }
        if let event = userInfo["event"] as? String, event == "command" {
            Task {
                await appServices.controlChannel.handleRemoteNotificationPayload(userInfo)
                completionHandler(.newData)
            }
            return
        }
        let handled = AppNotificationDelegate.shared.handleRemoteNotification(
            userInfo: userInfo,
            source: "didReceiveRemoteNotification"
        )
        completionHandler(handled ? .newData : .noData)
    }

    /// 用户划掉 app 时尽量清理「通话中」灵动岛（iOS 不保证一定会调，重开 app 时 didBecomeActive 会再清一次）。
    func application(
        _ application: UIApplication,
        willTerminateWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        Task { @MainActor in
            appServices?.liveActivityManager.endAllInCallActivitiesNow(reason: "willTerminate")
        }
    }
}

@main
struct CallMateApp: App {
    @UIApplicationDelegateAdaptor(RemoteNotificationAppDelegate.self) private var appDelegate
    private static let sharedAppServices = AppServices()
    private static let sharedAppRouter = AppRouter(services: sharedAppServices)

    private let appServices: AppServices
    private let appRouter: AppRouter
    private let apnsDeviceTokenKey = "callmate.apns_device_token"
    private let bleAudioCodecKey = "callmate.ble_audio_codec"

    init() {
        self.appServices = Self.sharedAppServices
        self.appRouter = Self.sharedAppRouter

        let defaults = UserDefaults.standard
        defaults.set("opus", forKey: bleAudioCodecKey)
        if let preferredLanguage = AppAutomation.preferredLanguage {
            defaults.set(preferredLanguage.rawValue, forKey: "callmate.language")
        }
        if AppAutomation.forceMainState {
            defaults.set(true, forKey: "callmate_has_accepted_legal_docs")
            defaults.set(true, forKey: "callmate_has_completed_onboarding")
        }
        // `ble_local_uplink_test_in_progress` is a runtime flag that must not survive
        // an app restart. A crash during a test would leave it stuck as `true` and
        // silently block all real incoming calls on the next launch.
        defaults.set(false, forKey: "ble_local_uplink_test_in_progress")
        // Initialize BLE central early so CoreBluetooth state restoration callbacks
        // can be delivered when iOS relaunches app in background.
        _ = appServices.ble
        let ble = appServices.ble
        // For users who have already bound a device, initialize CBCentralManager
        // immediately so iOS can deliver willRestoreState and background scan wakeups.
        // Skipped for first-time users to avoid premature Bluetooth permission prompts.
        if !AppAutomation.shouldSkipExternalBootstrap && ble.hasSavedPeripheral {
            ble.ensureCentralInitialized(reason: "app_launch_restore")
            // If the system already reconnected (e.g. user came back in range), attach and subscribe immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ble.autoConnectIfPossible()
            }
        }
        // Keep BLE AI controller alive at app level, so background push-triggered
        // outgoing calls can still enter call_state/WS/audio pipeline.
        _ = appServices.liveBLEController
        ProcessStrategyStore.ensureDefaultIfNeeded()
        OutboundTaskBGScheduler.register()
        AppNotificationDelegate.shared.configure(appServices: appServices, appRouter: appRouter)
        RemoteNotificationAppDelegate.configure(appServices: appServices)
        let center = UNUserNotificationCenter.current()
        center.delegate = AppNotificationDelegate.shared
        if let cached = UserDefaults.standard.string(forKey: apnsDeviceTokenKey), !cached.isEmpty {
            print("[APNS] cached device token=\(cached)")
        } else {
            print("[APNS] cached device token=nil")
        }
        // Do NOT auto-request notification permission at app launch.
        // If already authorized before, register silently for remote notifications.
        if !AppAutomation.shouldSkipExternalBootstrap {
            appDelegate.registerForRemoteNotificationsIfAuthorized(reason: "launch")
        }
        if AppAutomation.isUITesting {
            AppAutomationDataSeeder.seedIfNeeded(in: Self.sharedModelContainer)
        }
    }

    static let sharedModelContainer: ModelContainer = {
        let t0 = Date()
        print("[ModelContainer] init start thread=\(Thread.isMainThread ? "main" : "bg")")
        defer {
            print(String(format: "[ModelContainer] init done took=%.3fs", Date().timeIntervalSince(t0)))
        }
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: AppAutomation.shouldUseEphemeralPersistence)
            return try ModelContainer(
                for: CallLog.self,
                TranscriptLine.self,
                CallFeedback.self,
                OutboundPromptTemplate.self,
                OutboundContactBookEntry.self,
                AIChatMessage.self,
                configurations: configuration
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(appServices: appServices, appRouter: appRouter)
        }
        .modelContainer(CallMateApp.sharedModelContainer)
    }
}

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

@MainActor
private final class AppNotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    private var appServices: AppServices?
    private var appRouter: AppRouter?

    func configure(appServices: AppServices, appRouter: AppRouter) {
        self.appServices = appServices
        self.appRouter = appRouter
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

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

        // Local "live transcript" notification: open live call sheet or call detail by call id.
        if userInfo["live_transcript_call"] as? String == "1",
           let callIdStr = userInfo["call_id"] as? String {
            appRouter?.routeLiveTranscriptNotificationTap(callIdString: callIdStr)
        }
        completionHandler()
    }
}

@MainActor
private final class CallMateLifecycleAppDelegate: NSObject, UIApplicationDelegate {
    private static var configuredServices: AppServices?

    static func configure(appServices: AppServices) {
        configuredServices = appServices
    }

    private var appServices: AppServices? { Self.configuredServices }

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
    @UIApplicationDelegateAdaptor(CallMateLifecycleAppDelegate.self) private var lifecycleAppDelegate
    private static let sharedAppServices = AppServices()
    private static let sharedAppRouter = AppRouter(services: sharedAppServices)

    private let appServices: AppServices
    private let appRouter: AppRouter
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
        _ = appServices.liveBLEController
        ProcessStrategyStore.ensureDefaultIfNeeded()
        OutboundTaskBGScheduler.register()
        AppNotificationDelegate.shared.configure(appServices: appServices, appRouter: appRouter)
        CallMateLifecycleAppDelegate.configure(appServices: appServices)
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
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

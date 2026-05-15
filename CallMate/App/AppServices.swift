//
//  AppServices.swift
//  CallMate
//

import Foundation

/// Centralized app-level service composition.
///
/// Ownership rules:
/// - BLE / WebSocket / Audio remain globally unique runtime services.
/// - `CallSessionController.sharedBLE` remains the single long-lived BLE call controller.
/// - Root views and app delegates should depend on this container instead of reaching for
///   `Type.shared` directly, so dependency sources stay explicit.
@MainActor
final class AppServices {
    let ble: CallMateBLEClient
    let webSocket: WebSocketService
    let audio: AudioService
    let backendAuth: BackendAuthManager
    let permissions: PermissionsCenter
    let liveActivityManager: CallLiveActivityManager
    let liveTranscriptNotificationRouter: LiveTranscriptNotificationRouter
    let liveBLEController: CallSessionController

    init(
        ble: CallMateBLEClient? = nil,
        webSocket: WebSocketService? = nil,
        audio: AudioService? = nil,
        backendAuth: BackendAuthManager? = nil,
        permissions: PermissionsCenter? = nil,
        liveActivityManager: CallLiveActivityManager? = nil,
        liveTranscriptNotificationRouter: LiveTranscriptNotificationRouter? = nil,
        liveBLEController: CallSessionController? = nil
    ) {
        let resolvedBLE = ble ?? CallMateBLEClient.shared
        let resolvedWebSocket = webSocket ?? .shared
        let resolvedAudio = audio ?? .shared
        let resolvedBackendAuth = backendAuth ?? .shared
        let resolvedPermissions = permissions ?? .shared
        let resolvedLiveActivityManager = liveActivityManager ?? .shared
        let resolvedLiveTranscriptNotificationRouter = liveTranscriptNotificationRouter ?? .shared

        self.ble = resolvedBLE
        self.webSocket = resolvedWebSocket
        self.audio = resolvedAudio
        self.backendAuth = resolvedBackendAuth
        self.permissions = resolvedPermissions
        self.liveActivityManager = resolvedLiveActivityManager
        self.liveTranscriptNotificationRouter = resolvedLiveTranscriptNotificationRouter
        resolvedBLE.configureHostHooks(
            Self.makeBLEHostHooks(webSocket: resolvedWebSocket)
        )

        if let liveBLEController {
            self.liveBLEController = liveBLEController
        } else {
            let usesSharedBLEGraph =
                (resolvedBLE as AnyObject) === CallMateBLEClient.shared &&
                resolvedWebSocket === WebSocketService.shared &&
                resolvedAudio === AudioService.shared &&
                resolvedPermissions === PermissionsCenter.shared

            self.liveBLEController = usesSharedBLEGraph
                ? .sharedBLE
                : CallSessionController(
                    language: .zh,
                    inputSource: .ble,
                    monitorTTSOnPhone: false,
                    ws: resolvedWebSocket,
                    audio: resolvedAudio,
                    ble: resolvedBLE,
                    permissions: resolvedPermissions
                )
        }
    }

    static let preview = AppServices()

    private static func makeBLEHostHooks(webSocket: WebSocketService) -> CallMateBLEHostHooks {
        CallMateBLEHostHooks(
            isANCSAuthorizationEnabled: { AppFeatureFlags.ancsAuthorizationEnabled },
            isCallIdle: { CallSessionController.sharedBLE.status == .ended },
            disconnectWebSocket: {
                Task { @MainActor in
                    webSocket.disconnect()
                }
            },
            strategy: CallMateBLEStrategyHooks(
                currentJSONString: { ProcessStrategyStore.processStrategyJSONString() },
                saveJSONIfValid: { ProcessStrategyStore.saveProcessStrategyJSONIfValid($0) },
                validateJSON: { ProcessStrategyStore.validateProcessStrategyJSON($0) },
                addChangeObserver: { callback in
                    NotificationCenter.default.addObserver(
                        forName: ProcessStrategyStore.didChangeNotification,
                        object: nil,
                        queue: .main
                    ) { note in
                        callback(note.userInfo?["json"] as? String)
                    }
                },
                removeChangeObserver: { observer in
                    NotificationCenter.default.removeObserver(observer)
                }
            )
        )
    }
}

//
//  AppRouter.swift
//  CallMate
//

import Foundation

@MainActor
protocol LiveCallSessionRouting: AnyObject {
    var status: CallSessionController.Status { get }
    var currentIncomingCall: CallMateIncomingCall? { get }
    func consumeLiveCallRequest()
    func handoffToHuman()
    func end(abortReason: String)
}

extension CallSessionController: LiveCallSessionRouting {}

@MainActor
final class AppRouter {
    let liveTranscriptNotificationRouter: LiveTranscriptNotificationRouter
    let liveCallPresentation: LiveCallPresentationCoordinator

    private let liveSessionController: any LiveCallSessionRouting
    private let deepLinkHandler: LiveActivityDeepLinkHandling

    init(
        liveSessionController: (any LiveCallSessionRouting)? = nil,
        liveTranscriptNotificationRouter: LiveTranscriptNotificationRouter? = nil,
        deepLinkHandler: LiveActivityDeepLinkHandling? = nil
    ) {
        let resolvedLiveSessionController = liveSessionController ?? CallSessionController.sharedBLE
        let resolvedLiveTranscriptRouter = liveTranscriptNotificationRouter ?? .shared

        self.liveSessionController = resolvedLiveSessionController
        self.liveTranscriptNotificationRouter = resolvedLiveTranscriptRouter
        self.liveCallPresentation = LiveCallPresentationCoordinator(
            liveSessionController: resolvedLiveSessionController,
            liveTranscriptNotificationRouter: resolvedLiveTranscriptRouter
        )
        self.deepLinkHandler = deepLinkHandler ?? LiveActivityDeepLinkHandler(
            liveSessionController: resolvedLiveSessionController
        )
    }

    convenience init(services: AppServices) {
        self.init(
            liveSessionController: services.liveBLEController,
            liveTranscriptNotificationRouter: services.liveTranscriptNotificationRouter
        )
    }

    func handleOpenURL(_ url: URL) {
        deepLinkHandler.handle(url: url)
    }

    func routeLiveTranscriptNotificationTap(callIdString: String) {
        let trimmed = callIdString.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedId = UUID(uuidString: trimmed)
        let canShowLiveSession = liveSessionController.status != .ended
            && liveSessionController.currentIncomingCall != nil

        if let callId = parsedId, !trimmed.isEmpty {
            if canShowLiveSession {
                liveTranscriptNotificationRouter.pendingShowLiveCall = true
            } else {
                liveTranscriptNotificationRouter.pendingOpenCallDetailId = callId
            }
        } else if canShowLiveSession {
            // Answer-instant notification has no CallLog id yet (call_id empty).
            liveTranscriptNotificationRouter.pendingShowLiveCall = true
        }
    }
}

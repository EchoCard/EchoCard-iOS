//
//  LiveCallPresentationCoordinator.swift
//  CallMate
//

import Foundation
import Combine

@MainActor
final class LiveCallPresentationCoordinator: ObservableObject {
    @Published private(set) var presentedLiveCall: CallMateIncomingCall?

    private let liveSessionController: any LiveCallSessionRouting
    private let liveTranscriptNotificationRouter: LiveTranscriptNotificationRouter

    init(
        liveSessionController: any LiveCallSessionRouting,
        liveTranscriptNotificationRouter: LiveTranscriptNotificationRouter
    ) {
        self.liveSessionController = liveSessionController
        self.liveTranscriptNotificationRouter = liveTranscriptNotificationRouter
    }

    func dismissLiveCall() {
        presentedLiveCall = nil
    }

    func handleLiveCallRequest(_ call: CallMateIncomingCall?, appState: AppState) {
        guard let call, appState == .main else { return }
        presentLiveCall(call)
        liveSessionController.consumeLiveCallRequest()
    }

    func handlePendingShowLiveCall(appState: AppState) {
        guard liveTranscriptNotificationRouter.pendingShowLiveCall else { return }
        // Only consume the pending flag once we're actually in `.main` — otherwise keep it
        // buffered so that transitioning into main later (e.g. cold-launch after legal consent)
        // still opens the live transcript sheet, matching the pre-refactor behaviour.
        guard appState == .main else { return }
        defer { liveTranscriptNotificationRouter.clearShowLiveCall() }
        guard let call = liveSessionController.currentIncomingCall else { return }
        presentLiveCall(call)
    }

    func syncForActiveScene(appState: AppState) {
        guard appState == .main else { return }
        if liveSessionController.status != .ended,
           let currentCall = liveSessionController.currentIncomingCall {
            presentLiveCall(currentCall)
            return
        }
        if liveTranscriptNotificationRouter.pendingOpenCallDetailId != nil {
            liveTranscriptNotificationRouter.requestDismissTransientOverlays()
        }
        if liveSessionController.status == .ended {
            dismissLiveCall()
        }
    }

    private func presentLiveCall(_ call: CallMateIncomingCall) {
        liveTranscriptNotificationRouter.requestDismissTransientOverlays()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.presentedLiveCall = call
        }
    }
}

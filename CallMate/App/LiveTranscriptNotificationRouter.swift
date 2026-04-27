//
//  LiveTranscriptNotificationRouter.swift
//  CallMate
//
//  Routes tap on "AI has answered, tap to view live transcript" notification:
//  - If call still active → show live call sheet.
//  - If call ended → open call detail for that call (by local call id).
//

import Foundation
import Combine

final class LiveTranscriptNotificationRouter: ObservableObject {
    static let shared = LiveTranscriptNotificationRouter()

    /// When true, ContentView should show the live call fullScreenCover (same call as current session).
    @Published var pendingShowLiveCall: Bool = false

    /// When set, CallsView should open call detail for this call id (call has ended).
    @Published var pendingOpenCallDetailId: UUID?

    /// Incremented whenever call-related UI should take priority over transient overlays
    /// like the AI avatar sheet.
    @Published var overlayDismissToken: UUID = UUID()

    private init() {}

    func clearShowLiveCall() {
        pendingShowLiveCall = false
    }

    func clearOpenCallDetail() {
        pendingOpenCallDetailId = nil
    }

    func requestDismissTransientOverlays() {
        overlayDismissToken = UUID()
    }
}

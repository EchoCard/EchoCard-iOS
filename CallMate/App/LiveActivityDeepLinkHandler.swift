//
//  LiveActivityDeepLinkHandler.swift
//  CallMate
//

import Foundation

@MainActor
protocol LiveActivityDeepLinkHandling {
    func handle(url: URL)
}

@MainActor
final class LiveActivityDeepLinkHandler: LiveActivityDeepLinkHandling {
    private let liveSessionController: any LiveCallSessionRouting

    init(liveSessionController: any LiveCallSessionRouting) {
        self.liveSessionController = liveSessionController
    }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "callmate" else { return }
        guard url.host?.lowercased() == "livecall" else { return }
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !action.isEmpty else { return }

        switch action {
        case "handoff":
            liveSessionController.handoffToHuman()
        case "hangup":
            liveSessionController.end(abortReason: "live_activity_hangup")
        default:
            break
        }
    }
}

//
//  SystemCallObserver.swift
//  CallMate
//

import CallKit
import Foundation

final class SystemCallObserver: NSObject, CXCallObserverDelegate {
    static let shared = SystemCallObserver()

    private let observer = CXCallObserver()
    private var handlers: [UUID: () -> Void] = [:]
    private var answeredHandlers: [UUID: () -> Void] = [:]
    private var seenAnsweredCallUUIDs: Set<UUID> = []

    private override init() {
        super.init()
        observer.setDelegate(self, queue: nil)
    }

    func addCallEndedHandler(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func removeHandler(_ token: UUID) {
        handlers.removeValue(forKey: token)
        answeredHandlers.removeValue(forKey: token)
    }

    func addCallAnsweredHandler(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        answeredHandlers[token] = handler
        return token
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if !call.hasEnded, call.hasConnected, !call.isOutgoing {
            if !seenAnsweredCallUUIDs.contains(call.uuid) {
                seenAnsweredCallUUIDs.insert(call.uuid)
                let allAnswered = answeredHandlers.values
                for h in allAnswered { h() }
            }
        }
        if call.hasEnded {
            seenAnsweredCallUUIDs.remove(call.uuid)
            let all = handlers.values
            if all.isEmpty { return }
            for h in all { h() }
        }
    }
}

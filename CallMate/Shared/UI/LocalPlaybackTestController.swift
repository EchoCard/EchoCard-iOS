//
//  LocalPlaybackTestController.swift
//  CallMate
//
//  Offline uplink-chain test controller (mSBC removed; Opus-only pipeline).
//

import Combine
import Foundation

@MainActor
final class LocalPlaybackTestController: ObservableObject {
    enum Status: Equatable {
        case idle
        case ringing
        case connected
        case ended
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastError: String? = "mSBC test removed (Opus only)"
    @Published private(set) var sourceRecordingName: String?

    private let ble = CallMateBLEClient.shared
    private var cancellables: Set<AnyCancellable> = []

    init() {}

    func start(incomingCall: CallMateIncomingCall) {
        lastError = "Local BLE uplink test not available (mSBC removed)"
        print("[LocalTest] start: mSBC path removed, no-op")
    }

    func end() {
        status = .ended
        UserDefaults.standard.removeObject(forKey: "ble_local_uplink_test_armed")
        UserDefaults.standard.removeObject(forKey: "ble_local_uplink_test_in_progress")
    }
}

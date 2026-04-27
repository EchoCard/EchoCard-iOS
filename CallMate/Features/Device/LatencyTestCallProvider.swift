//
//  LatencyTestCallProvider.swift
//  CallMate
//
//  Minimal CallKit provider for latency test: report/answer/end a fake call
//  so iOS routes audio to HFP (Bluetooth headset) for play + record.
//
//  Required: In Xcode, add the "Voice over IP" background mode and ensure
//  the app has CallKit entitlement so reportNewIncomingCall works.
//

import AVFoundation
import CallKit
import Foundation

/// Reports and answers a fake "Latency Test" call so the system uses HFP (SCO) for audio.
/// Requires: CallKit capability and VoIP background mode if testing from background.
final class LatencyTestCallProvider: NSObject {
    static let shared = LatencyTestCallProvider()

    private let config: CXProviderConfiguration
    private let provider: CXProvider
    private let callController = CXCallController()

    private var activeCallUUID: UUID?
    private var onAnswered: (() -> Void)?        // fires in perform(CXAnswerCallAction)
    private var onAudioActivated: (() -> Void)?  // fires in provider(_:didActivate:)
    private var onEnded: (() -> Void)?
    private var onFailed: ((String) -> Void)?

    override init() {
        if #available(iOS 14.0, *) {
            config = CXProviderConfiguration()
        } else {
            config = CXProviderConfiguration(localizedName: "EchoCard")
        }
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// Report an incoming "Latency Test" call so iOS routes audio to HFP (SCO).
    ///
    /// - Parameter onAnswered: Called when the action is fulfilled — send `hfp_connect` here.
    ///   Do NOT activate AVAudioSession here; CallKit hasn't set up audio yet.
    /// - Parameter onAudioActivated: Called from `provider(_:didActivate:)` when iOS has
    ///   finished establishing SCO.  Start play/record here.
    /// - Parameter onEnded: Called when the call ends.
    /// - Parameter onFailed: Called when CallKit cannot create or answer the fake call.
    func reportAndAnswerLatencyTestCall(
        onAnswered: @escaping () -> Void,
        onAudioActivated: @escaping () -> Void,
        onEnded: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        self.onAnswered = onAnswered
        self.onAudioActivated = onAudioActivated
        self.onEnded = onEnded
        self.onFailed = onFailed
        let uuid = UUID()
        activeCallUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Latency Test")
        update.localizedCallerName = "Latency Test"

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                print("[LatencyTest] reportNewIncomingCall error: \(error)")
                let onFailed = self?.onFailed
                self?.activeCallUUID = nil
                self?.onAnswered = nil
                self?.onAudioActivated = nil
                self?.onEnded = nil
                self?.onFailed = nil
                onFailed?("CallKit reportNewIncomingCall failed: \(error.localizedDescription)")
                return
            }
            // Delay answer so the system incoming-call UI (fullscreen popup) is visible briefly.
            let delay: TimeInterval = 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.activeCallUUID == uuid else { return }
                let answerAction = CXAnswerCallAction(call: uuid)
                let transaction = CXTransaction(action: answerAction)
                self.callController.request(transaction) { err in
                    if let err = err {
                        print("[LatencyTest] request answer error: \(err)")
                        let onFailed = self.onFailed
                        self.onAnswered = nil
                        self.onAudioActivated = nil
                        self.onEnded = nil
                        self.onFailed = nil
                        onFailed?("CallKit answer request failed: \(err.localizedDescription)")
                    }
                }
            }
        }
    }

    /// End the latency test call (call this when test is done).
    func endLatencyTestCall() {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        activeCallUUID = nil
        onEnded?()
        onEnded = nil
        onAnswered = nil
        onAudioActivated = nil
        onFailed = nil
    }

    var isCallActive: Bool { activeCallUUID != nil }
}

extension LatencyTestCallProvider: CXProviderDelegate {
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        onAnswered?()
        onAnswered = nil
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        activeCallUUID = nil
        onEnded?()
        onEnded = nil
        onAnswered = nil
        onAudioActivated = nil
        onFailed = nil
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // iOS has established HFP SCO and activated the audio session.
        // This is the correct place to start using audio for a CallKit call.
        onAudioActivated?()
        onAudioActivated = nil
    }

    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
        onEnded = nil
        onAnswered = nil
        onAudioActivated = nil
        onFailed = nil
    }
}

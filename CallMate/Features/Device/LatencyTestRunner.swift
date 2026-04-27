//
//  LatencyTestRunner.swift
//  CallMate
//
//  Runs the HFP round-trip latency test: play square wave → HFP → MCU → Opus → BLE
//  → iOS echo → MCU → HFP uplink → record; measure T_record - T_play.
//

import AVFoundation
import Combine
import Foundation

enum LatencyWaveformKind: String, Identifiable {
    case playback
    case bleLoopback
    case microphone

    var id: String { rawValue }
}

struct LatencyWaveformTrace: Identifiable {
    let kind: LatencyWaveformKind
    let samples: [Float]
    let startTimeMs: Double
    let sampleRate: Double
    let eventTimeMs: Double?

    var id: String { kind.id }
}

struct LatencyStageMeasurement: Identifiable {
    let id: String
    let milliseconds: Double?
}

struct LatencyLoopbackPacket {
    let payload: Data
    let receivedAt: CFAbsoluteTime
}

@MainActor
final class LatencyTestRunner: ObservableObject {
    static let shared = LatencyTestRunner()

    @Published private(set) var isRunning = false
    @Published private(set) var isContinuousRunning = false
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var measuredLatencyMs: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var stageMeasurements: [LatencyStageMeasurement] = []
    @Published private(set) var waveformTraces: [LatencyWaveformTrace] = []

    /// Exposed for UI to show real-time frequency and waveform during continuous test.
    let continuousAnalyzer = ContinuousLatencyAnalyzer(sampleRate: 16000)

    private let ble = CallMateBLEClient.shared
    private let sampleRate: Double = 16000
    private let squareWaveHz: Double = 500
    private var playStartTime: CFAbsoluteTime?
    private var firstEdgeTime: CFAbsoluteTime?
    private var recordingTapInstalled = false
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var inputNode: AVAudioInputNode?
    private let testDuration: TimeInterval = 5.0
    private var testTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var scoWaitTimeoutTask: Task<Void, Never>?
    private var primingAudioActive = false
    private var inputFormatLogged = false
    private var cachedPlaybackSamples: [Float] = []
    private var cachedMicSamples: [Float] = []
    private var cachedLoopbackOpusPackets: [LatencyLoopbackPacket] = []
    private var analysisTask: Task<Void, Never>?
    private var isContinuousMode = false

    private init() {}

    func startTest() {
        print("[LatencyTest] startTest() called, isRunning=\(isRunning), ble.isReady=\(ble.isReady)")
        guard !isRunning else { return }
        guard !isContinuousRunning else { return }
        guard ble.isReady else {
            errorMessage = "BLE not ready"
            return
        }

        errorMessage = nil
        measuredLatencyMs = nil
        stageMeasurements = []
        statusMessage = "Starting…"
        waveformTraces = []
        isRunning = true
        isContinuousMode = false
        ble.latencyTestEchoMode = true
        resetCapturedData()
        ble.latencyTestLoopbackOpusObserver = { [weak self] packet, receivedAt in
            Task { @MainActor in
                self?.cacheLoopbackOpusPacket(packet, receivedAt: receivedAt)
            }
        }

        // Tell MCU to suppress ANCS incoming-call events before CallKit reports the
        // fake call — otherwise the ANCS "Removed" event (which arrives without app_id)
        // triggers a spurious phone_handled transition that blocks SCO establishment.
        print("[LatencyTest] sending latency_test_mode ON")
        ble.sendCommand("latency_test_mode", extra: ["enable": true], expectAck: true)

        // Start bringing up HFP before we auto-answer the fake CallKit call.
        // `didActivate` can arrive very quickly after answer; pre-connecting HFP gives
        // the phone a better chance to establish SCO before the test waits on `active`.
        print("[LatencyTest] preconnecting HFP before CallKit answer")
        ble.sendCommand("hfp_connect", expectAck: true)

        print("[LatencyTest] calling reportAndAnswerLatencyTestCall")
        LatencyTestCallProvider.shared.reportAndAnswerLatencyTestCall(
            onAnswered: { [weak self] in
                Task { @MainActor in self?.onCallAnswered() }
            },
            onAudioActivated: { [weak self] in
                Task { @MainActor in self?.onAudioActivated() }
            },
            onEnded: { [weak self] in
                Task { @MainActor in self?.onCallEnded() }
            },
            onFailed: { [weak self] message in
                Task { @MainActor in self?.finishWithError(message) }
            }
        )
    }

    // MARK: - Continuous test (no auto-stop; real-time FFT; user taps Stop)

    func startContinuousTest() {
        print("[LatencyTest] startContinuousTest() called, isContinuousRunning=\(isContinuousRunning), ble.isReady=\(ble.isReady)")
        guard !isContinuousRunning else { return }
        guard !isRunning else { return }
        guard ble.isReady else {
            errorMessage = "BLE not ready"
            return
        }
        errorMessage = nil
        statusMessage = "Starting…"
        isContinuousRunning = true
        isContinuousMode = true
        continuousAnalyzer.reset()
        ble.latencyTestEchoMode = true
        ble.latencyTestLoopbackOpusObserver = nil

        print("[LatencyTest] sending latency_test_mode ON (continuous)")
        ble.sendCommand("latency_test_mode", extra: ["enable": true], expectAck: true)
        print("[LatencyTest] preconnecting HFP before CallKit answer")
        ble.sendCommand("hfp_connect", expectAck: true)
        print("[LatencyTest] calling reportAndAnswerLatencyTestCall (continuous)")
        LatencyTestCallProvider.shared.reportAndAnswerLatencyTestCall(
            onAnswered: { [weak self] in
                Task { @MainActor in self?.onCallAnswered() }
            },
            onAudioActivated: { [weak self] in
                Task { @MainActor in self?.onAudioActivatedForContinuous() }
            },
            onEnded: { [weak self] in
                Task { @MainActor in self?.onCallEnded() }
            },
            onFailed: { [weak self] message in
                Task { @MainActor in self?.finishContinuousWithError(message) }
            }
        )
    }

    private func onAudioActivatedForContinuous() {
        print("[LatencyTest] onAudioActivatedForContinuous (provider didActivate audioSession)")
        statusMessage = "Waiting for SCO…"
        logCurrentAudioRoute(tag: "latency_continuous_didActivate_before_config")
        configureLatencyTestAudioSession()
        logCurrentAudioRoute(tag: "latency_continuous_didActivate_after_config")
        startPrimingAudioIO()
        print("[LatencyTest] subscribed for call_state=active (timeout 60s) [continuous]")

        Task { @MainActor [weak self] in
            for i in 1 ..< 4 {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.isContinuousRunning, self.scoWaitTimeoutTask != nil else { return }
                print("[LatencyTest] SCO wait: \(i * 15)s elapsed [continuous]...")
            }
        }

        ble.events
            .receive(on: DispatchQueue.main)
            .filter { event in
                if case .callState(let s) = event { return s == "active" }
                return false
            }
            .first()
            .sink { [weak self] _ in
                print("[LatencyTest] call_state=active -> onSCOReadyForContinuous")
                Task { @MainActor in self?.onSCOReadyForContinuous() }
            }
            .store(in: &cancellables)

        scoWaitTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            print("[LatencyTest] 60s timeout [continuous]")
            self.finishContinuousWithError("Timeout: SCO not established (call_state=active not received)")
        }
    }

    private func onSCOReadyForContinuous() {
        print("[LatencyTest] >>> onSCOReadyForContinuous (call_state=active received)")
        scoWaitTimeoutTask?.cancel()
        scoWaitTimeoutTask = nil
        cancellables.removeAll()

        statusMessage = "Starting latency encoder…"
        print("[LatencyTest] sending latency_test_start [continuous]")
        ble.sendCommand("latency_test_start", expectAck: true)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            teardownAudioIO()
            startContinuousPlayAndRecord()
        }
    }

    private func startContinuousPlayAndRecord() {
        print("[LatencyTest] startContinuousPlayAndRecord()")
        statusMessage = "Playing square wave & recording…"
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            finishContinuousWithError("Invalid format")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let continuousDuration: TimeInterval = 2.0
        let frameCount = AVAudioFrameCount(sampleRate * continuousDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            finishContinuousWithError("Buffer alloc failed")
            return
        }
        buffer.frameLength = frameCount
        let ptr = buffer.floatChannelData?[0]
        let count = Int(frameCount)
        guard let ptr, count > 0 else {
            finishContinuousWithError("Buffer channel nil")
            return
        }
        let samplesPerCycle = sampleRate / squareWaveHz
        for i in 0..<count {
            let phase = Double(i).truncatingRemainder(dividingBy: samplesPerCycle) / samplesPerCycle
            ptr[i] = phase < 0.5 ? 0.3 : -0.3
        }

        inputNode = engine.inputNode
        recordingTapInstalled = true
        let analyzer = continuousAnalyzer
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                if let channelData = buffer.floatChannelData?[0] {
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))
                    analyzer.push(samples: samples)
                }
            case .pcmFormatInt16:
                if let base = buffer.int16ChannelData?[0] {
                    let samples = Array(UnsafeBufferPointer(start: base, count: frames))
                    let scale: Float = 1.0 / 32768.0
                    let floats = samples.map { Float($0) * scale }
                    analyzer.push(samples: floats)
                }
            case .pcmFormatInt32:
                if let base = buffer.int32ChannelData?[0] {
                    let samples = Array(UnsafeBufferPointer(start: base, count: frames))
                    let scale: Float = 1.0 / 2147483648.0
                    let floats = samples.map { Float($0) * scale }
                    analyzer.push(samples: floats)
                }
            default:
                break
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finishContinuousWithError("Audio engine start failed: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.playerNode = player
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        if engine.isRunning {
            player.play()
        }
        print("[LatencyTest] continuous measurement engine running=\(engine.isRunning)")
    }

    func stopContinuousTest() {
        print("[LatencyTest] stopContinuousTest()")
        scoWaitTimeoutTask?.cancel()
        scoWaitTimeoutTask = nil
        cancellables.removeAll()
        if recordingTapInstalled, let input = inputNode {
            input.removeTap(onBus: 0)
            recordingTapInstalled = false
        }
        playerNode?.stop()
        engine?.stop()
        teardownAudioIO()
        continuousAnalyzer.stop()
        ble.latencyTestEchoMode = false
        ble.latencyTestLoopbackOpusObserver = nil
        ble.stopRateMonitorForLocalTeardown(reason: "latency_continuous_ended")
        ble.sendCommand("latency_test_stop", expectAck: false)
        ble.sendCommand("latency_test_mode", extra: ["enable": false], expectAck: false)
        ble.sendCommand("audio_stop", expectAck: false)
        LatencyTestCallProvider.shared.endLatencyTestCall()
        isContinuousRunning = false
        isContinuousMode = false
        statusMessage = "Stopped"
    }

    private func finishContinuousWithError(_ msg: String) {
        print("[LatencyTest] finishContinuousWithError: \(msg)")
        scoWaitTimeoutTask?.cancel()
        scoWaitTimeoutTask = nil
        cancellables.removeAll()
        errorMessage = msg
        statusMessage = "Error"
        if recordingTapInstalled, let input = inputNode {
            input.removeTap(onBus: 0)
            recordingTapInstalled = false
        }
        playerNode?.stop()
        engine?.stop()
        teardownAudioIO()
        continuousAnalyzer.stop()
        ble.latencyTestEchoMode = false
        ble.latencyTestLoopbackOpusObserver = nil
        ble.stopRateMonitorForLocalTeardown(reason: "latency_continuous_error")
        ble.sendCommand("latency_test_stop", expectAck: false)
        ble.sendCommand("latency_test_mode", extra: ["enable": false], expectAck: false)
        LatencyTestCallProvider.shared.endLatencyTestCall()
        isContinuousRunning = false
        isContinuousMode = false
    }

    private func onCallAnswered() {
        print("[LatencyTest] onCallAnswered (CXAnswerCallAction fulfilled)")
        statusMessage = "Connecting HFP…"
        // Fallback retry in case the preconnect was dropped or HFP had already torn down.
        ble.sendCommand("hfp_connect", expectAck: true)
    }

    /// Called from `provider(_:didActivate:)` — CallKit activated the audio session.
    /// Note: this fires as soon as CallKit activates audio, which may be BEFORE HFP SCO
    /// is fully established. We still need to wait for MCU's `call_state=active` which
    /// is only sent once SCO is connected and MCU transitions to IN_CALL.
    private func onAudioActivated() {
        print("[LatencyTest] onAudioActivated (provider didActivate audioSession)")
        statusMessage = "Waiting for SCO…"
        logCurrentAudioRoute(tag: "latency_didActivate_before_config")
        configureLatencyTestAudioSession()
        logCurrentAudioRoute(tag: "latency_didActivate_after_config")
        startPrimingAudioIO()
        print("[LatencyTest] subscribed for call_state=active (timeout 60s); any BLE call_state will log in [BLE][call_state]")

        // Progress log every 15s while waiting (helps diagnose "stuck waiting for SCO").
        Task { @MainActor [weak self] in
            for i in 1 ..< 4 {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.isRunning, self.scoWaitTimeoutTask != nil else { return }
                print("[LatencyTest] SCO wait: \(i * 15)s elapsed, still waiting for call_state=active...")
            }
        }

        // Wait for MCU to send call_state=active (means SCO connected + IN_CALL).
        ble.events
            .receive(on: DispatchQueue.main)
            .filter { event in
                if case .callState(let s) = event {
                    print("[LatencyTest] filter got call_state=\"\(s)\" -> \(s == "active" ? "MATCH" : "skip")")
                    return s == "active"
                }
                return false
            }
            .first()
            .sink { [weak self] _ in
                print("[LatencyTest] sink received call_state=active -> calling onSCOReady")
                Task { @MainActor in self?.onSCOReady() }
            }
            .store(in: &cancellables)

        // Safety timeout: 60 s for the entire HFP + SCO negotiation.
        scoWaitTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            print("[LatencyTest] 60s timeout: call_state=active never received")
            self.finishWithError("Timeout: SCO not established (call_state=active not received)")
        }
    }

    private func onSCOReady() {
        print("[LatencyTest] >>> onSCOReady (call_state=active received)")
        scoWaitTimeoutTask?.cancel()
        scoWaitTimeoutTask = nil
        cancellables.removeAll()

        statusMessage = "Starting latency encoder…"
        print("[LatencyTest] sending latency_test_start")
        ble.sendCommand("latency_test_start", expectAck: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for first BLE downlink Opus packet before measuring.
            // MCU may defer Opus start if SCO flash-disconnected; playing
            // before the encoder is running wastes the measurement window.
            let maxWaitSec = 15.0
            let pollInterval: UInt64 = 200_000_000 // 200ms
            let deadline = CFAbsoluteTimeGetCurrent() + maxWaitSec
            var gotData = !self.cachedLoopbackOpusPackets.isEmpty
            if !gotData {
                print("[LatencyTest] waiting for first BLE audio data (up to \(Int(maxWaitSec))s)…")
                statusMessage = "Waiting for BLE audio…"
            }
            while !gotData && CFAbsoluteTimeGetCurrent() < deadline && self.isRunning {
                try? await Task.sleep(nanoseconds: pollInterval)
                gotData = !self.cachedLoopbackOpusPackets.isEmpty
            }
            guard self.isRunning else { return }
            if gotData {
                print("[LatencyTest] first BLE audio data received, starting measurement")
            } else {
                print("[LatencyTest] WARNING: no BLE audio data within \(Int(maxWaitSec))s, starting measurement anyway")
            }
            teardownAudioIO()
            startPlayAndRecord()
        }
    }

    private func startPlayAndRecord() {
        print("[LatencyTest] startPlayAndRecord()")
        statusMessage = "Playing square wave & recording…"
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            finishWithError("Invalid format")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Buffer = testDuration seconds of square wave @ 16kHz.
        let frameCount = AVAudioFrameCount(sampleRate * testDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            finishWithError("Buffer alloc failed")
            return
        }
        buffer.frameLength = frameCount
        let ptr = buffer.floatChannelData?[0]
        let count = Int(frameCount)
        guard let ptr, count > 0 else {
            finishWithError("Buffer channel nil")
            return
        }
        let samplesPerCycle = sampleRate / squareWaveHz
        for i in 0..<count {
            let phase = Double(i).truncatingRemainder(dividingBy: samplesPerCycle) / samplesPerCycle
            ptr[i] = phase < 0.5 ? 0.3 : -0.3
        }
        cachePlaybackSamples(Array(UnsafeBufferPointer(start: ptr, count: count)))

        playStartTime = CFAbsoluteTimeGetCurrent()
        firstEdgeTime = nil
        inputFormatLogged = false

        // Record and detect first edge.
        // Pass nil so the tap uses the hardware's native format (avoids crash when
        // input node reports sampleRate=0 during HFP/VoiceChat session setup).
        inputNode = engine.inputNode
        recordingTapInstalled = true
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
            self?.processRecordedBuffer(buffer, hostTime: time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[LatencyTest] measurement engine start failed: \(error.localizedDescription)")
            finishWithError("Audio engine start failed: \(error.localizedDescription)")
            return
        }
        print("[LatencyTest] measurement engine running=\(engine.isRunning)")
        self.engine = engine
        self.playerNode = player

        player.scheduleBuffer(buffer, at: nil, options: [])
        if engine.isRunning {
            player.play()
        } else {
            finishWithError("Audio engine is not running")
            return
        }

        testTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(testDuration * 1_000_000_000))
            if !Task.isCancelled {
                stopTest()
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.isRunning else { return }
            let packets = self.cachedLoopbackOpusPackets
            guard packets.count >= 5 else { return }
            let avgSize = packets.reduce(0) { $0 + $1.payload.count } / packets.count
            if avgSize < 30 {
                print("[LatencyTest][DIAG] WARNING: avg BLE Opus packet size=\(avgSize)B (\(packets.count) pkts) — MCU likely encoding silence due to mSBC decode failure (BLE/SCO anchor collision?)")
            } else {
                print("[LatencyTest][DIAG] BLE Opus avg packet size=\(avgSize)B (\(packets.count) pkts) — looks healthy")
            }
        }
    }

    private func processRecordedBuffer(_ buffer: AVAudioPCMBuffer, hostTime: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
        if !inputFormatLogged {
            inputFormatLogged = true
            print("[LatencyTest] input tap format common=\(buffer.format.commonFormat.rawValue) sampleRate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved)")
        }
        let frames = Int(buffer.frameLength)

        func detectFirstEdge<S: BinaryInteger>(_ samples: UnsafePointer<S>?, scale: Float) -> Bool {
            guard let samples else { return false }
            for i in 0..<frames {
                let s = Float(Int64(samples[i])) / scale
                if abs(s) > 0.15 {
                    return true
                }
            }
            return false
        }

        let detected: Bool
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if let channelData = buffer.floatChannelData?[0] {
                cacheMicSamples(Array(UnsafeBufferPointer(start: channelData, count: frames)))
                detected = (0..<frames).contains { abs(channelData[$0]) > 0.15 }
            } else {
                detected = false
            }
        case .pcmFormatInt16:
            if let samples = buffer.int16ChannelData?[0] {
                cacheMicSamples(normalizeIntegerSamples(samples, count: frames, scale: 32768))
            }
            detected = detectFirstEdge(buffer.int16ChannelData?[0], scale: 32768)
        case .pcmFormatInt32:
            if let samples = buffer.int32ChannelData?[0] {
                cacheMicSamples(normalizeIntegerSamples(samples, count: frames, scale: 2147483648))
            }
            detected = detectFirstEdge(buffer.int32ChannelData?[0], scale: 2147483648)
        default:
            detected = false
        }

        guard detected else { return }
        let t = CFAbsoluteTimeGetCurrent()
        if firstEdgeTime == nil {
            firstEdgeTime = t
            Task { @MainActor in
                didDetectFirstEdge()
            }
        }
    }

    private func didDetectFirstEdge() {
        guard let tPlay = playStartTime, let tRec = firstEdgeTime else { return }
        let latencySec = tRec - tPlay
        measuredLatencyMs = latencySec * 1000
        print("[LatencyTest] first edge detected -> latency=\(Int(measuredLatencyMs ?? 0)) ms")
        statusMessage = "Completed"
        stopTest()
    }

    func stopTest() {
        scoWaitTimeoutTask?.cancel()
        scoWaitTimeoutTask = nil
        cancellables.removeAll()
        testTask?.cancel()
        testTask = nil
        if recordingTapInstalled, let input = inputNode {
            input.removeTap(onBus: 0)
            recordingTapInstalled = false
        }
        playerNode?.stop()
        engine?.stop()
        teardownAudioIO()
        ble.latencyTestEchoMode = false
        ble.latencyTestLoopbackOpusObserver = nil
        ble.stopRateMonitorForLocalTeardown(reason: "latency_test_ended")
        ble.sendCommand("latency_test_stop", expectAck: false)
        ble.sendCommand("latency_test_mode", extra: ["enable": false], expectAck: false)
        ble.sendCommand("audio_stop", expectAck: false)
        LatencyTestCallProvider.shared.endLatencyTestCall()
        buildWaveformTracesIfNeeded()
        isRunning = false
        if statusMessage.isEmpty {
            statusMessage = measuredLatencyMs != nil ? "Completed" : "Stopped"
        }
        if measuredLatencyMs == nil && playStartTime != nil && errorMessage == nil {
            let packets = cachedLoopbackOpusPackets
            let avgPktSize = packets.isEmpty ? 0 : packets.reduce(0) { $0 + $1.payload.count } / packets.count
            let micPeak = cachedMicSamples.reduce(Float.zero) { max($0, abs($1)) }
            errorMessage = "No first edge detected (check: BLE downlink, HFP route, or MCU SCO reconnect)"
            print("[LatencyTest] test ended without first edge; blePkts=\(packets.count) avgPktSize=\(avgPktSize)B micPeak=\(String(format: "%.4f", micPeak)) micSamples=\(cachedMicSamples.count)")
            if avgPktSize > 0 && avgPktSize < 30 {
                print("[LatencyTest] DIAGNOSIS: BLE Opus packets are tiny (\(avgPktSize)B avg) → MCU mSBC decode is failing (100%% rx errors). Root cause: BLE/SCO anchor collision. Fix: update MCU firmware with ble_service_nudge_conn_param() in latency_test_start.")
            }
        }
    }

    private func onCallEnded() {
        if isRunning {
            stopTest()
        } else if isContinuousRunning {
            stopContinuousTest()
        }
    }

    private func finishWithError(_ msg: String) {
        print("[LatencyTest] finishWithError: \(msg)")
        scoWaitTimeoutTask?.cancel()
        scoWaitTimeoutTask = nil
        cancellables.removeAll()
        errorMessage = msg
        statusMessage = "Error"
        ble.latencyTestEchoMode = false
        ble.latencyTestLoopbackOpusObserver = nil
        ble.stopRateMonitorForLocalTeardown(reason: "latency_test_error")
        ble.sendCommand("latency_test_stop", expectAck: false)
        ble.sendCommand("latency_test_mode", extra: ["enable": false], expectAck: false)
        LatencyTestCallProvider.shared.endLatencyTestCall()
        buildWaveformTracesIfNeeded()
        isRunning = false
    }

    private func configureLatencyTestAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            if let hfpInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfpInput)
                print("[LatencyTest][AudioRoute] preferredInput=bluetoothHFP name=\(hfpInput.portName)")
            } else {
                let inputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",") ?? ""
                print("[LatencyTest][AudioRoute] bluetoothHFP input unavailable availableInputs=[\(inputs)]")
            }
            try session.setActive(true)
        } catch {
            print("[LatencyTest][AudioRoute] configure failed: \(error.localizedDescription)")
        }
    }

    private func startPrimingAudioIO() {
        guard !primingAudioActive else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            print("[LatencyTest] priming skipped: invalid format")
            return
        }

        teardownAudioIO()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let ptr = buffer.floatChannelData?[0] else {
            print("[LatencyTest] priming skipped: silent buffer alloc failed")
            return
        }
        buffer.frameLength = frameCount
        let count = Int(frameCount)
        for i in 0..<count {
            ptr[i] = 0
        }

        inputNode = engine.inputNode
        recordingTapInstalled = true
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in
            // Keep HFP duplex I/O warm while we wait for SCO_CONNECTED/call_state=active.
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[LatencyTest] priming engine start failed: \(error.localizedDescription)")
            return
        }
        print("[LatencyTest] priming engine running=\(engine.isRunning)")
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        if engine.isRunning {
            player.play()
        }

        self.engine = engine
        self.playerNode = player
        primingAudioActive = true
        print("[LatencyTest] priming HFP audio I/O while waiting for SCO")
    }

    private func teardownAudioIO() {
        if recordingTapInstalled, let input = inputNode {
            input.removeTap(onBus: 0)
            recordingTapInstalled = false
        }
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        inputNode = nil
        primingAudioActive = false
    }

    private func resetCapturedData() {
        analysisTask?.cancel()
        analysisTask = nil
        cachedPlaybackSamples.removeAll(keepingCapacity: false)
        cachedMicSamples.removeAll(keepingCapacity: false)
        cachedLoopbackOpusPackets.removeAll(keepingCapacity: false)
    }

    private func cachePlaybackSamples(_ samples: [Float]) {
        cachedPlaybackSamples = samples
    }

    private func cacheMicSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let maxSamples = 16000 * 8
        let remaining = max(0, maxSamples - cachedMicSamples.count)
        guard remaining > 0 else { return }
        cachedMicSamples.append(contentsOf: samples.prefix(remaining))
    }

    private func cacheLoopbackOpusPacket(_ packet: Data, receivedAt: CFAbsoluteTime) {
        let maxPackets = 512
        guard cachedLoopbackOpusPackets.count < maxPackets else { return }
        cachedLoopbackOpusPackets.append(.init(payload: packet, receivedAt: receivedAt))
    }

    private func normalizeIntegerSamples<S: BinaryInteger>(_ samples: UnsafePointer<S>, count: Int, scale: Float) -> [Float] {
        guard count > 0 else { return [] }
        var normalized: [Float] = []
        normalized.reserveCapacity(count)
        for i in 0..<count {
            normalized.append(Float(Int64(samples[i])) / scale)
        }
        return normalized
    }

    private func buildWaveformTracesIfNeeded() {
        analysisTask?.cancel()
        let playbackSamples = cachedPlaybackSamples
        let micSamples = cachedMicSamples
        let loopbackPackets = cachedLoopbackOpusPackets
        let measuredLatencyMs = self.measuredLatencyMs
        let playStartTime = self.playStartTime
        guard !playbackSamples.isEmpty || !micSamples.isEmpty || !loopbackPackets.isEmpty else { return }

        analysisTask = Task.detached(priority: .utility) { [sampleRate, squareWaveHz] in
            let samplesPerCycle = max(1, Int(sampleRate / squareWaveHz))
            let desiredCount = max(samplesPerCycle * 16, 512)
            let bleSamples = Self.decodeLoopbackOpusPackets(loopbackPackets, sampleRate: Int32(sampleRate))
            let stageMeasurements = Self.makeStageMeasurements(
                loopbackPackets: loopbackPackets,
                sampleRate: sampleRate,
                playStartTime: playStartTime,
                totalLatencyMs: measuredLatencyMs
            )
            let playbackToBLEMs = stageMeasurements.first(where: { $0.id == "playback_to_ble" })?.milliseconds
            let totalLatencyMs = stageMeasurements.first(where: { $0.id == "total" })?.milliseconds
            let traces = [
                Self.makeTimelineTrace(
                    kind: .playback,
                    samples: playbackSamples,
                    desiredCount: desiredCount,
                    eventTimeMs: 0,
                    sampleRate: sampleRate
                ),
                Self.makeTimelineTrace(
                    kind: .bleLoopback,
                    samples: bleSamples,
                    desiredCount: desiredCount,
                    eventTimeMs: playbackToBLEMs,
                    sampleRate: sampleRate
                ),
                Self.makeTimelineTrace(
                    kind: .microphone,
                    samples: micSamples,
                    desiredCount: desiredCount,
                    eventTimeMs: totalLatencyMs,
                    sampleRate: sampleRate
                )
            ].compactMap { $0 }

            await MainActor.run {
                self.stageMeasurements = stageMeasurements
                self.waveformTraces = traces
                if measuredLatencyMs != nil {
                    self.statusMessage = "Completed"
                }
            }
        }
    }

    nonisolated private static func decodeLoopbackOpusPackets(_ packets: [LatencyLoopbackPacket], sampleRate: Int32) -> [Float] {
        guard let decoder = createOpusDecoder(sampleRate: sampleRate, channels: 1) else { return [] }
        let frameSize: Int32 = 960 // 60 ms @ 16 kHz
        let maxSamples = Int(sampleRate) * 8
        var decoded: [Float] = []
        decoded.reserveCapacity(min(maxSamples, packets.count * Int(frameSize)))
        for packet in packets {
            guard let pcm = decoder.decode(opus: packet.payload, frameSize: frameSize) else { continue }
            let packetSamples = pcm.withUnsafeBytes { rawBuffer -> [Float] in
                guard let base = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return [] }
                let count = rawBuffer.count / MemoryLayout<Int16>.size
                var result: [Float] = []
                result.reserveCapacity(count)
                for i in 0..<count {
                    result.append(Float(base[i]) / 32768)
                }
                return result
            }
            let remaining = max(0, maxSamples - decoded.count)
            guard remaining > 0 else { break }
            decoded.append(contentsOf: packetSamples.prefix(remaining))
        }
        return decoded
    }

    nonisolated private static func makeTimelineTrace(
        kind: LatencyWaveformKind,
        samples: [Float],
        desiredCount: Int,
        eventTimeMs: Double?,
        sampleRate: Double
    ) -> LatencyWaveformTrace? {
        guard !samples.isEmpty else { return nil }
        let index = firstInterestingIndex(in: samples) ?? 0
        let leading = min(index, desiredCount / 6)
        let start = max(0, index - leading)
        let end = min(samples.count, start + desiredCount)
        let slice = Array(samples[start..<end])
        let startTimeMs: Double
        if let eventTimeMs {
            startTimeMs = max(0, eventTimeMs - Double(index - start) * 1000 / sampleRate)
        } else {
            startTimeMs = Double(start) * 1000 / sampleRate
        }
        return LatencyWaveformTrace(
            kind: kind,
            samples: normalizeForDisplay(slice),
            startTimeMs: startTimeMs,
            sampleRate: sampleRate,
            eventTimeMs: eventTimeMs
        )
    }

    nonisolated private static func firstInterestingIndex(in samples: [Float]) -> Int? {
        for i in 0..<samples.count where abs(samples[i]) > 0.08 {
            return i
        }
        var bestIndex: Int?
        var bestMagnitude: Float = 0
        for i in 0..<samples.count {
            let mag = abs(samples[i])
            if mag > bestMagnitude {
                bestMagnitude = mag
                bestIndex = i
            }
        }
        return bestIndex
    }

    nonisolated private static func normalizeForDisplay(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        guard peak > 0.0001 else { return samples }
        return samples.map { $0 / peak }
    }

    nonisolated private static func makeStageMeasurements(
        loopbackPackets: [LatencyLoopbackPacket],
        sampleRate: Double,
        playStartTime: CFAbsoluteTime?,
        totalLatencyMs: Double?
    ) -> [LatencyStageMeasurement] {
        let playbackToBLEMs = estimatePlaybackToBLEMs(
            loopbackPackets: loopbackPackets,
            sampleRate: Int32(sampleRate),
            playStartTime: playStartTime
        )
        let bleToRecordingMs = totalLatencyMs.flatMap { total in
            playbackToBLEMs.map { max(0, total - $0) }
        }
        let totalMs = totalLatencyMs

        return [
            .init(id: "playback_to_ble", milliseconds: playbackToBLEMs),
            .init(id: "ble_to_recording", milliseconds: bleToRecordingMs),
            .init(id: "total", milliseconds: totalMs)
        ]
    }

    nonisolated private static func estimatePlaybackToBLEMs(
        loopbackPackets: [LatencyLoopbackPacket],
        sampleRate: Int32,
        playStartTime: CFAbsoluteTime?
    ) -> Double? {
        guard let playStartTime, let decoder = createOpusDecoder(sampleRate: sampleRate, channels: 1) else { return nil }
        let frameSize: Int32 = 960 // 60 ms @ 16 kHz
        let minimumPlausibleLatencyMs = 30.0

        for packet in loopbackPackets {
            guard packet.receivedAt >= playStartTime else { continue }
            guard let pcm = decoder.decode(opus: packet.payload, frameSize: frameSize) else { continue }
            let packetSamples = pcm.withUnsafeBytes { rawBuffer -> [Float] in
                guard let base = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return [] }
                let count = rawBuffer.count / MemoryLayout<Int16>.size
                var result: [Float] = []
                result.reserveCapacity(count)
                for i in 0..<count {
                    result.append(Float(base[i]) / 32768)
                }
                return result
            }
            guard let edgeIndex = firstSquareWaveEdgeIndex(in: packetSamples) else { continue }

            let decodedDurationMs = Double(packetSamples.count) * 1000 / Double(sampleRate)
            let edgeOffsetMs = Double(edgeIndex) * 1000 / Double(sampleRate)
            let estimatedEventTime = packet.receivedAt - (decodedDurationMs - edgeOffsetMs) / 1000
            let estimatedLatencyMs = max(0, (estimatedEventTime - playStartTime) * 1000)
            guard estimatedLatencyMs >= minimumPlausibleLatencyMs else { continue }
            return estimatedLatencyMs
        }

        return nil
    }

    nonisolated private static func firstSquareWaveEdgeIndex(in samples: [Float]) -> Int? {
        guard samples.count >= 40 else { return nil }
        let amplitudeThreshold: Float = 0.12
        let window = 8
        let halfCycleMin = 8
        let halfCycleMax = 24

        func mean(from start: Int, length: Int) -> Float {
            let end = min(samples.count, start + length)
            guard start < end else { return 0 }
            let sum = samples[start..<end].reduce(Float.zero, +)
            return sum / Float(end - start)
        }

        for i in 0..<(samples.count - window * 2) {
            let left = mean(from: i, length: window)
            let right = mean(from: i + window, length: window)
            guard abs(left) > amplitudeThreshold, abs(right) > amplitudeThreshold, left * right < 0 else { continue }

            let searchStart = i + halfCycleMin
            let searchEnd = min(samples.count - window * 2, i + halfCycleMax)
            for j in searchStart..<searchEnd {
                let nextLeft = mean(from: j, length: window)
                let nextRight = mean(from: j + window, length: window)
                if abs(nextLeft) > amplitudeThreshold, abs(nextRight) > amplitudeThreshold, nextLeft * nextRight < 0 {
                    return i + window
                }
            }
        }

        return nil
    }

    private func logCurrentAudioRoute(tag: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        print("[LatencyTest][AudioRoute][\(tag)] category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=[\(outputs)] inputs=[\(inputs)]")
    }
}

//
//  CallToneService.swift
//  CallMate
//
//  Procedural call tones (no bundled audio assets).
//

import AVFoundation

@MainActor
final class CallToneService {
    static let shared = CallToneService()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var waitingLoopScheduled: Bool = false
    private var ringbackLoopSamples: [Float]?
    private var connectedToneSamples: [Float]?
    private var prewarmTask: Task<Void, Never>?

    private let sampleRate: Double = 44_100
    private lazy var monoFormat: AVAudioFormat = {
        // Non-interleaved Float32, convenient for procedural synthesis
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }()

    private init() {}

    func prewarmToneAssetsIfNeeded() {
        if ringbackLoopSamples != nil, connectedToneSamples != nil { return }
        if prewarmTask != nil { return }
        let startedAt = Date()
        print("[LAT][Tone] t=\(CallSessionController.logDateFormatter.string(from: startedAt)) event=prewarm_begin")
        prewarmTask = Task.detached(priority: .utility) { [sampleRate] in
            let ringback = Self.buildRingbackLoopSamples(sampleRate: sampleRate)
            let connected = Self.buildBeepSamples(sampleRate: sampleRate, freqHz: 1_000, durationSec: 0.14, amp: 0.18)
            await MainActor.run {
                let service = CallToneService.shared
                service.ringbackLoopSamples = ringback
                service.connectedToneSamples = connected
                service.prewarmTask = nil
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                print("[LAT][Tone] t=\(CallSessionController.logDateFormatter.string(from: Date())) event=prewarm_end duration=\(durationMs)ms")
            }
        }
    }

    func startWaitingTone() {
        if waitingLoopScheduled { return }
        let startedAt = Date()
        ensureEngineReady()
        guard let player else { return }

        let afterEngine = Date()
        let buffer = makeRingbackLoopBuffer()
        let afterBuffer = Date()
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        player.play()
        waitingLoopScheduled = true
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let engineMs = Int(afterEngine.timeIntervalSince(startedAt) * 1000)
        let bufferMs = Int(afterBuffer.timeIntervalSince(afterEngine) * 1000)
        let scheduleMs = Int(Date().timeIntervalSince(afterBuffer) * 1000)
        let cacheState = ringbackLoopSamples == nil ? "miss" : "hit"
        print("[LAT][Tone] t=\(CallSessionController.logDateFormatter.string(from: Date())) event=start_waiting_tone engine=\(engineMs)ms buffer=\(bufferMs)ms schedule=\(scheduleMs)ms total=\(totalMs)ms cache=\(cacheState)")
    }

    func stopWaitingTone() {
        waitingLoopScheduled = false
        // Fully tear down the tone engine to avoid competing with
        // realtime duplex voice-processing pipelines.
        shutdown()
    }

    func playConnectedTone() {
        prewarmToneAssetsIfNeeded()
        ensureEngineReady()
        guard let player else { return }

        let buffer = makeBeepBuffer(freqHz: 1_000, durationSec: 0.14, amp: 0.18)
        player.scheduleBuffer(buffer, at: nil, options: [])
        if !player.isPlaying {
            player.play()
        }
    }

    func shutdown() {
        waitingLoopScheduled = false
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
    }

    // MARK: - Engine

    private func ensureEngineReady() {
        if engine != nil, player != nil { return }

        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: monoFormat)

        engine = e
        player = p

        do {
            // Do not override AudioService's session choice; just activate if needed.
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("[Tone] AVAudioSession activate failed: \(error.localizedDescription)")
        }

        do {
            try e.start()
        } catch {
            print("[Tone] engine start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Synthesis

    /// Standard "ringback" style: 2s tone (dual freq) + 4s silence, loop.
    private func makeRingbackLoopBuffer() -> AVAudioPCMBuffer {
        if let samples = ringbackLoopSamples {
            return makeBuffer(from: samples)
        }
        let toneSec: Double = 2.0
        let silenceSec: Double = 4.0
        let totalSec = toneSec + silenceSec

        let totalFrames = AVAudioFrameCount(sampleRate * totalSec)
        let toneFrames = Int(sampleRate * toneSec)

        let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames

        guard let ch0 = buffer.floatChannelData?[0] else { return buffer }

        let f1: Double = 440
        let f2: Double = 480
        let amp: Float = 0.12

        // Fade to avoid clicks.
        let fadeFrames = max(1, Int(sampleRate * 0.01)) // 10ms

        for i in 0..<Int(totalFrames) {
            if i < toneFrames {
                let t = Double(i) / sampleRate
                var s = sin(2 * .pi * f1 * t) + sin(2 * .pi * f2 * t)
                s *= 0.5
                var v = Float(s) * amp

                // fade in/out within the 2s tone segment
                if i < fadeFrames {
                    v *= Float(i) / Float(fadeFrames)
                } else if i > toneFrames - fadeFrames {
                    v *= Float(toneFrames - i) / Float(fadeFrames)
                }
                ch0[i] = v
            } else {
                ch0[i] = 0
            }
        }
        return buffer
    }

    private func makeBeepBuffer(freqHz: Double, durationSec: Double, amp: Float) -> AVAudioPCMBuffer {
        if freqHz == 1_000, durationSec == 0.14, amp == 0.18, let samples = connectedToneSamples {
            return makeBuffer(from: samples)
        }
        let frames = AVAudioFrameCount(sampleRate * durationSec)
        let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames)!
        buffer.frameLength = frames

        guard let ch0 = buffer.floatChannelData?[0] else { return buffer }

        let fadeFrames = max(1, Int(sampleRate * 0.01)) // 10ms
        let n = Int(frames)

        for i in 0..<n {
            let t = Double(i) / sampleRate
            var v = Float(sin(2 * .pi * freqHz * t)) * amp
            if i < fadeFrames {
                v *= Float(i) / Float(fadeFrames)
            } else if i > n - fadeFrames {
                v *= Float(n - i) / Float(fadeFrames)
            }
            ch0[i] = v
        }
        return buffer
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(samples.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                channelData.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    nonisolated private static func buildRingbackLoopSamples(sampleRate: Double) -> [Float] {
        let toneSec: Double = 2.0
        let silenceSec: Double = 4.0
        let totalFrames = Int(sampleRate * (toneSec + silenceSec))
        let toneFrames = Int(sampleRate * toneSec)
        let f1: Double = 440
        let f2: Double = 480
        let amp: Float = 0.12
        let fadeFrames = max(1, Int(sampleRate * 0.01))
        var samples = [Float](repeating: 0, count: totalFrames)

        for i in 0..<toneFrames {
            let t = Double(i) / sampleRate
            var s = sin(2 * .pi * f1 * t) + sin(2 * .pi * f2 * t)
            s *= 0.5
            var v = Float(s) * amp
            if i < fadeFrames {
                v *= Float(i) / Float(fadeFrames)
            } else if i > toneFrames - fadeFrames {
                v *= Float(toneFrames - i) / Float(fadeFrames)
            }
            samples[i] = v
        }
        return samples
    }

    nonisolated private static func buildBeepSamples(
        sampleRate: Double,
        freqHz: Double,
        durationSec: Double,
        amp: Float
    ) -> [Float] {
        let frameCount = Int(sampleRate * durationSec)
        let fadeFrames = max(1, Int(sampleRate * 0.01))
        var samples = [Float](repeating: 0, count: frameCount)

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            var v = Float(sin(2 * .pi * freqHz * t)) * amp
            if i < fadeFrames {
                v *= Float(i) / Float(fadeFrames)
            } else if i > frameCount - fadeFrames {
                v *= Float(frameCount - i) / Float(fadeFrames)
            }
            samples[i] = v
        }
        return samples
    }
}


//
//  ContinuousLatencyAnalyzer.swift
//  CallMate
//
//  Real-time FFT on local recording for continuous latency test.
//  Uses vDSP/Accelerate only. Ring buffer + background FFT → current frequency + waveform for UI.
//

import Accelerate
import Combine
import Foundation

private let fftSize = 2048
private let log2n: vDSP_Length = 11 // 2^11 = 2048
private let halfFFT = fftSize / 2

/// Thread-safe: push() may be called from audio tap; results are published on main.
final class ContinuousLatencyAnalyzer: ObservableObject {
    /// Current dominant frequency (Hz), nil until first FFT result.
    @Published private(set) var currentFrequencyHz: Double?
    /// Last waveform slice for UI (e.g. 256 points), normalized.
    @Published private(set) var lastWaveformSamples: [Float] = []
    /// Last magnitude spectrum slice for UI (0–1 kHz range), optional.
    @Published private(set) var lastSpectrumMagnitudes: [Float] = []

    private let sampleRate: Double
    private let fftQueue = DispatchQueue(label: "latency.continuous.fft", qos: .userInitiated)
    private var ringBuffer: [Float] = []
    private let ringCapacity: Int
    private var isStopped = false
    /// Throttle UI updates to at most every 100ms so drawing never stresses main thread.
    private var lastPublishTime: CFAbsoluteTime = 0
    private let publishInterval: CFAbsoluteTime = 0.1

    /// Bin range for 200–800 Hz at 16 kHz: k = f * 2048/16000 → 26..<103
    private var binLow: Int { max(0, Int(200.0 * Double(fftSize) / sampleRate)) }
    private var binHigh: Int { min(halfFFT + 1, Int(800.0 * Double(fftSize) / sampleRate) + 2) }

    init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
        self.ringCapacity = fftSize * 2
        self.ringBuffer.reserveCapacity(ringCapacity)
    }

    /// Call from audio tap only; copies samples into ring buffer. No FFT here.
    func push(samples: [Float]) {
        guard !isStopped else { return }
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        for s in samples {
            if ringBuffer.count >= ringCapacity {
                ringBuffer.removeFirst()
            }
            ringBuffer.append(s)
        }
        tryRunFFT()
    }

    /// Optional: push Int16 from tap (converts to Float and pushes).
    func push(int16Samples: UnsafeBufferPointer<Int16>) {
        guard !isStopped else { return }
        let scale: Float = 1.0 / 32768.0
        var floats: [Float] = []
        floats.reserveCapacity(int16Samples.count)
        for i in 0..<int16Samples.count {
            floats.append(Float(int16Samples[i]) * scale)
        }
        push(samples: floats)
    }

    func reset() {
        objc_sync_enter(self)
        ringBuffer.removeAll(keepingCapacity: true)
        objc_sync_exit(self)
        isStopped = false
        lastPublishTime = 0
        DispatchQueue.main.async { [weak self] in
            self?.currentFrequencyHz = nil
            self?.lastWaveformSamples = []
            self?.lastSpectrumMagnitudes = []
        }
    }

    func stop() {
        isStopped = true
    }

    /// Call while holding lock; runs FFT on fftQueue if we have enough samples.
    private func tryRunFFT() {
        let copy: [Float]
        if ringBuffer.count >= fftSize {
            copy = Array(ringBuffer.prefix(fftSize))
            ringBuffer.removeFirst(fftSize)
        } else {
            return
        }
        fftQueue.async { [weak self] in
            self?.runFFT(samples: copy)
        }
    }

    /// Runs on fftQueue. Uses vDSP for real FFT, then finds peak in 200–800 Hz.
    private func runFFT(samples: [Float]) {
        guard samples.count == fftSize else { return }

        // Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&windowed, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, windowed, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack for real FFT: split complex, real input → realp = even indices, imagp = odd
        var realp = [Float](repeating: 0, count: halfFFT + 1)
        var imagp = [Float](repeating: 0, count: halfFFT + 1)
        for i in 0..<halfFFT {
            realp[i] = windowed[2 * i]
            imagp[i] = windowed[2 * i + 1]
        }

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        realp.withUnsafeMutableBufferPointer { r in
            imagp.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        // Magnitude: bins 0..<halfFFT+1 (realp, imagp now hold FFT output)
        var magnitudes = [Float](repeating: 0, count: halfFFT + 1)
        for k in 0...(halfFFT) {
            let re = realp[k]
            let im = imagp[k]
            magnitudes[k] = sqrt(re * re + im * im)
        }

        // Peak in 200–800 Hz
        let lo = binLow
        let hi = min(binHigh, magnitudes.count)
        var peakBin = lo
        var peakVal: Float = 0
        for k in lo..<hi {
            if magnitudes[k] > peakVal {
                peakVal = magnitudes[k]
                peakBin = k
            }
        }

        // Parabolic interpolation for fractional bin
        var freqHz = Double(peakBin) * sampleRate / Double(fftSize)
        if peakBin > 0, peakBin < halfFFT, peakVal > 0 {
            let y0 = magnitudes[peakBin - 1]
            let y1 = magnitudes[peakBin]
            let y2 = magnitudes[peakBin + 1]
            let denom = y0 - 2 * y1 + y2
            if abs(denom) > 1e-6 {
                let delta = 0.5 * (y0 - y2) / denom
                freqHz = Double(peakBin) + Double(delta)
                freqHz *= sampleRate / Double(fftSize)
            }
        }

        // Downsample waveform for UI (256 points from 2048)
        let waveformPoints = 256
        var waveform: [Float] = []
        waveform.reserveCapacity(waveformPoints)
        let step = Double(samples.count - 1) / Double(waveformPoints - 1)
        for i in 0..<waveformPoints {
            let idx = min(Int(step * Double(i)), samples.count - 1)
            waveform.append(samples[idx])
        }
        let peak = waveform.map { abs($0) }.max() ?? 0.0001
        if peak > 0.0001 {
            waveform = waveform.map { $0 / peak }
        }

        // Spectrum for 0–~1 kHz: first 65 bins (0 to 1000 Hz)
        let spectrumCount = min(65, magnitudes.count)
        let spectrum = Array(magnitudes.prefix(spectrumCount))
        let specMax = spectrum.max() ?? 0.0001
        let spectrumNorm = specMax > 0 ? spectrum.map { $0 / specMax } : spectrum

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - self.lastPublishTime
            if self.lastPublishTime == 0 || elapsed >= self.publishInterval {
                self.lastPublishTime = now
                self.currentFrequencyHz = freqHz
                self.lastWaveformSamples = waveform
                self.lastSpectrumMagnitudes = spectrumNorm
            }
        }
    }
}

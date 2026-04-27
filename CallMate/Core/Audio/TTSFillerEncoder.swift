//
//  TTSFillerEncoder.swift
//  CallMate
//
//  Offline pipeline for turning a server-provided filler mp3 into an mSBC byte
//  stream ready to be flashed to the MCU.
//
//    mp3 (24 kHz mono, CBR 160 kbps, ~0.7–1.2 s)
//      → AVAudioFile.read → Float32 PCM at source rate
//      → manual linear-interpolation resample → 16 kHz mono Float32
//      → manual clamp → Int16 (120 samples / 7.5 ms per mSBC frame)
//      → MSBCEncoder (libsbc) → 57 bytes per SBC frame, concatenated
//      → Data (size % 57 == 0)
//
//  AVAudioConverter used to sit between steps 2–3 but was removed after
//  reproducible `status == .error` / nil-underlying-error failures on the
//  server's 64 kbps + ID3v2.4 mp3 batch (see `encodeLocalMP3` comment for
//  the full story). Pure Swift resample keeps this hot path deterministic.
//
//  The produced bytes are *pure* SBC frames — the MCU adds the 2-byte H2 header
//  when injecting them into HFP eSCO TX. See docs/tts-filler-low-latency.md §5.2.
//

@preconcurrency import AVFoundation
import Foundation

enum TTSFillerEncoderError: Error, CustomStringConvertible {
    case downloadFailed(URLError?)
    case httpStatus(Int)
    case openAudioFile(underlying: Error)
    case converterInit
    case converterFailed(underlying: Error)
    case encoderFailed
    case emptyOutput

    var description: String {
        switch self {
        case let .downloadFailed(err):
            return "TTSFillerEncoder: download failed \(err?.localizedDescription ?? "unknown")"
        case let .httpStatus(code):
            return "TTSFillerEncoder: HTTP \(code)"
        case let .openAudioFile(underlying):
            return "TTSFillerEncoder: open audio file failed \(underlying)"
        case .converterInit:
            return "TTSFillerEncoder: could not build AVAudioConverter"
        case let .converterFailed(underlying):
            return "TTSFillerEncoder: AVAudioConverter failed \(underlying)"
        case .encoderFailed:
            return "TTSFillerEncoder: mSBC encoder returned nil"
        case .emptyOutput:
            return "TTSFillerEncoder: produced 0 mSBC frames"
        }
    }
}

/// Immutable result of a single-filler encode.
struct TTSFillerEncodedAsset: Sendable, Equatable {
    let fillerId: String
    /// Concatenated SBC frames, each 57 B. `frames == data.count / 57`.
    let data: Data
    let frames: Int
    let crc32: UInt32
    /// Approximate playback duration on the MCU (each frame is 7.5 ms of 16 kHz mono).
    var durationMs: Int { frames * 15 / 2 }
}

/// Pure encode/transport helper. Stateless; safe to call from any actor.
enum TTSFillerEncoder {

    /// mSBC parameters (constants per BT HFP spec). Mirrors `MSBCCodec.swift`.
    static let msbcFrameBytes: Int = 57
    static let msbcSamplesPerFrame: Int = 120
    static let targetSampleRate: Double = 16000

    /// Max bytes any single filler may produce. Server-side inputs are 0.7–1.3 s; we
    /// cap at ~3 s for safety so a rogue long mp3 can't gobble FlashDB. 3 s * 16 kHz
    /// / 120 samples * 57 B ≈ 22 KB.
    static let maxEncodedBytes: Int = 32 * 1024

    /// Download the mp3, run the mp3→PCM→mSBC pipeline, return bytes + metadata.
    static func encode(item: TTSFillerItem) async throws -> TTSFillerEncodedAsset {
        let tmpURL = try await downloadToTemporary(url: item.audioURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let msbcData = try encodeLocalMP3(at: tmpURL)
        let frames = msbcData.count / msbcFrameBytes
        guard frames > 0 else { throw TTSFillerEncoderError.emptyOutput }
        let crc = CRC32MPEG2.checksum(data: msbcData)
        print("[TTSFillers][encode] id=\(item.fillerId) frames=\(frames) bytes=\(msbcData.count) crc32=0x\(String(crc, radix: 16))")
        return TTSFillerEncodedAsset(
            fillerId: item.fillerId,
            data: msbcData,
            frames: frames,
            crc32: crc
        )
    }

    /// Encode a local audio file (mp3/wav/m4a — anything AVAudioFile accepts).
    /// Public so offline unit/manual tests can point it at a pre-downloaded file.
    ///
    /// Pipeline:
    ///   1. AVAudioFile.read → Float32 PCM at source rate (system mp3 decoder)
    ///   2. Manual linear-interpolation resample → 16 kHz mono Float32
    ///   3. Manual clamp → Int16
    ///   4. MSBCEncoder → 57 B SBC frames
    ///
    /// Step 2/3 used to go through `AVAudioConverter`, but the system converter
    /// reproducibly fails with `status == .error` and a nil underlying error on
    /// the server's 64 kbps + ID3v2.4 mp3 batch (even for plain rate-only Float32
    /// → Float32 conversions). The failure is non-deterministic across runs and
    /// iOS versions. We bypass it entirely — a 3:2 linear downsample of
    /// sub-4 kHz filler speech is inaudibly clean and leaves no system black box
    /// in the hot path.
    static func encodeLocalMP3(at url: URL) throws -> Data {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TTSFillerEncoderError.openAudioFile(underlying: error)
        }

        let sourceFormat = file.processingFormat
        print("[TTSFillers][encode] open file=\(url.lastPathComponent) src=\(sourceFormat) fileLen=\(file.length)")

        // 1. Read the whole mp3 into one Float32 buffer. Filler audios are
        //    < 1.5 s @ 24 kHz mono ≈ 36 kB of Float32 — trivially small.
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else {
            throw TTSFillerEncoderError.emptyOutput
        }
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalFrames) else {
            throw TTSFillerEncoderError.converterInit
        }
        do {
            try file.read(into: srcBuffer, frameCount: totalFrames)
        } catch {
            throw TTSFillerEncoderError.converterFailed(underlying: error)
        }
        let srcFrames = Int(srcBuffer.frameLength)
        guard srcFrames > 0 else {
            throw TTSFillerEncoderError.emptyOutput
        }

        // Pull out channel 0 as `[Float]`. mp3 via AVAudioFile always decodes
        // to Float32; for `channels > 1`, we downmix to mono by averaging.
        let srcFloat = extractMonoFloat(buffer: srcBuffer, frames: srcFrames)

        // 2. Resample to target rate via linear interpolation.
        let srcRate = sourceFormat.sampleRate
        let dstRate = targetSampleRate
        let resampled = linearResample(srcFloat, srcRate: srcRate, dstRate: dstRate)
        guard !resampled.isEmpty else {
            throw TTSFillerEncoderError.emptyOutput
        }

        // 3. Float → Int16 clamp.
        var pcm16 = [Int16]()
        pcm16.reserveCapacity(resampled.count)
        for s in resampled {
            let v = s * 32768.0
            if v >= 32767 {
                pcm16.append(Int16.max)
            } else if v <= -32768 {
                pcm16.append(Int16.min)
            } else {
                pcm16.append(Int16(v.rounded()))
            }
        }

        // Trim trailing samples that don't fill a whole 7.5 ms SBC frame.
        let extra = pcm16.count % msbcSamplesPerFrame
        if extra > 0 { pcm16.removeLast(extra) }
        print("[TTSFillers][encode] srcFrames=\(srcFrames) srcRate=\(srcRate) resampled=\(resampled.count) pcm16=\(pcm16.count)")

        guard !pcm16.isEmpty else {
            throw TTSFillerEncoderError.emptyOutput
        }

        let encoder = MSBCEncoder()
        guard let encoded = encoder.encode(pcm16kMonoInt16: pcm16) else {
            throw TTSFillerEncoderError.encoderFailed
        }
        guard encoded.count <= maxEncodedBytes else {
            print("[TTSFillers][encode] produced bytes=\(encoded.count) > cap=\(maxEncodedBytes), truncating")
            return encoded.prefix(maxEncodedBytes - (maxEncodedBytes % msbcFrameBytes))
        }
        return encoded
    }

    // MARK: - Internals

    /// Pull Float32 samples out of an AVAudioPCMBuffer as a plain `[Float]`,
    /// downmixing to mono if the source has > 1 channel.
    ///
    /// We always look at Float32 data because `AVAudioFile.processingFormat` for
    /// mp3/aac inputs on iOS is always non-interleaved Float32.
    private static func extractMonoFloat(buffer: AVAudioPCMBuffer, frames: Int) -> [Float] {
        guard frames > 0, let floatChannels = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: frames)
        if channelCount == 1 {
            let ch = floatChannels[0]
            for i in 0..<frames { out[i] = ch[i] }
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount {
                    sum += floatChannels[c][i]
                }
                out[i] = sum / Float(channelCount)
            }
        }
        return out
    }

    /// Linear-interpolation resampler Float32 → Float32.
    ///
    /// Adequate for filler speech (energy concentrated below 4 kHz). For the 3:2
    /// 24 kHz→16 kHz case the inaudible aliasing is acceptable; if in the future
    /// the server ships a lot more high-frequency content, swap this for a
    /// proper polyphase resampler (e.g. AudioKit's Accelerate-based `vDSP_desamp`).
    ///
    /// `src` at `srcRate` Hz, return at `dstRate` Hz. Returns `src` unchanged
    /// when the rates match.
    private static func linearResample(_ src: [Float], srcRate: Double, dstRate: Double) -> [Float] {
        guard srcRate > 0, dstRate > 0, !src.isEmpty else { return [] }
        if abs(srcRate - dstRate) < 0.5 { return src }
        let ratio = srcRate / dstRate
        let srcCount = src.count
        let outCount = max(1, Int(Double(srcCount) / ratio))
        var out = [Float](); out.reserveCapacity(outCount)
        for j in 0..<outCount {
            let x = Double(j) * ratio
            let i0 = Int(x)
            if i0 >= srcCount - 1 {
                out.append(src[srcCount - 1])
                continue
            }
            let i1 = i0 + 1
            let frac = Float(x - Double(i0))
            out.append(src[i0] * (1 - frac) + src[i1] * frac)
        }
        return out
    }

    private static func downloadToTemporary(url: URL) async throws -> URL {
        let (tmpSrc, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmpSrc)
            throw TTSFillerEncoderError.httpStatus(http.statusCode)
        }
        // URLSession deletes the tmp file when the async call returns; move it ourselves.
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("filler-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mp3" : url.pathExtension)")
        try FileManager.default.moveItem(at: tmpSrc, to: dst)
        return dst
    }
}

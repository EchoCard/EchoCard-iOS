//
//  MSBCCodec.swift
//  CallMate
//
//  mSBC (HFP) decoder wrapper:
//  - Input: concatenated mSBC SBC frames, each 57 bytes (starting with 0xAD syncword)
//  - Output: 16kHz mono PCM Int16, 120 samples per frame (7.5ms)
//

import Foundation

final class MSBCDecoder {
    // This project builds with Swift 6's default isolation = MainActor.
    // libsbc contexts are not thread-safe, but this decoder instance is used
    // in a single pipeline; mark storage as nonisolated(unsafe) so we can call
    // from non-main contexts when needed.
    nonisolated(unsafe) private var ctx = sbc()

    init() {
        sbc_reset(&ctx)
    }

    /// Decode concatenated mSBC payload57 frames into PCM Int16.
    /// - Parameter payload57: 57*N bytes; any tail bytes (<57) are ignored.
    func decode(payload57: Data) -> Data? {
        let frameSize = Int(SBC_MSBC_SIZE) // 57
        let frames = payload57.count / frameSize
        guard frames > 0 else { return nil }

        let samplesPerFrame = Int(SBC_MSBC_SAMPLES) // 120
        var pcmOut = [Int16](repeating: 0, count: frames * samplesPerFrame)
        var frameDesc = sbc_frame()

        let ok = pcmOut.withUnsafeMutableBufferPointer { outBuf -> Bool in
            guard let outBase = outBuf.baseAddress else { return false }
            return payload57.withUnsafeBytes { rawPtr -> Bool in
                guard let inBase = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                for i in 0..<frames {
                    let inPtr = UnsafeRawPointer(inBase.advanced(by: i * frameSize))
                    let outPtr = outBase.advanced(by: i * samplesPerFrame)
                    // Decode one frame. For mSBC, decoder infers constant frame from syncword 0xAD.
                    let r = sbc_decode(&ctx, inPtr, UInt32(frameSize), &frameDesc, outPtr, 1, nil, 0)
                    if r != 0 {
                        return false
                    }
                }
                return true
            }
        }

        guard ok else { return nil }
        return Data(bytes: pcmOut, count: pcmOut.count * MemoryLayout<Int16>.size)
    }
}

/// mSBC (HFP) encoder wrapper:
/// - Input: 16kHz mono PCM Int16 (120 samples per frame = 7.5ms)
/// - Output: concatenated mSBC SBC frames, each 57 bytes (starts with 0xAD syncword)
final class MSBCEncoder: @unchecked Sendable {
    // Project builds with Swift 6 default isolation = MainActor.
    // We run the encoder on a background task for pacing, so we explicitly opt out.
    // libsbc context is not thread-safe; keep it per instance and never share across threads.
    nonisolated(unsafe) private var ctx = sbc()
    /// Frame description. For mSBC, libsbc will use its internal constant frame
    /// as long as `msbc=true`.
    nonisolated(unsafe) private var frameDesc = sbc_frame(
        msbc: true,
        freq: SBC_FREQ_16K,
        mode: SBC_MODE_MONO,
        bam: SBC_BAM_LOUDNESS,
        nblocks: 0,
        nsubbands: 0,
        bitpool: 0
    )

    nonisolated init() {
        sbc_reset(&ctx)
    }

    /// Encode exactly one 7.5ms frame: 120 samples (16kHz mono).
    nonisolated func encodeFrame(pcml: UnsafePointer<Int16>) -> Data? {
        let outSize = Int(SBC_MSBC_SIZE) // 57
        var out = [UInt8](repeating: 0, count: outSize)
        let r = out.withUnsafeMutableBytes { outPtr -> Int32 in
            guard let outBase = outPtr.baseAddress else { return -1 }
            return sbc_encode(&ctx,
                              pcml, 1,
                              nil, 0,
                              &frameDesc,
                              outBase, UInt32(outSize))
        }
        guard r == 0 else { return nil }
        return Data(out)
    }

    /// Encode concatenated PCM into mSBC payload57 frames.
    /// - Parameter pcm16kMonoInt16: 16kHz mono Int16 samples.
    /// - Note: Any tail samples (<120) are ignored.
    nonisolated func encode(pcm16kMonoInt16: [Int16]) -> Data? {
        let samplesPerFrame = Int(SBC_MSBC_SAMPLES) // 120
        let frames = pcm16kMonoInt16.count / samplesPerFrame
        guard frames > 0 else { return nil }

        var out = Data()
        out.reserveCapacity(frames * Int(SBC_MSBC_SIZE))

        let ok = pcm16kMonoInt16.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            for i in 0..<frames {
                let inPtr = base.advanced(by: i * samplesPerFrame)
                guard let frame = encodeFrame(pcml: inPtr) else { return false }
                out.append(frame)
            }
            return true
        }

        return ok ? out : nil
    }
}


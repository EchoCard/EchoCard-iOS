//
//  OpusCodec.swift
//  CallMate
//
//  Opus 编解码器封装
//  注意：需要添加 libopus 依赖才能使用真正的 Opus 编解码
//

import Foundation

// MARK: - 编译开关
// 默认情况下，工程不会启用真实 Opus（避免缺少 libopus 时无法编译）。
//
// 启用真实 Opus 的方式：
// 1) 使用 CocoaPods 拉取 libopus（Podfile: pod 'libopus'）
// 2) 在 Target Build Settings 设置：
//    - SWIFT_ACTIVE_COMPILATION_CONDITIONS 包含 USE_REAL_OPUS
//    - SWIFT_OBJC_BRIDGING_HEADER = "CallMate/CallMate-Bridging-Header.h"

// MARK: - Opus 编码器协议
protocol OpusEncoderProtocol {
    nonisolated func encode(pcm: Data, frameSize: Int32) -> Data?
}

// MARK: - Opus 解码器协议
protocol OpusDecoderProtocol {
    nonisolated func decode(opus: Data, frameSize: Int32) -> Data?
}

// MARK: - Mock 编码器（不需要 libopus）
class MockOpusEncoder: OpusEncoderProtocol {
    private let sampleRate: Int32
    private let channels: Int32
    
    nonisolated init(sampleRate: Int32, channels: Int32) {
        self.sampleRate = sampleRate
        self.channels = channels
        print("[MockOpus] 创建 Mock 编码器 (sampleRate: \(sampleRate), channels: \(channels))")
    }
    
    nonisolated func encode(pcm: Data, frameSize: Int32) -> Data? {
        // Mock: 直接返回 PCM 数据（实际应用中这是错误的，仅用于测试）
        // 服务端会收到非 Opus 数据，会失败
        // 真正的 Opus 编码会大幅压缩数据
        
        // 返回一个假的 Opus 包头 + 部分数据（模拟压缩）
        var mockData = Data()
        // Opus TOC byte (模拟)
        mockData.append(0xFC)
        // 取部分数据模拟压缩
        let compressedSize = min(pcm.count / 4, 200)
        if compressedSize > 0 {
            mockData.append(pcm.prefix(compressedSize))
        }
        return mockData
    }
}

// MARK: - Mock 解码器（不需要 libopus）
class MockOpusDecoder: OpusDecoderProtocol {
    private let sampleRate: Int32
    private let channels: Int32
    
    nonisolated init(sampleRate: Int32, channels: Int32) {
        self.sampleRate = sampleRate
        self.channels = channels
        print("[MockOpus] 创建 Mock 解码器 (sampleRate: \(sampleRate), channels: \(channels))")
    }
    
    nonisolated func decode(opus: Data, frameSize: Int32) -> Data? {
        // Mock: 生成静音数据
        // 真正的 Opus 解码会还原原始 PCM
        let pcmSize = Int(frameSize * channels) * 2  // 16-bit samples
        return Data(count: pcmSize)
    }
}

#if USE_REAL_OPUS
// MARK: - 真实 Opus 编码器（需要 libopus）
class RealOpusEncoder: OpusEncoderProtocol {
    nonisolated(unsafe) private var encoder: OpaquePointer?
    private let sampleRate: Int32
    private let channels: Int32
    
    nonisolated init?(sampleRate: Int32, channels: Int32) {
        self.sampleRate = sampleRate
        self.channels = channels
        
        var error: Int32 = 0
        encoder = opus_encoder_create(sampleRate, channels, OPUS_APPLICATION_VOIP, &error)
        
        guard error == OPUS_OK, encoder != nil else {
            print("[Opus] 创建编码器失败: \(error)")
            return nil
        }
        
        opus_encoder_ctl_set_bitrate(encoder!, 24000)
    }
    
    nonisolated deinit {
        if let enc = encoder {
            opus_encoder_destroy(enc)
        }
    }
    
    nonisolated func encode(pcm: Data, frameSize: Int32) -> Data? {
        guard let enc = encoder else { return nil }
        
        var outputBuffer = [UInt8](repeating: 0, count: 4000)
        let result = pcm.withUnsafeBytes { pcmPtr -> Int32 in
            guard let baseAddr = pcmPtr.baseAddress else { return -1 }
            return opus_encode(
                enc,
                baseAddr.assumingMemoryBound(to: Int16.self),
                frameSize,
                &outputBuffer,
                Int32(outputBuffer.count)
            )
        }
        
        guard result > 0 else { return nil }
        return Data(outputBuffer.prefix(Int(result)))
    }
}

// MARK: - 真实 Opus 解码器（需要 libopus）
class RealOpusDecoder: OpusDecoderProtocol {
    nonisolated(unsafe) private var decoder: OpaquePointer?
    private let sampleRate: Int32
    private let channels: Int32
    
    nonisolated init?(sampleRate: Int32, channels: Int32) {
        self.sampleRate = sampleRate
        self.channels = channels
        
        var error: Int32 = 0
        decoder = opus_decoder_create(sampleRate, channels, &error)
        
        guard error == OPUS_OK, decoder != nil else {
            print("[Opus] 创建解码器失败: \(error)")
            return nil
        }
    }
    
    nonisolated deinit {
        if let dec = decoder {
            opus_decoder_destroy(dec)
        }
    }
    
    nonisolated func decode(opus: Data, frameSize: Int32) -> Data? {
        guard let dec = decoder else { return nil }
        
        var outputBuffer = [Int16](repeating: 0, count: Int(frameSize * channels))
        let result = opus.withUnsafeBytes { opusPtr -> Int32 in
            guard let baseAddr = opusPtr.baseAddress else { return -1 }
            return opus_decode(
                dec,
                baseAddr.assumingMemoryBound(to: UInt8.self),
                Int32(opus.count),
                &outputBuffer,
                frameSize,
                0
            )
        }
        
        guard result > 0 else { return nil }
        return Data(bytes: outputBuffer, count: Int(result * channels) * 2)
    }
}
#endif

// MARK: - 工厂方法
nonisolated func createOpusEncoder(sampleRate: Int32, channels: Int32) -> OpusEncoderProtocol? {
    #if USE_REAL_OPUS
    return RealOpusEncoder(sampleRate: sampleRate, channels: channels)
    #else
    return MockOpusEncoder(sampleRate: sampleRate, channels: channels)
    #endif
}

nonisolated func createOpusDecoder(sampleRate: Int32, channels: Int32) -> OpusDecoderProtocol? {
    #if USE_REAL_OPUS
    return RealOpusDecoder(sampleRate: sampleRate, channels: channels)
    #else
    return MockOpusDecoder(sampleRate: sampleRate, channels: channels)
    #endif
}

//
//  CRC32MPEG2.swift
//  CallMate
//

import Foundation

struct CRC32MPEG2 {
    nonisolated private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i) << 24
            for _ in 0..<8 {
                if (crc & 0x8000_0000) != 0 {
                    crc = (crc << 1) ^ 0x04C11DB7
                } else {
                    crc <<= 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    nonisolated static func checksum(data: Data, seed: UInt32 = 0xFFFF_FFFF) -> UInt32 {
        var crc = seed
        for byte in data {
            let idx = Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)
            crc = (crc << 8) ^ table[idx]
        }
        return crc
    }
}

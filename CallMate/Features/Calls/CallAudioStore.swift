//
//  CallAudioStore.swift
//  CallMate
//

import Foundation

enum CallAudioStore {
    nonisolated static let fileExtension = "caf"

    nonisolated static func prewarmRecordingsDirectoryIfNeeded() {
        let startedAt = Date()
        Task.detached(priority: .utility) {
            do {
                _ = try recordingsDirectory()
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                print("[LAT][Recording] t=\(logTimestamp()) event=prewarm_directory_end duration=\(durationMs)ms")
            } catch {
                print("[LAT][Recording] t=\(logTimestamp()) event=prewarm_directory_failed error=\(error.localizedDescription)")
            }
        }
    }

    nonisolated static func recordingsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("CallRecordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated static func fileName(for callId: UUID) -> String {
        "call-\(callId.uuidString).\(fileExtension)"
    }

    nonisolated static func url(for callId: UUID) throws -> URL {
        try recordingsDirectory().appendingPathComponent(fileName(for: callId))
    }

    nonisolated static func url(forFileName fileName: String) throws -> URL {
        try recordingsDirectory().appendingPathComponent(fileName)
    }

    nonisolated static func logTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}


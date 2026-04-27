//
//  TTSFillerSyncCoordinator.swift
//  CallMate
//
//  Orchestrates the end-to-end filler preload for a given voice_id:
//
//    1. HTTP POST /api/tts/fillers          → 6 × {id, url, text}
//    2. Download mp3 + re-encode to mSBC    → TTSFillerEncodedAsset × 6
//    3. BLE preload session over CallMateBLEClient:
//         preload_begin
//         for each asset:
//           preload_asset_begin
//           binary chunks over preload characteristic
//           preload_asset_end
//         preload_end
//    4. Persist iOS-side mirror of meta so UI can check "is current
//       voice already pushed" on launch without round-tripping the MCU.
//
//  See docs/tts-filler-low-latency.md §4, §6.3, §8.
//

import Foundation
import Combine
import CryptoKit

@MainActor
final class TTSFillerSyncCoordinator: ObservableObject {

    static let shared = TTSFillerSyncCoordinator(ble: CallMateBLEClient.shared)

    // MARK: - Published state (drives UI progress / error banners)

    enum State: Equatable {
        case idle
        case fetchingMetadata(voiceId: String)
        case encoding(done: Int, total: Int)
        case uploading(assetIndex: Int, assetCount: Int, sentBytes: Int, totalBytes: Int)
        case success(voiceId: String, hash: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Last hash we pushed successfully to the MCU, so the UI can skip redundant uploads
    /// without an extra KV round-trip. Persisted to UserDefaults.
    @Published private(set) var lastPushedHash: String? = UserDefaults.standard.string(forKey: metaHashKey)
    @Published private(set) var lastPushedVoiceId: String? = UserDefaults.standard.string(forKey: metaVoiceKey)

    // MARK: - Config

    /// Hard cap for a single asset. Encoder caps at this too.
    private let maxAssetBytes = TTSFillerEncoder.maxEncodedBytes

    /// Safety: refuse to run preload while a call is active.
    var isBlockedByCall: Bool {
        ble.currentCallSID != nil
    }

    // MARK: - Internals

    private var runningTask: Task<Void, Error>?
    private let ble: any CallMateBLELibraryClient
    private var cancellables = Set<AnyCancellable>()
    private var eventContinuation: AsyncStream<CallMateBLEEvent>.Continuation?
    private var eventStream: AsyncStream<CallMateBLEEvent>!
    /// Asset currently being uploaded. Read by the preload_missing handler to
    /// pick which bytes to retransmit. Nil outside an active session.
    private var currentAsset: TTSFillerEncodedAsset?
    private var currentChunkSize: Int = 0
    /// Retransmit count per asset per session — bounded to avoid infinite loops
    /// if the MCU keeps reporting the same range missing.
    private var retransmitCount: [String: Int] = [:]
    private static let maxRetransmitsPerAsset = 3
    private static let metaHashKey = "callmate.filler.lastPushedHash"
    private static let metaVoiceKey = "callmate.filler.lastPushedVoiceId"

    private init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
        eventStream = AsyncStream { [weak self] cont in
            self?.eventContinuation = cont
        }
        ble.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.eventContinuation?.yield(event)
                self?.handleMissEventForFallback(event)
                self?.handlePreloadMissing(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Preload missing → retransmit

    /// Asynchronously retransmit the byte ranges MCU reports as missing for the
    /// current asset. MCU emits `preload_missing` any time between the last
    /// chunk on preload char and the `preload_asset_end` ack, so we fire the
    /// retransmits immediately (no await in the sink) and let the waiter for
    /// `preload_asset_end` keep ticking.
    private func handlePreloadMissing(_ event: CallMateBLEEvent) {
        guard case let .preloadMissing(id, ranges) = event else { return }
        guard let asset = currentAsset, asset.fillerId == id else {
            print("[TTSFillers][coord] preload_missing for inactive/other asset id=\(id); ignored")
            return
        }
        let count = (retransmitCount[id] ?? 0) + 1
        retransmitCount[id] = count
        guard count <= Self.maxRetransmitsPerAsset else {
            print("[TTSFillers][coord] preload_missing id=\(id) retransmit cap reached (\(count)); let asset_end fail")
            return
        }
        let chunkSize = currentChunkSize
        guard chunkSize > 0 else { return }
        let data = asset.data
        let total = data.count
        print("[TTSFillers][coord] preload_missing id=\(id) ranges=\(ranges.count) attempt=\(count)")

        Task { [weak self] in
            guard let self else { return }
            for range in ranges {
                let start = max(0, min(range.start, total))
                let end = max(start, min(range.end, total))
                guard end > start else { continue }
                var offset = start
                while offset < end {
                    if Task.isCancelled { return }
                    let n = min(chunkSize, end - offset)
                    let slice = data.subdata(in: offset..<(offset + n))
                    let crc = CRC32MPEG2.checksum(data: slice)
                    let index = UInt32(offset / chunkSize)
                    let packet = CallMateBLEPacketBuilder.buildTransferPacket(
                        index: index,
                        offset: UInt32(offset),
                        data: slice,
                        crc32: crc
                    )
                    do {
                        try await self.ble.loadPreloadPackets([packet], onProgress: nil)
                    } catch {
                        print("[TTSFillers][coord] retransmit chunk offset=\(offset) failed: \(error)")
                        return
                    }
                    offset += n
                }
            }
            print("[TTSFillers][coord] retransmit complete id=\(id)")
        }
    }

    // MARK: - Fallback: MCU reports `play_filler` miss → re-push in background

    /// Window in which a single miss is "cheap" — if we see misses across many
    /// calls or a long interval, we only re-push once per voice session.
    private var lastFallbackTriggerAt: Date = .distantPast
    private static let fallbackMinInterval: TimeInterval = 60

    private func handleMissEventForFallback(_ event: CallMateBLEEvent) {
        guard case let .ack(cmd, result) = event else { return }
        guard cmd == "play_filler", result != 0 else { return }
        // -1 = unknown id; -2 = not in audio_streaming state. Only -1 means the
        // MCU table is stale; -2 is a timing race we cannot fix from here.
        guard result == -1 else { return }

        guard !isBlockedByCall else {
            print("[TTSFillers][coord] miss during call; skip fallback (can't preload mid-call)")
            return
        }
        guard let voiceId = lastPushedVoiceId else {
            print("[TTSFillers][coord] miss but no lastPushedVoiceId; cannot re-push")
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastFallbackTriggerAt) > Self.fallbackMinInterval else {
            print("[TTSFillers][coord] miss fallback throttled (<\(Int(Self.fallbackMinInterval))s)")
            return
        }
        lastFallbackTriggerAt = now
        let deviceId = ble.runtimeMCUDeviceID ?? ""
        guard !deviceId.isEmpty else {
            print("[TTSFillers][coord] miss but no runtimeMCUDeviceID; cannot re-push")
            return
        }
        print("[TTSFillers][coord] play_filler miss → background re-push voice=\(voiceId)")
        _ = preload(voiceId: voiceId, deviceId: deviceId, force: true)
    }

    // MARK: - Public API

    /// Kick a preload run. Safe to call redundantly — if the same voice_id is
    /// already in flight, the call is coalesced. If the voice_id's hash matches
    /// `lastPushedHash` and `force == false`, returns immediately.
    @discardableResult
    func preload(voiceId: String, deviceId: String, force: Bool = false) -> Task<Void, Error> {
        if let running = runningTask, !running.isCancelled {
            return running
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            do {
                try await self.runPreload(voiceId: voiceId, deviceId: deviceId, force: force)
            } catch is CancellationError {
                print("[TTSFillers][coord] cancelled")
                await MainActor.run { self.state = .idle }
                throw CancellationError()
            } catch {
                print("[TTSFillers][coord] failed: \(error)")
                await MainActor.run { self.state = .failed(String(describing: error)) }
                throw error
            }
            await MainActor.run { self.runningTask = nil }
        }
        runningTask = task
        return task
    }

    func cancel() {
        runningTask?.cancel()
        ble.cancelPreloadUpload()
    }

    // MARK: - Flow

    private func runPreload(voiceId: String, deviceId: String, force: Bool) async throws {
        guard !isBlockedByCall else {
            throw CoordinatorError.inCall
        }
        guard ble.isReady else {
            throw CoordinatorError.bleNotReady
        }
        guard ble.isPreloadReady else {
            throw CoordinatorError.preloadCharMissing
        }

        // 1) HTTP fetch
        state = .fetchingMetadata(voiceId: voiceId)
        let resp = try await TTSFillerService.fetchFillers(voiceId: voiceId, deviceId: deviceId)
        guard !resp.fillers.isEmpty else {
            throw CoordinatorError.emptyResponse
        }

        // 2) Encode every filler (serial — mp3 decode + mSBC encode is CPU-bound
        //    but cheap; parallelising gains little and breaks AVAudioFile ownership.)
        state = .encoding(done: 0, total: resp.fillers.count)
        var encoded: [TTSFillerEncodedAsset] = []
        encoded.reserveCapacity(resp.fillers.count)
        for (idx, item) in resp.fillers.enumerated() {
            try Task.checkCancellation()
            let asset = try await TTSFillerEncoder.encode(item: item)
            guard asset.data.count <= maxAssetBytes else {
                throw CoordinatorError.assetTooLarge(id: asset.fillerId, bytes: asset.data.count)
            }
            encoded.append(asset)
            state = .encoding(done: idx + 1, total: resp.fillers.count)
        }

        // 3) Hash (iOS side record; MCU also stores its own copy).
        let hash = Self.computeMetaHash(voiceId: resp.voiceId, assets: encoded)
        if !force, hash == lastPushedHash, resp.voiceId == lastPushedVoiceId {
            print("[TTSFillers][coord] skip: hash unchanged (\(hash))")
            state = .success(voiceId: resp.voiceId, hash: hash)
            return
        }

        // 4) BLE preload session
        try await runBLEPreloadSession(voiceId: resp.voiceId, assets: encoded, hash: hash)

        // 5) Persist success
        UserDefaults.standard.set(hash, forKey: Self.metaHashKey)
        UserDefaults.standard.set(resp.voiceId, forKey: Self.metaVoiceKey)
        lastPushedHash = hash
        lastPushedVoiceId = resp.voiceId
        state = .success(voiceId: resp.voiceId, hash: hash)
        print("[TTSFillers][coord] success voice=\(resp.voiceId) hash=\(hash)")
    }

    // MARK: - BLE session

    private func runBLEPreloadSession(voiceId: String, assets: [TTSFillerEncodedAsset], hash: String) async throws {
        let totalBytes = assets.reduce(0) { $0 + $1.data.count }
        let chunkSize = max(60, ble.preloadMaxChunkPayloadBytes)
        let assetCount = assets.count

        // preload_begin — keep meta slim (voice_id + hash); count/total_bytes
        // already live on the root `params` dict so MCU doesn't need them twice.
        let meta: [String: Any] = [
            "voice_id": voiceId,
            "hash": hash,
        ]
        try await sendAndAwait(cmd: "preload_begin", extra: [
            "scope": "filler",
            "count": assetCount,
            "total_bytes": totalBytes,
            "meta": meta,
        ], timeout: 10)

        var sentAssets = 0
        var sentBytesTotal = 0

        currentChunkSize = chunkSize
        retransmitCount.removeAll(keepingCapacity: true)
        defer {
            currentAsset = nil
            currentChunkSize = 0
        }

        for asset in assets {
            try Task.checkCancellation()
            let packets = Self.buildPackets(for: asset, chunkSize: chunkSize)
            let assetBytes = asset.data.count
            state = .uploading(
                assetIndex: sentAssets,
                assetCount: assetCount,
                sentBytes: sentBytesTotal,
                totalBytes: totalBytes
            )

            // Make the asset visible to the preload_missing handler *before*
            // any bytes go out on the preload char — MCU may emit preload_missing
            // the moment our last chunk lands, which can race the ack below.
            currentAsset = asset

            // preload_asset_begin
            //
            // NOTE: we use `filler_id` rather than `id` because MCU's
            // `protocol_get_param_item` is root-first, and a plain `id` key in
            // `params` would be shadowed by the JSON-RPC request id (a number)
            // at the root level → handler reads a number where a string is
            // expected → result=-3. See inbox/mcu/PENDING/
            // 2026-04-22-preload-filler-id-field-rename.md
            try await sendAndAwait(cmd: "preload_asset_begin", extra: [
                "filler_id": asset.fillerId,
                "size": assetBytes,
                "crc32": Int(bitPattern: UInt(asset.crc32)),
                "chunk": chunkSize,
                "total": packets.count,
            ], timeout: 10)

            // binary chunks via preload characteristic
            let baseBytes = sentBytesTotal
            let assetIndex = sentAssets
            let currentAssetCount = assetCount
            let currentTotalBytes = totalBytes
            try await ble.loadPreloadPackets(packets, onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.state = .uploading(
                        assetIndex: assetIndex,
                        assetCount: currentAssetCount,
                        sentBytes: baseBytes + progress,
                        totalBytes: currentTotalBytes
                    )
                }
            })

            // preload_asset_end (MCU may answer slowly: FlashDB erase/write).
            try await sendAndAwait(cmd: "preload_asset_end", extra: [
                "filler_id": asset.fillerId,
            ], timeout: 20)

            sentAssets += 1
            sentBytesTotal += assetBytes
        }

        // preload_end — MCU reloads PSRAM; can take a second.
        try await sendAndAwait(cmd: "preload_end", extra: [
            "scope": "filler",
        ], timeout: 15)
    }

    /// Slice mSBC data into `fw_chunk_t`-style packets (pre-built), ready to
    /// hand to `loadPreloadPackets`.
    static func buildPackets(for asset: TTSFillerEncodedAsset, chunkSize: Int) -> [Data] {
        precondition(chunkSize > 0)
        let total = asset.data.count
        var packets: [Data] = []
        packets.reserveCapacity((total + chunkSize - 1) / chunkSize)
        var offset = 0
        var index: UInt32 = 0
        while offset < total {
            let n = min(chunkSize, total - offset)
            let slice = asset.data.subdata(in: offset..<(offset + n))
            let crc = CRC32MPEG2.checksum(data: slice)
            let pkt = CallMateBLEPacketBuilder.buildTransferPacket(
                index: index,
                offset: UInt32(offset),
                data: slice,
                crc32: crc
            )
            packets.append(pkt)
            offset += n
            index &+= 1
        }
        return packets
    }

    /// 16-char lowercase hex hash of `voice_id ‖ "\n" ‖ for each asset (id ‖ size)`.
    static func computeMetaHash(voiceId: String, assets: [TTSFillerEncodedAsset]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(voiceId.utf8))
        hasher.update(data: Data("\n".utf8))
        for asset in assets {
            hasher.update(data: Data(asset.fillerId.utf8))
            hasher.update(data: Data(":".utf8))
            var size = UInt32(asset.data.count).littleEndian
            withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data("\n".utf8))
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Ack wait

    private func sendAndAwait(cmd: String, extra: [String: Any], timeout: TimeInterval) async throws {
        ble.sendCommand(cmd, uid: nil, extra: extra, expectAck: true, sid: nil)
        let ack = await waitForAck(cmd: cmd, timeoutSeconds: timeout)
        guard let ack else {
            throw CoordinatorError.ackTimeout(cmd: cmd)
        }
        guard ack.result == 0 else {
            throw CoordinatorError.ackNonZero(cmd: cmd, result: ack.result)
        }
    }

    private func waitForAck(cmd: String, timeoutSeconds: TimeInterval) async -> (cmd: String, result: Int)? {
        let timeoutNs = UInt64(timeoutSeconds * 1_000_000_000)
        return await withTaskGroup(of: (String, Int)?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                for await event in await self.eventStream {
                    if case let .ack(rcv, result) = event, rcv == cmd {
                        return (rcv, result)
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Errors

    enum CoordinatorError: Error, CustomStringConvertible {
        case inCall
        case bleNotReady
        case preloadCharMissing
        case emptyResponse
        case assetTooLarge(id: String, bytes: Int)
        case ackTimeout(cmd: String)
        case ackNonZero(cmd: String, result: Int)

        var description: String {
            switch self {
            case .inCall:
                return "coord: in call, refusing to preload"
            case .bleNotReady:
                return "coord: BLE not ready"
            case .preloadCharMissing:
                return "coord: preload characteristic not found on device"
            case .emptyResponse:
                return "coord: server returned 0 fillers"
            case let .assetTooLarge(id, bytes):
                return "coord: asset \(id) is \(bytes) B (> cap)"
            case let .ackTimeout(cmd):
                return "coord: ack timeout for \(cmd)"
            case let .ackNonZero(cmd, result):
                return "coord: \(cmd) ack=\(result)"
            }
        }
    }
}

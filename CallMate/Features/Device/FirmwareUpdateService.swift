//
//  FirmwareUpdateService.swift
//  CallMate
//

import Foundation
import Combine
import SwiftUI

enum FirmwareUpdateStage: Equatable {
    case idle
    case downloading
    case upgrading
    case rebooting
}

struct FirmwareMetadata: Codable, Equatable {
    let device: String
    let version: String
    let size: Int
    let sha256: String
    let crc32: UInt32
    let url: String
}

struct FirmwareChunkAck: Equatable {
    let index: Int
    let result: Int
    let received: Int
    let total: Int
}

@MainActor
final class FirmwareUpdateService: ObservableObject {
    static let shared = FirmwareUpdateService(ble: CallMateBLEClient.shared)

    @Published var latestMetadata: FirmwareMetadata?
    @Published var isChecking: Bool = false
    @Published var isUpdating: Bool = false
    @Published var updateStage: FirmwareUpdateStage = .idle
    @Published var downloadProgress: Double = 0
    @Published var upgradeProgress: Double = 0
    @Published var progress: Double = 0
    @Published var statusText: String = ""
    @Published var transferSpeedKBps: Double = 0
    @Published var lastError: String?

    @AppStorage("fw_server_base_url") private var serverBaseURL: String = AppConfig.fwServerBaseURL

    /// 与 Android `serverBaseUrl.trimEnd('/')` 一致，避免 `.../echocard/` 拼出 `//api/...`。
    private var normalizedServerBaseURL: String {
        var s = serverBaseURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private let ble: any CallMateBLELibraryClient
    private var cancellables = Set<AnyCancellable>()
    private var waitingForReconnectAfterUpdate: Bool = false

    private var ackStream: AsyncStream<CallMateBLEEvent>!
    private var ackContinuation: AsyncStream<CallMateBLEEvent>.Continuation?
    private let otaWriteScheduler: OTAWriteScheduler

    private struct OTAUploadSnapshot: Sendable {
        let sentBytes: Int
        let sentChunks: Int
        let txKBps: Double
    }

    private struct OTAUploadResult: Sendable {
        let sentBytes: Int
        let sentChunks: Int
        let elapsedMs: Int
    }

    /// One-shot direct-queue OTA write scheduler.
    ///
    /// Architecture:
    ///   1. Pre-build: ALL packets are built synchronously on the cooperative pool
    ///      (CRC32 + 16-byte header + firmware slice). ~100 ms for a 1 MB firmware.
    ///   2. Load: The entire [Data] array is handed to bleQueue in ONE bleQueue.async call.
    ///      Zero per-packet bleQueue.sync round-trips on the critical path.
    ///   3. Drain: peripheralIsReady pops packets and writes them immediately, every CI.
    ///   4. Progress: polled from queue depth every 250 ms via a single bleQueue.async.
    ///
    /// Why previous approaches were slower:
    ///   - Polling (50 µs sleep): each canSend check = 2–10 ms cooperative overhead → 30 KB/s
    ///   - Callback continuation: cont.resume() doesn't guarantee immediate execution,
    ///     cooperative pool could be busy → missed CI window → speed cut in half
    ///   - Per-packet pushOTADirectPacket: bleQueue.sync per packet to check queue depth
    ///     → same 2–10 ms overhead, queue depth stays 1, window misses common
    ///
    /// Expected throughput: 60–64 KB/s (CI=15 ms, 2 packets × 480 B per event).
    private actor OTAWriteScheduler {
        private let ble: any CallMateBLELibraryClient

        init(ble: any CallMateBLELibraryClient) {
            self.ble = ble
        }

        func upload(
            firmwareData: Data,
            chunkSize: Int,
            onSnapshot: @escaping @Sendable (OTAUploadSnapshot) -> Void
        ) async throws -> OTAUploadResult {
            let total = firmwareData.count
            let totalChunks = (total + chunkSize - 1) / chunkSize

            // Step A: Pre-build every packet on the cooperative pool (no bleQueue involvement).
            let prebuildStart = Date()
            var allPackets: [Data] = []
            allPackets.reserveCapacity(totalChunks)
            var offset = 0
            var index: UInt32 = 0
            while offset < total {
                let end = min(offset + chunkSize, total)
                let chunk = firmwareData.subdata(in: offset..<end)
                let crc = CRC32MPEG2.checksum(data: chunk)
                allPackets.append(CallMateBLEPacketBuilder.buildTransferPacket(
                    index: index, offset: UInt32(offset), data: chunk, crc32: crc))
                offset = end
                index += 1
            }
            let prebuildMs = Int(Date().timeIntervalSince(prebuildStart) * 1000)
            print("[OTA] pre-build done: \(allPackets.count) packets in \(prebuildMs) ms")

            // Step B: Load the entire batch into bleQueue in ONE shot and start draining.
            let uploadStart = Date()
            ble.resetOTADirectQueue()
            ble.loadOTAPackets(allPackets)
            print("[OTA] loadOTAPackets: \(allPackets.count) packets loaded, BLE drain started")

            // Step C: Poll queue depth every 250 ms for INTERVAL-based speed.
            // Use per-interval delta (not cumulative average from T=0) to avoid the
            // initial "spike" caused by the first few packets draining in <1 ms.
            var prevSentChunks = 0
            var prevPollTime = uploadStart

            // Initial sleep so the first reading has a meaningful time window.
            try? await Task.sleep(nanoseconds: 250_000_000)

            while true {
                let remaining = await ble.getOTAQueueDepth()
                if remaining < 0 {
                    throw NSError(domain: "fw", code: -12, userInfo: [NSLocalizedDescriptionKey: "Device disconnected during update"])
                }
                let sentChunks = totalChunks - remaining
                let now = Date()

                let intervalChunks = sentChunks - prevSentChunks
                let intervalElapsed = now.timeIntervalSince(prevPollTime)

                // Per-interval KB/s (accurate, no startup spike).
                let txKBps = intervalElapsed > 0.05
                    ? Double(intervalChunks * chunkSize) / 1024.0 / intervalElapsed
                    : 0
                let pktPerSec = intervalElapsed > 0.05
                    ? Double(intervalChunks) / intervalElapsed
                    : 0

                let cumulElapsed = now.timeIntervalSince(uploadStart)
                let cumulKBps = cumulElapsed > 0
                    ? Double(sentChunks * chunkSize) / 1024.0 / cumulElapsed
                    : 0

                print(String(format: "[OTA] progress: sent=%d/%d  %.1f pkt/s × %dB = %.1f KB/s  (cumul %.1f KB/s)  remaining=%d",
                              sentChunks, totalChunks, pktPerSec, chunkSize, txKBps, cumulKBps, remaining))

                onSnapshot(OTAUploadSnapshot(sentBytes: sentChunks * chunkSize,
                                             sentChunks: sentChunks,
                                             txKBps: txKBps))
                prevSentChunks = sentChunks
                prevPollTime = now

                if remaining == 0 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            let elapsedMs = Int(Date().timeIntervalSince(uploadStart) * 1000)
            print(String(format: "[OTA] upload done: %d chunks in %d ms  avg=%.1f KB/s",
                         totalChunks, elapsedMs,
                         elapsedMs > 0 ? Double(total) / 1024.0 / (Double(elapsedMs) / 1000.0) : 0))
            onSnapshot(OTAUploadSnapshot(sentBytes: total, sentChunks: totalChunks, txKBps: 0))
            return OTAUploadResult(sentBytes: total, sentChunks: totalChunks, elapsedMs: elapsedMs)
        }

        func resendMissingChunks(ranges: [FirmwareMissingRange], chunkSize: Int, firmwareData: Data) async throws {
            guard !ranges.isEmpty else { return }
            var resendPackets: [Data] = []
            for range in ranges {
                if range.end < range.start { continue }
                for idx in range.start...range.end {
                    let chunkOffset = idx * chunkSize
                    if chunkOffset >= firmwareData.count { break }
                    let end = min(chunkOffset + chunkSize, firmwareData.count)
                    let chunk = firmwareData.subdata(in: chunkOffset..<end)
                    let crc = CRC32MPEG2.checksum(data: chunk)
                    resendPackets.append(CallMateBLEPacketBuilder.buildTransferPacket(
                        index: UInt32(idx), offset: UInt32(chunkOffset), data: chunk, crc32: crc))
                }
            }
            print("[OTA] resend: \(resendPackets.count) packets for \(ranges.count) missing range(s)")
            ble.loadOTAPackets(resendPackets)
            await ble.drainOTADirectQueue()
            print("[OTA] resend: drain complete")
        }
    }

    private var isChinese: Bool {
        (UserDefaults.standard.string(forKey: "callmate.language") ?? "zh") == "zh"
    }

    private func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    private init(ble: any CallMateBLELibraryClient) {
        self.ble = ble
        self.otaWriteScheduler = OTAWriteScheduler(ble: ble)
        ackStream = AsyncStream { continuation in
            self.ackContinuation = continuation
        }

        ble.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.ackContinuation?.yield(event)
            }
            .store(in: &cancellables)

        // Clear transient "rebooting" message once device is back online.
        ble.ctrlReadyPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self else { return }
                guard ready, self.waitingForReconnectAfterUpdate, !self.isUpdating else { return }
                self.waitingForReconnectAfterUpdate = false
                // Keep latest/failed messages, clear only transient rebooting state.
                if self.lastError == nil {
                    self.statusText = ""
                    if self.updateStage == .rebooting {
                        self.updateStage = .idle
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Maps MCU chip name (from get_info) to firmware server device identifier.
    /// Falls back to sf32lb525 if chip is unknown or not yet reported.
    static func deviceName(for chipName: String?) -> String {
        switch chipName {
        case "sf32lb52j":  return "callmate-sf32lb52j"
        case "sf32lb525":  return "callmate-sf32lb525"
        default:           return "callmate-sf32lb525"
        }
    }

    func checkForUpdate() async {
        let device = Self.deviceName(for: ble.deviceChipName)
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let urlString = "\(normalizedServerBaseURL)/api/firmware/latest?device=\(device)"
        print("[FW] checkForUpdate chip=\(ble.deviceChipName ?? "nil") device=\(device) URL: \(urlString)")

        guard let url = URL(string: urlString) else {
            lastError = t("更新服务地址无效，请稍后重试。", "Update server address is invalid. Please try again later.")
            print("[FW] ERROR: invalid URL")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? -1
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "(non-utf8)"
            print("[FW] HTTP \(statusCode), body: \(bodyPreview)")

            if statusCode != 200 {
                lastError = t("暂时无法连接更新服务，请稍后再试。", "Cannot reach update service right now. Please try again later.")
                return
            }

            let meta = try JSONDecoder().decode(FirmwareMetadata.self, from: data)
            latestMetadata = meta
            statusText = String(format: t("已获取最新版本：%@", "Latest version available: %@"), meta.version)
            print("[FW] Parsed OK: version=\(meta.version) size=\(meta.size) crc32=\(meta.crc32)")
        } catch {
            lastError = t("检查更新失败，请检查网络后重试。", "Failed to check updates. Please check your network and try again.")
            print("[FW] ERROR: \(error)")
        }
    }

    func startUpdateIfAvailable() async {
        guard let meta = latestMetadata else {
            lastError = t("还没有可用的更新信息，请先点击“检查更新”。", "No update info yet. Please tap \"Check\" first.")
            return
        }
        await startUpdate(metadata: meta)
    }

    func startUpdate(metadata: FirmwareMetadata) async {
        guard !isUpdating else {
            print("[FW] startUpdate: already updating, skip")
            return
        }
        isUpdating = true
        updateStage = .downloading
        downloadProgress = 0
        upgradeProgress = 0
        progress = 0
        transferSpeedKBps = 0
        lastError = nil
        waitingForReconnectAfterUpdate = false
        statusText = t("正在下载更新包，请稍候…", "Downloading update package...")

        print("[FW] ====== OTA UPDATE START ======")
        print("[FW] version=\(metadata.version) size=\(metadata.size) crc32=\(metadata.crc32)")
        print("[FW] url=\(metadata.url)")

        do {
            // Step 1: Download
            print("[FW] Step 1: Downloading firmware binary ...")
            let t0 = Date()
            let firmwareData = try await downloadFirmware(from: metadata.url, expectedSize: metadata.size)
            let dlMs = Int(Date().timeIntervalSince(t0) * 1000)
            print("[FW] Download done: \(firmwareData.count) bytes in \(dlMs)ms")
            downloadProgress = 1.0
            progress = 1.0

            if firmwareData.count != metadata.size {
                print("[FW] ERROR: size mismatch downloaded=\(firmwareData.count) expected=\(metadata.size)")
                throw NSError(domain: "fw", code: -1, userInfo: [NSLocalizedDescriptionKey: "Size mismatch: got \(firmwareData.count), expected \(metadata.size)"])
            }

            let crc32 = CRC32MPEG2.checksum(data: firmwareData)
            print("[FW] CRC32 check: computed=0x\(String(crc32, radix: 16)) expected=0x\(String(metadata.crc32, radix: 16))")
            if crc32 != metadata.crc32 {
                print("[FW] ERROR: CRC32 mismatch")
                throw NSError(domain: "fw", code: -2, userInfo: [NSLocalizedDescriptionKey: "CRC32 mismatch: got 0x\(String(crc32, radix: 16)), expected 0x\(String(metadata.crc32, radix: 16))"])
            }
            print("[FW] Firmware verified OK")

            // Step 2: fw_begin (adapt to current OTA write capacity, capped by MCU max)
            let bleMaxPayload = ble.otaMaxChunkPayloadBytes
            let rawChunkSize = min(480, max(120, bleMaxPayload > 0 ? bleMaxPayload : 480))
            // Keep fw chunk 4-byte aligned to avoid unaligned flash write offsets on MCU side.
            let alignedChunkSize = (rawChunkSize / 4) * 4
            let chunkSize = max(120, alignedChunkSize)
            let totalChunks = (firmwareData.count + chunkSize - 1) / chunkSize
            print("[FW] Step 2: Sending fw_begin (size=\(firmwareData.count) chunk=\(chunkSize), raw=\(rawChunkSize) totalChunks=\(totalChunks))")
            updateStage = .upgrading
            upgradeProgress = 0
            progress = 0
            statusText = t("正在准备升级，请保持设备靠近手机。", "Preparing update. Keep device near your phone.")
            ble.sendCommand("fw_begin", uid: nil, extra: [
                "size": firmwareData.count,
                "crc32": Int(crc32),
                "chunk": chunkSize,
                "version": metadata.version
            ], expectAck: true, sid: nil)

            let beginAck = await waitForCommandAck(cmd: "fw_begin", timeoutSeconds: 30)
            if beginAck == nil {
                print("[FW] ERROR: fw_begin ack timeout (no response in 30s, MCU may still be erasing flash)")
                throw NSError(domain: "fw", code: -3, userInfo: [NSLocalizedDescriptionKey: "fw_begin ack timeout"])
            }
            if beginAck!.result != 0 {
                print("[FW] ERROR: fw_begin ack rejected, result=\(beginAck!.result)")
                throw NSError(domain: "fw", code: -3, userInfo: [NSLocalizedDescriptionKey: "fw_begin rejected by MCU (result=\(beginAck!.result))"])
            }
            print("[FW] fw_begin ACK OK (result=\(beginAck!.result))")

            // Wait for the MCU-initiated OTA connection parameter update (7.5 ms CI)
            // to be accepted by iOS before starting the burst upload.
            //
            // After sending the fw_begin ACK the MCU calls ble_service_request_ota_conn_param()
            // which asks iOS to switch CI from 15 ms to 7.5 ms.  iOS typically accepts within
            // 1–2 CIs (15–30 ms), but the negotiation message itself takes ~one CI to arrive.
            // Without this pause the first ~50 ms of the upload runs at the old CI, wasting 3–4
            // connection events.  50 ms covers the worst common case without adding noticeable delay.
            try? await Task.sleep(nanoseconds: 50_000_000)
            print("[FW] CI settle wait done, starting upload")

            // Step 3: Send chunks via dedicated OTA channel.
            print("[FW] Step 3: Blind upload \(totalChunks) chunks via OTA channel ...")
            statusText = t("正在传输更新包…", "Transferring update...")
            let total = firmwareData.count
            let uploadResult = try await otaWriteScheduler.upload(
                firmwareData: firmwareData,
                chunkSize: chunkSize
            ) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let currentProgress = min(1.0, Double(snapshot.sentBytes) / Double(max(total, 1)))
                    self.upgradeProgress = currentProgress
                    self.progress = currentProgress
                    self.transferSpeedKBps = snapshot.txKBps
                    let pct = Int(currentProgress * 100)
                    self.statusText = String(
                        format: self.t("正在升级 %d%%（%d/%d）", "Updating %d%% (%d/%d)"),
                        pct, snapshot.sentChunks, totalChunks
                    )
                    if snapshot.sentChunks % 50 == 0 || snapshot.sentChunks >= totalChunks {
                        print("[FW] blind tx \(snapshot.sentChunks)/\(totalChunks) tx=\(snapshot.sentBytes)/\(total) (\(pct)%) TX \(String(format: "%.1f", snapshot.txKBps)) KB/s")
                    }
                }
            }

            // Step 3.5: Verify missing ranges and retransmit selectively.
            let maxVerifyRounds = 4
            var verifiedComplete = false
            var round = 1
            while round <= maxVerifyRounds {
                statusText = String(
                    format: t("正在校验数据（第 %d/%d 轮）", "Verifying data (round %d/%d)"),
                    round, maxVerifyRounds
                )
                ble.sendCommand("fw_verify", uid: nil, extra: [:], expectAck: true, sid: nil)

                guard let verify = await waitForFWVerifyResult(timeoutSeconds: 10) else {
                    throw NSError(domain: "fw", code: -7, userInfo: [NSLocalizedDescriptionKey: "fw_verify timeout"])
                }
                if verify.ackResult != 0 {
                    throw NSError(domain: "fw", code: -8, userInfo: [NSLocalizedDescriptionKey: "fw_verify rejected (\(verify.ackResult))"])
                }
                if verify.complete || verify.missingChunks == 0 {
                    verifiedComplete = true
                    print("[FW] verify round \(round): complete")
                    break
                }

                print("[FW] verify round \(round): missingChunks=\(verify.missingChunks) ranges=\(verify.ranges.count)")
                try await otaWriteScheduler.resendMissingChunks(
                    ranges: verify.ranges,
                    chunkSize: chunkSize,
                    firmwareData: firmwareData
                )
                round += 1
            }
            if !verifiedComplete {
                throw NSError(domain: "fw", code: -9, userInfo: [NSLocalizedDescriptionKey: "fw_verify unresolved missing chunks"])
            }

            print("[FW] All chunks sent in \(uploadResult.elapsedMs)ms (chunks=\(uploadResult.sentChunks), bytes=\(uploadResult.sentBytes))")

            // Step 4: fw_end
            print("[FW] Step 4: Sending fw_end ...")
            statusText = t("即将完成，正在写入设备…", "Almost done. Writing update to device...")
            ble.sendCommand("fw_end", uid: nil, extra: [:], expectAck: true, sid: nil)
            guard let endAck = await waitForCommandAck(cmd: "fw_end", timeoutSeconds: 10), endAck.result == 0 else {
                print("[FW] ERROR: fw_end ack failed or timeout")
                throw NSError(domain: "fw", code: -6, userInfo: [NSLocalizedDescriptionKey: "fw_end ack failed"])
            }
            print("[FW] fw_end ACK OK (result=\(endAck.result))")

            // Step 5: Reboot
            print("[FW] Step 5: Device will install and reboot ...")
            waitingForReconnectAfterUpdate = true
            updateStage = .rebooting
            upgradeProgress = 1.0
            progress = 1.0
            transferSpeedKBps = 0
            statusText = t("更新已发送，设备正在重启（约 5-10 秒）。", "Update sent. Device is rebooting (about 5-10s).")
            print("[FW] ====== OTA UPDATE COMPLETE ======")
        } catch {
            waitingForReconnectAfterUpdate = false
            updateStage = .idle
            transferSpeedKBps = 0
            lastError = t("升级没有完成，请保持设备靠近手机后重试。", "Update did not complete. Keep the device near your phone and try again.")
            statusText = t("升级未完成", "Update not completed")
            print("[FW] ====== OTA UPDATE FAILED ======")
            print("[FW] Error: \(error)")
        }

        isUpdating = false
    }

    private final class FirmwareDownloadProgressDelegate: NSObject, URLSessionDataDelegate {
        private let expectedSize: Int
        private let onProgress: @MainActor (Double) -> Void

        init(expectedSize: Int, onProgress: @escaping @MainActor (Double) -> Void) {
            self.expectedSize = max(0, expectedSize)
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            Task { @MainActor in
                onProgress(0)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            var totalExpected = dataTask.countOfBytesExpectedToReceive
            if totalExpected <= 0 {
                totalExpected = dataTask.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
            }
            if totalExpected <= 0, expectedSize > 0 {
                totalExpected = Int64(expectedSize)
            }
            guard totalExpected > 0 else { return }
            let received = dataTask.countOfBytesReceived
            let value = min(1.0, Double(received) / Double(totalExpected))
            Task { @MainActor in
                onProgress(value)
            }
        }
    }

    private func downloadFirmware(from urlString: String, expectedSize: Int) async throws -> Data {
        let fullURLString: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            fullURLString = urlString
        } else {
            fullURLString = normalizedServerBaseURL + urlString
        }
        print("[FW] Download URL: \(fullURLString)")
        guard let url = URL(string: fullURLString) else {
            print("[FW] ERROR: invalid download URL")
            throw NSError(domain: "fw", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL: \(fullURLString)"])
        }
        let request = URLRequest(url: url)
        let delegate = FirmwareDownloadProgressDelegate(expectedSize: expectedSize) { [weak self] value in
            self?.downloadProgress = value
            self?.progress = value
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: delegate)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[FW] Download HTTP \(httpCode), received \(data.count) bytes")
        if httpCode != 200 {
            throw NSError(domain: "fw", code: -11, userInfo: [NSLocalizedDescriptionKey: "Download failed HTTP \(httpCode)"])
        }
        downloadProgress = 1.0
        progress = 1.0
        return data
    }

    private func waitForFWVerifyResult(timeoutSeconds: Double) async -> (ackResult: Int, complete: Bool, missingChunks: Int, totalChunks: Int, ranges: [FirmwareMissingRange])? {
        let timeoutNs = UInt64(timeoutSeconds * 1_000_000_000)
        return await withTaskGroup(of: (Int, Bool, Int, Int, [FirmwareMissingRange])?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                var ackResult: Int?
                var missing: (Bool, Int, Int, [FirmwareMissingRange])?
                for await event in await self.ackStream {
                    switch event {
                    case let .ack(cmd, result) where cmd == "fw_verify":
                        ackResult = result
                    case let .firmwareMissing(complete, missingChunks, totalChunks, ranges):
                        missing = (complete, missingChunks, totalChunks, ranges)
                    default:
                        break
                    }
                    if let ack = ackResult, let m = missing {
                        return (ack, m.0, m.1, m.2, m.3)
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

    private func waitForCommandAck(cmd: String, timeoutSeconds: Double) async -> (cmd: String, result: Int)? {
        let timeoutNs = UInt64(timeoutSeconds * 1_000_000_000)
        return await withTaskGroup(of: (String, Int)?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                for await event in await self.ackStream {
                    if case let .ack(rcvCmd, result) = event, rcvCmd == cmd {
                        return (rcvCmd, result)
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
}

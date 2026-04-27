import Foundation
import UserNotifications
import AudioToolbox
@preconcurrency import AVFoundation

// MARK: - Emergency Flow

extension CallSessionController {
    func normalizedPhoneNumber(_ number: String) -> String {
        String(number.filter { $0.isNumber })
    }

    func normalizePhoneNumber(_ number: String) -> String {
        normalizedPhoneNumber(number)
    }

    func isEmergencyBlockedNumber(_ number: String) -> Bool {
        let normalized = normalizedPhoneNumber(number)
        guard !normalized.isEmpty else { return false }
        return emergencyNoPickupBlockedNumbers.contains(normalized)
    }

    func clearEmergencyBlockedNumber(_ number: String) {
        let normalized = normalizedPhoneNumber(number)
        guard !normalized.isEmpty else { return }
        if emergencyNoPickupBlockedNumbers.remove(normalized) != nil {
            persistEmergencyBlockedNumbers()
            print("[EmergencyMCP] cleared blocked number=\(normalized)")
        }
    }

    func persistEmergencyBlockedNumbers() {
        UserDefaults.standard.set(Array(emergencyNoPickupBlockedNumbers), forKey: emergencyBlockedNumbersKey)
    }

    func enqueueEmergencyBGM(durationSeconds: Int) async -> Bool {
        let maxSamples = max(0, durationSeconds) * 16_000
        let packets: [Data]
        do {
            packets = try Self.makeEmergencyBGMPackets(maxSamples: maxSamples)
        } catch {
            print("[EmergencyMCP] enqueue bgm failed: \(error)")
            return false
        }
        guard !packets.isEmpty else { return false }
        audioRouter.setTTSStopped(false)
        let frameDurationMs = 60.0
        let audioSec = audioRouter.configureEmergencyBGMProbe(
            totalFrames: packets.count,
            frameDurationMs: frameDurationMs
        )
        print(String(format: "[FASTCHK][iOS] emergency_bgm enqueue frames=%d audio=%.2fs q_before=%d",
                     packets.count,
                     audioSec,
                     audioRouter.uplinkQueueCount()))
        audioRouter.appendUplinkPackets(packets)
        if bleAudioStartAcked {
            scheduleTTSUplinkDrain(reason: "emergency_bgm_enqueue")
        } else {
            sendCallCommand("audio_start", extra: ["codec": bleMCUAudioCodecName], expectAck: false)
        }
        return true
    }

    private static func makeEmergencyBGMPackets(maxSamples: Int) throws -> [Data] {
        guard let audioURL = emergencyBGMURL() else {
            throw NSError(domain: "CallSessionController", code: -1001, userInfo: [NSLocalizedDescriptionKey: "BGM_16000.wav not found"])
        }
        let pcmSamples = try read16kMonoInt16Samples(from: audioURL, maxSamples: maxSamples)
        guard !pcmSamples.isEmpty else { return [] }
        guard let encoder = createOpusEncoder(sampleRate: 16_000, channels: 1) else { return [] }
        let frameSamples = 960 // 60ms @ 16k
        let frames = pcmSamples.count / frameSamples
        guard frames > 0 else { return [] }
        var packets: [Data] = []
        packets.reserveCapacity(frames)
        for i in 0..<frames {
            let start = i * frameSamples
            let end = start + frameSamples
            let slice = pcmSamples[start..<end]
            let frameData = slice.withUnsafeBufferPointer { ptr in
                Data(buffer: ptr)
            }
            if let packet = encoder.encode(pcm: frameData, frameSize: Int32(frameSamples)), !packet.isEmpty {
                packets.append(packet)
            }
        }
        return packets
    }

    private static func emergencyBGMURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "BGM_16000", withExtension: "wav") {
            return bundled
        }
        if let bundledInRes = Bundle.main.url(forResource: "BGM_16000", withExtension: "wav", subdirectory: "Resources") {
            return bundledInRes
        }
        return nil
    }

    private static func read16kMonoInt16Samples(from url: URL, maxSamples: Int) throws -> [Int16] {
        let srcFile = try AVAudioFile(forReading: url)
        let srcFormat = srcFile.processingFormat
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false) else {
            return []
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            return []
        }
        let srcFrameCount = AVAudioFrameCount(srcFile.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: max(1, srcFrameCount)) else {
            return []
        }
        try srcFile.read(into: srcBuffer)
        let ratio = dstFormat.sampleRate / max(1.0, srcFormat.sampleRate)
        let dstCapacity = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio) + 64
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: max(1, dstCapacity)) else {
            return []
        }
        var inputProvided = false
        var error: NSError?
        let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        guard status != .error, error == nil, let ptr = dstBuffer.int16ChannelData?[0] else {
            return []
        }
        let total = Int(dstBuffer.frameLength)
        if total <= 0 { return [] }
        let limit = maxSamples > 0 ? min(total, maxSamples) : total
        return Array(UnsafeBufferPointer(start: ptr, count: limit))
    }

    func handleNotifyOwnerToPickup(callId: String, arguments: [String: Any]) {
        guard inputSource == .ble else {
            ws.sendToolResponse(callId: callId, error: language == .zh ? "当前链路不支持紧急提醒推流" : "Emergency uplink is unsupported on current path")
            return
        }
        let reason = (arguments["emergency_reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let caller = (arguments["caller_identity"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urgency = (arguments["detected_urgency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "high"
        let displayReason = reason.isEmpty ? (language == .zh ? "紧急来电" : "Urgent call") : reason
        let displayCaller = caller.isEmpty ? (language == .zh ? "未知来电人" : "Unknown caller") : caller
        toastMessage = language == .zh
            ? "紧急提醒：\(displayCaller)（\(displayReason)）"
            : "Urgent: \(displayCaller) (\(displayReason))"
        emergencyLiveActivityText = language == .zh
            ? "紧急来电：\(displayCaller)（\(displayReason)）"
            : "Urgent call: \(displayCaller) (\(displayReason))"
        CallLiveActivityManager.shared.setResidentEmergencySummary(
            callerName: displayCaller,
            detailText: emergencyLiveActivityText ?? ""
        )
        didTriggerEmergencyNotifyInCurrentCall = true
        syncLiveActivity()
        postEmergencyLocalNotification(
            callId: callId,
            emergencyReason: displayReason,
            callerIdentity: displayCaller,
            urgency: urgency
        )
        emergencyPlaybackTask?.cancel()
        emergencyPlaybackTask = Task { [weak self] in
            guard let self else { return }
            defer { self.emergencyPlaybackTask = nil }
            self.emergencyNotifyAttemptCount += 1
            let continuePickup = self.emergencyNotifyAttemptCount < 2
            let clipSec = 10

            // Vibrate continuously for the entire alert duration (~1s interval)
            let vibrationTask = Task {
                for _ in 0..<clipSec {
                    guard !Task.isCancelled else { break }
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
            defer { vibrationTask.cancel() }

            let enqueued = await self.enqueueEmergencyBGM(durationSeconds: clipSec)
            if !enqueued {
                self.ws.sendToolResponse(callId: callId, error: self.language == .zh ? "紧急提示音播放失败" : "Emergency tone playback failed")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(clipSec) * 1_000_000_000)
            if Task.isCancelled { return }

            let pickedUp = self.phoneHandledCall || self.contactPassthroughActive || self.status == .ended
            if pickedUp {
                self.ws.sendToolResponse(callId: callId, result: [
                    "success": true,
                    "is_pickup": true,
                    "continue_pickup": false,
                    "message": self.language == .zh
                        ? "机主已接通，结束当前代接流程。"
                        : "Owner picked up. Ended AI screening."
                ])
                return
            }

            if continuePickup {
                self.ws.sendToolResponse(callId: callId, result: [
                    "success": true,
                    "is_pickup": false,
                    "continue_pickup": true,
                    "message": self.language == .zh
                        ? "告知对方：您稍等，我还在尝试提醒他接听。并继续调用 notify_owner_to_pickup"
                        : "Please wait, I am still trying to notify the owner."
                ])
            } else {
                if let number = self.currentIncomingCall?.number {
                    let normalized = self.normalizedPhoneNumber(number)
                    if !normalized.isEmpty {
                        self.emergencyNoPickupBlockedNumbers.insert(normalized)
                        self.persistEmergencyBlockedNumbers()
                    }
                }
                self.ws.sendToolResponse(callId: callId, result: [
                    "success": true,
                    "is_pickup": false,
                    "continue_pickup": false,
                    "message": self.language == .zh
                        ? "告知对方：不好意思，机主现在可能不在手机旁边，您稍后再打过来给他吧。"
                        : "Sorry, the owner may be away from the phone. Please call later."
                ])
            }
        }
    }

    func postEmergencyLocalNotification(
        callId: String,
        emergencyReason: String,
        callerIdentity: String,
        urgency: String
    ) {
        let content = UNMutableNotificationContent()
        if language == .zh {
            content.title = "紧急来电，请尽快接听"
            content.body = "来电人：\(callerIdentity)；原因：\(emergencyReason)"
        } else {
            content.title = "Urgent call, please answer soon"
            content.body = "Caller: \(callerIdentity); Reason: \(emergencyReason)"
        }
        content.sound = .default
        content.threadIdentifier = "notify_owner_to_pickup"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }
        content.userInfo = [
            "mcp_name": "notify_owner_to_pickup",
            "call_id": callId,
            "detected_urgency": urgency
        ]
        let request = UNNotificationRequest(
            identifier: "notify_owner_to_pickup_\(callId)_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[EmergencyMCP] local notification failed: \(error.localizedDescription)")
            } else {
                print("[EmergencyMCP] local notification scheduled callId=\(callId)")
            }
        }
    }
}

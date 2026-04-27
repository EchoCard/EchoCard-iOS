import SwiftUI
import Combine
import CoreBluetooth

@MainActor
final class SettingsViewModel: ObservableObject {
    struct AutoVoiceSelection {
        let voiceId: String
        let isCloneVoice: Bool
    }

    @Published var voices: [TTSVoice] = []
    @Published var isLoadingVoices = false
    @Published var voiceFetchError: String?

    func fetchVoicesIfNeeded(currentVoiceId: String) async -> String? {
        if isLoadingVoices { return nil }
        if !voices.isEmpty { return nil }

        isLoadingVoices = true
        voiceFetchError = nil
        defer { isLoadingVoices = false }

        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            voiceFetchError = "token_missing"
            return nil
        }

        do {
            let items = try await SettingsVoiceRepository.fetchVoices(token: token)
            voices = items
            if currentVoiceId.isEmpty {
                return items.first?.id
            }
        } catch {
            voiceFetchError = error.localizedDescription
        }
        return nil
    }

    func syncBoundCloneVoiceIfNeeded(wsDeviceId: String) async -> AutoVoiceSelection? {
        let deviceId = wsDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty else {
            print("[Settings] syncBoundCloneVoiceIfNeeded skipped: ws_device_id empty")
            return nil
        }
        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            print("[Settings] syncBoundCloneVoiceIfNeeded skipped: token missing")
            return nil
        }

        do {
            let payload = try await SettingsVoiceRepository.fetchBoundCloneVoice(deviceId: deviceId, token: token)
            guard let clone = payload.data.voice_clone else { return nil }
            let speakerId = clone.speaker_id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakerId.isEmpty else { return nil }
            if isUnknownCloneState(clone.state) {
                guard let fallbackId = voices.first(where: { $0.id != speakerId })?.id ?? voices.first?.id else {
                    print("[Settings] bound clone state=unknown but no fallback system voice available")
                    return nil
                }
                print("[Settings] bound clone state=unknown, fallback to system voice: \(fallbackId)")
                return AutoVoiceSelection(voiceId: fallbackId, isCloneVoice: false)
            }
            print("[Settings] auto-selected bound clone voice: \(speakerId)")
            return AutoVoiceSelection(voiceId: speakerId, isCloneVoice: true)
        } catch {
            print("[Settings] sync bound clone voice failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func isUnknownCloneState(_ state: String?) -> Bool {
        (state ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unknown"
    }

    func deviceConnectionText(ble: CallMateBLEClient, language: Language) -> String {
        let t: (String, String) -> String = { zh, en in
            language == .zh ? zh : en
        }
        switch ble.bluetoothState {
        case .poweredOff:
            return t("蓝牙未开启", "Bluetooth Off")
        case .unauthorized:
            return t("蓝牙权限未授权", "Bluetooth Permission Denied")
        case .unsupported, .resetting, .unknown:
            return t("未连接", "Disconnected")
        case .poweredOn:
            if ble.isReady && ble.connectedPeripheralID != nil {
                return t("已连接", "Connected")
            }
            if ble.connectingPeripheralID != nil || ble.connectedPeripheralID != nil {
                return t("连接中", "Connecting")
            }
            return t("未连接", "Disconnected")
        @unknown default:
            return t("未连接", "Disconnected")
        }
    }

    func deviceConnectionColor(ble: CallMateBLEClient) -> Color {
        if ble.bluetoothState == .poweredOff || ble.bluetoothState == .unauthorized {
            return AppColors.warning
        }
        if ble.bluetoothState != .poweredOn {
            return AppColors.textSecondary
        }
        if ble.isReady && ble.connectedPeripheralID != nil {
            return AppColors.success
        }
        if ble.connectingPeripheralID != nil || ble.connectedPeripheralID != nil {
            return AppColors.warning
        }
        return AppColors.textSecondary
    }

    func currentVoiceLabel(
        language: Language,
        voiceDisplayNameOverride: String,
        voiceId: String,
        voiceToneRaw: String
    ) -> String {
        if !voiceDisplayNameOverride.isEmpty {
            return voiceDisplayNameOverride
        }
        if let match = voices.first(where: { $0.id == voiceId }) {
            return match.name
        }
        return (VoiceTone(rawValue: voiceToneRaw) ?? .taiwan).displayName(language: language)
    }
}

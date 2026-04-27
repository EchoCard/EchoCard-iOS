import Foundation

enum SettingsVoiceRepository {
    static func fetchVoices(token: String) async throws -> [TTSVoice] {
        guard let url = URL(string: AppConfig.voiceApiBaseURL + "/api/tts/voices") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "SettingsVoiceRepository",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "http_\(http.statusCode)"]
            )
        }
        if let raw = String(data: data, encoding: .utf8) {
            print("[Settings] tts/voices response: \(raw)")
        }
        return try JSONDecoder().decode([TTSVoice].self, from: data)
    }

    static func fetchBoundCloneVoice(deviceId: String, token: String) async throws -> DeviceVoiceCloneResponse {
        guard let url = URL(string: AppConfig.voiceApiBaseURL + "/api/device/\(deviceId)/voice-clone") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DeviceVoiceCloneResponse.self, from: data)
    }
}

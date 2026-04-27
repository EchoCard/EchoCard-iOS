//
//  TTSFillerService.swift
//  CallMate
//
//  Wraps `POST /api/tts/fillers` on the new backend host.
//
//  Server returns a fixed set of short filler audios (e.g. "嗯", "哦") for the given
//  voice. These get pre-downloaded, re-encoded to mSBC, and pushed down to the MCU
//  so the firmware can play them on eSCO within a few tens of milliseconds after the
//  cloud pushes `{type:"filler",id}` on the AI WebSocket.
//
//  Pre-set voices: any caller can fetch; `device_id` is still required by schema but
//  does not enforce ownership.
//  Cloned voices: server enforces `devices.clone_voice_id == speaker_id`.
//
//  See: docs/tts-filler-low-latency.md §7.
//

import Foundation

/// One filler audio item as returned by the server.
struct TTSFillerItem: Sendable, Equatable {
    let fillerId: String
    let text: String
    let audioURL: URL
    let audioFormat: String
}

/// Response of `POST /api/tts/fillers`.
struct TTSFillerResponse: Sendable, Equatable {
    let voiceId: String
    let voiceSource: String
    let fillers: [TTSFillerItem]
}

enum TTSFillerServiceError: Error, CustomStringConvertible {
    case missingToken
    case http(status: Int, body: String)
    case invalidURL(String)
    case decode(String)

    var description: String {
        switch self {
        case .missingToken:
            return "TTSFillerService: missing JWT"
        case let .http(status, body):
            return "TTSFillerService: HTTP \(status) body=\(body)"
        case let .invalidURL(raw):
            return "TTSFillerService: invalid URL \(raw)"
        case let .decode(reason):
            return "TTSFillerService: decode failed \(reason)"
        }
    }
}

enum TTSFillerService {

    private static let apiBaseURL = URL(string: AppConfig.apiBaseURL)!
    private static let endpointPath = "/api/tts/fillers"

    /// Fetch fillers for the given voice.
    ///
    /// On HTTP 401, invalidates the cached JWT, re-bootstraps once, and retries.
    /// Any other non-2xx raises `.http`.
    static func fetchFillers(voiceId: String, deviceId: String) async throws -> TTSFillerResponse {
        let trimmedVoice = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDevice = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmedVoice.isEmpty, "voice_id must not be empty")
        precondition(!trimmedDevice.isEmpty, "device_id must not be empty")

        guard var token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            throw TTSFillerServiceError.missingToken
        }

        do {
            return try await requestOnce(voiceId: trimmedVoice, deviceId: trimmedDevice, bearer: token)
        } catch TTSFillerServiceError.http(status: 401, body: _) {
            print("[TTSFillers] 401, refreshing token and retrying once")
            // `invalidateCachedToken()` 是同步方法（仅改属性 + 清 UserDefaults），
            // 本项目 default actor isolation 会把 enum `TTSFillerService` 也推到 `@MainActor`，
            // 与 `BackendAuthManager`（显式 `@MainActor`）同隔离域，同步调用无 actor hop → 不需要 await。
            BackendAuthManager.shared.invalidateCachedToken()
            _ = await BackendAuthManager.shared.bootstrap()
            guard let fresh = await BackendAuthManager.shared.ensureToken(),
                  BackendAuthManager.looksLikeJWT(fresh) else {
                throw TTSFillerServiceError.missingToken
            }
            token = fresh
            return try await requestOnce(voiceId: trimmedVoice, deviceId: trimmedDevice, bearer: token)
        }
    }

    // MARK: - Private

    private static func requestOnce(voiceId: String, deviceId: String, bearer: String) async throws -> TTSFillerResponse {
        let url = apiBaseURL.appendingPathComponent(endpointPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let body = RequestBody(voice_id: voiceId, device_id: deviceId)
        request.httpBody = try JSONEncoder().encode(body)

        print("[TTSFillers] POST \(url.absoluteString) voice_id=\(voiceId) device_id=\(deviceId)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("[TTSFillers] HTTP \(http.statusCode) body=\(raw)")
            throw TTSFillerServiceError.http(status: http.statusCode, body: raw)
        }

        let decoded: Envelope
        do {
            decoded = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw TTSFillerServiceError.decode("\(error) body=\(raw.prefix(500))")
        }

        let items: [TTSFillerItem] = try decoded.data.fillers.map { raw in
            guard let url = URL(string: raw.audio_url) else {
                throw TTSFillerServiceError.invalidURL(raw.audio_url)
            }
            return TTSFillerItem(
                fillerId: raw.filler_id,
                text: raw.text,
                audioURL: url,
                audioFormat: raw.audio_format ?? "mp3"
            )
        }
        print("[TTSFillers] OK voice_id=\(decoded.data.voice_id) source=\(decoded.data.voice_source) count=\(items.count)")
        return TTSFillerResponse(
            voiceId: decoded.data.voice_id,
            voiceSource: decoded.data.voice_source,
            fillers: items
        )
    }

    // MARK: - Wire models

    private struct RequestBody: Encodable {
        let voice_id: String
        let device_id: String
    }

    private struct Envelope: Decodable {
        let data: Payload

        struct Payload: Decodable {
            let voice_id: String
            let voice_source: String
            let fillers: [Item]
        }

        struct Item: Decodable {
            let filler_id: String
            let text: String
            let audio_url: String
            let audio_format: String?
        }
    }
}

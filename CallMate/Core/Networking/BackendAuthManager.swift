//
//  BackendAuthManager.swift
//  CallMate
//
//  HTTP auth bootstrap:
//  - First launch: POST /api/app/register (pid_id + app_code)
//  - Then:        POST /api/app/token (app_code) -> JWT
//  - Persist token for subsequent requests (incl. WebSocket Authorization header)
//

import Foundation
import Combine
import CryptoKit
import UIKit

@MainActor
final class BackendAuthManager: ObservableObject {

    static let shared = BackendAuthManager()

    // MARK: - Config

    private let apiBaseURL = URL(string: AppConfig.apiBaseURL)!
    /// 控制面（`POST /api/callback` 等）。若与 `apiBaseURL` 不同域，在此单独配置 `AppConfig.controlApiBaseURL`。
    private let controlApiBaseURL = URL(string: AppConfig.controlApiBaseURL)!

    private let hardcodedPidId = AppConfig.hardcodedPidId
    private let hardcodedAppCode = AppConfig.hardcodedAppCode

    // MARK: - Storage keys

    private let pidIdKey = "callmate_pid_id"
    private let appCodeKey = "callmate_app_code_32"
    private let hasRegisteredKey = "callmate_has_registered"
    private let jwtTokenKey = "callmate_jwt_token"

    // MARK: - Device report
    fileprivate struct DeviceReportRequest: Encodable {
        let device_id: String
        let app_code: String
        let bluetooth_id: String
    }

    // MARK: - Published state

    @Published private(set) var pidId: String
    @Published private(set) var appCode: String
    @Published private(set) var token: String?

    private var bootstrappingTask: Task<String?, Never>?

    private init() {
        let defaults = UserDefaults.standard

        // TEMP: Use hardcoded credentials for testing
        let pid = hardcodedPidId
        let app = hardcodedAppCode
        
        defaults.set(pid, forKey: pidIdKey)
        defaults.set(app, forKey: appCodeKey)

        let cachedToken = defaults.string(forKey: jwtTokenKey)

        self.pidId = pid
        self.appCode = app
        self.token = cachedToken

        print("[Auth] init pid_id=\(pid) (hardcoded) app_code.len=\(app.count) (hardcoded) — see \(CallMateCredentialConsole.prefix) for full snapshot")
        CallMateCredentialConsole.logWhileSingletonIsInitializing(reason: "auth_manager_init", auth: self)
    }

    // MARK: - Public helpers

    /// Optional: override `app_code` at runtime (will be normalized to length 32 and persisted).
    func setAppCode(_ raw: String) {
        let normalized = Self.normalizeTo32(raw)
        appCode = normalized
        UserDefaults.standard.set(normalized, forKey: appCodeKey)
        print("[Auth] setAppCode app_code(32)=\(normalized) len=\(normalized.count)")
        CallMateCredentialConsole.log(reason: "app_code_changed")
    }

    /// Optional: override `pid_id` at runtime and persist it.
    func setPidId(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pidId = trimmed
        UserDefaults.standard.set(trimmed, forKey: pidIdKey)
        print("[Auth] setPidId pid_id=\(trimmed)")
        CallMateCredentialConsole.log(reason: "pid_id_changed")
    }

    /// Seconds before `exp` to proactively refresh. If server TTL is shorter than this (e.g. 1‑minute
    /// test tokens), lower this temporarily or JWT will look “always stale”.
    private static let jwtExpiryRefreshSkew: TimeInterval = 5 * 60

    /// Ensure we have a JWT that is still valid by `exp` (with skew). If missing/expired, run bootstrap.
    func ensureToken() async -> String? {
        if let token, Self.looksLikeJWT(token) {
            if let exp = Self.jwtExpirationDate(token) {
                if exp.timeIntervalSinceNow > Self.jwtExpiryRefreshSkew {
                    return token
                }
                print("[Auth] JWT exp=\(exp) expired or within \(Self.jwtExpiryRefreshSkew)s — refreshing")
                invalidateCachedToken()
                return await bootstrap()
            }
            // No `exp` in payload: keep using token (backward compatible).
            return token
        }
        return await bootstrap()
    }

    /// Clear cached JWT so the next `ensureToken()` / `bootstrap()` fetches a new one.
    func invalidateCachedToken() {
        token = nil
        UserDefaults.standard.removeObject(forKey: jwtTokenKey)
        print("[Auth] invalidated cached JWT")
        CallMateCredentialConsole.log(reason: "jwt_invalidated")
    }

    /// Run register (first install) + get_token. Safe to call multiple times.
    func bootstrap() async -> String? {
        if let existing = bootstrappingTask {
            return await existing.value
        }

        let snapshot = BackendAuthBootstrapSnapshot(
            pidId: pidId,
            appCode: appCode,
            cachedToken: token,
            hasRegistered: UserDefaults.standard.bool(forKey: hasRegisteredKey)
        )
        let apiBaseURL = self.apiBaseURL
        let hasRegisteredKey = self.hasRegisteredKey
        let jwtTokenKey = self.jwtTokenKey
        let appCodeKey = self.appCodeKey

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> String? in
            let result = await BackendAuthHTTPClient.bootstrap(
                apiBaseURL: apiBaseURL,
                snapshot: snapshot
            )
            let manager = self
            await MainActor.run {
                guard let manager else { return }
                if result.didRegister {
                    UserDefaults.standard.set(true, forKey: hasRegisteredKey)
                    print("[Auth] register OK -> set hasRegistered=true")
                }
                if result.resolvedAppCode != manager.appCode {
                    manager.appCode = result.resolvedAppCode
                    UserDefaults.standard.set(result.resolvedAppCode, forKey: appCodeKey)
                }
                if let token = result.token {
                    manager.token = token
                    UserDefaults.standard.set(token, forKey: jwtTokenKey)
                }
                manager.bootstrappingTask = nil
                CallMateCredentialConsole.log(reason: "bootstrap_http_complete")
            }
            return result.token
        }

        bootstrappingTask = task
        return await task.value
    }

    /// 控制面结果回传：`request_id` 由控制面签发，须 POST 至该域 `/api/callback`（勿误发到仅业务 API 域）。
    func postControlCallback(requestId: String, data: [String: Any]) async {
        guard !requestId.isEmpty else {
            print("[Auth] postControlCallback skipped: empty request_id")
            return
        }
        guard let token = await ensureToken(), Self.looksLikeJWT(token) else {
            print("[Auth] postControlCallback skipped: no JWT")
            return
        }
        let url = controlApiBaseURL.appendingPathComponent("/api/callback")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["request_id": requestId, "data": data]
        guard JSONSerialization.isValidJSONObject(body),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            print("[Auth] postControlCallback invalid JSON body")
            return
        }
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[Auth] postControlCallback bad response type")
                return
            }
            if (200..<300).contains(http.statusCode) {
                print("[Auth] postControlCallback OK url=\(url.absoluteString) request_id=\(requestId)")
            } else {
                let raw = String(data: data, encoding: .utf8) ?? ""
                print("[Auth] postControlCallback HTTP \(http.statusCode) url=\(url.absoluteString) request_id=\(requestId) body=\(raw)")
            }
        } catch {
            print("[Auth] postControlCallback error: \(error.localizedDescription)")
        }
    }

    /// Report device connection info to backend.
    /// Mirrors Python flow: POST /api/device/report with device_id/app_code/bluetooth_id.
    /// On **401**, invalidates JWT, re-bootstrap from `/api/app/token`, then retries once with the new Bearer.
    /// - Parameter token: Pass an existing token to avoid re-bootstrap; if nil, will try without auth.
    func reportDevice(deviceId: String, bluetoothId: String, token: String?) async throws {
        let appCode = self.appCode

        func attempt(bearer: String?) async throws {
            try await BackendAuthHTTPClient.reportDeviceSingle(
                apiBaseURL: apiBaseURL,
                deviceId: deviceId,
                appCode: appCode,
                bluetoothId: bluetoothId,
                bearerToken: bearer
            )
        }

        var bearer = token
        if bearer == nil || !Self.looksLikeJWT(bearer!) {
            bearer = await ensureToken()
        }

        if let t = bearer, Self.looksLikeJWT(t) {
            do {
                try await attempt(bearer: t)
                print("[Auth] device/report OK device_id=\(deviceId) bluetooth_id=\(bluetoothId)")
                return
            } catch {
                let ns = error as NSError
                if ns.domain == "BackendAuthManager", ns.code == 401 {
                    print("[Auth] device/report 401 — refreshing JWT and retrying once")
                    invalidateCachedToken()
                    _ = await bootstrap()
                    guard let fresh = await ensureToken(), Self.looksLikeJWT(fresh) else {
                        throw error
                    }
                    try await attempt(bearer: fresh)
                    print("[Auth] device/report OK after refresh device_id=\(deviceId) bluetooth_id=\(bluetoothId)")
                    return
                }
                print("[Auth] device/report failed with auth, retrying without auth: \(error)")
                try await attempt(bearer: nil)
                print("[Auth] device/report OK(no-auth) device_id=\(deviceId) bluetooth_id=\(bluetoothId)")
                return
            }
        }

        try await attempt(bearer: nil)
        print("[Auth] device/report OK(no-token) device_id=\(deviceId) bluetooth_id=\(bluetoothId)")
    }

    // MARK: - HTTP models

    fileprivate struct RegisterRequest: Encodable {
        let pid_id: String
        let app_code: String
        /// 1 = iOS, 2 = Android (see `/api/app/register`)
        var os_type: Int?

        enum CodingKeys: String, CodingKey {
            case pid_id, app_code, os_type
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pid_id, forKey: .pid_id)
            try c.encode(app_code, forKey: .app_code)
            try c.encodeIfPresent(os_type, forKey: .os_type)
        }
    }

    fileprivate struct TokenRequest: Encodable {
        let app_code: String
    }

    fileprivate struct RegisterResponse: Decodable {
        struct DataObj: Decodable {
            let id: Int?
            let pid_id: String?
            let app_code: String?
            let created_at: String?
            let updated_at: String?
        }
        let data: DataObj
    }

    fileprivate struct TokenResponse: Decodable {
        struct DataObj: Decodable {
            let token: String
        }
        let data: DataObj
    }

    // MARK: - HTTP calls

    /// Convert 32-char hex to UUID format (8-4-4-4-12)
    nonisolated fileprivate static func toUUIDFormat(_ hex: String) -> String {
        guard hex.count == 32 else { return hex }
        let s = hex.lowercased()
        let idx0 = s.startIndex
        let idx8 = s.index(idx0, offsetBy: 8)
        let idx12 = s.index(idx0, offsetBy: 12)
        let idx16 = s.index(idx0, offsetBy: 16)
        let idx20 = s.index(idx0, offsetBy: 20)
        return "\(s[idx0..<idx8])-\(s[idx8..<idx12])-\(s[idx12..<idx16])-\(s[idx16..<idx20])-\(s[idx20...])"
    }

    // MARK: - App code helpers (32 chars)

    private static func defaultAppCode32() -> String {
        let seed = Bundle.main.bundleIdentifier ?? "CallMate"
        return String(sha256Hex(seed).prefix(32))
    }

    /// Ensure output length is exactly 32.
    /// - If already 32: return as-is
    /// - Else: return first 32 hex chars of SHA256(raw)
    private static func normalizeTo32(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 32 { return trimmed }
        return String(sha256Hex(trimmed.isEmpty ? "CallMate" : trimmed).prefix(32))
    }

    private static func sha256Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func looksLikeJWT(_ token: String) -> Bool {
        // JWT typically has 3 segments separated by dots.
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.components(separatedBy: ".").count >= 3 && t.count > 20
    }

    /// JWT `exp` claim (seconds since 1970), if present and parseable.
    nonisolated static func jwtExpirationDate(_ token: String) -> Date? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let exp = obj["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = obj["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        if let exp = obj["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        return nil
    }
}

private struct BackendAuthBootstrapSnapshot: Sendable {
    let pidId: String
    let appCode: String
    let cachedToken: String?
    let hasRegistered: Bool
}

private struct BackendAuthBootstrapResult: Sendable {
    let token: String?
    let resolvedAppCode: String
    let didRegister: Bool
}

private enum BackendAuthHTTPClient {
    static func bootstrap(
        apiBaseURL: URL,
        snapshot: BackendAuthBootstrapSnapshot
    ) async -> BackendAuthBootstrapResult {
        var resolvedAppCode = snapshot.appCode
        var didRegister = false

        print("[Auth] bootstrap start hasRegistered=\(snapshot.hasRegistered)")

        if !snapshot.hasRegistered {
            do {
                let registerResponse = try await register(
                    apiBaseURL: apiBaseURL,
                    pidId: snapshot.pidId,
                    appCode: resolvedAppCode,
                    osType: 1
                )
                didRegister = true
                if let serverAppCode = registerResponse.data.app_code,
                   !serverAppCode.isEmpty,
                   serverAppCode != resolvedAppCode {
                    print("[Auth] register: updating app_code from server: \(serverAppCode)")
                    resolvedAppCode = serverAppCode
                }
            } catch {
                print("[Auth] register FAILED: \(error)")
            }
        } else {
            print("[Auth] register skipped (already registered)")
        }

        do {
            let tokenResult = try await getToken(apiBaseURL: apiBaseURL, appCode: resolvedAppCode)
            resolvedAppCode = tokenResult.resolvedAppCode
            let token = tokenResult.token
            print("[Auth] get_token OK token prefix=\(String(token.prefix(16)))... len=\(token.count)")
            return BackendAuthBootstrapResult(
                token: token,
                resolvedAppCode: resolvedAppCode,
                didRegister: didRegister
            )
        } catch {
            print("[Auth] get_token FAILED: \(error)")
            return BackendAuthBootstrapResult(
                token: snapshot.cachedToken,
                resolvedAppCode: resolvedAppCode,
                didRegister: didRegister
            )
        }
    }

    /// Single POST `/api/device/report` with optional Bearer (no retry — caller handles 401 refresh).
    static func reportDeviceSingle(
        apiBaseURL: URL,
        deviceId: String,
        appCode: String,
        bluetoothId: String,
        bearerToken: String?
    ) async throws {
        let url = apiBaseURL.appendingPathComponent("/api/device/report")
        let body = BackendAuthManager.DeviceReportRequest(
            device_id: deviceId,
            app_code: appCode,
            bluetooth_id: bluetoothId
        )
        try await postJSONExpectOK(url: url, body: body, bearerToken: bearerToken)
    }

    @discardableResult
    static func register(
        apiBaseURL: URL,
        pidId: String,
        appCode: String,
        osType: Int?
    ) async throws -> BackendAuthManager.RegisterResponse {
        let url = apiBaseURL.appendingPathComponent("/api/app/register")
        var body = BackendAuthManager.RegisterRequest(pid_id: pidId, app_code: appCode)
        body.os_type = osType

        print("[Auth] POST \(url.absoluteString) pid_id.len=\(pidId.count) app_code.len=\(appCode.count) os_type=\(osType.map(String.init) ?? "nil")")
        let response: BackendAuthManager.RegisterResponse = try await postJSON(
            url: url,
            body: body,
            responseType: BackendAuthManager.RegisterResponse.self
        )
        print("[Auth] register response id=\(response.data.id ?? -1) pid_id=\(response.data.pid_id ?? "nil") app_code=\(response.data.app_code ?? "nil")")
        return response
    }

    private static func getToken(
        apiBaseURL: URL,
        appCode: String
    ) async throws -> (token: String, resolvedAppCode: String) {
        let url = apiBaseURL.appendingPathComponent("/api/app/token")

        print("[Auth] POST \(url.absoluteString) app_code='\(appCode)'")
        do {
            let body = BackendAuthManager.TokenRequest(app_code: appCode)
            let response: BackendAuthManager.TokenResponse = try await postJSON(
                url: url,
                body: body,
                responseType: BackendAuthManager.TokenResponse.self
            )
            return (response.data.token, appCode)
        } catch {
            if appCode.count == 32 && !appCode.contains("-") {
                let uuidAppCode = BackendAuthManager.toUUIDFormat(appCode)
                print("[Auth] Retrying with UUID format app_code='\(uuidAppCode)'")
                let body = BackendAuthManager.TokenRequest(app_code: uuidAppCode)
                let response: BackendAuthManager.TokenResponse = try await postJSON(
                    url: url,
                    body: body,
                    responseType: BackendAuthManager.TokenResponse.self
                )
                print("[Auth] Saved UUID format app_code")
                return (response.data.token, uuidAppCode)
            }
            throw error
        }
    }

    /// Log server response for auth HTTP failures (status / body / decode).
    private static let authHTTPLogBodyMaxChars = 8192

    private static func logAuthHTTPFailure(
        label: String,
        url: URL,
        http: HTTPURLResponse?,
        data: Data,
        extra: String? = nil
    ) {
        let status = http.map { "\($0.statusCode)" } ?? "nil"
        let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
        var raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body, \(data.count) bytes>"
        if raw.count > authHTTPLogBodyMaxChars {
            raw = String(raw.prefix(authHTTPLogBodyMaxChars)) + "… [truncated, total \(data.count) bytes]"
        }
        let suffix = extra.map { " \($0)" } ?? ""
        print("[Auth][HTTP][\(label)] FAIL url=\(url.absoluteString) status=\(status) Content-Type=\(ct) body=\(raw)\(suffix)")
    }

    private static func postJSON<Body: Encodable, Resp: Decodable>(
        url: URL,
        body: Body,
        responseType: Resp.Type
    ) async throws -> Resp {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("[Auth][HTTP][postJSON] NETWORK url=\(url.absoluteString) error=\(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            logAuthHTTPFailure(label: "postJSON", url: url, http: nil, data: data, extra: "response not HTTPURLResponse")
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            logAuthHTTPFailure(label: "postJSON", url: url, http: http, data: data)
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw NSError(
                domain: "BackendAuthManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"]
            )
        }

        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            logAuthHTTPFailure(label: "postJSON-decode", url: url, http: http, data: data, extra: "decode error: \(error.localizedDescription)")
            throw error
        }
    }

    private static func postJSONExpectOK<Body: Encodable>(
        url: URL,
        body: Body,
        bearerToken: String?
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("[Auth][HTTP][device/report] NETWORK url=\(url.absoluteString) error=\(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            logAuthHTTPFailure(label: "expectOK", url: url, http: nil, data: data, extra: "response not HTTPURLResponse")
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            logAuthHTTPFailure(label: "expectOK", url: url, http: http, data: data)
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw NSError(
                domain: "BackendAuthManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"]
            )
        }
    }
}


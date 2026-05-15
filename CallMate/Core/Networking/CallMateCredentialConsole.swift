//
//  CallMateCredentialConsole.swift
//  CallMate
//
//  统一前缀 `[CallMateCred]`：一次性打印 Phone API 调试常用字段，便于 Xcode 控制台过滤。
//

import Foundation

/// EchoCard Phone skill 常用：`jwt` ≈ TOKEN；`mcu_device_id` 多为设备侧 DEVICE_ID（与后台约定为准）；`pid_id` 为 App 注册维度 ID。
enum CallMateCredentialConsole {
    static let prefix = "[CallMateCred]"

    /// 未设置时为 `true`（完整 JWT）。设为 `NO` 可截断敏感字段以防日志外泄。
    private static let fullSensitiveKey = "callmate.log_full_sensitive"

    private static var shouldPrintFullSensitive: Bool {
        if UserDefaults.standard.object(forKey: fullSensitiveKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: fullSensitiveKey)
    }

    /// 正常路径；会读 `BackendAuthManager.shared`。
    @MainActor
    static func log(reason: String) {
        emitSnapshot(reason: reason, auth: BackendAuthManager.shared)
    }

    /// **仅**在 `BackendAuthManager.init` 末尾调用。此处单例尚未初始化完成，禁止走 `log(reason:)`（会再次访问 `.shared` 导致崩溃）。
    @MainActor
    static func logWhileSingletonIsInitializing(reason: String, auth: BackendAuthManager) {
        emitSnapshot(reason: reason, auth: auth)
    }

    @MainActor
    private static func emitSnapshot(reason: String, auth: BackendAuthManager) {
        let ble = CallMateBLEClient.shared
        let d = UserDefaults.standard
        let jwt = auth.token ?? d.string(forKey: "callmate_jwt_token")
        let mcuRaw = ble.runtimeMCUDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mcu = (mcuRaw?.isEmpty == false) ? mcuRaw! : "nil"

        print("\(prefix) ----- snapshot reason=\(reason) -----")
        print("\(prefix) pid_id=\(auth.pidId)")
        print("\(prefix) app_code=\(auth.appCode)")
        if shouldPrintFullSensitive, let jwt, !jwt.isEmpty {
            print("\(prefix) jwt=\(jwt)")
        } else if let jwt, !jwt.isEmpty {
            print("\(prefix) jwt=\(String(jwt.prefix(24)))… len=\(jwt.count) hint=set UserDefaults key \(fullSensitiveKey)=YES for full")
        } else {
            print("\(prefix) jwt=nil")
        }
        print("\(prefix) mcu_device_id=\(mcu)")
        print("\(prefix) api_base=\(AppConfig.apiBaseURL)")
        print("\(prefix) control_api_base=\(AppConfig.controlApiBaseURL)")
        print("\(prefix) ----- end -----")
    }
}

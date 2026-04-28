// AppConfig.swift — 后端入口集中在此；模板见 AppConfig.swift.template（内容应对齐）
//
//   • api / control / voice HTTPS → BackendAuth、TTSFiller、ChatSummary、语音与 Onboarding
//   • wsBaseURL → WebSocketService
//   • fwServerBaseURL → FirmwareUpdateService（OTA）
enum AppConfig {
    // MARK: Dev — HTTPS API（REST / 语音 HTTP）
    private static let apiDevHTTPSBase = "https://api-dev.echocard.com"

    /// App 注册、JWT、`TTSFillerService`、设备上报等主 REST API。
    static let apiBaseURL = apiDevHTTPSBase

    /// 控制面回调等（`/api/callback`）。dev 与主 API 同网关；若线上拆分控制域，只改此处对应常量。
    static let controlApiBaseURL = apiDevHTTPSBase

    /// 语音克隆 / TTS 列表等（与 `apiBaseURL` 对齐）。
    static let voiceApiBaseURL = apiDevHTTPSBase

    /// xiaozhi WebSocket（通话 / 配置 / 外呼对话等）。
    static let wsBaseURL = "wss://chat-dev.echocard.com"

    /// OTA 固件元数据与下载基址（与 Android `fw_server_base_url` 一致）。
    static let fwServerBaseURL = "http://120.24.162.199/echocard"

    // MARK: 测试用注册凭据（仅开发环境；公开仓库请改为占位符）
    static let hardcodedPidId = "31ead3ac-ede8-4e81-b405-12be65f7b7e8"
    static let hardcodedAppCode = "3c4ff237-7501-f967-f21a-34a43bd650f5"
}

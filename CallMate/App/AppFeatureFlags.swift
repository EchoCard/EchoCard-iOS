import Foundation

enum AppFeatureFlags {
    /// 是否启用 ANCS 授权流程。
    /// false：跳过验证命令、不弹引导 Sheet、不显示警告 Banner，iOS 不会出现系统授权通知。
    /// true ：保持原有完整 ANCS 授权流程。
    static let ancsAuthorizationEnabled: Bool = false
}

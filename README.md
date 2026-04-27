# EchoCard iOS

EchoCard 的 iOS 客户二次开发仓。

当前仓库已经把对外交付名称切到 `EchoCard`，并将 BLE 能力封装为预编译 XCFramework（Binary Pod）。为了兼容现有代码，部分内部 target / scheme / source folder 仍保留 `CallMate` 命名，这不影响日常二开与编译。

## 快速开始

无需任何私有仓库权限，开箱即用：

1. 克隆本仓库
2. 在仓库根目录执行 `pod install`（BLE 库会自动从 GitHub Releases 下载，无需 token）
3. 打开 `EchoCard.xcworkspace`
4. 在 Xcode 中选择 `CallMate` scheme 运行

命令行验证：

```bash
pod install
xcodebuild -workspace EchoCard.xcworkspace -scheme CallMate -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

## 文档

- `docs/IOS_SECONDARY_DEVELOPMENT_GUIDE.md`
- `docs/MOBILE_BLE_PREBUILDS.md`

## 交付边界

- 可直接二开：UI、业务流程、本地数据、提示词、后端地址、外呼模板
- 私有封装：BLE 协议、OTA 传输、与 MCU 强绑定的控制命令和音频链路

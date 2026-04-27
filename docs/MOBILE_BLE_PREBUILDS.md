# 移动端 BLE 预编译依赖（对公开客户端工程）

**BLE 实现源码不随** `EchoCard-iOS` / `EchoCard-Android` 公开；这两仓只带**可公开的预编译**形式，便于在 GitHub 上全公开。

## iOS（CocoaPods）

- 在仓库中：`ThirdParty/CallMateBLEKit/CallMateBLEKit.podspec`，通过 `s.source` 的 **HTTP** 从 **本应用仓库的公开 GitHub Release** 拉取 `CallMateBLEKit.xcframework`。
- `Podfile` 使用**本仓**路径引用该 podspec，**不**用 `:git` 指向任何私有库。
- 维护者需在本应用仓库上创建 Release 标签 `callmate-ble-0.1.0`，并上传与 `sha256` 一致的 `CallMateBLEKit.xcframework.zip` 后，`pod install` 才能通过（详见 `ThirdParty/CallMateBLEKit/README.md`）。

## Android

- 预编译 AAR 放在本仓 `app/libs/callmate-ble-0.1.0.aar`，`app/build.gradle.kts` 使用 `implementation(files(...))` 引用，**不**从私有 Maven 拉取即可构建；公开仓库历史里不应再记录「必须 `read:packages` 才能解 BLE」的旧路径为唯一方式。

## 与内部私有工程的关系

内部 `EchoCardBLEKit` / `EchoCardAndroidBLE` 为**私有的**源码与构建用仓库；公开客户端仓**不**应在其历史中保留可复现出上述私有树或旧 `git+tag` 的提交。

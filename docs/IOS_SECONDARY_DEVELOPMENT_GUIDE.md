# EchoCard iOS 二次开发指南

> 元信息
> - Tags: `ios` `dev` `workflow` `build` `product`
> - Scope: `docs`
> - Priority: `high`
> - Related: `docs/MOBILE_BLE_PREBUILDS.md`, `docs/ARCHITECTURE.md`, `docs/CALLMATE_QUICK_INDEX.md`

> 适用对象：基于公开 `EchoCard-iOS` 做二开；BLE 通过本仓内 `ThirdParty/CallMateBLEKit/CallMateBLEKit.podspec` 的 **HTTP** 拉取预编译包，不依赖任何私有 Git 的 BLE 源码树。
>
> 说明：当前仓内为了兼容既有代码，部分内部 target / source folder / module 仍保留 `CallMate` 命名；对外仓库名、工作区名和交付文档已经切换为 `EchoCard`。
>
> 本文重点讲两件事：
> 1. 客户现在拿到的 iOS 主仓，哪些部分可以放心二开
> 2. 哪些改动会越过 BLE/协议/固件边界，需要和交付方一起改

---

## 1. 先看交付边界

当前 iOS 侧已经拆成了两层：

| 层 | 位置 | 是否开放二开 | 说明 |
|---|---|---|---|
| 主 App | `CallMate/` | 是 | UI、业务流程、本地数据、WebSocket、设置页、AI 提示词、外呼模板等都在这里 |
| 预编译 BLE 库 | `CallMateBLEKit`（CocoaPods + HTTP） | 否（默认） | 以 xcframework 形式从本应用仓库的公开 Release 拉取，不随本仓提供实现源码 |

你可以把它理解成：

- **客户可改**：品牌、界面、导航、AI 策略、提示词、后端地址、外呼模板、持久化字段、日志与运营能力
- **默认不要改**：BLE 协议、HFP/ANCS 相关实现、OTA 传输协议、与 MCU 强绑定的命令字和 ACK 行为

如果需求涉及下面这些内容，建议直接走交付方协作：

- 新增/修改 BLE 命令、UUID、Characteristic
- 修改 OTA 分包格式、ACK 规则、重传策略
- 修改与 MCU 对齐的音频帧格式
- 修改需要同步固件的协议字段

---

## 2. 本地开发环境

### 2.1 必备条件

- macOS
- Xcode
- CocoaPods
- 维护者已在 **本应用** GitHub 上发布 `callmate-ble-0.1.0` 与 `CallMateBLEKit.xcframework.zip`（与 `ThirdParty/CallMateBLEKit/CallMateBLEKit.podspec` 中 `sha256` 一致），详见 `ThirdParty/CallMateBLEKit/README.md`

### 2.2 预编译 BLE 依赖接入方式

`Podfile` 使用**本仓** podspec，通过 **HTTP** 从本应用仓库的 **公开** Release 下载框架，不引用私有 `EchoCard/EchoCardBLEKit` 等：

```ruby
pod 'CallMateBLEKit', :podspec => 'ThirdParty/CallMateBLEKit/CallMateBLEKit.podspec'
```

先验证：

```bash
cd /path/to/EchoCard-iOS
pod install
```

若 404，说明尚未上传对应 Release 资产，或 `sha256` 与 zip 不一致。

### 2.3 打开和编译

先安装依赖：

```bash
pod install
```

再打开工作区：

```bash
open EchoCard.xcworkspace
```

命令行验证编译可使用：

```bash
xcodebuild -workspace EchoCard.xcworkspace -scheme CallMate -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' build
```

如果你的本机没有 `iPhone 17` 模拟器，把 `name=` 改成 Xcode 当前可用的模拟器即可。

---

## 3. 项目结构与常用入口

客户二开时，优先看这些入口：

| 目标 | 先看这些文件 |
|---|---|
| App 启动 / 依赖装配 | `CallMate/App/CallMateApp.swift`, `CallMate/App/AppServices.swift` |
| 根路由 / 绑定流 / 主界面切换 | `CallMate/App/ContentView.swift` |
| 首页与 AI 分身入口 | `CallMate/App/MainTabView.swift` |
| 首次引导 / AI 配置向导 | `CallMate/App/OnboardingView.swift` |
| 设置页 / 语音 / 设备入口 | `CallMate/Features/Settings/SettingsView.swift` |
| 来电与通话流程 | `CallMate/Core/Telephony/` |
| 后端注册 / JWT / 设备上报 | `CallMate/Core/Networking/BackendAuthManager.swift` |
| 主 WebSocket | `CallMate/Core/Networking/WebSocketService.swift` |
| 通话摘要 / TTS filler / 语音克隆接口 | `CallMate/Core/Networking/`, `CallMate/Features/Settings/SettingsVoiceRepository.swift` |
| 默认代接策略 | `CallMate/Data/Stores/ProcessStrategyStore.swift` |
| 本地持久化模型 | `CallMate/Data/Models/PersistenceModels.swift` |
| AI 聊天历史 | `CallMate/Data/AIChatHistoryService.swift` |
| Prompt 资源 | `CallMate/Resources/Prompts/` |
| BLE 对外类型别名 | `CallMate/App/CallMateBLEKitAliases.swift` |

---

## 4. 客户最常改的内容

### 4.1 改品牌名、包名、图标

常见改动点：

- App 显示名：`EchoCard.xcodeproj/project.pbxproj`
- Bundle Identifier：`EchoCard.xcodeproj/project.pbxproj`
- App 图标：`CallMate/Assets.xcassets/AppIcon.appiconset/`
- 品牌图标与语音头像：`CallMate/Assets.xcassets/`
- URL Scheme / ATS / 后台模式：`Info.plist`
- Push 环境：`CallMate/CallMate.entitlements`
- Live Activity 扩展 Bundle ID：同样在 `EchoCard.xcodeproj/project.pbxproj`

特别提醒：

- 如果修改主包名，**别漏掉** Live Activity 扩展的 Bundle Identifier
- 如果修改 URL Scheme，注意和 `callmate://livecall` 相关的深链联动

### 4.2 改后端地址和接口

当前仓库里，后端地址不是完全收拢在一个文件里，客户二开时要成组排查。

重点文件：

- 主业务域名 / JWT / 设备上报：
  - `CallMate/Core/Networking/BackendAuthManager.swift`
- 主通话 WebSocket：
  - `CallMate/Core/Networking/WebSocketService.swift`
- 通话摘要：
  - `CallMate/Core/Networking/ChatSummaryService.swift`
- filler 预加载：
  - `CallMate/Core/Networking/TTSFillerService.swift`
- 声音克隆 / 音色列表：
  - `CallMate/Features/Settings/SettingsVoiceRepository.swift`
  - `CallMate/App/OnboardingView.swift`
- 固件服务器：
  - `CallMate/Features/Device/FirmwareUpdateService.swift`

建议全仓先 grep 一遍这些关键字：

```bash
rg -n "echocard.xiaozhi.me|echocard-control.xiaozhi.me|120.79.156.134|120.24.162.199|ws://|wss://" CallMate
```

通常客户第一轮切环境，至少要核对下面几类地址：

- App 注册 / Token / 设备上报
- AI 通话 WebSocket
- 通话摘要 HTTP
- 语音克隆接口
- 固件升级接口

### 4.3 改 AI 提示词、引导话术、默认策略

最常用入口：

- 内置 Prompt 文件：`CallMate/Resources/Prompts/*.txt`
- 运行时 Prompt 分段：`CallMate/Resources/Prompts/runtime/*.txt`
- 首次引导文案与引导消息：`CallMate/App/OnboardingView.swift`
- 用户可编辑的 Prompt：`CallMate/Features/Prompts/PromptEditorView.swift`
- 默认代接策略：`CallMate/Data/Stores/ProcessStrategyStore.swift`

建议做法：

1. 先改 `Resources/Prompts/` 中的静态 prompt
2. 再改 `OnboardingView.swift` 里的引导消息和交互文案
3. 如果要改默认代接规则，再调整 `ProcessStrategyStore.defaultRules()`

### 4.4 改 UI、业务流程、本地数据

常见入口：

- 首页和主导航：`CallMate/App/MainTabView.swift`
- 绑定流程：`CallMate/Features/Device/BindingFlowView.swift`
- 设置页：`CallMate/Features/Settings/`
- 来电/外呼页面：`CallMate/Features/Calls/`
- 通话记录与摘要模型：`CallMate/Data/Models/PersistenceModels.swift`
- AI 聊天历史：`CallMate/Data/AIChatHistoryService.swift`
- 通用组件：`CallMate/Shared/UI/`

### 4.5 改外呼模板和外呼流程

相关文件：

- 默认外呼模板入口：`CallMate/Features/Calls/Outbound/OutboundCallsView.swift`
- 外呼任务模型与队列：`CallMate/Features/Calls/Outbound/OutboundTaskModels.swift`, `CallMate/Features/Calls/Outbound/OutboundTaskQueueService.swift`
- 外呼模板持久化模型：`CallMate/Data/Models/PersistenceModels.swift`
- AI 分身页里的模板管理：`CallMate/Features/Settings/AISecView.swift`

---

## 5. BLE 相关改动应该怎么理解

现在主仓里与 BLE 的连接点，主要是：

- `CallMate/App/CallMateBLEKitAliases.swift`
- `CallMate/App/AppServices.swift`
- `CallMate/Core/Telephony/`
- `CallMate/Features/Device/`

其中：

- `CallMateBLEKitAliases.swift` 只是 **类型别名转发层**
- 真正的 BLE 实现已经在私有 `CallMateBLEKit` 里

所以客户可以做的 BLE 周边二开，通常是：

- 调整设备页 UI
- 调整连接状态展示
- 调整绑定流程上的文案、动画、交互
- 使用私有库已经暴露出来的状态和事件

默认不建议客户自己做的，是：

- 修改 BLE 控制命令
- 修改 GATT 服务/特征
- 修改 OTA 包格式
- 修改与 MCU 交互的 JSON 协议字段

凡是碰到协议字段变更，请默认按“**iOS 主 App + 私有 BLE 库 + MCU 固件**”三方联动来评估。

---

## 6. 推荐的二开顺序

建议客户按这个顺序推进，返工最少：

1. 先改品牌元素
   - App 名称、Bundle ID、图标、启动后第一屏文案
2. 再改后端环境
   - 注册域名、WebSocket、摘要服务、语音克隆、OTA 服务
3. 再改 AI 策略
   - Prompt、默认规则、引导流程、外呼模板
4. 最后改业务 UI
   - Calls / Settings / Device / AI 分身页
5. BLE/协议相关改动放到最后，单独立项

---

## 7. 交付前自检清单

完成二开后，至少做下面这些验证：

1. `pod install` 成功
2. `EchoCard.xcworkspace` 可正常编译
3. 真机安装成功，蓝牙权限、麦克风权限、推送权限文案正确
4. 设备可以正常绑定
5. 来电流程可走通
6. AI 接听、摘要、设置页、策略页可正常工作
7. 如果改了后端地址，确认 WebSocket、JWT、语音克隆、OTA 都指向新环境

---

## 8. 客户需要知道的限制

- `CallMate-Bridging-Header.h` 路径固定，不要移动
- 不要手改 `Pods/` 目录内容
- `Podfile.lock` 不要手工编辑
- 如果修改 BLE 协议字段，必须同步评估 MCU 侧影响
- 如果只改了 iOS 主工程代码，最终仍需要 **Xcode 重新编译并安装到手机**

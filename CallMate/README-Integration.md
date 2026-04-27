# CallMate WebSocket 集成说明

## 概述

已将 `xiaozhi-protocal` WebSocket 协议集成到 iOS 模拟通话页面。

## 新增文件

| 文件 | 说明 |
|------|------|
| `WebSocketService.swift` | WebSocket 通信服务（协议消息收发） |
| `AudioService.swift` | 音频服务（录音/播放） |
| `OpusCodec.swift` | Opus 编解码器（支持 Mock 和真实模式） |
| `Info.plist` | 权限配置 |
| `CallMate-Bridging-Header.h` | C 库桥接头（启用真实 Opus 时需要） |

## 已配置的权限

- **麦克风权限** (`NSMicrophoneUsageDescription`)
- **后台音频** (`UIBackgroundModes: audio`)

## 当前模式

项目默认使用 **Mock 模式**（不需要 libopus 库），可以编译运行，但：
- 上行音频不会真正编码为 Opus，服务端无法识别
- 下行音频不会真正解码，播放静音

这个模式用于 **UI 测试和开发**。

## 启用真实 Opus 编解码

### 步骤 1：添加 libopus 库

**方式 A：CocoaPods（推荐）**

```bash
# 在项目根目录创建 Podfile
cat > Podfile << 'EOF'
platform :ios, '15.0'
use_frameworks!

target 'CallMate' do
  pod 'libopus', '~> 1.3'
end
EOF

# 安装
pod install

# 之后使用 CallMate.xcworkspace 打开项目
```

**方式 B：Swift Package Manager**

1. Xcode → File → Add Package Dependencies
2. 输入：`https://github.com/nicklockwood/SwiftOpus.git`
3. 添加到 CallMate target

### 步骤 2：启用桥接头

在 Xcode Build Settings 中：
- 搜索 "Bridging Header"
- 设置 `Objective-C Bridging Header` 为 `CallMate/CallMate-Bridging-Header.h`

### 步骤 3：取消注释桥接头内容

编辑 `CallMate-Bridging-Header.h`，取消 `#include <opus/opus.h>` 的注释。

### 步骤 4：开启真实模式

编辑 `OpusCodec.swift`，将：
```swift
let USE_REAL_OPUS = false
```
改为：
```swift
let USE_REAL_OPUS = true
```

## WebSocket 协议

### 连接地址
```
ws://120.79.156.134:8081
```

### 请求头
```
Device-Id: <设备UUID>
Client-Id: CallMate-iOS
Protocol-Version: 1
```

### 消息流程

```
┌──────────┐                    ┌──────────┐
│  Client  │                    │  Server  │
└────┬─────┘                    └────┬─────┘
     │  1. Connect                   │
     │ ─────────────────────────────>│
     │                               │
     │  2. Hello (audio_params)      │
     │ ─────────────────────────────>│
     │                               │
     │  3. Hello (session_id)        │
     │ <─────────────────────────────│
     │                               │
     │  4. Listen(start)             │
     │ ─────────────────────────────>│
     │                               │
     │  5. Binary (Opus audio)       │
     │ ─────────────────────────────>│
     │  ...                          │
     │                               │
     │  6. Listen(stop)              │
     │ ─────────────────────────────>│
     │                               │
     │  7. STT (识别结果)             │
     │ <─────────────────────────────│
     │                               │
     │  8. TTS(start)                │
     │ <─────────────────────────────│
     │                               │
     │  9. Binary (Opus audio)       │
     │ <─────────────────────────────│
     │  ...                          │
     │                               │
     │ 10. TTS(stop)                 │
     │ <─────────────────────────────│
     │                               │
```

### 音频参数

| 方向 | 采样率 | 格式 | 声道 | 帧时长 |
|------|--------|------|------|--------|
| 上行 (Client→Server) | 16000 Hz | Opus | 1 | 60ms |
| 下行 (Server→Client) | 24000 Hz | Opus | 1 | 60ms |

## 使用方式

### SimulationView（模拟通话页面）

自动使用真实 WebSocket 连接：

```swift
SimulationView(language: .zh) {
    // 通话结束回调
}
```

### LockScreenSimulationView（锁屏模拟）

支持切换模式：

```swift
// 模拟模式（默认，使用预设对话）
LockScreenSimulationView(language: .zh, onClose: {})

// 真实模式（使用 WebSocket）
LockScreenSimulationView(language: .zh, onClose: {}, useRealConnection: true)
```

## 调试技巧

### 1. 文本模式测试

如果 Opus 编解码有问题，可以跳过录音直接发文本：

```swift
// 在 SimulationView 中点击"文本"按钮
// 或手动调用：
WebSocketService.shared.sendListenText("请问机主在吗？")
```

### 2. 查看日志

所有关键事件都有 `[WS]` 或 `[Audio]` 前缀的日志输出。

### 3. 检查连接状态

```swift
if WebSocketService.shared.isConnected {
    print("Session: \(WebSocketService.shared.sessionId ?? "nil")")
}
```

## 故障排除

### 问题：麦克风权限被拒绝

- 检查 Info.plist 中是否有 `NSMicrophoneUsageDescription`
- 在系统设置中手动开启权限

### 问题：WebSocket 连接失败

- 检查网络连接
- 确认服务器地址 `ws://120.79.156.134:8081` 可访问

### 问题：服务端返回"抱歉没听清"

- 这是服务端正常响应，表示它不理解输入内容
- 服务端是一个电话私人秘书场景，需要发送类似"请问机主在吗"这样的问题

//
//  WebSocketCloseSemantics.swift
//  CallMate
//
//  与网关约定的 WebSocket Close Code + UTF-8 reason 字符串对齐（见 mobile-websocket / 后端说明）。
//

import Foundation

/// 后端下发的关闭原因字符串（与 Close 帧 UTF-8 payload 一致，区分 1011/1008 等多义 code）。
enum WebSocketCloseReason: String, Equatable, Sendable, CaseIterable {
    case normalEnd = "normal_end"
    case idleTimeout = "idle_timeout"
    case internalError = "internal_error"
    case asrClosed = "asr_closed"
    case ttsError = "tts_error"
    case unauthorized = "unauthorized"
    case invalidDevice = "invalid_device"
    case replaced = "replaced"
    case initError = "init_error"
    case socketError = "socket_error"
}

/// 解析后的关闭语义；业务分流应使用 `kind`，不能仅依赖 RFC close code（尤其 1011）。
enum WebSocketCloseReasonKind: Equatable, Sendable {
    case normalEnd
    case idleTimeout
    case replaced
    case unauthorized
    case invalidDevice
    case internalError
    case asrClosed
    case ttsError
    case initError
    case socketError
    /// code / reason 与已知枚举不完全匹配时保留原始信息。
    case unknown(closeCode: Int?, reason: String?)
    /// 无有效 Close 帧（断网、系统错误等）。
    case transportError
}

struct WebSocketDisconnectInfo: Equatable, Sendable {
    let closeCode: Int?
    let closeReasonRaw: String?
    let kind: WebSocketCloseReasonKind

    var logDescription: String {
        let codeStr = closeCode.map { String($0) } ?? "nil"
        let reasonStr = closeReasonRaw.map { "\"\($0)\"" } ?? "nil"
        let kindStr: String
        switch kind {
        case .normalEnd: kindStr = "normalEnd"
        case .idleTimeout: kindStr = "idleTimeout"
        case .replaced: kindStr = "replaced"
        case .unauthorized: kindStr = "unauthorized"
        case .invalidDevice: kindStr = "invalidDevice"
        case .internalError: kindStr = "internalError"
        case .asrClosed: kindStr = "asrClosed"
        case .ttsError: kindStr = "ttsError"
        case .initError: kindStr = "initError"
        case .socketError: kindStr = "socketError"
        case .unknown(let c, let r): kindStr = "unknown(code:\(c.map(String.init) ?? "nil"),reason:\(r.map { "\"\($0)\"" } ?? "nil"))"
        case .transportError: kindStr = "transportError"
        }
        return "code=\(codeStr) reason=\(reasonStr) kind=\(kindStr)"
    }
}

enum WebSocketCloseSemantics {
    /// 从 `URLSessionWebSocketTask` 与失败错误构造断开信息；`task` 在 receive 失败回调中通常仍可读 close 元数据。
    static func disconnectInfo(from task: URLSessionWebSocketTask?, error: Error) -> WebSocketDisconnectInfo {
        let code: Int?
        let reasonData: Data?
        if let task {
            if task.closeCode == .invalid {
                return WebSocketDisconnectInfo(closeCode: nil, closeReasonRaw: nil, kind: .transportError)
            }
            code = Int(task.closeCode.rawValue)
            reasonData = task.closeReason
        } else {
            code = nil
            reasonData = nil
        }

        let reasonStr = reasonData
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = (reasonStr?.isEmpty == true) ? nil : reasonStr

        if let known = normalizedReason.flatMap(WebSocketCloseReason.init(rawValue:)) {
            let kind = mapKnownReason(known)
            return WebSocketDisconnectInfo(closeCode: code, closeReasonRaw: normalizedReason, kind: kind)
        }

        if let c = code, c == 1000, normalizedReason == nil {
            return WebSocketDisconnectInfo(closeCode: c, closeReasonRaw: normalizedReason, kind: .normalEnd)
        }

        if normalizedReason != nil || code != nil {
            return WebSocketDisconnectInfo(closeCode: code, closeReasonRaw: normalizedReason, kind: .unknown(closeCode: code, reason: normalizedReason))
        }

        return WebSocketDisconnectInfo(closeCode: nil, closeReasonRaw: nil, kind: .transportError)
    }

    private static func mapKnownReason(_ r: WebSocketCloseReason) -> WebSocketCloseReasonKind {
        switch r {
        case .normalEnd: return .normalEnd
        case .idleTimeout: return .idleTimeout
        case .internalError: return .internalError
        case .asrClosed: return .asrClosed
        case .ttsError: return .ttsError
        case .unauthorized: return .unauthorized
        case .invalidDevice: return .invalidDevice
        case .replaced: return .replaced
        case .initError: return .initError
        case .socketError: return .socketError
        }
    }
}

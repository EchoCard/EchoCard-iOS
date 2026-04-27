//
//  ControlChannelService.swift
//  CallMate
//
//  控制通道：服务端经 APNs Background Push 下发指令（无长连接 WebSocket）。
//  解析 `event == command` 的 payload，调用 OutboundTaskQueueService；查询类指令结果经 POST /api/callback 回传（外呼执行结束不再 callback）。
//

import Foundation
import Combine
import UIKit
import SwiftData

@MainActor
final class ControlChannelService: ObservableObject {
    static let shared = ControlChannelService()

    /// 最近一次向服务端同步 APNs 注册是否成功（非「在线」状态——推送无持久连接）
    @Published private(set) var isRegistered = false
    @Published private(set) var lastError: String?

    /// 幂等：避免推送重试重复执行（FIFO 窗口）
    private var recentRequestIdOrder: [String] = []
    private var recentRequestIdSet = Set<String>()
    private let maxTrackedRequestIds = 200

    private init() {}

    /// 与 MCU device-id 就绪后调用：上报 JWT + APNs 至 `/api/app/register`，供服务端下发静默推送。
    func activate() {
        Task { await activateAsync() }
    }

    func deactivate() {
        lastError = nil
        isRegistered = false
    }

    private func activateAsync() async {
        let mcuDeviceId: String? = await MainActor.run {
            CallMateBLEClient.shared.runtimeMCUDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let deviceId = mcuDeviceId, !deviceId.isEmpty else {
            lastError = "mcu_not_ready"
            isRegistered = false
            print("[ControlPush] activate skipped: MCU not connected or device-id not synced yet")
            return
        }
        guard let token = await BackendAuthManager.shared.ensureToken(),
              BackendAuthManager.looksLikeJWT(token) else {
            lastError = "token_missing"
            isRegistered = false
            print("[ControlPush] activate skipped: no JWT token (bootstrap first)")
            return
        }
        _ = token
        let ok = await BackendAuthManager.shared.syncPushRegistration()
        if ok {
            lastError = nil
            isRegistered = true
            print("[ControlPush] activate OK Device-Id=\(deviceId) (MCU) + push registration synced")
        } else {
            lastError = "push_register_failed"
            isRegistered = false
        }
    }

    /// 后台/前台收到静默推送时调用（`event` == `command`）。
    func handleRemoteNotificationPayload(_ userInfo: [AnyHashable: Any]) async {
        let stringKeyed = Self.flattenUserInfoToStringAny(userInfo)
        guard let event = stringKeyed["event"] as? String, event == "command" else { return }

        let requestId = stringKeyed["request_id"] as? String ?? ""
        if !requestId.isEmpty {
            if recentRequestIdSet.contains(requestId) {
                print("[ControlPush] duplicate request_id=\(requestId), skip")
                return
            }
            recentRequestIdSet.insert(requestId)
            recentRequestIdOrder.append(requestId)
            while recentRequestIdOrder.count > maxTrackedRequestIds, let old = recentRequestIdOrder.first {
                recentRequestIdOrder.removeFirst()
                recentRequestIdSet.remove(old)
            }
        }

        guard let action = stringKeyed["action"] as? String ?? stringKeyed["type"] as? String else {
            print("[ControlPush] missing action in command payload")
            return
        }

        await handleAction(action, requestId: requestId, json: stringKeyed)
    }

    /// 将 APNs `userInfo` 转为 `[String: Any]`，并把 `params` 字典合并到顶层（与文档一致，且兼容旧 WS 顶层字段）。
    private static func flattenUserInfoToStringAny(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        var merged: [String: Any] = [:]
        for (k, v) in userInfo {
            guard let ks = k as? String else { continue }
            merged[ks] = v
        }
        if let params = merged["params"] as? [String: Any] {
            for (k, v) in params {
                merged[k] = v
            }
        } else if let paramsAny = merged["params"] as? [AnyHashable: Any] {
            var p: [String: Any] = [:]
            for (k, v) in paramsAny {
                if let ks = k as? String { p[ks] = v }
            }
            for (k, v) in p {
                merged[k] = v
            }
        }
        return merged
    }

    private func handleAction(_ action: String, requestId: String, json: [String: Any]) async {
        let queue = OutboundTaskQueueService.shared

        switch action {
        case "task.create":
            guard let prompt = json["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                  let contactsRaw = json["contacts"] as? [[String: Any]] else {
                return
            }
            let contacts = contactsRaw.compactMap { c -> OutboundContact? in
                guard let phone = c["phone"] as? String, !phone.isEmpty else { return nil }
                let name = c["name"] as? String ?? phone
                return OutboundContact(phone: phone, name: name)
            }
            guard !contacts.isEmpty else { return }
            let promptType = json["prompt_type"] as? String ?? "apns"
            let scheduledAt: Date?
            if let s = json["scheduled_at"] as? String, !s.isEmpty {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                scheduledAt = formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            } else {
                scheduledAt = nil
            }
            let callFrequency = (json["call_frequency"] as? Int).map { max(1, $0) } ?? 30
            let redialMissed = json["redial_missed"] as? Bool ?? false
            _ = queue.createTask(
                promptType: promptType,
                prompt: prompt,
                contacts: contacts,
                scheduledAt: scheduledAt,
                callFrequency: callFrequency,
                redialMissed: redialMissed,
                apnsRequestId: requestId.isEmpty ? nil : requestId
            )

        case "task.delete":
            guard let taskIdStr = json["task_id"] as? String, let taskId = UUID(uuidString: taskIdStr) else { return }
            _ = queue.deleteTask(taskId: taskId)

        case "task.update":
            guard let taskIdStr = json["task_id"] as? String, let taskId = UUID(uuidString: taskIdStr) else { return }
            var scheduledAt: Date?
            if let s = json["scheduled_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                scheduledAt = formatter.date(from: s)
                if scheduledAt == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    scheduledAt = formatter.date(from: s)
                }
            }
            var contacts: [OutboundContact]?
            if let arr = json["contacts"] as? [[String: Any]] {
                contacts = arr.compactMap { c -> OutboundContact? in
                    guard let phone = c["phone"] as? String else { return nil }
                    return OutboundContact(phone: phone, name: c["name"] as? String ?? phone)
                }
                if contacts?.isEmpty == true { contacts = nil }
            }
            let prompt = json["prompt"] as? String
            let promptType = json["prompt_type"] as? String
            let callFrequency = json["call_frequency"] as? Int
            let redialMissed = json["redial_missed"] as? Bool
            _ = queue.updateTask(taskId: taskId, scheduledAt: scheduledAt, contacts: contacts, prompt: prompt, promptType: promptType, callFrequency: callFrequency, redialMissed: redialMissed)

        case "task.list":
            let statusStr = json["status"] as? String
            let status: OutboundTaskStatus? = statusStr.flatMap { OutboundTaskStatus(rawValue: $0) }
            let list = queue.listTasks(status: status)
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(list),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                await BackendAuthManager.shared.postControlCallback(requestId: requestId, data: ["tasks": []])
                return
            }
            await BackendAuthManager.shared.postControlCallback(requestId: requestId, data: ["tasks": arr])

        case "task.get":
            guard let taskIdStr = json["task_id"] as? String, let taskId = UUID(uuidString: taskIdStr) else { return }
            guard let dto = queue.getTask(taskId: taskId) else {
                await BackendAuthManager.shared.postControlCallback(requestId: requestId, data: ["task": NSNull()])
                return
            }
            let encoder = JSONEncoder()
            guard let tdata = try? encoder.encode(dto),
                  let obj = try? JSONSerialization.jsonObject(with: tdata) as? [String: Any] else { return }
            await BackendAuthManager.shared.postControlCallback(requestId: requestId, data: ["task": obj])

        case "task.report":
            guard let taskIdStr = json["task_id"] as? String, let taskId = UUID(uuidString: taskIdStr) else { return }
            guard let dto = queue.getTask(taskId: taskId) else {
                await BackendAuthManager.shared.postControlCallback(requestId: requestId, data: ["contacts": []])
                return
            }
            let contactsPayload = buildTaskReportContacts(taskId: taskId, taskContacts: dto.contacts)
            await BackendAuthManager.shared.postControlCallback(requestId: requestId, data: ["contacts": contactsPayload])

        case "task.run":
            guard let taskIdStr = json["task_id"] as? String, let taskId = UUID(uuidString: taskIdStr) else { return }
            queue.executeTask(taskID: taskId, apnsRequestId: requestId.isEmpty ? nil : requestId)

        case "task.cancel":
            guard let taskIdStr = json["task_id"] as? String, let taskId = UUID(uuidString: taskIdStr) else { return }
            _ = queue.cancelTask(taskId: taskId)

        case "dial":
            guard let phone = json["phone"] as? String, !phone.isEmpty,
                  let prompt = json["prompt"] as? String else { return }
            _ = queue.dialOncePersisted(
                phone: phone,
                prompt: prompt,
                apnsRequestId: requestId.isEmpty ? nil : requestId,
                promptType: "apns"
            )

        default:
            print("[ControlPush] unknown action: \(action)")
        }
    }

    /// 根据任务 ID 与任务联系人列表，从 CallLog 汇总每个联系人的拨打情况；拨通则附上聊天记录。
    private func buildTaskReportContacts(taskId: UUID, taskContacts: [[String: String]]) -> [[String: Any]] {
        let context = CallMateApp.sharedModelContainer.mainContext
        var callLogs: [CallLog] = []
        do {
            let descriptor = FetchDescriptor<CallLog>(
                predicate: #Predicate<CallLog> { log in
                    log.outboundTaskID == taskId
                },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            callLogs = try context.fetch(descriptor)
        } catch {
            return taskContacts.map { c in
                [
                    "phone": c["phone"] ?? "",
                    "name": c["name"] ?? (c["phone"] ?? ""),
                    "status": "pending"
                ] as [String: Any]
            }
        }

        return taskContacts.map { contact in
            let phone = contact["phone"] ?? ""
            let name = contact["name"] ?? phone
            let logsForPhone = callLogs.filter { $0.phone == phone }
            let best: CallLog? = logsForPhone.first { $0.statusRaw == CallStatus.handled.rawValue }
                ?? logsForPhone.first

            var item: [String: Any] = [
                "phone": phone,
                "name": name
            ]
            let status: String
            if let log = best {
                switch log.statusRaw {
                case CallStatus.handled.rawValue: status = "connected"
                case CallStatus.blocked.rawValue: status = "blocked"
                case CallStatus.missed.rawValue: status = "missed"
                default: status = "failed"
                }
                item["status"] = status
                if let msg = log.errorMessage, !msg.isEmpty { item["message"] = msg }
                if status == "connected", !log.transcript.isEmpty {
                    let chatRecord = log.transcript
                        .sorted { ($0.index, $0.timestamp) < ($1.index, $1.timestamp) }
                        .map { line -> [String: Any] in
                            var row: [String: Any] = ["sender": line.senderRaw, "text": line.text]
                            if let ms = line.startOffsetMs { row["start_offset_ms"] = ms }
                            return row
                        }
                    item["chat_record"] = chatRecord
                }
            } else {
                item["status"] = "pending"
            }
            return item
        }
    }
}

//
//  OutboundTaskQueueService.swift
//  CallMate
//
//  外呼任务队列服务：增删改查 + 执行，供 UI 与 ControlChannelService 共用。
//

import Foundation
import SwiftData
import Combine

/// 供 WS 等外部使用的任务 DTO（可序列化为 JSON）
struct OutboundTaskDTO: Encodable {
    var task_id: String
    var prompt_type: String
    var prompt: String
    var contacts: [[String: String]]  // [{ "phone", "name" }]
    var scheduled_at: String?          // ISO8601, nil = 立即执行
    var status: String
    var dial_success_count: Int
    var dial_failure_count: Int
    var call_frequency: Int
    var redial_missed: Bool
    var summary: String?
    var created_at: String

    static func from(_ task: OutboundTask) -> OutboundTaskDTO {
        OutboundTaskDTO(
            task_id: task.id.uuidString,
            prompt_type: task.promptType,
            prompt: task.promptRule,
            contacts: task.contacts.map { ["phone": $0.phone, "name": $0.name] },
            scheduled_at: task.scheduledAt.map { ISO8601DateFormatter().string(from: $0) },
            status: task.status.rawValue,
            dial_success_count: task.dialSuccessCount,
            dial_failure_count: task.dialFailureCount,
            call_frequency: task.callFrequency,
            redial_missed: task.redialMissed,
            summary: task.summary,
            created_at: ISO8601DateFormatter().string(from: task.createdAt)
        )
    }
}

@MainActor
final class OutboundTaskQueueService: ObservableObject {
    static let shared = OutboundTaskQueueService()

    /// 当前正在执行的任务 ID 集合（通常最多一个）
    @Published private(set) var runningTaskIds: Set<UUID> = []

    /// 任务因风控（深夜 / 紧急号码）未能开始执行时由 `executeTask` 写入；界面应弹出提示后 `clearOutboundDialBlockedMessage()`。
    @Published private(set) var outboundDialBlockedMessage: String?

    private var runningRunner: Task<Void, Never>?
    private let outboundSummaryPrefix = "[OUTBOUND_TASK]"
    private let unansweredTimeoutSeconds = 20

    /// APNs 推送顶层的 `request_id`（见 ios-integration.md）：用于 WS `hello.initiate.apns_request_id`。
    private var apnsRequestIdByTaskId: [UUID: String] = [:]

    /// 当前外呼任务若由 APNs 下发，返回对应 `request_id`，供 `hello` 使用。
    func apnsRequestId(forTask taskId: UUID?) -> String? {
        guard let taskId else { return nil }
        return apnsRequestIdByTaskId[taskId]
    }

    private init() {}

    private var language: Language {
        if let raw = UserDefaults.standard.string(forKey: "callmate.language"),
           let lang = Language(rawValue: raw) {
            return lang
        }
        return .zh
    }

    private var languageRaw: String { language.rawValue }

    private func modelContext() -> ModelContext {
        ModelContext(CallMateApp.sharedModelContainer)
    }

    // MARK: - 增

    /// 创建任务；若 scheduled_at 为 nil 则立即执行。返回 task_id。
    /// - Parameter apnsRequestId: 若来自 APNs `command`（如 `task.create`），填入推送中的 `request_id`，用于 WS hello。
    func createTask(
        promptType: String,
        prompt: String,
        contacts: [OutboundContact],
        scheduledAt: Date?,
        callFrequency: Int = 30,
        redialMissed: Bool = false,
        apnsRequestId: String? = nil
    ) -> UUID? {
        guard !contacts.isEmpty else { return nil }
        let task = OutboundTask(
            promptType: promptType,
            promptRule: prompt,
            contacts: contacts,
            scheduledAt: scheduledAt,
            status: scheduledAt == nil ? .running : .scheduled,
            callFrequency: max(1, callFrequency),
            redialMissed: redialMissed,
            createdAt: Date()
        )
        var list = OutboundTaskStore.load()
        list.append(task)
        OutboundTaskStore.save(list)

        if let rid = apnsRequestId?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty {
            apnsRequestIdByTaskId[task.id] = rid
        }

        if scheduledAt == nil {
            executeTask(taskID: task.id)
        } else {
            OutboundTaskBGScheduler.scheduleIfNeeded()
            OutboundTaskBGScheduler.scheduleLocalNotification(at: scheduledAt!)
        }
        return task.id
    }

    // MARK: - 删

    /// 删除任务；若正在执行则取消执行并删除。
    func deleteTask(taskId: UUID) -> Bool {
        if runningTaskIds.contains(taskId) {
            runningRunner?.cancel()
            runningRunner = nil
            runningTaskIds.remove(taskId)
        }
        var list = OutboundTaskStore.load()
        guard list.contains(where: { $0.id == taskId }) else { return false }
        list.removeAll { $0.id == taskId }
        OutboundTaskStore.save(list)
        return true
    }

    // MARK: - 改

    /// 仅当任务 status == .scheduled 时可更新。
    func updateTask(
        taskId: UUID,
        scheduledAt: Date? = nil,
        contacts: [OutboundContact]? = nil,
        prompt: String? = nil,
        promptType: String? = nil,
        callFrequency: Int? = nil,
        redialMissed: Bool? = nil
    ) -> Bool {
        var list = OutboundTaskStore.load()
        guard let idx = list.firstIndex(where: { $0.id == taskId }) else { return false }
        let t = list[idx]
        guard t.status == .scheduled else { return false }
        let updated = OutboundTask(
            id: t.id,
            promptType: promptType ?? t.promptType,
            promptRule: prompt ?? t.promptRule,
            contacts: contacts ?? t.contacts,
            scheduledAt: scheduledAt ?? t.scheduledAt,
            status: t.status,
            dialSuccessCount: t.dialSuccessCount,
            dialFailureCount: t.dialFailureCount,
            callFrequency: callFrequency.map { max(1, $0) } ?? t.callFrequency,
            redialMissed: redialMissed ?? t.redialMissed,
            summary: t.summary,
            createdAt: t.createdAt
        )
        list[idx] = updated
        OutboundTaskStore.save(list)
        return true
    }

    // MARK: - 查

    func listTasks(status: OutboundTaskStatus? = nil) -> [OutboundTaskDTO] {
        var list = OutboundTaskStore.load()
        if let s = status {
            list = list.filter { $0.status == s }
        }
        return list.map { OutboundTaskDTO.from($0) }
    }

    func getTask(taskId: UUID) -> OutboundTaskDTO? {
        let list = OutboundTaskStore.load()
        guard let task = list.first(where: { $0.id == taskId }) else { return nil }
        return OutboundTaskDTO.from(task)
    }

    // MARK: - 执行

    func clearOutboundDialBlockedMessage() {
        outboundDialBlockedMessage = nil
    }

    /// 立即执行指定任务（仅当当前无任务在执行时）
    /// - Parameter apnsRequestId: APNs `task.run` 推送中的 `request_id`（覆盖同任务上一次的值，供本轮通话 hello 使用）。
    func executeTask(taskID: UUID, apnsRequestId: String? = nil) {
        guard runningRunner == nil, !runningTaskIds.contains(taskID) else { return }
        var list = OutboundTaskStore.load()
        guard let idx = list.firstIndex(where: { $0.id == taskID }) else { return }
        if list[idx].status == .completed { return }

        for contact in list[idx].contacts {
            if let risk = OutboundDialRiskControl.evaluate(phone: contact.phone, at: Date()) {
                outboundDialBlockedMessage = riskReasonMessage(risk.reason)
                // `createTask` already persisted this task as `.running`; revert since we never started the runner.
                var reverted = OutboundTaskStore.load()
                if let rIdx = reverted.firstIndex(where: { $0.id == taskID }) {
                    var t = reverted[rIdx]
                    t.status = .failed
                    t.dialFailureCount = max(t.dialFailureCount, t.contacts.count)
                    reverted[rIdx] = t
                    OutboundTaskStore.save(reverted)
                }
                return
            }
        }
        outboundDialBlockedMessage = nil

        if let rid = apnsRequestId?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty {
            apnsRequestIdByTaskId[taskID] = rid
        }

        list[idx].status = .running
        list[idx].dialSuccessCount = 0
        list[idx].dialFailureCount = 0
        OutboundTaskStore.save(list)

        runningTaskIds.insert(taskID)
        let taskSnapshot = list[idx]
        let runner = Task { @MainActor [weak self] in
            await self?.runTaskLoop(taskID: taskID, taskSnapshot: taskSnapshot)
            self?.runningTaskIds.remove(taskID)
            self?.runningRunner = nil
        }
        runningRunner = runner
    }

    /// 取消正在执行的任务
    func cancelTask(taskId: UUID) -> Bool {
        guard runningTaskIds.contains(taskId) else { return false }
        runningRunner?.cancel()
        runningRunner = nil
        runningTaskIds.remove(taskId)
        var list = OutboundTaskStore.load()
        if let idx = list.firstIndex(where: { $0.id == taskId }) {
            if list[idx].status == .running {
                list[idx].status = .partial
                OutboundTaskStore.save(list)
            }
        }
        return true
    }

    // MARK: - 单呼（落库）

    /// 单呼并落库：创建一条单联系人任务并立即执行，返回 (success, message, task_id)。供 WS / APNs `dial` 使用；成功后可用 task.report(task_id) 查询。
    /// - Parameter apnsRequestId: 若来自远端 `dial` 且带 `request_id`，写入任务映射供 WS `hello.initiate.apns_request_id` 使用。
    /// - Parameter promptType: 远端控制通道拨号使用 `"apns"`，本地/WS 默认 `"ws"`。
    func dialOncePersisted(
        phone: String,
        prompt: String,
        apnsRequestId: String? = nil,
        promptType: String = "ws"
    ) -> (success: Bool, message: String, taskId: UUID?) {
        if let risk = OutboundDialRiskControl.evaluate(phone: phone, at: Date()) {
            return (false, riskReasonMessage(risk.reason), nil)
        }
        let contact = OutboundContact(phone: phone, name: phone)
        guard let taskId = createTask(
            promptType: promptType,
            prompt: prompt,
            contacts: [contact],
            scheduledAt: nil,
            apnsRequestId: apnsRequestId
        ) else {
            return (false, "create failed", nil)
        }
        return (true, "dial_sent", taskId)
    }

    // MARK: - 单呼（不落库，仅内部/兼容用）

    /// 用指定 prompt 拨打一个号码，不创建持久化任务。返回是否成功发出拨号并收到 ACK 成功。
    func dialOnce(phone: String, prompt: String) async -> (success: Bool, message: String) {
        if let risk = OutboundDialRiskControl.evaluate(phone: phone, at: Date()) {
            let msg = riskReasonMessage(risk.reason)
            return (false, msg)
        }
        let controller = CallSessionController.sharedBLE
        let ble = CallMateBLEClient.shared
        ble.autoConnectIfPossible()
        if !ble.isReady {
            ble.ensureConnectionRecovered(reason: "outbound_dial_once")
        }
        await controller.waitForOutboundCallEnd(timeoutSeconds: 300)
        controller.setOutboundTaskContext(taskID: nil, prompt: prompt)
        controller.prepareForOutboundDial()
        let ackResult = await waitForDialAckResult { ble.dialPhoneNumber(phone, expectAck: true) }
        let ackSuccess = ackResult == 0
        if ackSuccess {
            return (true, "dial_sent")
        }
        return (false, ackErrorMessage(from: ackResult))
    }

    // MARK: - 内部：执行循环

    private func runTaskLoop(taskID: UUID, taskSnapshot: OutboundTask) async {
        let ble = CallMateBLEClient.shared
        let controller = CallSessionController.sharedBLE
        ble.autoConnectIfPossible()
        if !ble.isReady {
            ble.ensureConnectionRecovered(reason: "outbound_task_execute")
        }

        let callFrequency = max(1, taskSnapshot.callFrequency)
        let dialIntervalSeconds = max(1.0, 3600.0 / Double(callFrequency))
        var lastDialStartedAt: Date?
        var finalResults: [UUID: Bool] = [:]
        var pendingRedial: [OutboundContact] = []
        let ctx = modelContext()

        func applyDialResult(for contact: OutboundContact, success: Bool) {
            var list = OutboundTaskStore.load()
            guard let idx = list.firstIndex(where: { $0.id == taskID }) else { return }
            let previous = finalResults[contact.id]
            if let prev = previous {
                if prev { list[idx].dialSuccessCount = max(0, list[idx].dialSuccessCount - 1) }
                else { list[idx].dialFailureCount = max(0, list[idx].dialFailureCount - 1) }
            }
            if success { list[idx].dialSuccessCount += 1 }
            else { list[idx].dialFailureCount += 1 }
            finalResults[contact.id] = success
            OutboundTaskStore.save(list)
        }

        func waitForDialSlotIfNeeded() async {
            guard let last = lastDialStartedAt else { return }
            let remaining = dialIntervalSeconds - Date().timeIntervalSince(last)
            guard remaining > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        func dialContact(_ contact: OutboundContact, passLabel: String, index: Int, total: Int) async -> Bool {
            if Task.isCancelled { return false }
            if let risk = OutboundDialRiskControl.evaluate(phone: contact.phone, at: Date()) {
                let riskMsg = riskReasonMessage(risk.reason)
                insertBlockedCallLog(ctx: ctx, taskID: taskID, taskSnapshot: taskSnapshot, contact: contact, message: riskMsg)
                return false
            }
            await controller.waitForOutboundCallEnd(timeoutSeconds: 300)
            await waitForDialSlotIfNeeded()
            let personalizedPrompt = Self.substituteVariables(taskSnapshot.promptRule, contact: contact)
            controller.setOutboundTaskContext(
                taskID: taskID,
                prompt: personalizedPrompt,
                targetPhone: contact.phone,
                callerName: "",
                taskGoal: ""
            )
            controller.prepareForOutboundDial()
            lastDialStartedAt = Date()
            let ackResult = await waitForDialAckResult { ble.dialPhoneNumber(contact.phone, expectAck: true) }
            let ackSuccess = ackResult == 0
            if ackSuccess {
                await controller.waitForOutboundCallStart(timeoutSeconds: unansweredTimeoutSeconds)
                if controller.outboundCallAborted {
                    controller.outboundCallAborted = false
                    insertMissedCallLog(ctx: ctx, taskID: taskID, taskSnapshot: taskSnapshot, contact: contact, error: nil)
                    return false
                }
                if controller.status == .ended {
                    controller.sendCallCommand("audio_stop", expectAck: false)
                    controller.sendCallCommand("hangup", expectAck: false)
                    insertMissedCallLog(ctx: ctx, taskID: taskID, taskSnapshot: taskSnapshot, contact: contact, error: "Unanswered \(unansweredTimeoutSeconds)s")
                    return false
                }
                await controller.waitForOutboundCallEnd(timeoutSeconds: 300)
                return true
            }
            insertBlockedCallLog(ctx: ctx, taskID: taskID, taskSnapshot: taskSnapshot, contact: contact, message: ackErrorMessage(from: ackResult))
            return false
        }

        for (idx, contact) in taskSnapshot.contacts.enumerated() {
            if Task.isCancelled { break }
            let ok = await dialContact(contact, passLabel: "pass1", index: idx + 1, total: taskSnapshot.contacts.count)
            applyDialResult(for: contact, success: ok)
            if taskSnapshot.redialMissed && !ok { pendingRedial.append(contact) }
        }
        if taskSnapshot.redialMissed && !pendingRedial.isEmpty {
            for (idx, contact) in pendingRedial.enumerated() {
                if Task.isCancelled { break }
                let ok = await dialContact(contact, passLabel: "redial", index: idx + 1, total: pendingRedial.count)
                applyDialResult(for: contact, success: ok)
            }
        }

        do { try ctx.save() } catch {
            print("[OutboundTaskQueue] persist error: \(error.localizedDescription)")
        }

        var list = OutboundTaskStore.load()
        guard let idx = list.firstIndex(where: { $0.id == taskID }) else { return }
        let success = taskSnapshot.contacts.reduce(0) { $0 + ((finalResults[$1.id] ?? false) ? 1 : 0) }
        let failure = max(0, taskSnapshot.contacts.count - success)
        list[idx].dialSuccessCount = success
        list[idx].dialFailureCount = failure
        if failure == 0 { list[idx].status = .completed }
        else if success == 0 { list[idx].status = .failed }
        else { list[idx].status = .partial }
        OutboundTaskStore.save(list)

        apnsRequestIdByTaskId.removeValue(forKey: taskID)
    }

    private func insertBlockedCallLog(ctx: ModelContext, taskID: UUID, taskSnapshot: OutboundTask, contact: OutboundContact, message: String) {
        let now = Date()
        let log = CallLog(
            startedAt: now,
            endedAt: now,
            durationSeconds: 0,
            recordingFileName: nil,
            statusRaw: CallStatus.blocked.rawValue,
            phone: contact.phone,
            label: contact.name,
            summary: "\(outboundSummaryPrefix) \(taskSnapshot.promptType) BLOCKED",
            fullSummary: taskSnapshot.promptRule,
            isSimulation: false,
            languageRaw: languageRaw,
            outboundTaskID: taskID,
            wsSessionId: nil,
            errorMessage: message
        )
        ctx.insert(log)
    }

    private func insertMissedCallLog(ctx: ModelContext, taskID: UUID, taskSnapshot: OutboundTask, contact: OutboundContact, error: String?) {
        let now = Date()
        let log = CallLog(
            startedAt: now,
            endedAt: now,
            durationSeconds: 0,
            recordingFileName: nil,
            statusRaw: CallStatus.missed.rawValue,
            phone: contact.phone,
            label: contact.name,
            summary: "\(outboundSummaryPrefix) \(taskSnapshot.promptType) UNANSWERED",
            fullSummary: taskSnapshot.promptRule,
            isSimulation: false,
            languageRaw: languageRaw,
            outboundTaskID: taskID,
            wsSessionId: nil,
            errorMessage: error
        )
        ctx.insert(log)
    }

    private func waitForDialAckResult(sendCommand: () -> Void, timeoutNs: UInt64 = 6_000_000_000) async -> Int? {
        let ble = CallMateBLEClient.shared
        var ackCancel: AnyCancellable?
        let ackStream = AsyncStream<Int> { cont in
            ackCancel = ble.events.sink { event in
                if case let .ack(cmd, result) = event, cmd == "dial" {
                    cont.yield(result)
                    cont.finish()
                }
            }
        }
        sendCommand()
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                for await value in ackStream { return value }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            ackCancel?.cancel()
            return result
        }
    }

    /// Replace template variables with actual contact data and global context.
    /// Canonical variable IDs: name, phone, title, time_greeting, today_date, task_name, brand_name, membership
    /// Also handles legacy names like target_name for backward compatibility.
    static func substituteVariables(_ prompt: String, contact: OutboundContact) -> String {
        var result = prompt

        let hour = Calendar.current.component(.hour, from: Date())
        let timeGreeting: String = {
            switch hour {
            case 0...5: return "凌晨好"
            case 6...8: return "早上好"
            case 9...11: return "上午好"
            case 12: return "中午好"
            case 13...17: return "下午好"
            default: return "晚上好"
            }
        }()

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"
        let todayDate = df.string(from: Date())

        let phoneSuffix = contact.phone.count >= 4
            ? String(contact.phone.suffix(4))
            : contact.phone

        let replacements: [(String, String)] = [
            ("name", contact.name),
            ("phone", phoneSuffix),
            ("title", ""),
            ("time_greeting", timeGreeting),
            ("today_date", todayDate),
            ("membership", ""),
            // Legacy variable names (backward compat)
            ("target_name", contact.name),
            ("target_phone", contact.phone),
            ("联系人", contact.name),
            ("联系电话", contact.phone),
        ]
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: "&{\(key)}", with: value)
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    private func riskReasonMessage(_ reason: OutboundDialRiskReason) -> String {
        switch reason {
        case .emergencyNumber:
            return language == .zh ? "命中紧急号码风控，默认禁止 AI 外呼。" : "Emergency-number risk control: AI outbound blocked."
        case .deepNight:
            return language == .zh
                ? "当前处于当地深夜时段（\(OutboundDialRiskControl.deepNightStartHour):00-\(OutboundDialRiskControl.deepNightEndHour):00），默认禁止 AI 外呼。"
                : "Local deep-night window (\(OutboundDialRiskControl.deepNightStartHour):00-\(OutboundDialRiskControl.deepNightEndHour):00): AI outbound blocked."
        }
    }

    private func ackErrorMessage(from ackResult: Int?) -> String {
        guard let r = ackResult else { return language == .zh ? "拨号 ACK 超时" : "Dial ACK timeout" }
        let reason = ackReadableReason(r)
        return language == .zh ? "拨号 ACK 失败(\(r))：\(reason)" : "Dial ACK failed (\(r)): \(reason)"
    }

    private func ackReadableReason(_ result: Int) -> String {
        switch result {
        case 0: return "Success"
        case -1: return "Invalid state for dialing"
        case -2: return "Rejected by device guard"
        case -6: return "Request does not match current session"
        case -7: return "Stale session or SID mismatch"
        case -8: return "No active session on device"
        case -9: return "Invalid parameter format"
        case -10: return "Missing required session parameter"
        default: return "Unknown error"
        }
    }
}

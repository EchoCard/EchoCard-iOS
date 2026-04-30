//
//  OutboundTaskModels.swift
//  CallMate
//

import Foundation
import SwiftUI
import BackgroundTasks
import UserNotifications

enum ContactMode {
    case existing
    case manual
}

enum TimingMode {
    case immediate
    case scheduled
}

enum OutboundDialRiskReason {
    case emergencyNumber
    case deepNight
}

struct OutboundDialRiskDecision {
    let reason: OutboundDialRiskReason
    let normalizedPhone: String
}

enum OutboundDialRiskControl {
    // Default quiet hours in local time.
    static let deepNightStartHour = 23
    static let deepNightEndHour = 8

    /// When `true`, outbound is blocked during [deepNightStartHour, deepNightEndHour) local time.
    /// Set to `false` to temporarily allow late-night dialing (restore by flipping to `true`).
    static var enforceDeepNightOutboundBlock: Bool = false

    // Widely used emergency numbers across regions/countries.
    private static let emergencyShortCodes: Set<String> = [
        "000", // AU
        "110", // CN/JP police
        "112", // EU/common GSM
        "118", // some regions emergency
        "119", // CN/JP fire
        "120", // CN ambulance
        "122", // CN traffic police
        "911", // US/CA
        "999"  // UK/HK/SG
    ]

    static func evaluate(phone: String, at date: Date = Date(), calendar: Calendar = .current) -> OutboundDialRiskDecision? {
        let normalized = normalizePhone(phone)
        if isEmergencyNumber(normalizedPhone: normalized) {
            return OutboundDialRiskDecision(reason: .emergencyNumber, normalizedPhone: normalized)
        }
        if enforceDeepNightOutboundBlock, isDeepNight(at: date, calendar: calendar) {
            return OutboundDialRiskDecision(reason: .deepNight, normalizedPhone: normalized)
        }
        return nil
    }

    static func isDeepNight(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= deepNightStartHour || hour < deepNightEndHour
    }

    static func normalizePhone(_ rawPhone: String) -> String {
        rawPhone.filter(\.isNumber)
    }

    static func isEmergencyNumber(_ phone: String) -> Bool {
        let normalized = normalizePhone(phone)
        return isEmergencyNumber(normalizedPhone: normalized)
    }

    private static func isEmergencyNumber(normalizedPhone: String) -> Bool {
        guard !normalizedPhone.isEmpty else { return false }
        if emergencyShortCodes.contains(normalizedPhone) {
            return true
        }
        // Also block country-code-prefixed emergency numbers like +86110 / 0086110.
        return emergencyShortCodes.contains { code in
            normalizedPhone.hasSuffix(code) && normalizedPhone.count <= code.count + 4
        }
    }
}

struct OutboundContact: Identifiable, Hashable, Codable {
    let id: UUID
    let phone: String
    let name: String

    init(id: UUID = UUID(), phone: String, name: String) {
        self.id = id
        self.phone = phone
        self.name = name
    }
}

struct OutboundTask: Identifiable, Codable {
    let id: UUID
    let promptType: String
    let promptRule: String
    let contacts: [OutboundContact]
    let scheduledAt: Date?
    var status: OutboundTaskStatus
    var dialSuccessCount: Int
    var dialFailureCount: Int
    var callFrequency: Int
    var redialMissed: Bool
    /// Backend call_outbound scene summary (outcome JSON from server).
    var summary: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        promptType: String,
        promptRule: String,
        contacts: [OutboundContact],
        scheduledAt: Date?,
        status: OutboundTaskStatus,
        dialSuccessCount: Int = 0,
        dialFailureCount: Int = 0,
        callFrequency: Int = 30,
        redialMissed: Bool = false,
        summary: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.promptType = promptType
        self.promptRule = promptRule
        self.contacts = contacts
        self.scheduledAt = scheduledAt
        self.status = status
        self.dialSuccessCount = dialSuccessCount
        self.dialFailureCount = dialFailureCount
        self.callFrequency = callFrequency
        self.redialMissed = redialMissed
        self.summary = summary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case promptType
        case promptRule
        case contacts
        case scheduledAt
        case status
        case dialSuccessCount
        case dialFailureCount
        case callFrequency
        case redialMissed
        case summary
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        promptType = try container.decode(String.self, forKey: .promptType)
        promptRule = try container.decode(String.self, forKey: .promptRule)
        contacts = try container.decode([OutboundContact].self, forKey: .contacts)
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        status = try container.decode(OutboundTaskStatus.self, forKey: .status)
        dialSuccessCount = try container.decodeIfPresent(Int.self, forKey: .dialSuccessCount) ?? 0
        dialFailureCount = try container.decodeIfPresent(Int.self, forKey: .dialFailureCount) ?? 0
        callFrequency = try container.decodeIfPresent(Int.self, forKey: .callFrequency) ?? 30
        redialMissed = try container.decodeIfPresent(Bool.self, forKey: .redialMissed) ?? false
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

enum OutboundTaskStatus: String, Codable {
    case scheduled
    case running
    case completed
    case partial
    case failed
    /// AI 完成了通话，但 summary 要求机主后续跟进（如"机主需确认订金"）。
    case pending
    /// 外呼未接通（无真人接听，仅系统提示音）。
    case notConnected

    /// Maps server `call_outbound` summary `outcome` (plan §5.2).
    static func fromSummaryOutcome(_ raw: String?) -> OutboundTaskStatus? {
        guard let o = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !o.isEmpty else { return nil }
        switch o {
        case "success": return .completed
        case "partial": return .partial
        case "failed": return .failed
        case "pending": return .pending
        case "not_connected": return .notConnected
        default: return nil
        }
    }

    func title(language: Language) -> String {
        switch self {
        case .scheduled: return language == .zh ? "已定时" : "Scheduled"
        case .running: return language == .zh ? "执行中" : "Running"
        case .completed: return language == .zh ? "已完成" : "Completed"
        case .partial: return language == .zh ? "部分成功" : "Partial"
        case .failed: return language == .zh ? "失败" : "Failed"
        case .pending: return language == .zh ? "待跟进" : "Pending"
        case .notConnected: return language == .zh ? "未接通" : "Not Connected"
        }
    }

    var color: Color {
        switch self {
        case .scheduled: return AppColors.warning
        case .running: return AppColors.primary
        case .completed: return AppColors.success
        case .partial: return AppColors.warning
        case .failed: return AppColors.error
        case .pending: return AppColors.accent
        case .notConnected: return AppColors.textSecondary
        }
    }
}

enum OutboundTaskStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("outbound_tasks.json")
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func save(_ tasks: [OutboundTask]) {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[OutboundTaskStore] save failed: \(error.localizedDescription)")
        }
    }

    static func load() -> [OutboundTask] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            var tasks = try JSONDecoder().decode([OutboundTask].self, from: data)
            for i in tasks.indices {
                if tasks[i].status == .running {
                    tasks[i].status = .pending
                }
            }
            return tasks
        } catch {
            print("[OutboundTaskStore] load failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Persists backend summary JSON and optionally overrides task status from `outcome` (plan §5).
    static func mergeOutboundSummary(taskId: UUID, summaryJSON: String, outcome: String?) {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.id == taskId }) else {
            print("[OutboundSummary] merge skip: no task id=\(taskId)")
            return
        }
        list[idx].summary = summaryJSON
        if let mapped = OutboundTaskStatus.fromSummaryOutcome(outcome) {
            list[idx].status = mapped
        }
        save(list)
        print("[OutboundSummary] merged task=\(taskId) outcome=\(outcome ?? "nil") len=\(summaryJSON.count)")
        NotificationCenter.default.post(name: .outboundTasksSummaryUpdated, object: taskId)
    }
}

enum OutboundTaskBGScheduler {
    static let taskIdentifier = "com.callmate.outbound-task"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { bgTask in
            guard let task = bgTask as? BGAppRefreshTask else { return }
            print("[OutboundBG] background task fired")
            handleBGTask(task)
        }
    }

    static func scheduleIfNeeded() {
        let tasks = OutboundTaskStore.load()
        guard let nextScheduled = tasks
            .filter({ $0.status == .scheduled && $0.scheduledAt != nil && $0.scheduledAt! > Date() })
            .compactMap({ $0.scheduledAt })
            .min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextScheduled
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[OutboundBG] scheduled wake-up at \(nextScheduled)")
        } catch {
            print("[OutboundBG] schedule failed: \(error.localizedDescription)")
        }
    }

    static func scheduleLocalNotification(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "外呼任务到期"
        content.body = "您有定时外呼任务需要执行，点击打开应用。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "outbound-task-\(Int(date.timeIntervalSince1970))",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
        print("[OutboundBG] local notification scheduled at \(date)")
    }

    private static func handleBGTask(_ bgTask: BGAppRefreshTask) {
        bgTask.expirationHandler = {
            print("[OutboundBG] background task expired")
        }
        let tasks = OutboundTaskStore.load()
        let dueTasks = tasks.filter { task in
            task.status == .scheduled &&
            task.scheduledAt != nil &&
            task.scheduledAt! <= Date()
        }
        if dueTasks.isEmpty {
            print("[OutboundBG] no due tasks")
        } else {
            print("[OutboundBG] \(dueTasks.count) due tasks found, posting notification")
            NotificationCenter.default.post(name: .outboundTaskDue, object: nil)
        }
        bgTask.setTaskCompleted(success: true)
        scheduleIfNeeded()
    }
}

extension Notification.Name {
    static let outboundTaskDue = Notification.Name("outboundTaskDue")
    /// Posted after `OutboundTaskStore.mergeOutboundSummary` updates disk.
    static let outboundTasksSummaryUpdated = Notification.Name("outboundTasksSummaryUpdated")
}

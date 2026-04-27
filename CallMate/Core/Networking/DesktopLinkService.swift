import Foundation
import Combine
import UIKit
import SwiftData

/// 桌面端连接状态
enum DesktopLinkStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// 桌面端通信服务 — 通过局域网 WebSocket 连接 EchoCard Desktop
@MainActor
final class DesktopLinkService: ObservableObject {
    static let shared = DesktopLinkService()
    
    @Published private(set) var status: DesktopLinkStatus = .disconnected
    @Published private(set) var desktopIP: String = ""
    @Published private(set) var desktopPort: Int = 0
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var token: String = ""
    private var sessionId: String?
    private var pingTimer: Timer?
    
    private init() {}
    
    /// 解析 QR 码 payload 并发起连接
    func connect(qrPayload: String) {
        guard let data = qrPayload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String,
              let port = json["port"] as? Int,
              let token = json["token"] as? String else {
            status = .failed("二维码格式无效")
            return
        }
        
        self.desktopIP = ip
        self.desktopPort = port
        self.token = token
        
        startConnection()
    }
    
    func disconnect() {
        cleanup()
        status = .disconnected
    }
    
    // MARK: - Connection
    
    private func startConnection() {
        cleanup()
        
        status = .connecting
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        urlSession = URLSession(configuration: config)
        
        guard let url = URL(string: "ws://\(desktopIP):\(desktopPort)") else {
            status = .failed("地址格式错误")
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        sendAuth()
    }
    
    private func sendAuth() {
        let authManager = BackendAuthManager.shared
        var payload: [String: Any] = [
            "type": "auth",
            "token": token,
            "app_code": authManager.appCode,
            "device_id": authManager.pidId,
            "device": UIDevice.current.name
        ]
        if let sid = sessionId {
            payload["session_id"] = sid
        }
        print("[DesktopLink] sendAuth app_code=\(authManager.appCode.prefix(8))... device_id=\(authManager.pidId.prefix(8))...")
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        
        webSocketTask?.send(.string(str)) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.status = .failed(error.localizedDescription)
                    return
                }
                self?.startReceiving()
            }
        }
    }
    
    // MARK: - Receive
    
    private func startReceiving() {
        guard let task = webSocketTask else { return }
        
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    self?.startReceiving()
                case .failure(let error):
                    if self?.status == .connected {
                        self?.status = .failed("连接断开: \(error.localizedDescription)")
                        self?.scheduleReconnect()
                    }
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            let type = json["type"] as? String ?? ""
            
            switch type {
            case "auth_ok":
                sessionId = json["session_id"] as? String
                status = .connected
                startPing()
                print("[DesktopLink] auth ok, session=\(sessionId ?? "-")")
                
            case "auth_fail":
                let reason = json["reason"] as? String ?? "认证失败"
                status = .failed(reason)
                print("[DesktopLink] auth failed: \(reason)")
                
            case "task_create":
                handleTaskCreate(json)
                
            case "task_pause", "task_resume", "task_cancel":
                handleTaskControl(type, json)

            case "recording_upload_request":
                handleRecordingUploadRequest(json)

            default:
                print("[DesktopLink] unknown message type: \(type)")
            }
            
        case .data:
            break
        @unknown default:
            break
        }
    }
    
    // MARK: - Task Handling
    
    private var desktopTaskIdMap: [UUID: String] = [:]
    private var taskObservers: [UUID: AnyCancellable] = [:]
    /// 已发送过 call_result 的 callLog ID，避免重复发送
    private var sentCallLogIds: Set<UUID> = []
    
    private func handleTaskCreate(_ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? json
        let desktopTaskId = payload["task_id"] as? String ?? ""
        let prompt = payload["prompt"] as? String
            ?? (payload["script"] as? [String: Any])?["content"] as? String
            ?? ""
        
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("[DesktopLink] task_create ignored: empty prompt")
            sendTaskProgress(taskId: desktopTaskId, status: "failed", done: 0, success: 0, failed: 0)
            return
        }
        
        let contactsRaw = payload["contacts"] as? [[String: Any]] ?? []
        let contacts = contactsRaw.compactMap { c -> OutboundContact? in
            guard let phone = c["phone"] as? String, !phone.isEmpty else { return nil }
            let name = c["name"] as? String ?? phone
            return OutboundContact(phone: phone, name: name)
        }
        
        guard !contacts.isEmpty else {
            print("[DesktopLink] task_create ignored: no contacts")
            sendTaskProgress(taskId: desktopTaskId, status: "failed", done: 0, success: 0, failed: 0)
            return
        }
        
        let strategy = payload["strategy"] as? [String: Any] ?? [:]
        let callFrequency = strategy["call_frequency"] as? Int ?? 30
        let redialMissed = strategy["redial_missed"] as? Bool ?? false
        
        print("[DesktopLink] task_create: prompt=\(prompt.prefix(50))..., contacts=\(contacts.count)")
        
        let queue = OutboundTaskQueueService.shared
        if let iosTaskId = queue.createTask(
            promptType: "desktop",
            prompt: prompt,
            contacts: contacts,
            scheduledAt: nil,
            callFrequency: callFrequency,
            redialMissed: redialMissed
        ) {
            desktopTaskIdMap[iosTaskId] = desktopTaskId
            observeTaskUpdates(iosTaskId: iosTaskId, desktopTaskId: desktopTaskId, totalContacts: contacts.count)
            sendTaskProgress(taskId: desktopTaskId, status: "running", done: 0, success: 0, failed: 0)
        } else {
            sendTaskProgress(taskId: desktopTaskId, status: "failed", done: 0, success: 0, failed: 0)
        }
    }
    
    private func handleTaskControl(_ type: String, _ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? json
        let desktopTaskId = payload["task_id"] as? String ?? ""
        print("[DesktopLink] \(type) received, task=\(desktopTaskId)")
        
        guard let (iosId, _) = desktopTaskIdMap.first(where: { $0.value == desktopTaskId }) else {
            print("[DesktopLink] no iOS task mapped for desktop id \(desktopTaskId)")
            return
        }
        
        let queue = OutboundTaskQueueService.shared
        switch type {
        case "task_pause":
            _ = queue.cancelTask(taskId: iosId)
            sendTaskProgress(taskId: desktopTaskId, status: "paused", done: 0, success: 0, failed: 0)
        case "task_resume":
            queue.executeTask(taskID: iosId)
            sendTaskProgress(taskId: desktopTaskId, status: "running", done: 0, success: 0, failed: 0)
        case "task_cancel":
            _ = queue.cancelTask(taskId: iosId)
            sendTaskProgress(taskId: desktopTaskId, status: "cancelled", done: 0, success: 0, failed: 0)
        default:
            break
        }
    }
    
    private func observeTaskUpdates(iosTaskId: UUID, desktopTaskId: String, totalContacts: Int) {
        taskObservers[iosTaskId]?.cancel()
        taskObservers[iosTaskId] = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.status == .connected else { return }
                let queue = OutboundTaskQueueService.shared
                guard let dto = queue.getTask(taskId: iosTaskId) else { return }
                
                let done = dto.dial_success_count + dto.dial_failure_count
                self.sendTaskProgress(
                    taskId: desktopTaskId,
                    status: dto.status,
                    done: done,
                    success: dto.dial_success_count,
                    failed: dto.dial_failure_count
                )
                
                // 实时发送已完成通话的 call_result（不等任务结束）
                self.sendIncrementalCallResults(iosTaskId: iosTaskId, desktopTaskId: desktopTaskId)

                if dto.status == "completed" || dto.status == "failed" || dto.status == "partial" || dto.status == "cancelled" {
                    self.taskObservers[iosTaskId]?.cancel()
                    self.taskObservers.removeValue(forKey: iosTaskId)
                    self.sendCallResultsWithDelay(iosTaskId: iosTaskId, desktopTaskId: desktopTaskId)
                }
            }
    }

    /// 增量发送 call_result：只发送尚未发送过的通话记录
    private func sendIncrementalCallResults(iosTaskId: UUID, desktopTaskId: String) {
        let context = CallMateApp.sharedModelContainer.mainContext
        do {
            let descriptor = FetchDescriptor<CallLog>(
                predicate: #Predicate<CallLog> { log in
                    log.outboundTaskID == iosTaskId
                },
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
            let logs = try context.fetch(descriptor)
            for log in logs where !sentCallLogIds.contains(log.id) {
                sendCallResultForLog(log, desktopTaskId: desktopTaskId)
                sentCallLogIds.insert(log.id)
                print("[DesktopLink] incremental call_result sent: \(log.id.uuidString.prefix(8)) phone=\(log.phone)")
            }
        } catch {
            print("[DesktopLink] sendIncrementalCallResults failed: \(error)")
        }
    }

    private func sendCallResultsWithDelay(iosTaskId: UUID, desktopTaskId: String, attempt: Int = 0) {
        let delay: TimeInterval = attempt == 0 ? 3 : 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.status == .connected else { return }
            let count = self.sendCallResultsIfNeeded(iosTaskId: iosTaskId, desktopTaskId: desktopTaskId)
            if count == 0 && attempt < 3 {
                print("[DesktopLink] call_result: no logs yet for task \(iosTaskId.uuidString.prefix(8)), retry \(attempt + 1)")
                self.sendCallResultsWithDelay(iosTaskId: iosTaskId, desktopTaskId: desktopTaskId, attempt: attempt + 1)
            }
        }
    }

    @discardableResult
    private func sendCallResultsIfNeeded(iosTaskId: UUID, desktopTaskId: String) -> Int {
        let context = CallMateApp.sharedModelContainer.mainContext
        do {
            let descriptor = FetchDescriptor<CallLog>(
                predicate: #Predicate<CallLog> { log in
                    log.outboundTaskID == iosTaskId
                },
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
            let logs = try context.fetch(descriptor)
            print("[DesktopLink] sendCallResults: found \(logs.count) logs for task \(iosTaskId.uuidString.prefix(8))")
            for log in logs {
                sendCallResultForLog(log, desktopTaskId: desktopTaskId)
            }
            return logs.count
        } catch {
            print("[DesktopLink] sendCallResultsIfNeeded failed: \(error.localizedDescription)")
            return 0
        }
    }

    func sendUpdatedCallResultIfMapped(for log: CallLog) {
        guard let taskId = log.outboundTaskID,
              let desktopTaskId = desktopTaskIdMap[taskId],
              status == .connected else { return }
        sendCallResultForLog(log, desktopTaskId: desktopTaskId)
    }

    private func sendCallResultForLog(_ log: CallLog, desktopTaskId: String) {
        let status: String
        switch log.statusRaw {
        case CallStatus.handled.rawValue:
            status = "connected"
        case CallStatus.missed.rawValue:
            status = "no_answer"
        case CallStatus.blocked.rawValue:
            status = "failed"
        default:
            status = "failed"
        }

        let transcriptText = log.transcript
            .sorted { ($0.index, $0.timestamp) < ($1.index, $1.timestamp) }
            .map { line in
                let role = line.senderRaw == ChatSender.ai.rawValue ? "AI" : "用户"
                return "\(role): \(line.text)"
            }
            .joined(separator: "\n")

        let summaryText = log.backendSummary
            ?? log.fullSummary
            ?? log.displaySummary
            ?? log.summary

        let recordingMeta = log.recordingFileName.map { "ios-recording://\($0)" }

        print("[DesktopLink] sending call_result: id=\(log.id.uuidString.prefix(8)) phone=\(log.phone) status=\(status) dur=\(log.durationSeconds)s summary=\(summaryText?.prefix(40) ?? "(none)") transcript=\(transcriptText.isEmpty ? "no" : "yes(\(transcriptText.count)c)") recording=\(recordingMeta ?? "none")")

        sendCallResult(
            taskId: desktopTaskId,
            callId: log.id.uuidString,
            phone: log.phone,
            status: status,
            duration: log.durationSeconds,
            summary: summaryText,
            transcript: transcriptText.isEmpty ? nil : transcriptText,
            recordingUrl: recordingMeta,
            calledAt: ISO8601DateFormatter().string(from: log.startedAt)
        )

        // 发完 call_result 后主动推送录音文件（延迟1秒确保文件写入完成）
        if let fileName = log.recordingFileName {
            let callLogId = log.id.uuidString
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendRecordingAsBase64(callLogId: callLogId, fileName: fileName)
            }
        }
    }

    /// 读取本地录音文件并通过 base64 JSON 文本消息发送（避免二进制帧兼容问题）
    private func sendRecordingAsBase64(callLogId: String, fileName: String) {
        guard status == .connected else {
            print("[DesktopLink] skip recording upload: not connected")
            return
        }

        guard let fileUrl = try? CallAudioStore.url(forFileName: fileName) else {
            print("[DesktopLink] recording file path error: \(fileName)")
            return
        }

        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            print("[DesktopLink] recording file not found: \(fileUrl.path)")
            return
        }

        guard let audioData = try? Data(contentsOf: fileUrl) else {
            print("[DesktopLink] failed to read recording: \(fileName)")
            return
        }

        let base64Str = audioData.base64EncodedString()
        print("[DesktopLink] sending recording base64: id=\(callLogId.prefix(8)) size=\(audioData.count / 1024)KB base64Len=\(base64Str.count)")

        sendMessage([
            "type": "recording_data",
            "call_log_id": callLogId,
            "file_name": fileName,
            "data": base64Str
        ])
    }
    
    /// 发送通话结果回桌面端
    func sendCallResult(taskId: String, callId: String? = nil, phone: String, status: String, duration: Int, summary: String?, transcript: String?, recordingUrl: String? = nil, calledAt: String? = nil) {
        sendMessage([
            "type": "call_result",
            "id": callId ?? UUID().uuidString,
            "task_id": taskId,
            "phone": phone,
            "status": status,
            "duration": duration,
            "summary": summary ?? "",
            "transcript": transcript ?? "",
            "recording_url": recordingUrl ?? "",
            "called_at": calledAt ?? ISO8601DateFormatter().string(from: Date())
        ])
    }
    
    /// 发送任务进度更新
    func sendTaskProgress(taskId: String, status: String, done: Int, success: Int, failed: Int) {
        sendMessage([
            "type": "task_progress",
            "task_id": taskId,
            "status": status,
            "done": done,
            "success": success,
            "failed": failed
        ])
    }
    
    // MARK: - Recording Upload

    private func handleRecordingUploadRequest(_ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? json
        guard let callLogId = payload["call_log_id"] as? String,
              let recordingUrl = payload["recording_url"] as? String else {
            print("[DesktopLink] recording_upload_request: missing call_log_id or recording_url")
            return
        }

        let fileName: String
        if recordingUrl.hasPrefix("ios-recording://") {
            fileName = String(recordingUrl.dropFirst("ios-recording://".count))
        } else {
            fileName = recordingUrl
        }

        sendRecordingAsBase64(callLogId: callLogId, fileName: fileName)
    }

    // MARK: - Send

    private func sendMessage(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        
        webSocketTask?.send(.string(str)) { error in
            if let error {
                print("[DesktopLink] send error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Ping / Reconnect
    
    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.webSocketTask?.sendPing { error in
                    if error != nil {
                        Task { @MainActor [weak self] in
                            self?.status = .failed("Ping 失败")
                            self?.scheduleReconnect()
                        }
                    }
                }
            }
        }
    }
    
    private func scheduleReconnect() {
        cleanup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.status != .connected, !self.token.isEmpty else { return }
            self.startConnection()
        }
    }
    
    private func cleanup() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
}

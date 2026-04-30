import Foundation

// MARK: - Public API

extension CallSessionController {
    struct RuleChangeItem: Identifiable, Equatable {
        let id: String
        let type: String
        let rule: String
        let action: String
    }

    struct RuleChangeRequest: Identifiable, Equatable {
        let id: String
        let originalRule: String
        let updatedRuleSummary: String
        let updatedRules: [RuleChangeItem]
    }

    /// A request from the AI to create a new outbound prompt template.
    struct OutboundTemplateRequest: Identifiable, Equatable {
        let id: String   // callId from tool call
        let name: String
        let content: String
    }

    /// A request from the AI to initiate an outbound call, pending user confirmation.
    struct OutboundCallRequest: Identifiable, Equatable {
        let id: String   // callId from tool call
        let phone: String
        let templateName: String
    }

    /// A request from the AI to schedule an outbound call at a specific time.
    struct OutboundScheduleCallRequest: Identifiable, Equatable {
        let id: String          // callId from tool call
        let phone: String
        let templateName: String
        let scheduledAt: Date   // resolved absolute time
        let timeDescription: String  // human-readable label, e.g. "今天下午 3:30"
    }

    /// 引导图/视频展示请求（need4：takeover_reminder=循环视频，ios_call_filter_setting=图，unknown_call_handling=图）
    struct GuideImageRequest: Identifiable, Equatable {
        let id: String          // callId from tool call
        let imageId: String     // takeover_reminder | ios_call_filter_setting | unknown_call_handling
        let caption: String?
    }

    /// 引导交互卡片请求（需要用户明确操作后才回复服务端）
    struct GuideCardRequest: Identifiable, Equatable {
        let id: String      // callId from tool call
        let cardId: String  // clone_authorization | clone_start_reading | ...
    }

    /// Call before initiating an outbound dial so the controller stays
    /// alive when the system Phone UI pushes the app to background.
    func prepareForOutboundDial() {
        guard inputSource == .ble else { return }
        outboundCallAborted = false
        /* MCU opens a new call session + sid on dial; BLE `dialPhoneNumber` only clears
         * `CallMateBLEClient.currentCallSID`. `CallTransportCoordinator.currentBLECallSID`
         * can still hold the *previous* call's sid — `sendCallCommand` prefers the coordinator,
         * so `audio_start` would carry a stale sid and fail `protocol_validate_cmd_sid` (-7). */
        clearCallSessionSID(reason: "outbound_dial_prepare")
        // 与 AI 分身（`scene=update_config`）等共用 [WebSocketService.shared]：不断开则外呼全程
        // `wsSession=true` 但实际仍是配置会话，`outgoing_answered` 时无法切到 `call_outbound`（表现为无 AI 声）。
        Self.activeControllerId = controllerId
        Self.activeController = self
        ws.addDelegate(self)
        if ws.isOccupiedByNonCallWebsocketScene {
            print("[OutboundRec] prepareForOutboundDial: disconnect non-call WS so outbound can use call_outbound")
            ws.disconnect()
        }
        print("[OutboundRec] prepareForOutboundDial: status=\(status) bgActive=\(bleBackgroundSupportActive)")
        startBLEBackgroundSupport(reason: "outbound_dial_prepare")
    }

    /// Bind the next outbound call session to a task ID for exact history mapping.
    func setOutboundTaskContext(
        taskID: UUID?,
        prompt: String? = nil,
        targetPhone: String? = nil,
        callerName: String? = nil,
        taskGoal: String? = nil
    ) {
        pendingOutboundTaskID = taskID
        if let prompt {
            pendingOutboundPrompt = prompt
            print("[PromptTrace] setOutboundTaskContext: prompt set len=\(prompt.count) empty=\(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) taskID=\(taskID?.uuidString ?? "nil")")
        } else if taskID == nil {
            pendingOutboundPrompt = nil
            print("[PromptTrace] setOutboundTaskContext: cleared (taskID=nil, prompt=nil)")
        } else {
            print("[PromptTrace] setOutboundTaskContext: taskID set but prompt=nil, pendingPrompt unchanged=\(pendingOutboundPrompt?.count ?? -1) chars")
        }
        outboundTargetPhone = targetPhone
        outboundCallerName = callerName
        outboundTaskGoal = taskGoal
    }

    /// Wait until the outbound call actually begins (status leaves `.ended`).
    /// Call this after a successful dial ACK to ensure the call has started
    /// before proceeding to `waitForOutboundCallEnd` for sequential dialing.
    func waitForOutboundCallStart(timeoutSeconds: Int = 60) async {
        guard status == .ended else {
            print("[OutboundDial] waitForCallStart: already non-ended (status=\(status))")
            return
        }
        print("[OutboundDial] waitForCallStart: waiting for call to begin (up to \(timeoutSeconds)s)")
        let start = Date()
        let deadline = start.addingTimeInterval(Double(timeoutSeconds))
        while status == .ended, !outboundCallAborted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        if outboundCallAborted {
            print("[OutboundDial] waitForCallStart: aborted early (call ended before session started) after \(elapsed)s")
        } else if status != .ended {
            print("[OutboundDial] waitForCallStart: call started (status=\(status)) after \(elapsed)s")
        } else {
            print("[OutboundDial] waitForCallStart: TIMEOUT after \(elapsed)s, call never started")
        }
    }

    /// Wait until the current outbound call session ends (status returns to `.ended`).
    /// Returns immediately if no call is active. Has a hard timeout to prevent deadlocks.
    func waitForOutboundCallEnd(timeoutSeconds: Int = 300) async {
        guard status != .ended else {
            print("[OutboundDial] waitForCallEnd: already ended, returning immediately")
            return
        }
        print("[OutboundDial] waitForCallEnd: status=\(status), waiting up to \(timeoutSeconds)s")
        let start = Date()
        let deadline = start.addingTimeInterval(Double(timeoutSeconds))
        while status != .ended, Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        if status == .ended {
            print("[OutboundDial] waitForCallEnd: call ended after \(elapsed)s")
        } else {
            print("[OutboundDial] waitForCallEnd: TIMEOUT after \(elapsed)s, status=\(status)")
        }
    }

    func toggleMute() {
        isMuted.toggle()
        audioRouter.setMuted(isMuted)
    }

    func toggleSpeaker() {
        isSpeaker.toggle()
        audioRouter.setSpeakerEnabled(isSpeaker)
    }

    /// Handoff the current BLE-handled call to the phone (human answers).
    /// This will ask the MCU to disconnect HFP (passthrough) and end the AI session
    /// without sending `hangup` to the MCU.
    func handoffToHuman() {
        guard inputSource == .ble else { return }
        guard status != .ended else { return }

        // Mark passthrough so we suppress hangup/audio_stop from `end()`.
        contactPassthroughActive = true

        toastMessage = language == .zh ? "已转交真人接听（系统通话接管）" : "Handed off to phone (human takeover)."

        // Ask MCU to drop HFP so the system call UI can take over.
        sendHFPDisconnectWithCooldown()

        // End AI session (WS/audio) but do NOT hang up the phone call.
        end(abortReason: "handoff_to_human")
        syncLiveActivity(ttsOverride: language == .zh ? "已转真人接听" : "Handed off to human")
    }

    func sendTestText() {
        let text = language == .zh ? "请问机主在吗？" : "Is the owner available?"
        ws.sendListenText(text)
    }

    func sendListenText(_ text: String) {
        ws.sendListenText(text)
    }

    /// Refresh reconnect context so WS re-connect can carry latest initiate.messages.
    func updateReconnectInitMessages(_ initMessages: [[String: String]]?) {
        guard scene.isManualInteractionScene else { return }
        ws.setInitMessagesForReconnect(initMessages)
    }

    /// Stop current manual listen and abort server-side processing (used by "swipe up to cancel").
    func cancelManualListen() {
        guard scene.isManualInteractionScene else { return }
        manualPressActive = false
        manualReconnectPending = false
        // Keep cancel path independent from `endManualListen()` so we don't send `listen_stop`.
        if manualListenStartTask != nil {
            manualListenStartTask?.cancel()
            manualListenStartTask = nil
        }
        if wsListeningStarted {
            wsListeningStarted = false
        }
        if audio.isRecording {
            audio.stopRecording()
            manualLastRecordingStopAt = Date()
        }
        print("[CallSession] manual listen cancel (ui/local only, no ws command)")
    }

    /// v1 §3.3 `display_rule_change` response.
    /// `confirm` → `{ success: true, operation: "confirm" }`
    /// `cancel`  → `{ success: false, action: "cancelled", reason: "user_cancelled", operation: "cancel" }`
    func sendToolResponse(callId: String, operation: String) {
        if operation == "confirm" {
            if let change = pendingRuleChange {
                let updates = change.updatedRules.map {
                    ProcessStrategyChange(type: $0.type, rule: $0.rule, action: $0.action)
                }
                ProcessStrategyStore.applyChanges(updates)
            }
            ws.sendToolResponse(callId: callId, result: [
                "success": true,
                "operation": "confirm"
            ])
        } else {
            ws.sendToolResponse(callId: callId, result: [
                "success": false,
                "action": "cancelled",
                "reason": "user_cancelled",
                "operation": "cancel"
            ])
        }
    }

    /// UI 关闭引导图/视频后调用，避免重复弹窗。
    func clearPendingGuideImage() {
        pendingGuideImage = nil
    }

    /// 用户对引导卡片做出决定后调用：accepted=true 发送成功回执，false 发送拒绝。
    func respondToGuideCard(callId: String, accepted: Bool) {
        pendingGuideCard = nil
        if accepted {
            ws.sendToolResponse(callId: callId, result: ["success": true])
        } else {
            ws.sendToolResponse(callId: callId, result: nil, error: "用户拒绝")
        }
    }

    func consumeLiveCallRequest() {
        liveCallRequest = nil
    }

    /// Called by LiveCallView after it has persisted an outbound call,
    /// so that persistOutboundCallIfNeeded() (called from end()) skips and avoids a duplicate record.
    func markOutboundCallHandledByLiveView() {
        outboundCallId = nil
        outboundCallStartedAt = nil
        activeOutboundPrompt = nil
        activeOutboundTaskID = nil
    }

    static func sharedStopCurrentSession() {
        guard let active = activeController else { return }
        DispatchQueue.main.async {
            active.end()
        }
    }
}

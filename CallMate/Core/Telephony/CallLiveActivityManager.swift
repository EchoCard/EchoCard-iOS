import Foundation
import ActivityKit
import UIKit

@MainActor
final class CallLiveActivityManager {
    static let shared = CallLiveActivityManager()
    private static let residentCallId = "resident.default"

    private struct ResidentEmergencySummary {
        let callerName: String
        let detailText: String
    }

    private struct PendingStartRequest {
        let callId: String
        let state: CallMateLiveActivityAttributes.ContentState
    }

    private var activity: Activity<CallMateLiveActivityAttributes>?
    private var currentCallId: String?
    private var pendingStartRequest: PendingStartRequest?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private(set) var isResidentEnabled: Bool = false
    private var residentEnabled: Bool {
        get { isResidentEnabled }
        set { isResidentEnabled = newValue }
    }
    private var residentEmergencySummary: ResidentEmergencySummary?
    private var summaryDismissTask: Task<Void, Never>?
    private var lastEndedState: CallMateLiveActivityAttributes.ContentState?

    private init() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.residentEmergencySummary != nil {
                    self.clearResidentEmergencySummary()
                }
                if self.residentEnabled {
                    self.ensureResidentIdleActivity(trigger: "didBecomeActive_force_idle")
                }
                self.startPendingIfNeeded(trigger: "didBecomeActive")
                self.endStaleInCallActivitiesIfNeeded()
            }
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func setResidentModeEnabled(_ enabled: Bool) {
        residentEnabled = enabled
        if enabled {
            ensureResidentIdleActivity(trigger: "enable")
            return
        }

        residentEmergencySummary = nil
        if pendingStartRequest?.callId == Self.residentCallId {
            pendingStartRequest = nil
        }
        Task {
            for item in Activity<CallMateLiveActivityAttributes>.activities
            where item.attributes.callId == Self.residentCallId {
                await item.end(nil, dismissalPolicy: .immediate)
            }
        }
        if currentCallId == Self.residentCallId {
            self.activity = nil
            self.currentCallId = nil
        }
        print("[LiveActivity] resident idle ended trigger=disable")
    }

    func setResidentEmergencySummary(callerName: String, detailText: String) {
        residentEmergencySummary = ResidentEmergencySummary(
            callerName: callerName.trimmingCharacters(in: .whitespacesAndNewlines),
            detailText: detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        ensureResidentIdleActivity(trigger: "set_emergency_summary")
    }

    func clearResidentEmergencySummary() {
        residentEmergencySummary = nil
        ensureResidentIdleActivity(trigger: "clear_emergency_summary")
    }

    // MARK: - In-call updates

    func startOrUpdate(
        callId: String,
        statusText: String,
        durationSeconds: Int,
        ttsText: String,
        sttText: String = "",
        callerName: String,
        callerNumber: String,
        canHandoff: Bool,
        canHangup: Bool,
        allowBackgroundStart: Bool = false
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        summaryDismissTask?.cancel()
        summaryDismissTask = nil
        lastEndedState = nil

        let state = CallMateLiveActivityAttributes.ContentState(
            statusText: statusText,
            durationSeconds: durationSeconds,
            ttsText: ttsText,
            sttText: sttText,
            callerName: callerName,
            callerNumber: callerNumber,
            canHandoff: canHandoff,
            canHangup: canHangup,
            phase: .calling
        )

        if let activity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
            currentCallId = callId
            return
        }

        if UIApplication.shared.applicationState != .active, !allowBackgroundStart {
            pendingStartRequest = PendingStartRequest(callId: callId, state: state)
            print("[LiveActivity] defer start: appState=\(UIApplication.shared.applicationState.rawValue) callId=\(callId)")
            return
        }

        if UIApplication.shared.applicationState != .active, allowBackgroundStart {
            print("[LiveActivity] background start from push callId=\(callId)")
        }
        startNewActivity(callId: callId, state: state)
    }

    // MARK: - Post-call: show ended state (waiting for summary)

    func showEndedState(
        callerName: String,
        callerNumber: String,
        durationSeconds: Int
    ) {
        // Discard any deferred start regardless of whether an activity exists,
        // so it never fires when the app becomes active after the call has ended.
        self.pendingStartRequest = nil
        guard let activity else {
            print("[LiveActivity] showEndedState skipped: no activity")
            return
        }

        let state = CallMateLiveActivityAttributes.ContentState(
            statusText: "通话已结束",
            durationSeconds: durationSeconds,
            ttsText: "",
            sttText: "",
            callerName: callerName,
            callerNumber: callerNumber,
            canHandoff: false,
            canHangup: false,
            phase: .ended
        )
        lastEndedState = state

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        print("[LiveActivity] showEndedState caller=\(callerName)")

        scheduleSummaryTimeout()
    }

    // MARK: - Post-call: show summary

    func showSummary(
        summaryTitle: String,
        summaryDetail: String,
        callerName: String? = nil
    ) {
        guard let activity else {
            print("[LiveActivity] showSummary skipped: no activity")
            return
        }

        summaryDismissTask?.cancel()

        let base = lastEndedState
        let state = CallMateLiveActivityAttributes.ContentState(
            statusText: "通话摘要",
            durationSeconds: base?.durationSeconds ?? 0,
            ttsText: "",
            sttText: "",
            callerName: callerName ?? base?.callerName ?? "EchoCard",
            callerNumber: base?.callerNumber ?? "",
            canHandoff: false,
            canHangup: false,
            phase: .summary,
            summaryTitle: summaryTitle,
            summaryDetail: summaryDetail
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        print("[LiveActivity] showSummary title=\(summaryTitle)")

        scheduleSummaryDismiss(delay: 12)
    }

    // MARK: - End

    func end() {
        summaryDismissTask?.cancel()
        summaryDismissTask = nil
        lastEndedState = nil
        // Always discard any deferred start so it never resurfaces after the call ends.
        self.pendingStartRequest = nil

        if residentEnabled {
            ensureResidentIdleActivity(trigger: "end_to_idle")
            return
        }
        guard let activity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        self.currentCallId = nil
        print("[LiveActivity] ended")
    }

    // MARK: - Private

    private func startNewActivity(callId: String, state: CallMateLiveActivityAttributes.ContentState) {
        pendingStartRequest = nil

        if let old = activity {
            Task {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            self.activity = nil
        }

        do {
            let attrs = CallMateLiveActivityAttributes(callId: callId)
            activity = try Activity.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            currentCallId = callId
            print("[LiveActivity] started id=\(activity?.id ?? "nil") callId=\(callId)")
        } catch {
            print("[LiveActivity] start failed: \(error.localizedDescription)")
        }
    }

    private func startPendingIfNeeded(trigger: String) {
        guard UIApplication.shared.applicationState == .active else { return }
        guard let pending = pendingStartRequest else { return }
        print("[LiveActivity] resume deferred start trigger=\(trigger) callId=\(pending.callId)")
        startNewActivity(callId: pending.callId, state: pending.state)
    }

    /// When app relaunches after crash/kill or MCU disconnect, any Live Activity still showing "calling"
    /// is stale. End those so the Dynamic Island / Lock Screen recovers.
    private func endStaleInCallActivitiesIfNeeded() {
        let hasActiveCall = CallSessionController.activeController != nil
            && CallSessionController.activeController?.status != .ended
        if hasActiveCall { return }
        endAllInCallActivitiesNow(reason: "didBecomeActive_stale")
    }

    /// End all non-resident Live Activities (calling / ended / summary).
    /// Call from applicationWillTerminate (user 划掉 app) so 灵动岛 doesn’t stay stuck; also used by endStaleInCallActivitiesIfNeeded.
    func endAllInCallActivitiesNow(reason: String = "app_terminate") {
        Task { @MainActor in
            for item in Activity<CallMateLiveActivityAttributes>.activities {
                guard item.attributes.callId != Self.residentCallId else { continue }
                // 清理 calling / ended(正在生成摘要) / summary，避免半路杀 app 后灵动岛一直显示
                await item.end(nil, dismissalPolicy: .immediate)
                if currentCallId == item.attributes.callId {
                    self.activity = nil
                    self.currentCallId = nil
                }
                print("[LiveActivity] ended activity reason=\(reason) phase=\(item.content.state.phase) callId=\(item.attributes.callId)")
            }
        }
    }

    private func ensureResidentIdleActivity(trigger: String) {
        guard residentEnabled else { return }
        let hasEmergencySummary: Bool = {
            guard let residentEmergencySummary else { return false }
            return !residentEmergencySummary.callerName.isEmpty || !residentEmergencySummary.detailText.isEmpty
        }()
        let callerName = hasEmergencySummary
            ? ((residentEmergencySummary?.callerName.isEmpty == false) ? (residentEmergencySummary?.callerName ?? "EchoCard") : "EchoCard")
            : "EchoCard"
        let detailText = hasEmergencySummary ? (residentEmergencySummary?.detailText ?? "") : ""
        let state = CallMateLiveActivityAttributes.ContentState(
            statusText: hasEmergencySummary ? "紧急来电记录" : "待命中",
            durationSeconds: 0,
            ttsText: detailText,
            callerName: callerName,
            callerNumber: "",
            canHandoff: false,
            canHangup: false
        )
        startOrUpdate(
            callId: Self.residentCallId,
            statusText: state.statusText,
            durationSeconds: state.durationSeconds,
            ttsText: state.ttsText,
            callerName: state.callerName,
            callerNumber: state.callerNumber,
            canHandoff: state.canHandoff,
            canHangup: state.canHangup
        )
        print("[LiveActivity] resident idle ensured trigger=\(trigger)")
    }

    /// Auto-dismiss after summary timeout (no summary arrived in time).
    private func scheduleSummaryTimeout() {
        summaryDismissTask?.cancel()
        summaryDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000) // 25s
            guard !Task.isCancelled else { return }
            self?.end()
            print("[LiveActivity] summary timeout -> ended")
        }
    }

    /// Auto-dismiss a fixed delay after summary is shown.
    private func scheduleSummaryDismiss(delay: TimeInterval) {
        summaryDismissTask?.cancel()
        summaryDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.end()
            print("[LiveActivity] summary dismiss after \(delay)s -> ended")
        }
    }
}

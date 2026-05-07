//
//  LocalUserDataDeletion.swift
//  CallMate
//
//  Clears user-generated local content while keeping device binding and app entry state.
//

import Foundation
import SwiftData
import UserNotifications

enum LocalUserDataDeletion {

    /// Removes call logs (and recordings), outbound SwiftData models, AI chat threads, outbound task queue file,
    /// process strategy (reset to default), and selected personalization defaults.
    /// Does **not** clear onboarding completion, legal consent, saved BLE peripheral, or general app preferences
    /// such as language / pickup delay / MCU toggles.
    @MainActor
    static func wipeAllLocalUserContent(modelContext: ModelContext) throws {
        let callDescriptor = FetchDescriptor<CallLog>()
        let calls = try modelContext.fetch(callDescriptor)
        for call in calls {
            if let fileName = call.recordingFileName,
               let url = try? CallAudioStore.url(forFileName: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.delete(call)
        }

        let templates = try modelContext.fetch(FetchDescriptor<OutboundPromptTemplate>())
        for row in templates { modelContext.delete(row) }

        let contacts = try modelContext.fetch(FetchDescriptor<OutboundContactBookEntry>())
        for row in contacts { modelContext.delete(row) }

        try modelContext.save()

        try AIChatHistoryService.deleteAllThreads(context: modelContext)

        OutboundTaskStore.clearAll()
        OutboundTaskQueueService.shared.resetInMemoryStateAfterTasksFileCleared()
        OutboundTaskBGScheduler.scheduleIfNeeded()
        cancelPendingOutboundTaskNotifications()

        ProcessStrategyStore.resetToDefault()

        let ud = UserDefaults.standard
        ud.removeObject(forKey: "callmate.voiceId")
        ud.removeObject(forKey: "callmate.voiceDisplayNameOverride")
        ud.removeObject(forKey: "callmate.voiceTone")
        ud.removeObject(forKey: "callmate.userManuallySelectedVoice")
        ud.removeObject(forKey: "callmate.userAppellation")
        ud.removeObject(forKey: "callmate.ai_calls_total")
        ud.removeObject(forKey: "callmate.hfp_pairing_needed")

        NotificationCenter.default.post(name: .outboundTasksSummaryUpdated, object: nil)
    }

    static func cancelPendingOutboundTaskNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("outbound-task-") }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

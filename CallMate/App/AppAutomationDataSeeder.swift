import Foundation
import SwiftData

@MainActor
enum AppAutomationDataSeeder {
    static func seedIfNeeded(in container: ModelContainer) {
        guard let callCount = AppAutomation.seededCallCount else { return }

        let context = container.mainContext

        do {
            let existingCalls = try context.fetch(FetchDescriptor<CallLog>())
            for call in existingCalls {
                context.delete(call)
            }

            let now = Date()
            for index in 0..<callCount {
                let startedAt = now.addingTimeInterval(TimeInterval(-(index + 1) * 420))
                let durationSeconds = 45 + (index % 6) * 12
                let phone = String(format: "1888000%04d", index)
                let label = index.isMultiple(of: 4) ? "VIP Caller \(index)" : "Automation Caller \(index)"
                let summary = "Automation caller \(index)"
                let fullSummary = "Automation scroll seed call \(index) for UI testing."

                let call = CallLog(
                    createdAt: startedAt,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
                    durationSeconds: durationSeconds,
                    statusRaw: CallStatus.handled.rawValue,
                    phone: phone,
                    label: label,
                    summary: summary,
                    fullSummary: fullSummary,
                    isSimulation: false,
                    isImportant: index.isMultiple(of: 5),
                    languageRaw: Language.en.rawValue
                )
                call.tokenCount = 120 + index * 7
                call.aiDuration = max(10, durationSeconds - 8)
                context.insert(call)
            }

            try context.save()
            print("[AppAutomation] Seeded \(callCount) call logs for UI testing")
        } catch {
            print("[AppAutomation] Failed to seed call logs: \(error.localizedDescription)")
        }
    }
}

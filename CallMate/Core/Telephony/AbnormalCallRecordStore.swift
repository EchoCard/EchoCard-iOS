//
//  AbnormalCallRecordStore.swift
//  CallMate
//
//  异常通话记录：当陌生来电未由 AI 代接时记录时间与原因，供诊断页查看。
//

import Combine
import Foundation

struct AbnormalCallRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let reasonCode: String
    let detail: String?

    init(id: UUID = UUID(), date: Date = Date(), reasonCode: String, detail: String? = nil) {
        self.id = id
        self.date = date
        self.reasonCode = reasonCode
        self.detail = detail
    }
}

private let maxRecords = 200
private let userDefaultsKey = "callmate.abnormal_call_records"

@MainActor
final class AbnormalCallRecordStore: ObservableObject {
    static let shared = AbnormalCallRecordStore()

    @Published private(set) var records: [AbnormalCallRecord] = []

    private init() {
        load()
    }

    private let maxDetailLength = 120

    func append(reasonCode: String, detail: String? = nil) {
        var trimmedDetail: String? = nil
        if let d = detail, !d.isEmpty {
            trimmedDetail = d.count > maxDetailLength ? String(d.prefix(maxDetailLength)) + "…" : d
        }
        let record = AbnormalCallRecord(reasonCode: reasonCode, detail: trimmedDetail)
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([AbnormalCallRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

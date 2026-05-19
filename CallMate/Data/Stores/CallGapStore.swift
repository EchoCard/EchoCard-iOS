//
//  CallGapStore.swift
//  CallMate
//
//  存储 AI 通话结束后上报的不确定处理记录（report_call_gap tool）。
//  用于提示用户补充 Skill 规则。
//

import Foundation

struct CallGapRecord: Codable, Identifiable, Equatable {
    let id: String
    let scene: String       // 来电场景简述
    let question: String    // 希望用户补充什么规则
    let handling: String    // 本次 AI 的处理方式
    let createdAt: Date
}

enum CallGapStore {
    private static let key = "callmate.call_gaps"
    static let didChangeNotification = Notification.Name("CallGapStore.didChange")

    static func loadAll() -> [CallGapRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([CallGapRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func append(_ record: CallGapRecord) {
        var records = loadAll()
        // 去重：同一 callId 只保留一条
        records.removeAll { $0.id == record.id }
        records.append(record)
        // 最多保留 50 条
        if records.count > 50 {
            records = Array(records.suffix(50))
        }
        save(records)
    }

    static func delete(id: String) {
        var records = loadAll()
        records.removeAll { $0.id == id }
        save(records)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func save(_ records: [CallGapRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

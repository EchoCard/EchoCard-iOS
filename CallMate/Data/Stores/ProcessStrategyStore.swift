//
//  ProcessStrategyStore.swift
//  CallMate
//
//  向后兼容适配层 — 内部委托给 SkillStore。
//  新代码请直接使用 SkillStore。
//

import Foundation

struct ProcessStrategyRule: Codable, Equatable {
    let id: Int
    let type: String
    let rule: String
}

struct ProcessStrategyChange {
    let type: String
    let rule: String
    let action: String
}

enum ProcessStrategyStore {
    static var didChangeNotification: Notification.Name {
        SkillStore.didChangeNotification
    }

    static func processStrategyJSONString() -> String? {
        SkillStore.skillsJSONString()
    }

    static func ensureDefaultIfNeeded() {
        SkillStore.ensureDefaultIfNeeded()
    }

    static func resetToDefault() {
        SkillStore.resetToDefault()
    }

    static func loadRules() -> [ProcessStrategyRule] {
        SkillStore.loadSkills().enumerated().map { idx, skill in
            ProcessStrategyRule(id: idx + 1, type: skill.name, rule: skill.body)
        }
    }

    static func saveRules(_ rules: [ProcessStrategyRule]) {
        let skills: [SkillRule] = rules.map { rule in
            SkillRule(
                tag: tagFromType(rule.type),
                name: rule.type,
                description: "",
                priority: "normal",
                body: rule.rule
            )
        }
        SkillStore.saveSkills(skills)
    }

    static func saveProcessStrategyJSONIfValid(_ json: String) -> Bool {
        if SkillStore.saveJSONIfValid(json) { return true }
        guard let data = json.data(using: .utf8),
              let oldRules = try? JSONDecoder().decode([ProcessStrategyRule].self, from: data) else {
            return false
        }
        saveRules(oldRules)
        return true
    }

    static func validateProcessStrategyJSON(_ json: String) -> Bool {
        if SkillStore.validateJSON(json) { return true }
        guard let data = json.data(using: .utf8),
              let _ = try? JSONDecoder().decode([ProcessStrategyRule].self, from: data) else {
            return false
        }
        return true
    }

    static func getStrategyManifest() -> [[String: String]] {
        SkillStore.getStrategyManifest()
    }

    static func getRule(tag: String) -> (name: String, content: String)? {
        if let resp = SkillStore.getStrategyResponse(tag: tag) {
            return (name: resp.name, content: resp.rules)
        }
        if let body = SkillStore.getRuleBody(tag: tag) {
            let skills = SkillStore.loadSkills()
            let name = skills.first(where: { $0.tag == tag || $0.name == tag })?.name ?? tag
            return (name: name, content: body)
        }
        return nil
    }

    static func applyChanges(_ changes: [ProcessStrategyChange]) {
        let isZh = currentLanguage == .zh
        let skillChanges = changes.map { change in
            let tag = tagFromType(change.type)
            let name = canonicalName(for: tag, originalType: change.type, isZh: isZh)
            return SkillChange(
                tag: tag,
                name: name,
                description: "",
                priority: "normal",
                body: change.rule,
                action: change.action
            )
        }
        SkillStore.applyChanges(skillChanges)
    }

    private static func canonicalName(for tag: String, originalType: String, isZh: Bool) -> String {
        let zhNames: [String: String] = [
            "express": "快递", "takeout": "外卖", "telecom": "运营商",
            "finance": "银行金融", "marketing": "营销推销",
            "acquaintance": "熟人来电", "unknown": "未归类来电"
        ]
        let enNames: [String: String] = [
            "express": "Express", "takeout": "Takeout", "telecom": "Telecom",
            "finance": "Finance", "marketing": "Marketing",
            "acquaintance": "Contacts", "unknown": "Unknown"
        ]
        if isZh { return zhNames[tag] ?? originalType }
        return enNames[tag] ?? originalType
    }

    private static var currentLanguage: Language {
        if let raw = UserDefaults.standard.string(forKey: "callmate.language"),
           let lang = Language(rawValue: raw) { return lang }
        return .zh
    }

    private static func tagFromType(_ type: String) -> String {
        let map: [String: String] = [
            "外卖": "takeout", "外卖/骑手": "takeout",
            "快递": "express", "快递/驿站/派件": "express",
            "运营商": "telecom", "运营商（移动/联通/电信）": "telecom",
            "金融推销": "finance", "银行/保险/贷款/理财": "finance",
            "营销推销": "marketing", "营销/推销/房产/课程/广告": "marketing",
            "熟人来电": "acquaintance", "熟人来电（系统已识别为有姓名的来电）": "acquaintance",
            "未知来电": "unknown", "未归类来电（兜底分流规则）": "unknown"
        ]
        if let tag = map[type] { return tag }
        let knownTags: Set<String> = ["express", "takeout", "telecom", "finance", "marketing", "acquaintance", "unknown"]
        let lower = type.lowercased()
        if knownTags.contains(lower) { return lower }
        return lower
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "_")).inverted)
            .joined(separator: "_")
            .trimmingCharacters(in: .init(charactersIn: "_"))
    }
}

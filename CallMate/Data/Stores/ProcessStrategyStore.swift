//
//  ProcessStrategyStore.swift
//  CallMate
//
//  Persist and update processStrategy rules on device.
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
    private static let key = "ws_process_strategy"
    static let didChangeNotification = Notification.Name("ProcessStrategyStore.didChange")
    
    static func processStrategyJSONString() -> String? {
        ensureDefaultIfNeeded()
        return UserDefaults.standard.string(forKey: key)
    }
    
    static func ensureDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        let existing = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing, !existing.isEmpty {
            return
        }
        let rules = defaultRules()
        guard let json = encodeRules(rules) else { return }
        setStrategyJSONString(json, source: "default_init")
    }

    /// 强制将策略重置为内置默认规则，无论当前是否已有保存值。
    /// 用于"重新配置AI向导"时完全抛弃已有策略。
    static func resetToDefault() {
        let rules = defaultRules()
        guard let json = encodeRules(rules) else { return }
        // Bypass the "unchanged" guard by clearing the key first.
        UserDefaults.standard.removeObject(forKey: key)
        setStrategyJSONString(json, source: "reset_to_default")
    }
    
    static func loadRules() -> [ProcessStrategyRule] {
        guard let json = UserDefaults.standard.string(forKey: key),
              let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode([ProcessStrategyRule].self, from: data) else {
            return defaultRules()
        }
        return rules
    }
    
    static func saveRules(_ rules: [ProcessStrategyRule]) {
        guard let json = encodeRules(rules) else { return }
        setStrategyJSONString(json, source: "save_rules")
    }
    
    /// 校验并保存策略 JSON 字符串；仅当能解码为 [ProcessStrategyRule] 时保存并返回 true。
    static func saveProcessStrategyJSONIfValid(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let _ = try? JSONDecoder().decode([ProcessStrategyRule].self, from: data) else {
            return false
        }
        setStrategyJSONString(trimmed, source: "save_json")
        return true
    }
    
    /// 校验策略 JSON 字符串是否可解码为 [ProcessStrategyRule]，不写入。
    static func validateProcessStrategyJSON(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let _ = try? JSONDecoder().decode([ProcessStrategyRule].self, from: data) else {
            return false
        }
        return true
    }
    
    static func applyChanges(_ changes: [ProcessStrategyChange]) {
        var rules = loadRules()
        var nextId = (rules.map { $0.id }.max() ?? 0) + 1
        
        for change in changes {
            let action = change.action.lowercased()
            if action == "delete" {
                rules.removeAll { $0.type == change.type }
                continue
            }
            if let idx = rules.firstIndex(where: { $0.type == change.type }) {
                if action == "update" || action == "add" {
                    let current = rules[idx]
                    rules[idx] = ProcessStrategyRule(id: current.id, type: change.type, rule: change.rule)
                }
            } else {
                if action == "add" || action == "update" {
                    rules.append(ProcessStrategyRule(id: nextId, type: change.type, rule: change.rule))
                    nextId += 1
                }
            }
        }
        saveRules(rules)
    }
    
    private static func encodeRules(_ rules: [ProcessStrategyRule]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setStrategyJSONString(_ json: String, source: String) {
        if Thread.isMainThread {
            setStrategyJSONStringOnMain(json, source: source)
        } else {
            // Use async to avoid deadlock: bleQueue callbacks call this while the main
            // thread may be blocked on bleQueue.sync (via runOnBLEQueueSync), causing
            // a mutual lock if we use DispatchQueue.main.sync here.
            DispatchQueue.main.async {
                setStrategyJSONStringOnMain(json, source: source)
            }
        }
    }

    private static func setStrategyJSONStringOnMain(_ json: String, source: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = UserDefaults.standard
        let old = defaults.string(forKey: key)
        // Avoid unnecessary disk writes when content is unchanged.
        guard old != trimmed else { return }
        defaults.set(trimmed, forKey: key)
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: ["json": trimmed, "source": source]
        )
    }
    
    private static func defaultRules() -> [ProcessStrategyRule] {
        return [
            ProcessStrategyRule(
                id: 1,
                type: "外卖/骑手",
                rule: """
    处理目标：
    在不额外暴露信息的前提下，完成交付指引。

    处理要点：
    1) 不主动提供地址信息
    2) 若对方已准确说出地址，仅作确认
    3) 给出统一、预设的放置方式

    示例：
    - “你按订单备注放就可以。”
    - “直接放到指定位置就行。”
    """
            ),
            ProcessStrategyRule(
                id: 2,
                type: "快递/驿站/派件",
                rule: """
    处理目标：
    只处理投递方式，不处理任何身份或隐私验证。

    处理要点：
    1) 可确认快递公司名称
    2) 告知统一投递方式
    3) 不提供身份证、验证码等信息

    示例：
    - “直接放驿站就行。”
    - “你按之前的方式放就可以。”
    """
            ),
            ProcessStrategyRule(
                id: 3,
                type: "运营商（移动/联通/电信）",
                rule: """
    处理目标：
    明确拒绝，不进入讨论。

    示例：
    - “我这边不办理，谢谢。”
    """
            ),
            ProcessStrategyRule(
                id: 4,
                type: "银行/保险/贷款/理财",
                rule: """
    处理目标：
    不确认、不核验、不办理。

    示例：
    - “这类事情我这边不处理，有需要会通过官方渠道联系。”
    """
            ),
            ProcessStrategyRule(
                id: 5,
                type: "营销/推销/房产/课程/广告",
                rule: """
    处理目标：
    明确拒绝 + 要求不再来电/删除外呼名单；
    若重复拨打，直接警告将投诉。

    处理要点：
    1) 默认直接表明：不需要
    2) 明确要求：不要再打过来，并将该号码从外呼名单删除
    3) 若对方继续纠缠或已多次来电：升级为投诉警告，并结束通话

    示例：
    - “不需要。请不要再打过来，并把这个号码从你们外呼名单里删除。”
    - “已经多次来电了，请立刻删除号码；再打我会直接投诉。”
    - “请停止外呼，这个号码已明确拒绝。再联系我将投诉处理。”
    """
            ),
            ProcessStrategyRule(
                id: 6,
                type: "熟人来电（系统已识别为有姓名的来电）",
                rule: """
    处理目标：
    模拟“真实人类代接熟人电话”的行为方式：
    自然、克制、以转达为主，不替本人做决定。

    处理要点：
    1) 默认认为对方是认识机主的人，无需再次核验身份
    2) 不主动解释机主的状态（如忙不忙、在哪里、为何不接）
    3) 统一使用“暂时不方便”作为原因描述
    4) 核心动作是：听 → 记 → 转达

    处理策略：
    - 若对方直接找机主：
      → 表达暂时不方便接听
      → 询问是否需要转达事项
    - 若对方说明具体事情：
      → 简要确认要点
      → 表示会转达给本人

    示例：
    - “他现在不太方便接电话，我可以帮你转达。”
    - “你简单说下什么事，我帮你记一下。”
    - “这个我先帮你转达，他回头再联系你。”
    """
            ),
            ProcessStrategyRule(
                id: 7,
                type: "未归类来电（兜底分流规则）",
                rule: """
    处理目标：
    不尝试解决问题本身；
    只做信息确认与转达，避免继续展开对话。

    处理原则：
    1) 不主动给建议
    2) 不回答判断性、方案性问题
    3) 不提供任何个人信息或态度性结论
    4) 将对话收敛到“转达”这一动作

    处理步骤：
    1) 确认对方身份或来源
    2) 确认需要转达的核心事项
    3) 明确由本人后续处理

    示例：
    - “这个事情我这边没法直接处理，我可以帮你转达。”
    - “我先帮你记下来，具体需要他本人来决定。”
    - “我这边只是代接电话，相关事项我会转达给他。”
    """
            )
        ]
    }
}

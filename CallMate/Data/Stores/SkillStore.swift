//
//  SkillStore.swift
//  CallMate
//
//  来电 Skill 规则系统 — 每个场景一个 .md 文件，存于 Documents/strategies/ 目录。
//  文件格式：YAML frontmatter（tag/name/description/priority）+ markdown 正文
//  目录下还维护 manifest.json 轻量索引，供 hello 消息的 strategyManifest 字段使用。
//

import Foundation

// MARK: - 数据模型

struct SkillRule: Codable, Equatable, Identifiable {
    var id: String { tag }
    let tag: String          // 英文小写场景标识，如 express / takeout
    let name: String         // 中文场景名，如 快递
    let description: String  // 触发描述，用于 rule_summary 展示
    let priority: String     // "normal" 或 "urgent"
    let body: String         // 规则正文（markdown，条件 → 处理 + ## 禁止）
}

struct SkillChange {
    let tag: String
    let name: String
    let description: String
    let priority: String
    let body: String
    let action: String  // "add" | "update" | "delete"
}

// MARK: - Store

enum SkillStore {
    static let didChangeNotification = Notification.Name("SkillStore.didChange")

    // 内存缓存
    private static var cachedSummary: String = ""
    private static var cachedManifest: [[String: String]] = []

    // MARK: - 目录

    private static var strategiesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("strategies", isDirectory: true)
    }

    private static var manifestURL: URL {
        strategiesDirectory.appendingPathComponent("manifest.json")
    }

    private static func fileURL(for tag: String) -> URL {
        strategiesDirectory.appendingPathComponent("\(tag).md")
    }

    private static func ensureDirectoryExists() {
        let dir = strategiesDirectory
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 初始化

    private static let skillFormatVersionKey = "callmate.skill_format_version"
    private static let currentSkillFormatVersion = 2  // Skill 格式（- 条件 → 处理 + ## 禁止）

    static func ensureDefaultIfNeeded() {
        ensureDirectoryExists()
        migrateFromRulesDirectoryIfNeeded()  // rules/ → strategies/
        migrateFromUserDefaultsIfNeeded()
        let existing = loadSkills()
        if existing.isEmpty {
            for skill in defaultSkills() { writeSkillFile(skill) }
            rebuildSummary()
            UserDefaults.standard.set(currentSkillFormatVersion, forKey: skillFormatVersionKey)
        } else {
            migrateDefaultSkillsToNewFormatIfNeeded()
        }
    }

    /// 将旧 rules/ 目录迁移到 strategies/
    private static func migrateFromRulesDirectoryIfNeeded() {
        let fm = FileManager.default
        let oldDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rules", isDirectory: true)
        guard fm.fileExists(atPath: oldDir.path) else { return }
        let newDir = strategiesDirectory
        if !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        } else {
            // 新目录已存在：把旧目录里的 .md 文件逐个移过去
            if let files = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "md" {
                    let dest = newDir.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
            try? fm.removeItem(at: oldDir)
        }
        print("[SkillStore] migrated rules/ → strategies/")
    }

    /// 检测默认规则是否还是旧格式，是则用新 Skill 格式覆盖。自定义规则（非默认 tag）不动。
    private static func migrateDefaultSkillsToNewFormatIfNeeded() {
        let savedVersion = UserDefaults.standard.integer(forKey: skillFormatVersionKey)
        guard savedVersion < currentSkillFormatVersion else { return }

        let oldMarkers = ["处理目标：", "处理要点：", "处理原则：", "示例："]
        let newDefaults = defaultSkills().reduce(into: [String: SkillRule]()) { $0[$1.tag] = $1 }
        let existing = loadSkills()
        var didChange = false

        for skill in existing {
            guard let newDefault = newDefaults[skill.tag] else { continue }  // 自定义规则跳过
            let isOldFormat = oldMarkers.contains { skill.body.contains($0) }
            guard isOldFormat else { continue }
            writeSkillFile(newDefault)
            didChange = true
        }

        if didChange {
            rebuildSummary()
            notifyChange(source: "migrate_default_format")
        }
        UserDefaults.standard.set(currentSkillFormatVersion, forKey: skillFormatVersionKey)
    }

    static func resetToDefault() {
        ensureDirectoryExists()
        // 删除所有现有 .md 文件
        if let files = try? FileManager.default.contentsOfDirectory(
            at: strategiesDirectory, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "md" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        for skill in defaultSkills() {
            writeSkillFile(skill)
        }
        cachedSummary = ""
        rebuildSummary()
        notifyChange(source: "reset_to_default")
    }

    // MARK: - CRUD

    static func loadSkills() -> [SkillRule] {
        ensureDirectoryExists()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: strategiesDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> SkillRule? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parseMD(content)
            }
    }

    static func saveSkills(_ skills: [SkillRule], source: String = "save_skills") {
        ensureDirectoryExists()
        for skill in skills { writeSkillFile(skill) }
        rebuildSummary()
        notifyChange(source: source)
    }

    static func saveSkill(_ skill: SkillRule) {
        ensureDirectoryExists()
        writeSkillFile(skill)
        rebuildSummary()
        notifyChange(source: "save_skill_\(skill.tag)")
    }

    static func deleteSkill(tag: String) {
        try? FileManager.default.removeItem(at: fileURL(for: tag))
        rebuildSummary()
        notifyChange(source: "delete_skill_\(tag)")
    }

    static func applyChanges(_ changes: [SkillChange]) {
        ensureDirectoryExists()
        for change in changes {
            let action = change.action.lowercased()
            if action == "delete" {
                try? FileManager.default.removeItem(at: fileURL(for: change.tag))
                continue
            }
            let skill = SkillRule(
                tag: change.tag,
                name: change.name.isEmpty ? change.tag : change.name,
                description: change.description,
                priority: change.priority.isEmpty ? "normal" : change.priority,
                body: change.body
            )
            writeSkillFile(skill)
        }
        rebuildSummary()
        notifyChange(source: "apply_changes")
    }

    // MARK: - save_rule_file / delete_rule_file / get_all_rules（AI 编辑器工具）

    /// AI 编辑器调用 save_rule_file(tag, content) 时使用
    /// content 为完整 .md 文件内容（含 frontmatter）
    @discardableResult
    static func saveRuleFile(tag: String, content: String) -> Bool {
        guard let skill = parseMD(content), skill.tag == tag else { return false }
        ensureDirectoryExists()
        writeSkillFile(skill)
        rebuildSummary()
        notifyChange(source: "save_rule_file_\(tag)")
        return true
    }

    /// AI 编辑器调用 delete_rule_file(tag) 时使用
    static func deleteRuleFile(tag: String) {
        try? FileManager.default.removeItem(at: fileURL(for: tag))
        rebuildSummary()
        notifyChange(source: "delete_rule_file_\(tag)")
    }

    /// AI 编辑器调用 get_all_rules 时使用，返回所有文件完整内容
    static func getAllRulesContent() -> String {
        let skills = loadSkills()
        guard !skills.isEmpty else { return "暂无用户规则。" }
        return skills.map { encodeMD($0) }.joined(separator: "\n\n")
    }

    // MARK: - strategyManifest（hello 消息用，轻量索引数组）

    /// 返回 strategyManifest 数组，用于 hello 消息的 template_vars
    /// 格式：[{"id": "express", "name": "快递", "description": "..."}]
    static func getStrategyManifest() -> [[String: String]] {
        if cachedManifest.isEmpty { rebuildSummary() }
        return cachedManifest
    }

    /// 根据 systemCallType 预加载匹配的策略，用于 hello 消息的 preloadedStrategy 字段
    /// 返回 {"id": "express", "name": "快递", "content": "..."} 或 nil
    static func getPreloadedStrategy(for systemCallType: String) -> [String: String]? {
        let query = systemCallType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        // 先直接用 tag 文件名匹配
        if let content = try? String(contentsOf: fileURL(for: query), encoding: .utf8),
           let skill = parseMD(content) {
            return ["id": skill.tag, "name": skill.name, "content": skill.body]
        }
        // 再按 name 或包含匹配
        let skills = loadSkills()
        if let skill = skills.first(where: { $0.name == query })
            ?? skills.first(where: { query.contains($0.name) || $0.name.contains(query) }) {
            return ["id": skill.tag, "name": skill.name, "content": skill.body]
        }
        return nil
    }

    // MARK: - rule_summary（AI分身 用，保留兼容）

    static func getRuleSummary() -> String {
        if cachedSummary.isEmpty { rebuildSummary() }
        return cachedSummary.isEmpty ? "暂无用户规则。" : cachedSummary
    }

    // MARK: - load_rules tool 响应

    /// UI 展示用：只返回规则正文（不含 frontmatter），用于修改前后对比卡片
    static func getRuleBody(tag: String) -> String? {
        let query = normalizeStrategyType(tag)
        if let content = try? String(contentsOf: fileURL(for: query), encoding: .utf8),
           let skill = parseMD(content) {
            return skill.body
        }
        let skills = loadSkills()
        if let skill = skills.first(where: { $0.tag == query || $0.name == query })
            ?? skills.first(where: { query.contains($0.name) || $0.name.contains(query) }) {
            return skill.body
        }
        return nil
    }

    /// AI 调用 load_strategy / load_rules 时，返回完整 .md 文件内容（含 frontmatter）
    /// strategy_type 可能是 "express"、"express_delivery"、"快递" 等多种形式
    static func getRule(tag: String) -> String? {
        let query = normalizeStrategyType(tag)
        // 1. 精确匹配 tag 文件（express.md）→ 返回完整 .md 内容
        if let content = try? String(contentsOf: fileURL(for: query), encoding: .utf8),
           parseMD(content) != nil {
            return content
        }
        // 2. 遍历匹配 name 或包含匹配 → 重建完整 .md 内容返回
        let skills = loadSkills()
        if let skill = skills.first(where: { $0.tag == query || $0.name == query })
            ?? skills.first(where: { query.contains($0.name) || $0.name.contains(query) }) {
            return encodeMD(skill)
        }
        return nil
    }

    /// load_strategy tool_response 用：返回结构化的 (strategy_id, strategy_name, rules)
    /// rules 为纯正文（不含 frontmatter），strategy_id 为本地 tag
    static func getStrategyResponse(tag: String) -> (id: String, name: String, rules: String)? {
        let query = normalizeStrategyType(tag)
        // 1. 精确匹配 tag 文件
        if let content = try? String(contentsOf: fileURL(for: query), encoding: .utf8),
           let skill = parseMD(content) {
            return (id: skill.tag, name: skill.name, rules: skill.body)
        }
        // 2. 遍历匹配
        let skills = loadSkills()
        if let skill = skills.first(where: { $0.tag == query || $0.name == query })
            ?? skills.first(where: { query.contains($0.name) || $0.name.contains(query) }) {
            return (id: skill.tag, name: skill.name, rules: skill.body)
        }
        return nil
    }

    /// 后端 strategy_type（如 express_delivery）→ 本地 tag（如 express）
    private static func normalizeStrategyType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let map: [String: String] = [
            "express_delivery": "express",
            "food_delivery": "takeout",
            "telecom_service": "telecom",
            "financial_service": "finance",
            "marketing_call": "marketing",
            "acquaintance_call": "acquaintance",
            "unknown_call": "unknown",
            // 中文直接匹配
            "快递": "express", "外卖": "takeout", "运营商": "telecom",
            "银行": "finance", "金融": "finance", "推销": "marketing",
            "营销": "marketing", "熟人": "acquaintance", "未知": "unknown"
        ]
        return map[trimmed] ?? trimmed
    }

    // MARK: - MCU BLE 同步（JSON 格式，兼容 MCU FlashDB）

    static func skillsJSONString() -> String? {
        ensureDefaultIfNeeded()
        let skills = loadSkills()
        guard !skills.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(skills) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func validateJSON(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let _ = try? JSONDecoder().decode([SkillRule].self, from: data) else {
            return false
        }
        return true
    }

    /// MCU 同步过来的 JSON → 解码为 SkillRule → 保存为 .md 文件
    static func saveJSONIfValid(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let skills = try? JSONDecoder().decode([SkillRule].self, from: data) else {
            return false
        }
        saveSkills(skills, source: "save_json")
        return true
    }

    // MARK: - 私有：文件读写

    private static func writeSkillFile(_ skill: SkillRule) {
        let content = encodeMD(skill)
        try? content.write(to: fileURL(for: skill.tag), atomically: true, encoding: .utf8)
    }

    private static func rebuildSummary() {
        let skills = loadSkills()
        // rule_summary（AI分身 prompt 用）
        cachedSummary = skills.map { skill in
            let urgentTag = skill.priority == "urgent" ? "[转接]" : ""
            return "- \(skill.tag)\(urgentTag): \(skill.name)（\(skill.description)）"
        }.joined(separator: "\n")
        // strategyManifest（hello 消息用）
        cachedManifest = skills.map { skill in
            var entry: [String: String] = [
                "id": skill.tag,
                "name": skill.name,
                "description": skill.description
            ]
            if skill.priority == "urgent" { entry["priority"] = "urgent" }
            return entry
        }
        // 写 manifest.json 到磁盘
        writeManifestFile(skills: skills)
    }

    private static func writeManifestFile(skills: [SkillRule]) {
        let entries = skills.map { skill -> [String: String] in
            var entry: [String: String] = [
                "id": skill.tag,
                "name": skill.name,
                "description": skill.description
            ]
            if skill.priority == "urgent" { entry["priority"] = "urgent" }
            return entry
        }
        let manifest: [String: Any] = ["version": 1, "strategies": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func notifyChange(source: String) {
        let json = skillsJSONString() ?? ""
        let perform = {
            NotificationCenter.default.post(
                name: didChangeNotification,
                object: nil,
                userInfo: ["json": json, "source": source]
            )
        }
        if Thread.isMainThread { perform() }
        else { DispatchQueue.main.async { perform() } }
    }

    // MARK: - MD 编解码

    static func encodeMD(_ skill: SkillRule) -> String {
        """
        ---
        tag: \(skill.tag)
        name: \(skill.name)
        description: \(skill.description)
        priority: \(skill.priority)
        ---

        \(skill.body)
        """
    }

    static func parseMD(_ content: String) -> SkillRule? {
        // 以 "---" 分割，兼容首行空白
        let parts = content.components(separatedBy: "\n---")
        // 格式：[可选空内容, frontmatter, body...]
        // 也支持内容以 "---\n" 开头
        var frontmatter = ""
        var body = ""

        if content.hasPrefix("---") {
            // ---\nfrontmatter\n---\nbody
            let stripped = String(content.dropFirst(3)) // 去掉第一个 ---
            let fmEnd = stripped.range(of: "\n---")
            if let r = fmEnd {
                frontmatter = String(stripped[stripped.startIndex..<r.lowerBound])
                body = String(stripped[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                frontmatter = stripped
            }
        } else {
            // 没有 frontmatter，整体当 body（兼容老数据）
            body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 解析 frontmatter
        var tag = "", name = "", description = "", priority = "normal"
        for line in frontmatter.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("tag:") {
                tag = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("name:") {
                name = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("description:") {
                description = String(t.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("priority:") {
                priority = String(t.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard !tag.isEmpty else { return nil }
        if name.isEmpty { name = tag }
        return SkillRule(tag: tag, name: name, description: description, priority: priority, body: body)
    }

    // MARK: - UserDefaults 迁移（旧 JSON → .md 文件）

    private static let legacyKey = "callmate.skill_rules"

    private static func migrateFromUserDefaultsIfNeeded() {
        guard let json = UserDefaults.standard.string(forKey: legacyKey),
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let skills = try? JSONDecoder().decode([SkillRule].self, from: data) else { return }
        print("[SkillStore] migrating \(skills.count) skills from UserDefaults → .md files")
        for skill in skills { writeSkillFile(skill) }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    // MARK: - 默认规则（Skill 格式）

    private static func defaultSkills() -> [SkillRule] {
        [
            SkillRule(
                tag: "takeout",
                name: "外卖",
                description: "外卖配送员来电",
                priority: "normal",
                body: """
                - 正常配送 → 放门口，提醒对方按备注放
                - 有问题（洒了、少了、送错了）→ 记录具体问题，转达机主

                ## 禁止

                - 不主动提供地址信息
                - 不告知是否在家
                - 不替机主要求退款或重新配送
                """
            ),
            SkillRule(
                tag: "express",
                name: "快递",
                description: "快递员来电取件或派件",
                priority: "normal",
                body: """
                - 普通件 → 放驿站或门口
                - 到付件 → 不签收，记录金额和快递单号，转达机主
                - 贵重物品（对方主动说了贵重）→ 让改时间再送

                ## 禁止

                - 不告知具体地址门牌号
                - 不提供身份证、验证码等信息
                - 不替机主决定是否签收到付件
                """
            ),
            SkillRule(
                tag: "telecom",
                name: "运营商",
                description: "移动/联通/电信业务推广来电",
                priority: "normal",
                body: """
                - 涉及套餐/宽带/优惠/升级 → 直接拒绝，"我这边不办理，谢谢。"
                - 重复来电 → 同样拒绝，不进入讨论

                ## 禁止

                - 不确认是哪家运营商的客户
                - 不提供任何账户信息
                """
            ),
            SkillRule(
                tag: "finance",
                name: "银行金融",
                description: "银行/保险/贷款/理财等推广来电",
                priority: "normal",
                body: """
                - 涉及银行/保险/信用卡/贷款/额度/理赔 → "这类事情我这边不处理，有需要会通过官方渠道联系。"

                ## 禁止

                - 不确认是否为该银行/机构客户
                - 不提供任何账户信息
                """
            ),
            SkillRule(
                tag: "marketing",
                name: "营销推销",
                description: "房产/课程/广告等营销推广来电",
                priority: "normal",
                body: """
                - 推销电话 → "不需要，请不要再打过来，并把这个号码从外呼名单里删除。"
                - 问卷调查 → 拒绝参与，"不方便，谢谢。"
                - 已多次来电 → "已经多次来电了，请立刻删除号码，再打我会直接投诉。"

                ## 禁止

                - 不进入任何实质性讨论
                """
            ),
            SkillRule(
                tag: "acquaintance",
                name: "熟人来电",
                description: "系统识别为通讯录联系人的来电",
                priority: "normal",
                body: """
                - 对方直接找机主 → 表达暂时不方便接听，询问是否需要转达
                - 对方说明具体事情 → 简要确认要点，表示会转达给本人

                ## 禁止

                - 不主动解释机主的状态或位置
                - 不替机主做任何承诺或决定
                """
            ),
            SkillRule(
                tag: "unknown",
                name: "未归类来电",
                description: "无法归类的兜底来电",
                priority: "normal",
                body: """
                - 来意不明 → 询问身份和来电目的
                - 来意已明但不在其他规则范围内 → 记录核心事项，转达机主

                ## 禁止

                - 不主动给建议或做判断
                - 不提供任何个人信息
                """
            )
        ]
    }
}

//
//  OutboundSettingsViews.swift
//  CallMate
//

import SwiftUI
import SwiftData

// MARK: - Outbound Task Type

enum OutboundTaskType: String, CaseIterable, Identifiable {
    case booking = "Booking"
    case negotiation = "Negotiation"
    case collection = "Collection"
    case notification = "Notification"
    case inquiry = "Inquiry"
    case general = "General"

    var id: String { rawValue }

    func label(_ lang: Language) -> String {
        switch self {
        case .booking: lang == .zh ? "订位 / 预约" : "Booking"
        case .negotiation: lang == .zh ? "谈判 / 议价" : "Negotiation"
        case .collection: lang == .zh ? "催收 / 催款" : "Collection"
        case .notification: lang == .zh ? "通知 / 传话" : "Notification"
        case .inquiry: lang == .zh ? "咨询 / 确认" : "Inquiry"
        case .general: lang == .zh ? "通用" : "General"
        }
    }

    func tag(_ lang: Language) -> String {
        switch self {
        case .booking: lang == .zh ? "订位" : "Book"
        case .negotiation: lang == .zh ? "谈判" : "Negotiate"
        case .collection: lang == .zh ? "催收" : "Collect"
        case .notification: lang == .zh ? "通知" : "Notify"
        case .inquiry: lang == .zh ? "咨询" : "Inquiry"
        case .general: lang == .zh ? "通用" : "General"
        }
    }

    var tagColor: Color {
        switch self {
        case .booking: AppColors.primary
        case .negotiation: AppColors.warning
        case .collection: AppColors.error
        case .notification: AppColors.accent
        case .inquiry: AppColors.success
        case .general: Color.gray
        }
    }

    var icon: String {
        switch self {
        case .booking: "fork.knife"
        case .negotiation: "dollarsign.circle"
        case .collection: "exclamationmark.bubble"
        case .notification: "megaphone"
        case .inquiry: "questionmark.circle"
        case .general: "ellipsis.circle"
        }
    }

    func briefDescription(_ lang: Language) -> String {
        switch self {
        case .booking: lang == .zh ? "适合订餐、预约、排队、订位" : "For reservations, appointments"
        case .negotiation: lang == .zh ? "适合采购、砍价、议价谈判" : "For purchasing, bargaining"
        case .collection: lang == .zh ? "适合催收、催款、投诉索赔" : "For debt collection, claims"
        case .notification: lang == .zh ? "适合请假、通知、单向传话" : "For notices, one-way messages"
        case .inquiry: lang == .zh ? "适合价格、库存、营业时间、是否可办" : "For prices, stock, business hours"
        case .general: lang == .zh ? "其他无法归类的通用场景" : "General purpose scenarios"
        }
    }

    func defaultGoal(_ lang: Language) -> String {
        switch self {
        case .booking:
            lang == .zh
                ? "围绕用户确认的时间、人数、位置偏好与决策边界，帮用户与商家完成订位或预约。"
                : "Complete a booking based on user's time, party size, preference and fallback rules."
        case .negotiation:
            lang == .zh
                ? "围绕用户设定的目标价格与底线，帮用户与对方完成谈判或议价。"
                : "Negotiate based on user's target price and bottom line."
        case .collection:
            lang == .zh
                ? "围绕欠款金额与还款期限，帮用户催促对方完成还款或达成还款方案。"
                : "Collect payment based on owed amount and due date."
        case .notification:
            lang == .zh
                ? "将用户的消息准确传达给对方，确认对方收到并理解。"
                : "Deliver user's message and confirm receipt."
        case .inquiry:
            lang == .zh
                ? "围绕用户想确认的问题进行简洁沟通，拿到明确答复后结束。"
                : "Ask specific questions and get clear answers."
        case .general:
            lang == .zh
                ? "根据用户描述的任务目标，完成电话沟通。"
                : "Complete the call based on user's described goal."
        }
    }
}

// MARK: - Template Field Model

struct TemplateFieldItem: Identifiable {
    let id: UUID
    var key: String
    var label: String
    var type: String
    var defaultValue: String
    var requireFreshInput: Bool
    var category: FieldCategory

    enum FieldCategory: String {
        case routing, identity, strategy, business, custom
    }

    init(
        id: UUID = UUID(),
        key: String,
        label: String,
        type: String = "string",
        defaultValue: String = "",
        requireFreshInput: Bool = true,
        category: FieldCategory
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.requireFreshInput = requireFreshInput
        self.category = category
    }
}

// MARK: - Default Fields per Task Type

extension OutboundTaskType {
    func defaultSystemFields(_ lang: Language) -> [TemplateFieldItem] {
        let zh = lang == .zh
        var fields: [TemplateFieldItem] = [
            TemplateFieldItem(key: "target_name", label: zh ? "联系人" : "Contact Name", category: .routing),
            TemplateFieldItem(key: "target_phone", label: zh ? "联系电话" : "Phone Number", type: "phone", category: .routing),
        ]
        switch self {
        case .booking:
            fields += [
                TemplateFieldItem(key: "booking_time", label: zh ? "用餐时间" : "Booking Time", category: .business),
                TemplateFieldItem(key: "party_size", label: zh ? "人数" : "Party Size", category: .business),
                TemplateFieldItem(key: "seating_preference", label: zh ? "位置偏好" : "Seating Preference", requireFreshInput: false, category: .strategy),
                TemplateFieldItem(key: "fallback_no_room", label: zh ? "包厢不可用时怎么处理" : "If private room unavailable", requireFreshInput: false, category: .strategy),
                TemplateFieldItem(key: "fallback_min_charge", label: zh ? "出现低消/加价时怎么处理" : "If minimum charge applies", requireFreshInput: false, category: .strategy),
            ]
        case .negotiation:
            fields += [
                TemplateFieldItem(key: "product_name", label: zh ? "商品/服务名称" : "Product/Service", category: .business),
                TemplateFieldItem(key: "target_price", label: zh ? "目标价格" : "Target Price", category: .business),
                TemplateFieldItem(key: "price_floor", label: zh ? "底线价格" : "Price Floor", requireFreshInput: false, category: .strategy),
                TemplateFieldItem(key: "fallback_strategy", label: zh ? "超出底线怎么处理" : "If exceeds floor", requireFreshInput: false, category: .strategy),
            ]
        case .collection:
            fields += [
                TemplateFieldItem(key: "debt_amount", label: zh ? "欠款金额" : "Debt Amount", category: .business),
                TemplateFieldItem(key: "due_date", label: zh ? "到期日期" : "Due Date", category: .business),
                TemplateFieldItem(key: "negotiation_space", label: zh ? "可协商空间" : "Negotiation Space", requireFreshInput: false, category: .strategy),
                TemplateFieldItem(key: "escalation", label: zh ? "拒绝还款时怎么处理" : "If payment refused", requireFreshInput: false, category: .strategy),
            ]
        case .notification:
            fields += [
                TemplateFieldItem(key: "message_content", label: zh ? "传达内容" : "Message Content", category: .business),
                TemplateFieldItem(key: "confirm_receipt", label: zh ? "是否需要对方确认" : "Confirmation needed", defaultValue: zh ? "是" : "Yes", requireFreshInput: false, category: .strategy),
            ]
        case .inquiry:
            fields += [
                TemplateFieldItem(key: "inquiry_topic", label: zh ? "咨询主题" : "Inquiry Topic", category: .business),
                TemplateFieldItem(key: "specific_questions", label: zh ? "具体问题" : "Specific Questions", category: .business),
                TemplateFieldItem(key: "fallback_strategy", label: zh ? "问不到时怎么处理" : "If can't get answer", requireFreshInput: false, category: .strategy),
            ]
        case .general:
            break
        }
        return fields
    }

    func defaultCallRules(_ lang: Language) -> String {
        let zh = lang == .zh
        switch self {
        case .booking:
            return zh
                ? "开场直接说明预订需求\n确认时间人数是否可行\n不可行则询问最近可选时间"
                : "State booking request upfront\nConfirm availability\nAsk for alternatives if unavailable"
        case .negotiation:
            return zh
                ? "开场说明采购意向和目标价\n探明对方底价\n按底线策略决定是否成交"
                : "State purchase intent and target\nExplore their floor price\nDecide based on strategy"
        case .collection:
            return zh
                ? "开场确认对方身份和欠款事实\n明确还款期限要求\n按策略决定是否升级处理"
                : "Confirm identity and debt\nState repayment deadline\nEscalate per strategy"
        case .notification:
            return zh
                ? "开场说明来意\n准确传达消息内容\n确认对方已收到并理解"
                : "State purpose\nDeliver message\nConfirm receipt"
        case .inquiry:
            return zh
                ? "开场说明咨询目的\n依次提出具体问题\n记录对方的明确答复"
                : "State inquiry purpose\nAsk specific questions\nRecord clear answers"
        case .general:
            return ""
        }
    }
}

// MARK: - Template Form Data

struct TemplateFormData {
    var templateName: String = ""
    var taskType: OutboundTaskType = .booking
    var goal: String = ""
    var systemFields: [TemplateFieldItem] = []
    var customFields: [TemplateFieldItem] = []
    var callRules: String = ""

    var allEditableFields: [TemplateFieldItem] {
        systemFields + customFields
    }

    var filledCount: Int {
        allEditableFields.filter { !$0.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var totalCount: Int {
        allEditableFields.count
    }
}

// MARK: - Content ↔ Form Parsing

extension TemplateFormData {

    /// Extract the first top-level JSON object from mixed content (JSON + plain text).
    /// Uses balanced-brace matching instead of greedy regex to avoid capturing trailing text.
    private static func extractTopLevelJSON(from content: String) -> [String: Any]? {
        guard let start = content.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false

        for idx in content.indices[start...] {
            let ch = content[idx]
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let jsonStr = String(content[start...idx])
                    guard let data = jsonStr.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return nil }
                    return obj
                }
            }
        }
        return nil
    }

    init(name: String, content: String, language: Language) {
        self.templateName = name

        guard let json = Self.extractTopLevelJSON(from: content) else {
            self.taskType = .general
            self.goal = ""
            self.systemFields = []
            self.customFields = []
            self.callRules = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        if let typeStr = json["task_type"] as? String,
           let type = OutboundTaskType(rawValue: typeStr) {
            self.taskType = type
        } else {
            self.taskType = .general
        }

        self.goal = json["goal"] as? String ?? ""

        var sys: [TemplateFieldItem] = []
        var cus: [TemplateFieldItem] = []

        if let schema = json["frontend_schema"] as? [String: Any] {
            let categoryMap: [(String, TemplateFieldItem.FieldCategory)] = [
                ("routing_variables", .routing),
                ("strategy_variables", .strategy),
                ("business_variables", .business),
            ]
            for (key, cat) in categoryMap {
                if let vars = schema[key] as? [[String: Any]] {
                    for v in vars {
                        let isCustom = v["is_custom"] as? Bool ?? false
                        let field = TemplateFieldItem(
                            key: v["key"] as? String ?? "",
                            label: v["label"] as? String ?? "",
                            type: v["type"] as? String ?? "string",
                            defaultValue: v["default_value"] as? String ?? "",
                            requireFreshInput: v["require_fresh_input"] as? Bool ?? true,
                            category: isCustom ? .custom : cat
                        )
                        if isCustom {
                            cus.append(field)
                        } else {
                            sys.append(field)
                        }
                    }
                }
            }
        }

        self.systemFields = sys
        self.customFields = cus

        if let rules = json["call_rules"] as? [String] {
            self.callRules = rules.joined(separator: "\n")
        } else {
            self.callRules = ""
        }
    }

    func toContent() -> String {
        func fieldDict(_ f: TemplateFieldItem, isCustom: Bool = false) -> [String: Any] {
            var d: [String: Any] = [
                "key": f.key,
                "label": f.label,
                "type": f.type,
                "require_fresh_input": f.requireFreshInput,
                "default_value": f.defaultValue,
            ]
            if isCustom { d["is_custom"] = true }
            return d
        }

        let routingVars = systemFields.filter { $0.category == .routing }.map { fieldDict($0) }
        let strategyVars = systemFields.filter { $0.category == .strategy }.map { fieldDict($0) }
        let businessVars = systemFields.filter { $0.category == .business }.map { fieldDict($0) }
            + customFields.map { fieldDict($0, isCustom: true) }

        let identityVars: [[String: Any]] = [
            ["key": "callback_phone", "label": "预留电话", "type": "phone", "require_fresh_input": false, "default_value": ""],
            ["key": "user_name", "label": "本次称呼", "type": "string", "require_fresh_input": false, "default_value": ""],
        ]

        let schema: [String: Any] = [
            "routing_variables": routingVars,
            "identity_variables": identityVars,
            "strategy_variables": strategyVars,
            "business_variables": businessVars,
        ]

        let rules = callRules
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let root: [String: Any] = [
            "template_name": templateName,
            "task_type": taskType.rawValue,
            "goal": goal,
            "frontend_schema": schema,
            "call_rules": rules,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return callRules
    }
}

// MARK: - Editor Mode

private enum TemplateEditorMode: Identifiable {
    case new
    case edit(OutboundPromptTemplate)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let t): return t.id.uuidString
        }
    }

    var template: OutboundPromptTemplate? {
        if case .edit(let t) = self { return t }
        return nil
    }
}

// MARK: - Template Settings View (List Page)

struct OutboundTemplateSettingsView: View {
    let language: Language
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OutboundPromptTemplate.updatedAt, order: .reverse) private var templates: [OutboundPromptTemplate]
    @State private var editorMode: TemplateEditorMode?

    @AppStorage("outbound_default_user_name") private var defaultUserName: String = ""
    @AppStorage("outbound_callback_method") private var callbackMethod: String = "current"
    @AppStorage("outbound_custom_callback_phone") private var customCallbackPhone: String = ""
    @State private var showIdentityPrefs = false

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                headerInfoCard
                identityPrefsSection
                templateListSection
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
        }
        .background(AppColors.backgroundSecondary)
        .navigationTitle(t("话术配置", "Script Config"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorMode = .new
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            OutboundTemplateEditorSheet(
                language: language,
                template: mode.template,
                onSave: { name, content in
                    saveTemplate(name: name, content: content)
                },
                onDelete: mode.template == nil ? nil : {
                    deleteTemplate(mode.template)
                }
            )
        }
        .sheet(isPresented: $showIdentityPrefs) {
            OutboundIdentityPrefsSheet(
                language: language,
                userName: $defaultUserName,
                callbackMethod: $callbackMethod,
                customPhone: $customCallbackPhone
            )
        }
    }

    // MARK: Header Info Card

    private var headerInfoCard: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(AppColors.primary)
                .padding(.top, 2)
            Text(t(
                "这里保存的是 AI 外呼默认话术骨架。\n首次先设置默认称呼和留号方式；每个任务模板只保留固定字段名，用户只能改内容，也可以增加补充事项。",
                "These are default AI call script skeletons.\nSet your default name and callback first; each template has fixed field names — you can edit values and add extras."
            ))
            .font(AppTypography.footnote)
            .foregroundColor(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .background(AppColors.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    // MARK: Identity Preferences

    private var identityPrefsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(t("默认身份偏好", "Default Identity"))
                .font(AppTypography.footnoteEmphasized)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, AppSpacing.xxs)

            Button { showIdentityPrefs = true } label: {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "person.text.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(AppColors.primary)
                            .frame(width: 36, height: 36)
                            .background(AppColors.primary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("预留信息", "Reserved Info"))
                                .font(AppTypography.subheadlineEmphasized)
                                .foregroundColor(AppColors.textPrimary)
                            Text(identitySubtitle)
                                .font(AppTypography.caption1)
                                .foregroundColor(AppColors.textTertiary)
                        }
                        Spacer()
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            identityRow(
                                label: t("默认称呼", "Default Name"),
                                value: defaultUserName.isEmpty ? t("未设置", "Not set") : defaultUserName,
                                isEmpty: defaultUserName.isEmpty
                            )
                            identityRow(
                                label: t("留号方式", "Callback"),
                                value: callbackMethodDisplay,
                                isEmpty: false
                            )
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.chevron)
                    }
                }
                .padding(AppSpacing.md)
                .background(AppColors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func identityRow(label: String, value: String, isEmpty: Bool) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(label)
                .font(AppTypography.footnote)
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 65, alignment: .leading)
            Text(value)
                .font(AppTypography.footnote)
                .foregroundColor(isEmpty ? AppColors.textTertiary : AppColors.textPrimary)
        }
    }

    private var identitySubtitle: String {
        if defaultUserName.isEmpty {
            return t("你还没设置默认称呼，首次外呼时会先补这两个信息。",
                     "No default name set. Will ask on first call.")
        }
        return t("已设置默认称呼，外呼时会自动使用。",
                 "Default name is set and will be used automatically.")
    }

    private var callbackMethodDisplay: String {
        if callbackMethod == "custom" && !customCallbackPhone.isEmpty {
            return customCallbackPhone
        }
        return t("当前拨打号码", "Current calling number")
    }

    // MARK: Template List

    private var templateListSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(t("任务模板", "Task Templates"))
                .font(AppTypography.footnoteEmphasized)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, AppSpacing.xxs)

            if templates.isEmpty {
                emptyTemplateCard
            } else {
                ForEach(templates, id: \.id) { template in
                    templateCard(template)
                }
            }
        }
    }

    private var emptyTemplateCard: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.textTertiary)
            Text(t("还没有模板，点击右上角 + 新建。", "No templates yet. Tap + to create one."))
                .font(AppTypography.subheadline)
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
        .background(AppColors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    private func templateCard(_ template: OutboundPromptTemplate) -> some View {
        let form = TemplateFormData(name: template.name, content: template.content, language: language)
        let taskType = form.taskType
        let isStructured = !form.systemFields.isEmpty || form.taskType != .general || !form.goal.isEmpty

        return Button {
            editorMode = .edit(template)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: taskType.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(taskType.tagColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppSpacing.xs) {
                            Text(template.name)
                                .font(AppTypography.bodyEmphasized)
                                .foregroundColor(AppColors.textPrimary)

                            if isStructured {
                                Text(taskType.tag(language))
                                    .font(AppTypography.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(taskType.tagColor.opacity(0.12))
                                    .foregroundColor(taskType.tagColor)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(isStructured ? taskType.briefDescription(language) : templatePreview(template.content))
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.chevron)
                }

                if isStructured {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("实现目标", "Goal"))
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textSecondary)
                        Text(form.goal.isEmpty ? taskType.defaultGoal(language) : form.goal)
                            .font(AppTypography.subheadline)
                            .foregroundColor(AppColors.textPrimary)
                            .lineLimit(2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("已填写默认项", "Defaults Filled"))
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textSecondary)
                        Text(filledStatusText(form))
                            .font(AppTypography.caption1)
                            .foregroundColor(AppColors.textTertiary)
                    }
                }
            }
            .padding(AppSpacing.md)
            .background(AppColors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                deleteTemplate(template)
            } label: {
                Label(t("删除", "Delete"), systemImage: "trash")
            }
        }
    }

    private func filledStatusText(_ form: TemplateFormData) -> String {
        if form.filledCount == 0 {
            return t("还没有填写默认项，后续会在对话里补齐。",
                     "No defaults filled yet, will be collected in conversation.")
        }
        return t("已填写 \(form.filledCount)/\(form.totalCount) 项",
                 "\(form.filledCount)/\(form.totalCount) filled")
    }

    private func templatePreview(_ content: String) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let pattern = "####\\s*任务目标设定\\s*####([\\s\\S]*?)(?:####|$)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            let extracted = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if !extracted.isEmpty { return extracted }
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("你是") })
            ?? text.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Persistence

    private func deleteTemplate(_ template: OutboundPromptTemplate?) {
        guard let template else { return }
        modelContext.delete(template)
        do {
            try modelContext.save()
            editorMode = nil
        } catch {
            print("[OutboundTemplate] delete failed: \(error.localizedDescription)")
        }
    }

    private func saveTemplate(name: String, content: String) {
        let now = Date()
        if let editingTemplate = editorMode?.template {
            editingTemplate.name = name
            editingTemplate.content = content
            editingTemplate.updatedAt = now
        } else {
            let template = OutboundPromptTemplate(
                name: name,
                content: content,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(template)
        }
        do {
            try modelContext.save()
        } catch {
            print("[OutboundTemplate] save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Identity Preferences Sheet

struct OutboundIdentityPrefsSheet: View {
    let language: Language
    @Binding var userName: String
    @Binding var callbackMethod: String
    @Binding var customPhone: String
    @Environment(\.dismiss) private var dismiss

    @State private var editName: String = ""
    @State private var editMethod: String = "current"
    @State private var editPhone: String = ""

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(t("外呼时如果对方需要留姓名和回电号码，会优先使用这里的默认值。",
                           "When the call recipient asks for name or callback number, these defaults will be used."))
                        .font(AppTypography.footnote)
                        .foregroundColor(AppColors.textSecondary)
                        .listRowBackground(Color.clear)
                }

                Section(t("称呼", "Name")) {
                    TextField(t("例如：张先生", "e.g. Mr. Zhang"), text: $editName)
                }

                Section(t("留号方式", "Callback Method")) {
                    Picker(t("留号方式", "Method"), selection: $editMethod) {
                        Text(t("当前拨打号码", "Current calling number")).tag("current")
                        Text(t("自定义号码", "Custom number")).tag("custom")
                    }
                    .pickerStyle(.segmented)

                    if editMethod == "custom" {
                        TextField(t("输入回电号码", "Enter callback number"), text: $editPhone)
                            .keyboardType(.phonePad)
                    }
                }
            }
            .navigationTitle(t("身份偏好", "Identity Preferences"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("保存", "Save")) {
                        userName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        callbackMethod = editMethod
                        customPhone = editPhone.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                editName = userName
                editMethod = callbackMethod
                editPhone = customPhone
            }
        }
    }
}

// MARK: - Template Editor Sheet

struct OutboundTemplateEditorSheet: View {
    let language: Language
    let template: OutboundPromptTemplate?
    let onSave: (String, String) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var templateName: String = ""
    @State private var taskType: OutboundTaskType = .booking
    @State private var goal: String = ""
    @State private var systemFields: [TemplateFieldItem] = []
    @State private var customFields: [TemplateFieldItem] = []
    @State private var callRules: String = ""
    @State private var isStructured: Bool = true
    @State private var rawContent: String = ""
    @State private var showDeleteConfirmation = false
    @State private var isNewTemplate: Bool = true

    init(
        language: Language,
        template: OutboundPromptTemplate?,
        onSave: @escaping (String, String) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.language = language
        self.template = template
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var canSave: Bool {
        !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isStructured {
                    structuredEditor
                } else {
                    rawEditor
                }
            }
            .background(AppColors.backgroundSecondary)
            .navigationTitle(template == nil ? t("新建模板", "New Template") : t("编辑模板", "Edit Template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("保存", "Save")) { saveAction() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                t("确认删除这个模板吗？", "Delete this template?"),
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(t("删除", "Delete"), role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button(t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(t("删除后不可恢复。", "This action cannot be undone."))
            }
            .onAppear { loadTemplate() }
        }
    }

    // MARK: Structured Editor

    private var structuredEditor: some View {
        Form {
            infoNoteSection
            basicInfoSection
            systemFieldsSection
            customFieldsSection
            callRulesSection
            if template != nil, onDelete != nil {
                deleteSection
            }
        }
    }

    // MARK: Raw Editor (for old-format templates)

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.x2) {
            TextField(t("模板名称", "Template Name"), text: $templateName)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $rawContent)
                .font(AppTypography.body)
                .frame(minHeight: 220)
                .padding(DS.Spacing.x1)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(DS.Radius.button)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.button)
                        .stroke(AppColors.border, lineWidth: 1)
                )

            if template != nil, onDelete != nil {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "trash")
                        Text(t("删除模板", "Delete Template"))
                    }
                    .font(AppTypography.bodyEmphasized)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.x1)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.x2)
    }

    // MARK: Form Sections

    private var infoNoteSection: some View {
        Section {
            Text(t("固定字段名不能删除或改名，你只需要填写内容；如果不够用，可以自己增加补充事项。",
                   "Fixed field names can't be changed or deleted. Just fill in the content; add extras if needed."))
                .font(AppTypography.footnote)
                .foregroundColor(AppColors.textSecondary)
        }
    }

    private var basicInfoSection: some View {
        Section(t("基础信息", "Basic Info")) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(t("模板名称", "Template Name"), text: $templateName)
                    .font(AppTypography.body)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("任务类型", "Task Type"))
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textSecondary)
                Picker("", selection: $taskType) {
                    ForEach(OutboundTaskType.allCases) { type in
                        Text(type.label(language)).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .onChange(of: taskType) { _, newType in
                guard isNewTemplate else { return }
                systemFields = newType.defaultSystemFields(language)
                goal = newType.defaultGoal(language)
                callRules = newType.defaultCallRules(language)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("实现目标", "Goal"))
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textSecondary)
                ZStack(alignment: .topLeading) {
                    if goal.isEmpty {
                        Text(t("描述这类电话要达成的结果", "Describe the goal for this type of call"))
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textTertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $goal)
                        .font(AppTypography.body)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var systemFieldsSection: some View {
        Section(t("系统固定字段", "System Fields")) {
            if systemFields.isEmpty {
                Text(t("该类型暂无固定字段", "No fixed fields for this type"))
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textTertiary)
            } else {
                ForEach($systemFields) { $field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field.label)
                            .font(AppTypography.footnote)
                            .foregroundColor(AppColors.textSecondary)
                        TextField(t("填写默认内容", "Default value"), text: $field.defaultValue)
                            .font(AppTypography.body)
                    }
                }
            }
        }
    }

    private var customFieldsSection: some View {
        Section {
            ForEach($customFields) { $field in
                VStack(alignment: .leading, spacing: 6) {
                    TextField(t("字段名称", "Field name"), text: $field.label)
                        .font(AppTypography.footnote)
                        .foregroundColor(AppColors.textSecondary)
                    TextField(t("填写默认内容", "Default value"), text: $field.defaultValue)
                        .font(AppTypography.body)
                }
            }
            .onDelete { indices in
                customFields.remove(atOffsets: indices)
            }

            Button {
                withAnimation {
                    customFields.append(TemplateFieldItem(
                        key: "custom_\(customFields.count + 1)",
                        label: "",
                        category: .custom
                    ))
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(AppColors.primary)
                    Text(t("新增", "Add"))
                        .foregroundColor(AppColors.primary)
                }
                .font(AppTypography.subheadline)
            }
        } header: {
            HStack {
                Text(t("补充事项", "Additional Items"))
            }
        } footer: {
            Text(t("没有补充事项时也没关系，后续可以随时增加。",
                   "No worries if empty — you can add items anytime."))
        }
    }

    private var callRulesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("AI 外呼时遵守的规则，每行一条",
                       "Rules AI follows during the call, one per line"))
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.textSecondary)
                ZStack(alignment: .topLeading) {
                    if callRules.isEmpty {
                        Text(t("例如：开场直接说明预订需求", "e.g. State booking request upfront"))
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textTertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $callRules)
                        .font(AppTypography.body)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                }
            }
        } header: {
            Text(t("通话规则", "Call Rules"))
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "trash")
                    Text(t("删除模板", "Delete Template"))
                }
                .font(AppTypography.bodyEmphasized)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Load / Save

    private func loadTemplate() {
        guard let template else {
            isNewTemplate = true
            isStructured = true
            taskType = .booking
            templateName = ""
            goal = taskType.defaultGoal(language)
            systemFields = taskType.defaultSystemFields(language)
            customFields = []
            callRules = taskType.defaultCallRules(language)
            return
        }

        isNewTemplate = false
        templateName = template.name

        let form = TemplateFormData(name: template.name, content: template.content, language: language)

        if form.systemFields.isEmpty && form.taskType == .general && form.goal.isEmpty && !form.callRules.isEmpty {
            isStructured = false
            rawContent = template.content
            return
        }

        isStructured = true
        taskType = form.taskType
        goal = form.goal
        systemFields = form.systemFields
        customFields = form.customFields
        callRules = form.callRules
    }

    private func saveAction() {
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content: String

        if isStructured {
            var form = TemplateFormData()
            form.templateName = name
            form.taskType = taskType
            form.goal = goal
            form.systemFields = systemFields
            form.customFields = customFields.filter {
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            form.callRules = callRules
            content = form.toContent()
        } else {
            content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        onSave(name, content)
        dismiss()
    }
}

// MARK: - Call Settings Hub

struct OutboundCallSettingsView: View {
    let language: Language
    let onBack: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(language: Language, onBack: (() -> Void)? = nil) {
        self.language = language
        self.onBack = onBack
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private func handleBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    OutboundContactsManagementView(language: language)
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(AppColors.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(t("外呼名单管理", "Contact List"))
                            .font(DS.Typography.body)
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .padding(.vertical, AppSpacing.xxxs)
                }

                NavigationLink {
                    OutboundTemplateSettingsView(language: language)
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "text.quote")
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(AppColors.warning)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(t("话术配置", "Prompt Config"))
                            .font(DS.Typography.body)
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .padding(.vertical, AppSpacing.xxxs)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(t("打电话设置", "Call Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        handleBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(DS.Typography.body.weight(.semibold))
                            .foregroundStyle(AppColors.primary)
                    }
                }
            }
        }
    }
}

// MARK: - Contacts Management

struct OutboundContactsManagementView: View {
    let language: Language
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OutboundContactBookEntry.updatedAt, order: .reverse) private var contacts: [OutboundContactBookEntry]
    @State private var searchText = ""
    @State private var showEditor = false
    @State private var editingContact: OutboundContactBookEntry?

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        List {
            if filteredContacts.isEmpty {
                Text(t("暂无联系人，点击右上角 + 新建。", "No contacts yet. Tap + to add one."))
                    .font(DS.Typography.body)
                    .foregroundColor(AppColors.textSecondary)
            } else {
                ForEach(filteredContacts, id: \.id) { contact in
                    HStack(spacing: AppSpacing.md) {
                        VStack(alignment: .leading, spacing: AppSpacing.xxxs) {
                            Text(contact.name)
                                .font(DS.Typography.body.weight(.semibold))
                                .foregroundColor(AppColors.textPrimary)
                            Text(contact.phone)
                                .font(DS.Typography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        Spacer()
                        Button {
                            editingContact = contact
                            showEditor = true
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(AppColors.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, AppSpacing.xxxs)
                }
                .onDelete(perform: deleteContacts)
            }
        }
        .listStyle(.plain)
        .navigationTitle(t("外呼名单", "Contact List"))
        .searchable(text: $searchText, prompt: Text(t("搜索姓名或手机号", "Search name or phone")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingContact = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            OutboundContactEditorSheet(language: language, contact: editingContact) { name, phone in
                saveContact(name: name, phone: phone)
            }
        }
    }

    private var filteredContacts: [OutboundContactBookEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return contacts }
        return contacts.filter { item in
            item.name.localizedCaseInsensitiveContains(keyword)
            || item.phone.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func deleteContacts(at offsets: IndexSet) {
        let targets = offsets.map { filteredContacts[$0] }
        for item in targets {
            modelContext.delete(item)
        }
        do {
            try modelContext.save()
        } catch {
            print("[OutboundContactBook] delete failed: \(error.localizedDescription)")
        }
    }

    private func saveContact(name: String, phone: String) {
        let now = Date()
        if let editingContact {
            editingContact.name = name
            editingContact.phone = phone
            editingContact.updatedAt = now
        } else {
            let entry = OutboundContactBookEntry(
                name: name,
                phone: phone,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(entry)
        }
        do {
            try modelContext.save()
        } catch {
            print("[OutboundContactBook] save failed: \(error.localizedDescription)")
        }
    }
}

struct OutboundContactEditorSheet: View {
    let language: Language
    let contact: OutboundContactBookEntry?
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String
    @State private var phoneText: String

    init(
        language: Language,
        contact: OutboundContactBookEntry?,
        onSave: @escaping (String, String) -> Void
    ) {
        self.language = language
        self.contact = contact
        self.onSave = onSave
        _nameText = State(initialValue: contact?.name ?? "")
        _phoneText = State(initialValue: contact?.phone ?? "")
    }

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var canSave: Bool {
        !nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !phoneText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DS.Spacing.x2) {
                TextField(t("姓名", "Name"), text: $nameText)
                    .textFieldStyle(.roundedBorder)
                TextField(t("手机号", "Phone"), text: $phoneText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.phonePad)
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.x2)
            .background(AppColors.background)
            .navigationTitle(contact == nil ? t("新增联系人", "Add Contact") : t("编辑联系人", "Edit Contact"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(t("取消", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(t("保存", "Save")) {
                        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let phone = phoneText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(name, phone)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

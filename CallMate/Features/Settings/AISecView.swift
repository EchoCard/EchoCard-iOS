//
//  AISecView.swift
//  CallMate
//
//  Global voice chat view (AI Secretary)
//

import SwiftUI
import SwiftData

struct AISecView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let language: Language
    @Query(sort: \CallLog.startedAt, order: .reverse) private var allCalls: [CallLog]
    @Query(sort: \OutboundContactBookEntry.updatedAt, order: .reverse) private var contactBookEntries: [OutboundContactBookEntry]
    @Query(sort: \OutboundPromptTemplate.updatedAt, order: .reverse) private var promptTemplates: [OutboundPromptTemplate]
    @StateObject private var voiceControl = FeedbackVoiceControl()
    @StateObject private var queueService = OutboundTaskQueueService.shared
    @State private var isSoundEnabled = true
    @State private var showOutboundAssistant = false
    @State private var showCreateTaskSheet = false
    @State private var createTaskDraft: OutboundCreateTaskDraft?
    @State private var nextAlertMessage: String?
    @State private var lastOutboundRiskAlertAt: Date?
    @AppStorage("outbound_default_user_name") private var savedDefaultUserName: String = ""
    @AppStorage("outbound_callback_method") private var savedCallbackMethod: String = "current"
    @AppStorage("outbound_custom_callback_phone") private var savedCustomCallbackPhone: String = ""

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    var body: some View {
        NavigationStack {
            ZStack {
                FeedbackChatModalView(
                    language: language,
                    feedbackType: "none",
                    onClose: { },
                    isEmbedded: true,
                    voiceControl: voiceControl,
                    showCloseButton: false,
                    initialMessages: [
                        ExtendedMessage(
                            id: Int.random(in: 10000...99999),
                            sender: .ai,
                            text: language == .zh
                                ? "你好，我是你的专属AI分身。你可以直接让我帮你调整接听策略，也可以让我帮你打电话、订位或做预约。"
                                : "Hi, I'm your AI personal secretary. I can help adjust call rules, place AI calls, book restaurants, or handle reservations.",
                            msgType: .text
                        )
                    ],
                    showInitialMessage: false,
                    initMessagesOverride: [
                        ["role": "user", "content": "你好"],
                        ["role": "assistant", "content": language == .zh
                         ? "你好，我是你的专属AI分身。你可以直接让我帮你调整接听策略，也可以让我帮你打电话、订位或做预约。"
                         : "Hi, I'm your AI personal secretary. I can help adjust call rules, place AI calls, book restaurants, or handle reservations." ]
                    ],
                    autoPlayIntro: false,
                    isSoundEnabled: $isSoundEnabled,
                    messagesPersistenceKey: "callmate.ai_secretary.persisted_messages.v2",
                    onCreateTemplate: { name, content, respond in
                        saveTemplate(name: name, content: content)
                        respond(true)
                    },
                    onInitiateCall: { phone, templateName, respond in
                        guard let resolvedTemplateContent = resolveTemplateContent(name: templateName),
                              !resolvedTemplateContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            respond(
                                false,
                                t(
                                    "未找到本地模板：\(templateName)。请先创建模板，再发起外呼。",
                                    "Local template not found: \(templateName). Please create the template first."
                                )
                            )
                            return
                        }
                        respond(true, nil)
                        createOutboundTask(
                            phone: phone,
                            templateName: templateName,
                            templateContent: resolvedTemplateContent,
                            scheduledAt: nil
                        )
                    },
                    onScheduleCall: { phone, templateName, scheduledAt, timeDescription, respond in
                        guard let resolvedTemplateContent = resolveTemplateContent(name: templateName),
                              !resolvedTemplateContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            respond(
                                false,
                                t(
                                    "未找到本地模板：\(templateName)。请先创建模板，再安排外呼。",
                                    "Local template not found: \(templateName). Please create the template first."
                                )
                            )
                            return
                        }
                        respond(true, nil)
                        createOutboundTask(
                            phone: phone,
                            templateName: templateName,
                            templateContent: resolvedTemplateContent,
                            scheduledAt: scheduledAt
                        )
                    },
                    outboundConfirmationDataProvider: { phone, templateName, scheduledAt, timeDescription in
                        makeOutboundConfirmationData(
                            phone: phone,
                            templateName: templateName,
                            scheduledAt: scheduledAt,
                            timeDescription: timeDescription
                        )
                    }
                )
                .background(Color.clear)
                .opacity(showOutboundAssistant || showCreateTaskSheet ? 0 : 1)
                .allowsHitTesting(!showOutboundAssistant && !showCreateTaskSheet)

                if showOutboundAssistant {
                    OutboundCreateTaskAIView(
                        language: language,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.25)) { showOutboundAssistant = false }
                        },
                        onOpenCreateTask: {
                            guard !showCreateTaskSheet else { return }
                            createTaskDraft = .empty
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showCreateTaskSheet = true
                            }
                        },
                        promptTemplates: promptTemplates,
                        onCreateTemplate: { name, content in
                            saveTemplate(name: name, content: content)
                        },
                        onCallConfirmed: { phone, templateName, templateContent, scheduledAt in
                            createOutboundTask(
                                phone: phone,
                                templateName: templateName,
                                templateContent: templateContent,
                                scheduledAt: scheduledAt
                            )
                        }
                    )
                    .transition(.move(edge: .trailing))
                    .zIndex(10)
                }

                if showCreateTaskSheet {
                    OutboundCreateTaskView(
                        language: language,
                        templates: promptTemplates,
                        existingContacts: existingContacts,
                        initialDraft: createTaskDraft,
                        onOpenAI: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showCreateTaskSheet = false
                                showOutboundAssistant = true
                            }
                        },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.25)) { showCreateTaskSheet = false }
                        },
                        onCreate: { submission in
                            createTask(from: submission)
                        }
                    )
                    .edgeSwipeBack(perform: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { showCreateTaskSheet = false }
                    })
                    .transition(.move(edge: .trailing))
                    .zIndex(11)
                }

            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(t("AI 分身", "AI Avatar"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(t("内容由 AI 生成", "Content generated by AI"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color(lightHex: "9CA3AF", darkHex: "6B7280"))
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSoundEnabled.toggle()
                    } label: {
                        Image(systemName: isSoundEnabled ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color(lightHex: "6B7280", darkHex: "9CA3AF"))
                            .background(Color.clear)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .background {
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: "F6F8FF"), location: 0),
                        .init(color: Color(hex: "F3F5FF"), location: 0.4),
                        .init(color: Color(hex: "F5F4FF"), location: 0.7),
                        .init(color: Color(hex: "F4F7FF"), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [Color(hex: "DCE8FF").opacity(0.5), .clear],
                    center: UnitPoint(x: 0.2, y: 0.1),
                    startRadius: 0,
                    endRadius: 400
                )
                RadialGradient(
                    colors: [Color(hex: "E6E1FA").opacity(0.35), .clear],
                    center: UnitPoint(x: 0.85, y: 0.6),
                    startRadius: 0,
                     endRadius: 350
                )
                RadialGradient(
                    colors: [Color(hex: "D7E6FF").opacity(0.3), .clear],
                    center: UnitPoint(x: 0.4, y: 0.9),
                    startRadius: 0,
                    endRadius: 300
                )
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.25), value: showOutboundAssistant)
        .animation(.easeInOut(duration: 0.25), value: showCreateTaskSheet)
        .alert(t("提示", "Notice"), isPresented: Binding(
            get: { nextAlertMessage != nil },
            set: { if !$0 { nextAlertMessage = nil } }
        )) {
            Button(t("知道了", "OK"), role: .cancel) { nextAlertMessage = nil }
        } message: {
            Text(nextAlertMessage ?? "")
        }
        .onChange(of: queueService.outboundDialBlockedMessage) { _, msg in
            guard let msg, !msg.isEmpty else { return }
            let now = Date()
            if let last = lastOutboundRiskAlertAt, now.timeIntervalSince(last) < 30 {
                queueService.clearOutboundDialBlockedMessage()
                return
            }
            lastOutboundRiskAlertAt = now
            nextAlertMessage = msg
            queueService.clearOutboundDialBlockedMessage()
        }
    }

    private var existingContacts: [OutboundContact] {
        var seen: Set<String> = []
        var result: [OutboundContact] = []
        for entry in contactBookEntries where !entry.phone.isEmpty {
            let phone = entry.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty, !seen.contains(phone) else { continue }
            seen.insert(phone)
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? t("名单联系人", "Address Book Contact")
                : entry.name
            result.append(OutboundContact(phone: phone, name: name))
            if result.count >= 60 { return result }
        }
        for call in allCalls where !call.phone.isEmpty && !call.isSimulation {
            let phone = call.phone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty, !seen.contains(phone) else { continue }
            seen.insert(phone)
            let name = call.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? t("历史号码", "History Contact")
                : call.label
            result.append(OutboundContact(phone: phone, name: name))
            if result.count >= 30 { break }
        }
        return result
    }

    private func normalizedTemplateKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noWhitespace = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)
        return noWhitespace.components(separatedBy: punctuationAndSymbols).joined()
    }

    private func resolveTemplateContent(name: String) -> String? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        var content: String?

        if let exact = promptTemplates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            content = exact.content
        } else if let ciExact = promptTemplates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(target) == .orderedSame
        }) {
            content = ciExact.content
        } else {
            let normalizedTarget = normalizedTemplateKey(target)
            if let normalizedExact = promptTemplates.first(where: {
                normalizedTemplateKey($0.name) == normalizedTarget
            }) {
                content = normalizedExact.content
            } else {
                let fuzzyCandidates = promptTemplates.filter {
                    let key = normalizedTemplateKey($0.name)
                    return !key.isEmpty && (key.contains(normalizedTarget) || normalizedTarget.contains(key))
                }
                if fuzzyCandidates.count == 1, let only = fuzzyCandidates.first {
                    content = only.content
                }
            }
        }

        guard let resolved = content else { return nil }
        return injectIdentityDefaults(into: resolved)
    }

    private func injectIdentityDefaults(into content: String) -> String {
        let userName = savedDefaultUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        let callbackPhone: String
        if savedCallbackMethod == "custom" && !savedCustomCallbackPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            callbackPhone = savedCustomCallbackPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            callbackPhone = "当前拨打号码"
        }

        guard !userName.isEmpty || callbackPhone != "当前拨打号码" else { return content }

        var result = content
        if !userName.isEmpty {
            result = result.replacingOccurrences(
                of: #""key":"user_name","label":"本次称呼","type":"string","require_fresh_input":false,"default_value":"""#,
                with: #""key":"user_name","label":"本次称呼","type":"string","require_fresh_input":false,"default_value":"\#(userName)""#
            )
            result = result.replacingOccurrences(
                of: #""key": "user_name", "label": "本次称呼", "type": "string", "require_fresh_input": false, "default_value": """#,
                with: #""key": "user_name", "label": "本次称呼", "type": "string", "require_fresh_input": false, "default_value": "\#(userName)""#
            )
        }
        if callbackPhone != "当前拨打号码" {
            result = result.replacingOccurrences(
                of: #""key":"callback_phone","label":"预留电话","type":"phone","require_fresh_input":false,"default_value":"""#,
                with: #""key":"callback_phone","label":"预留电话","type":"phone","require_fresh_input":false,"default_value":"\#(callbackPhone)""#
            )
            result = result.replacingOccurrences(
                of: #""key": "callback_phone", "label": "预留电话", "type": "phone", "require_fresh_input": false, "default_value": """#,
                with: #""key": "callback_phone", "label": "预留电话", "type": "phone", "require_fresh_input": false, "default_value": "\#(callbackPhone)""#
            )
        }
        return result
    }

    private func makeOutboundConfirmationData(
        phone: String,
        templateName: String,
        scheduledAt: Date?,
        timeDescription: String?
    ) -> OutboundConfirmationData {
        let templateContent = resolveTemplateContent(name: templateName) ?? ""
        let sections = parseOutboundTemplateSections(templateContent)
        return OutboundConfirmationData(
            phone: phone,
            contactName: resolveOutboundContactName(phone: phone, fallback: templateName),
            goal: sections.goal,
            keyPoints: sections.points,
            templateName: templateName,
            scheduledAt: scheduledAt,
            timeDescription: timeDescription
        )
    }

    private func resolveOutboundContactName(phone: String, fallback: String) -> String {
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry = contactBookEntries.first(where: {
            $0.phone.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPhone &&
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return entry.name
        }
        if let call = allCalls.first(where: {
            $0.phone.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPhone &&
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return call.label
        }
        return fallback
    }

    private func parseOutboundTemplateSections(_ text: String) -> (goal: String?, points: String?) {
        let remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return (nil, nil) }

        // Extract key→label mapping from frontend_schema JSON (if present in template content)
        let labelMapping = extractVariableLabelMapping(from: remaining)

        // Try new #### Title #### format first (Phase 6 JIT-compiled call rules)
        let hashSections = parseHashHeaderSections(remaining)
        if !hashSections.isEmpty {
            let goalRaw = hashSections["任务目标设定"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let goal: String? = goalRaw.isEmpty ? nil : goalRaw
            let bgRaw = hashSections["背景信息"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pointsRaw = extractBackgroundInfoLines(from: bgRaw, labelMapping: labelMapping) ?? ""
            let points: String? = pointsRaw.isEmpty ? nil : pointsRaw
            if goal != nil || points != nil {
                return (goal, points)
            }
        }

        // Fall back to old "处理目标：" colon-delimited format
        let sectionTitles = ["处理目标", "处理要点", "处理原则", "处理策略", "处理步骤", "示例"]

        func findMarker(_ title: String) -> Range<String.Index>? {
            if let range = remaining.range(of: title + "：") { return range }
            if let range = remaining.range(of: title + ":") { return range }
            return nil
        }

        func extractContent(for title: String) -> String? {
            guard let range = findMarker(title) else { return nil }
            let start = range.upperBound
            var end = remaining.endIndex
            for other in sectionTitles where other != title {
                if let otherRange = findMarker(other),
                   otherRange.lowerBound > range.lowerBound,
                   otherRange.lowerBound < end {
                    end = otherRange.lowerBound
                }
            }
            let content = String(remaining[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        }

        let goal = extractContent(for: "处理目标")
        let points = extractContent(for: "处理要点")
            ?? extractContent(for: "处理原则")
            ?? extractContent(for: "处理策略")
            ?? extractContent(for: "处理步骤")

        if goal == nil && points == nil {
            return (templateNameFallback(from: remaining), remaining)
        }
        return (goal, points)
    }

    /// Parses `#### Title ####` style sections into a dictionary keyed by title.
    private func parseHashHeaderSections(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = "####\\s*(.+?)\\s*####"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for (i, match) in matches.enumerated() {
            guard let titleRange = Range(match.range(at: 1), in: text) else { continue }
            let title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let contentStart = match.range.upperBound
            let contentEnd = i + 1 < matches.count ? matches[i + 1].range.lowerBound : nsText.length
            guard contentStart <= contentEnd,
                  let range = Range(NSRange(location: contentStart, length: contentEnd - contentStart), in: text) else { continue }
            let content = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[title] = content
        }
        return result
    }

    /// Extracts variable name→label pairs from JSON schema embedded in template content.
    /// Uses JSON parsing for reliability; falls back to regex if JSON parsing fails.
    private func extractVariableLabelMapping(from templateContent: String) -> [String: String] {
        var mapping: [String: String] = [:]

        if let jsonStr = extractLeadingJSON(from: templateContent),
           let data = jsonStr.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["routing_variables", "business_variables"] {
                if let vars = root[key] as? [[String: Any]] {
                    for v in vars {
                        if let name = v["name"] as? String ?? v["key"] as? String,
                           let label = v["description"] as? String ?? v["label"] as? String,
                           !name.isEmpty, !label.isEmpty {
                            mapping[name] = label
                        }
                    }
                }
            }
        }

        if mapping.isEmpty {
            let pattern = #""(?:name|key)"\s*:\s*"([^"]+)"[^}]*"(?:description|label)"\s*:\s*"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsText = templateContent as NSString
                for match in regex.matches(in: templateContent, range: NSRange(location: 0, length: nsText.length)) {
                    guard let keyRange = Range(match.range(at: 1), in: templateContent),
                          let labelRange = Range(match.range(at: 2), in: templateContent) else { continue }
                    let key = String(templateContent[keyRange])
                    if mapping[key] == nil {
                        mapping[key] = String(templateContent[labelRange])
                    }
                }
            }
        }

        return mapping
    }

    /// Finds the first top-level JSON object `{...}` at the beginning of the template content.
    private func extractLeadingJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        var depth = 0
        for (i, ch) in trimmed.enumerated() {
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1 }
            if depth == 0 {
                return String(trimmed.prefix(i + 1))
            }
        }
        return nil
    }

    /// Parses `&{key} = value` lines from the 背景信息 section.
    /// Excludes target_phone / target_name (already shown in the card header).
    /// Applies consistent display label overrides for user-facing display.
    private func extractBackgroundInfoLines(from text: String?, labelMapping: [String: String] = [:]) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let excluded: Set<String> = ["target_phone", "target_name"]

        let keyLabelOverrides: [String: String] = [
            "callback_phone": "预留电话",
            "user_name": "本次称呼",
            "booking_time": "预订时间",
            "party_size": "人数",
            "seat_preference": "席位偏好",
            "fallback_strategy": "应答策略",
            "task_goal": "电话内容",
            "task_message": "电话内容",
            "task_question": "咨询内容",
            "constraint": "约束条件",
            "priority_rule": "优先规则",
            "negotiation_floor": "谈判底线",
        ]

        let textLabelOverrides: [String: String] = [
            "打给谁": "", "餐厅名称": "", "目标商家": "", "联系人": "", "对方接听号码": "",
            "用户回电号码": "预留电话", "接收回电的真实号码": "预留电话", "用户回电号码（留给对方，不是拨出号码）": "预留电话",
            "用户称呼": "本次称呼",
            "本次业务信息": "电话内容",
            "策略底线": "应答策略",
        ]

        let lines = text
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("&{"),
                      let closeBrace = trimmed.firstIndex(of: "}"),
                      let eqRange = trimmed.range(of: " = ") else { return nil }
                let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBrace])
                guard !excluded.contains(key) else { return nil }
                let value = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }

                if key == "callback_phone" {
                    let normalized = value.replacingOccurrences(of: " ", with: "")
                    if normalized == "当前拨打号码" || normalized == "当前号码" || normalized == "现在这个号码" { return nil }
                }

                var label = keyLabelOverrides[key] ?? labelMapping[key] ?? key
                if let override = textLabelOverrides[label] {
                    if override.isEmpty { return nil }
                    label = override
                }
                return "\(label)：\(value)"
            }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func templateNameFallback(from content: String) -> String? {
        let firstLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return firstLine
    }

    private func saveTemplate(name: String, content: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !normalizedContent.isEmpty else { return }

        let now = Date()
        if let existing = promptTemplates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName
        }) {
            existing.content = normalizedContent
            existing.updatedAt = now
        } else {
            let template = OutboundPromptTemplate(
                name: normalizedName,
                content: normalizedContent,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(template)
        }

        do {
            try modelContext.save()
        } catch {
            nextAlertMessage = t("保存话术失败", "Failed to save prompt template")
        }

        extractAndSaveIdentityDefaults(from: normalizedContent)
    }

    private func extractAndSaveIdentityDefaults(from content: String) {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("&{"),
                  let closeBrace = trimmed.firstIndex(of: "}"),
                  let eqRange = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBrace])
            let value = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            if key == "user_name" {
                savedDefaultUserName = value
            } else if key == "callback_phone" {
                let normalized = value.replacingOccurrences(of: " ", with: "")
                if normalized == "当前拨打号码" || normalized == "当前号码" || normalized == "现在这个号码" {
                    savedCallbackMethod = "current"
                    savedCustomCallbackPhone = ""
                } else {
                    savedCallbackMethod = "custom"
                    savedCustomCallbackPhone = value
                }
            }
        }
    }

    private func createOutboundTask(
        phone: String,
        templateName: String,
        templateContent: String,
        scheduledAt: Date?
    ) {
        let contact = OutboundContact(phone: phone, name: templateName)
        guard queueService.createTask(
            promptType: templateName,
            prompt: templateContent,
            contacts: [contact],
            scheduledAt: scheduledAt
        ) != nil else {
            nextAlertMessage = t("创建外呼任务失败", "Failed to create outbound task")
            return
        }
    }

    private func createTask(from submission: OutboundCreateTaskSubmission) {
        guard queueService.createTask(
            promptType: submission.promptName,
            prompt: submission.promptContent,
            contacts: submission.contacts,
            scheduledAt: submission.scheduledAt,
            callFrequency: submission.callFrequency,
            redialMissed: submission.redialMissed
        ) != nil else {
            nextAlertMessage = t("创建任务失败", "Failed to create task")
            return
        }
        showCreateTaskSheet = false
    }
}

#Preview {
    AISecView(language: .zh)
}

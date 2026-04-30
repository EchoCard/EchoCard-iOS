//
//  OutboundTemplateStore.swift
//  CallMate
//
//  Encapsulates SwiftData reads/writes for `OutboundPromptTemplate`,
//  exposing the manifest / load / save surface required by the
//  update_config v1 protocol (`templateManifest`, `load_template`,
//  `create_template`).
//

import Foundation
import SwiftData

enum OutboundTemplateLookup {
    case hit(name: String, taskType: String, content: String)
    case ambiguous(matches: [String])
    case miss
}

enum OutboundTemplateStore {
    /// Parses `business_variables` from the JSON object that prefixes the first `#### ` section (plan §3.3).
    static func parseBusinessVariables(from templateContent: String) -> [String: String] {
        guard let sectionRange = templateContent.range(of: "#### ") else { return [:] }
        let header = String(templateContent[..<sectionRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard header.hasPrefix("{"), let data = header.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bv = obj["business_variables"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in bv {
            switch value {
            case let s as String:
                out[key] = s
            case let n as NSNumber:
                out[key] = n.stringValue
            case is NSNull:
                out[key] = ""
            default:
                if let sub = try? JSONSerialization.data(withJSONObject: value),
                   let str = String(data: sub, encoding: .utf8) {
                    out[key] = str
                }
            }
        }
        return out
    }

    /// Extract the business-rules body from a full template (JSON schema header + `####` sections).
    ///
    /// - Returns: `nil` when there is no `#### ` markdown section (invalid template for call_outbound).
    /// - Substitutes `&{key}` using `businessVariables` (merge with `parseBusinessVariables` for full §3.3 behavior).
    static func extractBusinessPrompt(
        from templateContent: String,
        businessVariables: [String: String]? = nil
    ) -> String? {
        guard let sectionRange = templateContent.range(of: "#### ") else { return nil }
        var body = String(templateContent[sectionRange.lowerBound...])
        if let vars = businessVariables {
            for (key, value) in vars {
                body = body.replacingOccurrences(of: "&{\(key)}", with: value)
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : body
    }

    /// 旧版外呼任务正文可能没有 `#### ` 章节；此前客户端会把**整段**当作业务正文发给服务端。
    /// `call_outbound` 仍要求 `template_vars.business_prompt`，缺省会直接导致无 TTS / 无下行音频。
    static func legacyBusinessPromptFallback(
        from templateContent: String,
        businessVariables: [String: String]
    ) -> String {
        var body = templateContent.trimmingCharacters(in: .whitespacesAndNewlines)
        for (key, value) in businessVariables {
            body = body.replacingOccurrences(of: "&{\(key)}", with: value)
        }
        return body
    }

    /// Returns one element per persisted template. Element keys match v1 spec:
    /// `name`, `task_type`, `updated_at` (ISO8601 date).
    @MainActor
    static func getManifest() -> [[String: String]] {
        let templates = fetchAllTemplates()
        let formatter = isoDateFormatter()
        return templates.map { template in
            return [
                "name": template.name.trimmingCharacters(in: .whitespacesAndNewlines),
                "task_type": inferTaskType(from: template.content),
                "updated_at": formatter.string(from: template.updatedAt)
            ]
        }
    }

    /// Look up the full content of a template.
    /// Resolution order:
    /// 1. Exact match (after trim).
    /// 2. Case-insensitive exact match.
    /// 3. Punctuation/whitespace-stripped exact match.
    /// 4. LIKE-style fuzzy substring match (either direction).
    ///    - Single hit → `.hit`
    ///    - Multiple hits → `.ambiguous(matches: [name, ...])`
    ///    - No hit → `.miss`
    @MainActor
    static func lookup(name: String) -> OutboundTemplateLookup {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return .miss }
        let templates = fetchAllTemplates()
        if templates.isEmpty { return .miss }

        if let exact = templates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            return makeHit(exact)
        }
        if let ciExact = templates.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(target) == .orderedSame
        }) {
            return makeHit(ciExact)
        }
        let normalizedTarget = normalizedKey(target)
        if !normalizedTarget.isEmpty,
           let normExact = templates.first(where: { normalizedKey($0.name) == normalizedTarget }) {
            return makeHit(normExact)
        }
        let fuzzy = templates.filter {
            let key = normalizedKey($0.name)
            return !key.isEmpty
                && (key.contains(normalizedTarget) || normalizedTarget.contains(key))
        }
        if fuzzy.count == 1, let only = fuzzy.first {
            return makeHit(only)
        }
        if fuzzy.count > 1 {
            return .ambiguous(matches: fuzzy.map {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        }
        return .miss
    }

    /// Save (insert or overwrite by name). Returns `(success, ISO8601 updatedAt)`.
    /// Same name → silent overwrite (per v1 spec §3.5).
    @MainActor
    @discardableResult
    static func save(name: String, content: String) -> (success: Bool, updatedAt: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !normalizedContent.isEmpty else {
            return (false, "")
        }
        let context = CallMateApp.sharedModelContainer.mainContext
        let now = Date()
        if let existing = fetchAllTemplates().first(where: {
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
            context.insert(template)
        }
        do {
            try context.save()
        } catch {
            print("[OutboundTemplateStore] save failed: \(error)")
            return (false, "")
        }
        return (true, isoDateFormatter().string(from: now))
    }

    // MARK: - Private

    @MainActor
    private static func fetchAllTemplates() -> [OutboundPromptTemplate] {
        let context = CallMateApp.sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<OutboundPromptTemplate>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func makeHit(_ template: OutboundPromptTemplate) -> OutboundTemplateLookup {
        return .hit(
            name: template.name.trimmingCharacters(in: .whitespacesAndNewlines),
            taskType: inferTaskType(from: template.content),
            content: template.content
        )
    }

    private static func normalizedKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noWhitespace = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)
        return noWhitespace.components(separatedBy: punctuationAndSymbols).joined()
    }

    /// Templates persist `task_type` inside the JSON schema header that prefixes
    /// the content body. We sniff it directly so we don't need a SwiftData
    /// migration for this v1 cycle.
    private static func inferTaskType(from content: String) -> String {
        let allowed: Set<String> = [
            "Booking", "Consultation", "Notification",
            "Negotiation", "Collection", "General"
        ]
        // Look for `"task_type": "X"` (allow optional whitespace and either quote style).
        let pattern = #""task_type"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(
               in: content,
               options: [],
               range: NSRange(content.startIndex..., in: content)
           ),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: content) {
            let raw = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip "X | Y | Z" enum docstrings (template-text artefact).
            let firstToken = raw.split(separator: "|").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? raw
            if allowed.contains(firstToken) {
                return firstToken
            }
        }
        return "General"
    }

    private static func isoDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

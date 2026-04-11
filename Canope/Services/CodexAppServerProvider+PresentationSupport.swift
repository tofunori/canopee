import Foundation

extension CodexAppServerProvider {
    nonisolated static func commandExecutionSummary(_ item: [String: Any]) -> String {
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = (item["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command, !command.isEmpty, let cwd, !cwd.isEmpty {
            return "\(command) · \(cwd)"
        }
        if let command, !command.isEmpty {
            return command
        }
        return "Command in progress"
    }

    nonisolated static func fileChangeSummary(_ item: [String: Any]) -> String {
        if let changes = item["changes"] as? [[String: Any]], !changes.isEmpty {
            let firstPath = (changes.first?["path"] as? String) ?? (changes.first?["newPath"] as? String)
            if let firstPath, !firstPath.isEmpty {
                return "Modification proposee · \((firstPath as NSString).lastPathComponent)"
            }
            return "Modification proposee · \(changes.count) fichier(s)"
        }
        return "Modification proposee"
    }

    nonisolated static func completedCommandExecutionSummary(_ item: [String: Any], bufferedOutput: String?) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command"
        let exitCode = jsonInt(item["exitCode"])
        let output = ((item["aggregatedOutput"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            ?? (bufferedOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        let statusLabel: String
        switch status {
        case "declined":
            statusLabel = AppStrings.commandDeclined
        case "failed":
            statusLabel = AppStrings.commandFailed
        default:
            statusLabel = AppStrings.commandCompleted
        }
        let suffix = exitCode.map { " (code \($0))" } ?? ""
        if let output {
            return "\(statusLabel)\(suffix) · \(command)\n\(output)"
        }
        return "\(statusLabel)\(suffix) · \(command)"
    }

    nonisolated static func completedFileChangeSummary(_ item: [String: Any], bufferedOutput: String?) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let base = fileChangeSummary(item)
        let output = (bufferedOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        switch status {
        case "declined":
            return "\(base) \(AppStrings.changeDeclined)"
        case "failed":
            if let output, !output.isEmpty {
                return "\(base) \(AppStrings.changeNotApplied)"
            }
            return "\(base) \(AppStrings.changeNotApplied)"
        default:
            if let output {
                return "\(base) \(AppStrings.changeApplied)\n\(output)"
            }
            return "\(base) \(AppStrings.changeApplied)"
        }
    }

    nonisolated static func completedDynamicToolCallSummary(_ item: [String: Any]) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let text = extractText(fromContentItems: item["contentItems"] as? [[String: Any]])
        switch status {
        case "failed":
            return text ?? AppStrings.toolCallFailed
        default:
            return text ?? AppStrings.toolCallCompleted
        }
    }

    nonisolated static func dynamicToolCallSummary(_ item: [String: Any]) -> String {
        if let tool = (item["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
            if let argsPreview = compactKeyValuePreview(
                from: item["arguments"] as? [String: Any],
                preferredKeys: ["path", "filePath", "query", "url", "cwd", "pattern"],
                maxLines: 1
            ) {
                return "Dynamic call · \(tool) · \(argsPreview.replacingOccurrences(of: "\n", with: " · "))"
            }
            return "Dynamic call · \(tool)"
        }
        return "Dynamic tool call"
    }

    nonisolated static func dynamicToolCallInputPreview(_ item: [String: Any]) -> String? {
        compactKeyValuePreview(
            from: item["arguments"] as? [String: Any],
            preferredKeys: ["path", "filePath", "query", "url", "cwd", "pattern", "command", "text"],
            maxLines: 5
        )
    }

    nonisolated static func webSearchSummary(_ item: [String: Any]) -> String {
        let query = (item["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (item["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let query, !query.isEmpty, let action {
            return "Recherche web · \(query) · \(action)"
        }
        if let query, !query.isEmpty {
            return "Recherche web · \(query)"
        }
        return "Recherche web"
    }

    nonisolated static func webSearchInputPreview(_ item: [String: Any]) -> String? {
        var lines: [String] = []
        if let query = (item["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            lines.append("query: \(query)")
        }
        if let action = (item["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            lines.append("action: \(action)")
        }
        if let domains = item["allowedDomains"] as? [String], !domains.isEmpty {
            lines.append("domains: \(domains.prefix(3).joined(separator: ", "))")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    nonisolated static func completedWebSearchSummary(_ item: [String: Any]) -> String? {
        let base = webSearchSummary(item)
        if let action = (item["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return "\(base)\nAction: \(action)"
        }
        return base
    }

    nonisolated static func imageViewSummary(_ item: [String: Any]) -> String {
        if let path = (item["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return "Image ouverte · \((path as NSString).lastPathComponent)"
        }
        return "Image ouverte"
    }

    nonisolated static func completedImageViewSummary(_ item: [String: Any]) -> String? {
        imageViewSummary(item)
    }

    nonisolated static func collabAgentToolCallSummary(_ item: [String: Any]) -> String {
        let tool = (item["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = (item["senderThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (item["targetThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tool, !tool.isEmpty, let sender, !sender.isEmpty, let target, !target.isEmpty {
            return "Collab agent · \(tool) · \(sender.prefix(6)) → \(target.prefix(6))"
        }
        if let tool, !tool.isEmpty, let sender, !sender.isEmpty {
            return "Collab agent · \(tool) · \(sender.prefix(8))"
        }
        if let tool, !tool.isEmpty {
            return "Collab agent · \(tool)"
        }
        return "Collab agent"
    }

    nonisolated static func collabAgentToolCallInputPreview(_ item: [String: Any]) -> String? {
        var lines: [String] = []
        if let sender = (item["senderThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            lines.append("sender: \(sender)")
        }
        if let target = (item["targetThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            lines.append("target: \(target)")
        }
        if let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            lines.append("status: \(status)")
        }
        if let argumentsPreview = compactKeyValuePreview(
            from: item["arguments"] as? [String: Any],
            preferredKeys: ["path", "query", "url", "cwd"],
            maxLines: 2
        ), !argumentsPreview.isEmpty {
            lines.append(argumentsPreview)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    nonisolated static func completedCollabAgentToolCallSummary(_ item: [String: Any]) -> String? {
        let base = collabAgentToolCallSummary(item)
        if let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return "\(base)\nStatut: \(status)"
        }
        return base
    }

    nonisolated static func compactKeyValuePreview(
        from dictionary: [String: Any]?,
        preferredKeys: [String],
        maxLines: Int
    ) -> String? {
        guard let dictionary, !dictionary.isEmpty else { return nil }

        var orderedKeys: [String] = []
        for key in preferredKeys where dictionary[key] != nil {
            orderedKeys.append(key)
        }
        for key in dictionary.keys.sorted() where !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }

        var lines: [String] = []
        for key in orderedKeys {
            guard let value = dictionary[key],
                  let previewValue = compactPreviewValue(value),
                  !previewValue.isEmpty
            else { continue }
            lines.append("\(key): \(previewValue)")
            if lines.count >= maxLines { break }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    nonisolated static func compactPreviewValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case let number as NSNumber:
            return number.stringValue
        case let array as [String]:
            let trimmed = array
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !trimmed.isEmpty else { return nil }
            let prefix = trimmed.prefix(3).joined(separator: ", ")
            return trimmed.count > 3 ? "\(prefix), …" : prefix
        case let array as [Any]:
            let values = array.compactMap { compactPreviewValue($0) }
            guard !values.isEmpty else { return nil }
            let prefix = values.prefix(3).joined(separator: ", ")
            return values.count > 3 ? "\(prefix), …" : prefix
        case let nested as [String: Any]:
            return compactKeyValuePreview(from: nested, preferredKeys: Array(nested.keys.sorted()), maxLines: 1)?
                .replacingOccurrences(of: "\n", with: " · ")
        default:
            return nil
        }
    }

    static func derivedStatusBadges(
        forServerRequestMethod method: String,
        disposition: ServerRequestDisposition
    ) -> (auth: ChatStatusBadge?, mcp: ChatStatusBadge?, review: ChatStatusBadge?) {
        switch method {
        case "account/chatgptAuthTokens/refresh":
            return (ChatStatusBadge(kind: .authRequired, text: "ChatGPT login"), nil, nil)
        case "mcpServer/oauth/login":
            return (ChatStatusBadge(kind: .authRequired, text: "Login MCP"), ChatStatusBadge(kind: .mcpWarning, text: "MCP login"), nil)
        case "config/mcpServer/reload":
            let kind: ChatStatusBadgeKind = disposition == .unsupported || disposition == .reject ? .mcpWarning : .mcpOkay
            let text = disposition == .unsupported || disposition == .reject ? "MCP reload" : "MCP recharge"
            return (nil, ChatStatusBadge(kind: kind, text: text), nil)
        case "mcpServerStatus/list":
            let kind: ChatStatusBadgeKind = disposition == .unsupported || disposition == .reject ? .mcpWarning : .mcpOkay
            return (nil, ChatStatusBadge(kind: kind, text: kind == .mcpOkay ? "MCP status" : "MCP attention"), nil)
        case let value where value.hasPrefix("mcpServer/"):
            let kind: ChatStatusBadgeKind = disposition == .unsupported || disposition == .reject ? .mcpWarning : .mcpOkay
            return (nil, ChatStatusBadge(kind: kind, text: kind == .mcpOkay ? "MCP OK" : "MCP attention"), nil)
        default:
            return (nil, nil, nil)
        }
    }

    static func derivedStatusBadges(
        forErrorText text: String
    ) -> (auth: ChatStatusBadge?, mcp: ChatStatusBadge?, review: ChatStatusBadge?) {
        let lower = text.lowercased()
        let auth: ChatStatusBadge?
        if lower.contains("chatgpt") && (lower.contains("auth") || lower.contains("token") || lower.contains("login")) {
            auth = ChatStatusBadge(kind: .authRequired, text: "ChatGPT login")
        } else if lower.contains("oauth") || lower.contains("login") || lower.contains("auth") || lower.contains("token") {
            auth = ChatStatusBadge(kind: .authRequired, text: "Auth requise")
        } else {
            auth = nil
        }

        let mcp: ChatStatusBadge?
        if lower.contains("mcp") && lower.contains("reload") {
            mcp = ChatStatusBadge(kind: .mcpWarning, text: "MCP reload")
        } else if lower.contains("mcp") && (lower.contains("transport") || lower.contains("broken pipe") || lower.contains("connection reset")) {
            mcp = ChatStatusBadge(kind: .mcpWarning, text: "MCP transport")
        } else if lower.contains("mcp") {
            mcp = ChatStatusBadge(kind: .mcpWarning, text: "MCP attention")
        } else {
            mcp = nil
        }

        let review: ChatStatusBadge?
        if lower.contains("review") {
            review = ChatStatusBadge(kind: .reviewAttention, text: "Review attention")
        } else {
            review = nil
        }

        return (auth, mcp, review)
    }

    static func statusActions(for badge: ChatStatusBadge) -> [ChatStatusAction] {
        switch badge.kind {
        case .authRequired:
            if badge.text == "ChatGPT login" {
                return [
                    ChatStatusAction(
                        id: "chatgptAuthRefresh",
                        label: "Rafraichir l'auth ChatGPT",
                        systemImage: "arrow.clockwise"
                    ),
                ]
            }
            return [
                ChatStatusAction(
                    id: "mcpOAuthLogin",
                    label: "Relancer le login MCP",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                ),
                ChatStatusAction(
                    id: "mcpStatusList",
                    label: "Verifier l'etat MCP",
                    systemImage: "server.rack"
                ),
            ]
        case .mcpOkay:
            return [
                ChatStatusAction(
                    id: "mcpStatusList",
                    label: "Verifier l'etat MCP",
                    systemImage: "server.rack"
                ),
                ChatStatusAction(
                    id: "mcpReload",
                    label: "Recharger la config MCP",
                    systemImage: "arrow.triangle.2.circlepath"
                ),
            ]
        case .mcpWarning:
            return [
                ChatStatusAction(
                    id: "mcpReload",
                    label: "Recharger la config MCP",
                    systemImage: "arrow.triangle.2.circlepath"
                ),
                ChatStatusAction(
                    id: "mcpStatusList",
                    label: "Verifier l'etat MCP",
                    systemImage: "server.rack"
                ),
            ]
        default:
            return []
        }
    }

    nonisolated static func reviewStateDescription(_ item: [String: Any]) -> String {
        let review = (item["review"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let review, !review.isEmpty {
            return "Review actif · \(review)"
        }
        return "Review actif"
    }

    func appendExitedReviewModeMessages(_ item: [String: Any]) {
        guard let rendered = (item["review"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rendered.isEmpty
        else {
            return
        }

        let parsed = Self.parseReviewOutput(rendered)
        if let summary = parsed.summary, !summary.isEmpty {
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: summary,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
            )
        }

        for finding in parsed.findings {
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: finding.body,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false,
                    presentationKind: .reviewFinding,
                    reviewFinding: finding
                )
            )
        }
    }

    nonisolated static func parseReviewOutput(_ rendered: String) -> (summary: String?, findings: [ChatReviewFinding]) {
        let normalized = rendered
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return (nil, []) }

        let lines = normalized.components(separatedBy: "\n")
        let findingStarts = lines.indices.filter { index in
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("[P") && line.contains("]")
        }

        guard let firstStart = findingStarts.first else {
            return (normalized, [])
        }

        let prefix = lines[..<firstStart]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = prefix
            .replacingOccurrences(of: "Review Findings:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var findings: [ChatReviewFinding] = []
        for (offset, start) in findingStarts.enumerated() {
            let end = offset + 1 < findingStarts.count ? findingStarts[offset + 1] : lines.count
            let block = Array(lines[start..<end])
            guard let finding = parseRenderedReviewFinding(block) else { continue }
            findings.append(finding)
        }
        return (summary, findings)
    }

    nonisolated static func parseRenderedReviewFinding(_ blockLines: [String]) -> ChatReviewFinding? {
        guard let firstLineRaw = blockLines.first else { return nil }
        let firstLine = firstLineRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty else { return nil }

        let titleRegex = try? NSRegularExpression(pattern: #"^\[P([0-3])\]\s*(.+)$"#)
        let nsTitle = firstLine as NSString
        let titleRange = NSRange(location: 0, length: nsTitle.length)
        let titleMatch = titleRegex?.firstMatch(in: firstLine, range: titleRange)

        let priority = titleMatch.flatMap { match -> Int? in
            guard match.numberOfRanges > 1 else { return nil }
            return Int(nsTitle.substring(with: match.range(at: 1)))
        }
        let title = titleMatch.map { match -> String in
            guard match.numberOfRanges > 2 else { return firstLine }
            return nsTitle.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? firstLine

        var bodyLines: [String] = []
        var filePath: String?
        var lineStart: Int?
        var lineEnd: Int?
        var confidenceScore: Double?

        for rawLine in blockLines.dropFirst() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Location:") {
                let location = String(trimmed.dropFirst("Location:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = parseReviewLocation(location)
                filePath = parsed.path
                lineStart = parsed.start
                lineEnd = parsed.end
                continue
            }
            if trimmed.lowercased().hasPrefix("confidence:") {
                let raw = String(trimmed.dropFirst("Confidence:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                confidenceScore = Double(raw)
                continue
            }
            bodyLines.append(rawLine)
        }

        let body = bodyLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ChatReviewFinding(
            title: title,
            body: body.isEmpty ? title : body,
            filePath: filePath,
            lineStart: lineStart,
            lineEnd: lineEnd,
            priority: priority,
            confidenceScore: confidenceScore
        )
    }

    nonisolated static func parseReviewLocation(_ location: String) -> (path: String?, start: Int?, end: Int?) {
        let regex = try? NSRegularExpression(pattern: #"^(.*?):(\d+)(?:-(\d+))?$"#)
        let nsLocation = location as NSString
        let range = NSRange(location: 0, length: nsLocation.length)
        guard let match = regex?.firstMatch(in: location, range: range), match.numberOfRanges >= 3 else {
            return (location.nilIfEmpty, nil, nil)
        }

        let path = nsLocation.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Int(nsLocation.substring(with: match.range(at: 2)))
        let end: Int? = {
            guard match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound else { return nil }
            return Int(nsLocation.substring(with: match.range(at: 3)))
        }()
        return (path.nilIfEmpty, start, end)
    }

    nonisolated static func extractText(fromContentItems items: [[String: Any]]?) -> String? {
        items?
            .compactMap { item in
                if let text = item["text"] as? String { return text }
                if let text = item["content"] as? String { return text }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func renderPlanText(plan: [[String: Any]], explanation: String?) -> String {
        var lines: [String] = []
        if let explanation, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Objectif")
            lines.append(explanation)
            lines.append("")
        }
        lines.append("Plan")
        for (index, step) in plan.enumerated() {
            let status = (step["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (step["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Etape \(index + 1)"
            if let status, !status.isEmpty {
                lines.append("\(index + 1). [\(status)] \(text)")
            } else {
                lines.append("\(index + 1). \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func badgeFromMCPStatusResult(_ result: Any?) -> ChatStatusBadge {
        guard let result else {
            return ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")
        }

        let statusStrings = collectLowercasedStatusStrings(from: result)
        if statusStrings.contains(where: { $0.contains("error") || $0.contains("failed") || $0.contains("disconnected") }) {
            return ChatStatusBadge(kind: .mcpWarning, text: "MCP attention")
        }
        if statusStrings.contains(where: { $0.contains("auth") || $0.contains("login") || $0.contains("oauth") }) {
            return ChatStatusBadge(kind: .mcpWarning, text: "MCP login")
        }
        return ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")
    }

    static func collectLowercasedStatusStrings(from value: Any) -> [String] {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed.lowercased()]
        case let dict as [String: Any]:
            return dict.values.flatMap { collectLowercasedStatusStrings(from: $0) }
        case let array as [Any]:
            return array.flatMap { collectLowercasedStatusStrings(from: $0) }
        default:
            return []
        }
    }
}

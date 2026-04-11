import Foundation

enum CodexSessionPersistence {
    static func ephemeralThreadList(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] {
        final class Box: @unchecked Sendable {
            var rows: [ChatSessionListItem] = []
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task {
            box.rows = await CodexThreadCoordinator.ephemeralThreadListAsync(
                limit: limit,
                matchingDirectory: matchingDirectory
            )
            sem.signal()
        }
        sem.wait()
        return box.rows
    }

    static func renameChatSession(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            try? await CodexThreadCoordinator.ephemeralRename(threadId: id, name: trimmed)
        }
    }

    static func sanitizeAssistantDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let paragraphs = trimmed.components(separatedBy: "\n\n")
        let filtered = paragraphs.filter { paragraph in
            let normalized = paragraph.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale.current
            )
            if normalized.contains("l'edition directe a echoue") { return false }
            if normalized.contains("the direct edit failed") { return false }
            if normalized.contains("direct edit failed") { return false }
            if normalized.contains("i couldn't find the exact text") { return false }
            if normalized.contains("je n'ai pas trouve le texte exact") { return false }
            if normalized.contains("le texte exact") && normalized.contains("pas ete retrouve") { return false }
            if normalized.contains("exact text") && normalized.contains("not found") { return false }
            return true
        }

        guard !filtered.isEmpty else { return "" }
        return filtered.joined(separator: "\n\n")
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

    static func historySnapshot(fromThreadReadResult result: [String: Any]) -> CodexThreadHistorySnapshot? {
        guard let thread = result["thread"] as? [String: Any] else { return nil }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        var messages: [ChatMessage] = []
        var reviewStateDescription: String?
        var reviewStatusBadge: ChatStatusBadge?

        for turn in turns {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                messages.append(contentsOf: historyMessages(
                    for: item,
                    reviewStateDescription: &reviewStateDescription,
                    reviewStatusBadge: &reviewStatusBadge
                ))
            }
        }

        return CodexThreadHistorySnapshot(
            name: thread["name"] as? String,
            turns: turns.count,
            messages: messages,
            reviewStateDescription: reviewStateDescription,
            reviewStatusBadge: reviewStatusBadge
        )
    }

    static func reviewTarget(from command: String?) -> [String: Any] {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return ["type": "uncommittedChanges"]
        }

        if trimmed.hasPrefix("branch ") {
            let branch = String(trimmed.dropFirst("branch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return ["type": "uncommittedChanges"] }
            return [
                "type": "baseBranch",
                "branch": branch,
            ]
        }

        if trimmed.hasPrefix("commit ") {
            let sha = String(trimmed.dropFirst("commit ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { return ["type": "uncommittedChanges"] }
            return [
                "type": "commit",
                "sha": sha,
            ]
        }

        return [
            "type": "custom",
            "instructions": trimmed,
        ]
    }

    private static func historyMessages(
        for item: [String: Any],
        reviewStateDescription currentReviewStateDescription: inout String?,
        reviewStatusBadge currentReviewStatusBadge: inout ChatStatusBadge?
    ) -> [ChatMessage] {
        guard let type = item["type"] as? String else { return [] }

        switch type {
        case "userMessage":
            guard let text = historyUserMessageText(from: item) else { return [] }
            var message = ChatMessage(
                role: .user,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
            message.isFromHistory = true
            return [message]

        case "agentMessage":
            let text = sanitizeAssistantDisplayText((item["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            var message = ChatMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
            message.isFromHistory = true
            return [message]

        case "plan":
            let text = ((item["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            var message = ChatMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false,
                presentationKind: .plan
            )
            message.isFromHistory = true
            return [message]

        case "commandExecution":
            return [historyToolMessage(
                toolName: "Bash",
                content: CodexAppServerProvider.commandExecutionSummary(item),
                toolInput: CodexAppServerProvider.jsonString(item["command"] ?? item["commandActions"] ?? item),
                toolOutput: CodexAppServerProvider.completedCommandExecutionSummary(item, bufferedOutput: item["aggregatedOutput"] as? String)
            )]

        case "fileChange":
            return [historyToolMessage(
                toolName: "Edit",
                content: CodexAppServerProvider.fileChangeSummary(item),
                toolInput: CodexAppServerProvider.jsonString(item["changes"] ?? item),
                toolOutput: CodexAppServerProvider.completedFileChangeSummary(item, bufferedOutput: item["aggregatedOutput"] as? String)
            )]

        case "mcpToolCall":
            let name = (item["tool"] as? String) ?? "mcp"
            let summary = (item["server"] as? String).map { "\($0) · \(name)" } ?? name
            return [historyToolMessage(
                toolName: name,
                content: summary,
                toolInput: CodexAppServerProvider.jsonString(item["arguments"]),
                toolOutput: CodexAppServerProvider.completedDynamicToolCallSummary(item)
            )]

        case "dynamicToolCall":
            return [historyToolMessage(
                toolName: (item["tool"] as? String) ?? "dynamicTool",
                content: CodexAppServerProvider.dynamicToolCallSummary(item),
                toolInput: CodexAppServerProvider.dynamicToolCallInputPreview(item) ?? CodexAppServerProvider.jsonString(item["arguments"] ?? item),
                toolOutput: CodexAppServerProvider.completedDynamicToolCallSummary(item)
            )]

        case "webSearch":
            return [historyToolMessage(
                toolName: "WebSearch",
                content: CodexAppServerProvider.webSearchSummary(item),
                toolInput: CodexAppServerProvider.webSearchInputPreview(item) ?? CodexAppServerProvider.jsonString(["query": item["query"] as? String ?? "", "action": item["action"] as Any]),
                toolOutput: CodexAppServerProvider.completedWebSearchSummary(item)
            )]

        case "imageView":
            return [historyToolMessage(
                toolName: "ImageView",
                content: CodexAppServerProvider.imageViewSummary(item),
                toolInput: CodexAppServerProvider.jsonString(["path": item["path"] as? String ?? ""]),
                toolOutput: CodexAppServerProvider.completedImageViewSummary(item)
            )]

        case "collabAgentToolCall":
            return [historyToolMessage(
                toolName: "Agent",
                content: CodexAppServerProvider.collabAgentToolCallSummary(item),
                toolInput: CodexAppServerProvider.collabAgentToolCallInputPreview(item) ?? CodexAppServerProvider.jsonString(item),
                toolOutput: CodexAppServerProvider.completedCollabAgentToolCallSummary(item)
            )]

        case "enteredReviewMode":
            currentReviewStateDescription = CodexAppServerProvider.reviewStateDescription(item)
            currentReviewStatusBadge = ChatStatusBadge(kind: .reviewActive, text: currentReviewStateDescription ?? "Review active")
            return []

        case "exitedReviewMode":
            currentReviewStateDescription = nil
            currentReviewStatusBadge = ChatStatusBadge(kind: .reviewDone, text: "Review terminee")
            guard let rendered = (item["review"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rendered.isEmpty
            else {
                return []
            }
            let parsed = CodexAppServerProvider.parseReviewOutput(rendered)
            var renderedMessages: [ChatMessage] = []
            if let summary = parsed.summary, !summary.isEmpty {
                var summaryMessage = ChatMessage(
                    role: .assistant,
                    content: summary,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
                summaryMessage.isFromHistory = true
                renderedMessages.append(summaryMessage)
            }
            for finding in parsed.findings {
                var findingMessage = ChatMessage(
                    role: .assistant,
                    content: finding.body,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false,
                    presentationKind: .reviewFinding,
                    reviewFinding: finding
                )
                findingMessage.isFromHistory = true
                renderedMessages.append(findingMessage)
            }
            return renderedMessages

        default:
            return []
        }
    }

    private static func historyToolMessage(
        toolName: String,
        content: String,
        toolInput: String?,
        toolOutput: String?
    ) -> ChatMessage {
        var message = ChatMessage(
            role: .toolUse,
            content: content,
            timestamp: Date(),
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            isStreaming: false,
            isCollapsed: true
        )
        message.isFromHistory = true
        return message
    }

    private static func historyUserMessageText(from item: [String: Any]) -> String? {
        let content = item["content"] as? [[String: Any]] ?? []
        let fragments = content.compactMap { fragment -> String? in
            let type = (fragment["type"] as? String) ?? ""
            switch type {
            case "text":
                return (fragment["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .codexNilIfEmpty
            case "localImage":
                if let path = (fragment["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    return "[Image jointe: \((path as NSString).lastPathComponent)]"
                }
                return "[Image jointe]"
            case "image":
                if let url = (fragment["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                    return "[Image jointe: \(url)]"
                }
                return "[Image jointe]"
            case "mention", "skill":
                let name = (fragment["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return name?.codexNilIfEmpty.map { "[\($0)]" } ?? "[Contexte joint]"
            default:
                if let text = (fragment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
                return nil
            }
        }

        let text = fragments.joined(separator: "\n\n").codexNilIfEmpty
        let cleaned = text.map(CodexAppServerProvider.cleanedResumedUserMessage(_:))
        return cleaned?.codexNilIfEmpty
    }
}

private extension String {
    var codexNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

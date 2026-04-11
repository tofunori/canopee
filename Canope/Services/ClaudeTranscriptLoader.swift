import Foundation

enum ClaudeTranscriptLoader {
    static func parseSessionHistory(id: String) -> [ChatMessage] {
        var result: [ChatMessage] = []
        loadSessionHistoryInto(id: id, messages: &result)
        return result
    }

    static func loadSessionHistoryInto(id: String, messages: inout [ChatMessage]) {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeDir, includingPropertiesForKeys: nil
        ) else { return }

        var jsonlURL: URL?
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                jsonlURL = candidate
                break
            }
        }
        guard let url = jsonlURL,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        let allLines = content.components(separatedBy: "\n")
        let lines = allLines.suffix(20)
        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            guard type == "user" || type == "assistant" else { continue }
            guard let msg = json["message"] as? [String: Any] else { continue }
            let role = msg["role"] as? String ?? type
            let contentVal = msg["content"]

            if role == "user" {
                if let text = contentVal as? String, !text.isEmpty {
                    messages.append(ChatMessage(
                        role: .user,
                        content: ClaudeHeadlessProvider.cleanedResumedUserMessage(text),
                        timestamp: Date(),
                        isStreaming: false,
                        isCollapsed: false,
                        isFromHistory: true
                    ))
                } else if let blocks = contentVal as? [[String: Any]] {
                    let text = blocks.compactMap { block -> String? in
                        if block["type"] as? String == "text" { return block["text"] as? String }
                        return nil
                    }.joined(separator: "\n")
                    if !text.isEmpty {
                        messages.append(ChatMessage(
                            role: .user,
                            content: ClaudeHeadlessProvider.cleanedResumedUserMessage(text),
                            timestamp: Date(),
                            isStreaming: false,
                            isCollapsed: false,
                            isFromHistory: true
                        ))
                    }
                }
            } else if role == "assistant" {
                guard let blocks = contentVal as? [[String: Any]] else { continue }
                for block in blocks {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                        messages.append(ChatMessage(
                            role: .assistant,
                            content: text,
                            timestamp: Date(),
                            isStreaming: false,
                            isCollapsed: false,
                            isFromHistory: true
                        ))
                    } else if blockType == "tool_use" {
                        let toolName = block["name"] as? String ?? "tool"
                        let summary = ClaudeHeadlessProvider.toolSummary(name: toolName, input: block["input"] as? [String: Any])
                        messages.append(ChatMessage(
                            role: .toolUse,
                            content: summary,
                            timestamp: Date(),
                            toolName: toolName,
                            isStreaming: false,
                            isCollapsed: true
                        ))
                    }
                }
            }
        }
    }
}

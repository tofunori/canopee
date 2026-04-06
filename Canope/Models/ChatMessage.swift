import Foundation
import SwiftUI

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var toolName: String?
    var toolInput: String?
    var toolOutput: String?
    var isStreaming: Bool
    var isCollapsed: Bool
    var isFromHistory: Bool = false
    var preRenderedMarkdown: AttributedString?
    var toolCount: Int?

    enum Role: Equatable {
        case user
        case assistant
        case toolUse
        case toolResult
        case system
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming
            && lhs.isCollapsed == rhs.isCollapsed
    }

    /// Pre-render full markdown into a single AttributedString (call off main thread).
    /// Handles headings, lists, code blocks, tables — all as styled text, no SwiftUI sub-views.
    mutating func prerenderMarkdown() {
        let raw = content.contains("$") ? LaTeXUnicode.convert(content) : content
        var result = AttributedString()
        let lines = raw.components(separatedBy: "\n")
        var i = 0
        var isFirst = true

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines (add spacing)
            if trimmed.isEmpty {
                result += AttributedString("\n")
                i += 1
                continue
            }

            if !isFirst { result += AttributedString("\n") }
            isFirst = false

            // Heading
            if trimmed.hasPrefix("###") {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                var attr = inlineAttr(text)
                attr.font = .system(size: 13, weight: .bold)
                result += attr
            } else if trimmed.hasPrefix("##") {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                var attr = inlineAttr(text)
                attr.font = .system(size: 15, weight: .bold)
                attr.foregroundColor = .orange
                result += attr
            } else if trimmed.hasPrefix("#") {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                var attr = inlineAttr(text)
                attr.font = .system(size: 18, weight: .bold)
                attr.foregroundColor = .orange
                result += attr
            }
            // Horizontal rule
            else if trimmed.range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil {
                var attr = AttributedString("────────────────────────")
                attr.foregroundColor = .secondary
                result += attr
            }
            // Code block
            else if trimmed.hasPrefix("```") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                var attr = AttributedString(codeLines.joined(separator: "\n"))
                attr.font = .system(size: 12).monospaced()
                attr.foregroundColor = .init(nsColor: .init(white: 0.75, alpha: 1))
                result += attr
            }
            // Table row
            else if trimmed.contains("|") && trimmed.hasPrefix("|") {
                // Skip separator rows
                if trimmed.range(of: #"^\|[-\s|]+\|$"#, options: .regularExpression) == nil {
                    let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    var attr = inlineAttr(cells.joined(separator: "  ·  "))
                    attr.font = .system(size: 12).monospaced()
                    result += attr
                }
            }
            // List item
            else if trimmed.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) != nil {
                let text = trimmed.replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
                result += AttributedString("  •  ")
                result += inlineAttr(text)
            }
            // Numbered list
            else if trimmed.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) != nil {
                result += inlineAttr(trimmed)
            }
            // Blockquote
            else if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                var bar = AttributedString("  ┃  ")
                bar.foregroundColor = .secondary
                result += bar
                var attr = inlineAttr(text)
                attr.foregroundColor = .secondary
                result += attr
            }
            // Regular paragraph
            else {
                result += inlineAttr(trimmed)
            }

            i += 1
        }
        preRenderedMarkdown = result
    }

    private func inlineAttr(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
    }
}

// MARK: - Session Info

struct SessionInfo: Equatable {
    var id: String?
    var model: String?
    var costUSD: Double = 0
    var turns: Int = 0
    var durationMs: Int = 0
}

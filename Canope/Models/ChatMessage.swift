import Foundation
import SwiftUI

enum ChatInteractionMode: String, Codable, CaseIterable, Equatable {
    case agent
    case acceptEdits
    case plan

    var badgeLabel: String {
        switch self {
        case .agent: return "Agent"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        }
    }

    var iconName: String {
        switch self {
        case .agent: return "sparkles"
        case .acceptEdits: return "checkmark.circle"
        case .plan: return "list.bullet.clipboard"
        }
    }

    var tint: Color {
        switch self {
        case .agent: return .orange
        case .acceptEdits: return .green
        case .plan: return .blue
        }
    }

    var inputPlaceholderSuffix: String {
        switch self {
        case .agent: return "Message"
        case .acceptEdits: return "Instruction"
        case .plan: return "Plan"
        }
    }

    var sendButtonSymbolName: String {
        switch self {
        case .agent, .acceptEdits: return "arrow.up.circle.fill"
        case .plan: return "list.bullet.clipboard.fill"
        }
    }

    var next: ChatInteractionMode {
        switch self {
        case .agent: return .acceptEdits
        case .acceptEdits: return .plan
        case .plan: return .agent
        }
    }
}

struct ChatApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let prompt: String
    let displayText: String
    let rpcRequestID: Int?
    let rpcMethod: String?
    let itemID: String?
    let threadID: String?
    let turnID: String?

    init(
        toolName: String,
        prompt: String,
        displayText: String,
        rpcRequestID: Int? = nil,
        rpcMethod: String? = nil,
        itemID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil
    ) {
        self.toolName = toolName
        self.prompt = prompt
        self.displayText = displayText
        self.rpcRequestID = rpcRequestID
        self.rpcMethod = rpcMethod
        self.itemID = itemID
        self.threadID = threadID
        self.turnID = turnID
    }
}

enum ChatInputItem: Equatable {
    static let maxInlineTextFileCharacters = 8_000

    case text(String)
    case image(URL)
    case localImage(path: String)
    case textFile(name: String, path: String, content: String)
    case skill(name: String, path: String)
    case mention(name: String, path: String)

    var codexPayloads: [[String: Any]] {
        switch self {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [[
                "type": "text",
                "text": trimmed,
                "text_elements": [],
            ]]
        case .image(let url):
            return [[
                "type": "image",
                "url": url.absoluteString,
            ]]
        case .localImage(let path):
            return [[
                "type": "localImage",
                "path": path,
            ]]
        case .textFile(let name, let path, let content):
            return ChatInputItem.text(Self.legacyTextFilePrompt(name: name, path: path, content: content)).codexPayloads
        case .skill(let name, let path):
            return [[
                "type": "skill",
                "name": name,
                "path": path,
            ]]
        case .mention(let name, let path):
            return [[
                "type": "mention",
                "name": name,
                "path": path,
            ]]
        }
    }

    static func legacyPrompt(from items: [ChatInputItem]) -> String {
        var sections: [String] = []

        for item in items {
            switch item {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sections.append(trimmed)
                }
            case .textFile(let name, let path, let content):
                sections.append(Self.legacyTextFilePrompt(name: name, path: path, content: content))
            case .image(let url):
                sections.append(Self.legacyImagePrompt(name: url.lastPathComponent, path: url.path))
            case .localImage(let path):
                sections.append(Self.legacyImagePrompt(name: URL(fileURLWithPath: path).lastPathComponent, path: path))
            case .skill(let name, let path):
                sections.append("""
                [Attached skill: \(name)]
                Path: \(path)
                [/Attached skill]
                """)
            case .mention(let name, let path):
                sections.append("""
                [Attached mention: \(name)]
                Path: \(path)
                [/Attached mention]
                """)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private static func legacyTextFilePrompt(name: String, path: String, content: String) -> String {
        let truncated = content.count > maxInlineTextFileCharacters
            ? String(content.prefix(maxInlineTextFileCharacters)) + "\n… (tronqué)"
            : content
        return """
        [Attached file: \(name)]
        Path: \(path)
        \(truncated)
        [/Attached file]
        """
    }

    private static func legacyImagePrompt(name: String, path: String) -> String {
        """
        [Attached image: \(name)]
        Path: \(path)
        [/Attached image]
        """
    }
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    enum PresentationKind: Equatable {
        case standard
        case plan
    }

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
    var queuePosition: Int? = nil
    var presentationKind: PresentationKind = .standard

    enum Role: Equatable {
        case user
        case assistant
        case toolUse
        case toolResult
        case system
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.content == rhs.content
            && lhs.isStreaming == rhs.isStreaming
            && lhs.isCollapsed == rhs.isCollapsed
            && lhs.isFromHistory == rhs.isFromHistory
            && lhs.toolName == rhs.toolName
            && lhs.toolInput == rhs.toolInput
            && lhs.toolOutput == rhs.toolOutput
            && lhs.toolCount == rhs.toolCount
            && lhs.queuePosition == rhs.queuePosition
            && lhs.preRenderedMarkdown == rhs.preRenderedMarkdown
            && lhs.presentationKind == rhs.presentationKind
    }

    /// Uses the same markdown pipeline as [`MarkdownBlockView`](MarkdownBlockView.swift).
    @MainActor
    static func attributedPreview(for raw: String) -> AttributedString {
        MarkdownBlockView.attributedPreview(for: raw)
    }

    var isQueued: Bool {
        queuePosition != nil
    }

    var isLegacyAcceptEditsApprovalNotice: Bool {
        role == .system && content.hasPrefix("Mode accept edits:")
    }
}

// MARK: - Session Info

struct SessionInfo: Equatable {
    var id: String?
    var name: String?
    var model: String?
    var costUSD: Double = 0
    var turns: Int = 0
    var durationMs: Int = 0
}

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
    var queuePosition: Int? = nil

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
    }

    /// Uses the same markdown pipeline as [`MarkdownBlockView`](MarkdownBlockView.swift).
    @MainActor
    static func attributedPreview(for raw: String) -> AttributedString {
        MarkdownBlockView.attributedPreview(for: raw)
    }

    var isQueued: Bool {
        queuePosition != nil
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

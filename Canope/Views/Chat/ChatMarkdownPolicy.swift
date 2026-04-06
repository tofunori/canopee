import Foundation

/// Centralized limits for chat markdown rendering (CPU + memory).
enum ChatMarkdownPolicy {
    /// Beyond this, keep inline-only rendering and skip block `MarkdownBlockView` / heavy pre-render.
    static let maxFullRenderCharacters = 48_000

    /// Soft cap for combined markdown caches (inline + block parse + attributed runs).
    static let maxApproximateCacheBytes = 1_500_000

    static let maxInlineCacheEntries = 64
    static let maxBlockTextKeys = 48
    static let maxAttributedRunCacheEntries = 96

    // MARK: - Pre-rendered `AttributedString` retention (per-message store on `ChatMessage`)

    /// Max total `content` character count for which we keep rich `preRenderedMarkdown` (newest assistants first).
    static let maxRetainedPreRenderedCharacters = 25_000

    /// Hard cap on how many assistant messages may keep `preRenderedMarkdown` at once.
    static let maxRetainedPreRenderedMessages = 6

    static func shouldSkipFullMarkdown(for text: String) -> Bool {
        text.count > maxFullRenderCharacters
    }

    /// Drops `preRenderedMarkdown` on older assistant messages so retained pre-renders stay within budget (newest first).
    /// The single newest pre-rendered assistant message is always kept so a very long latest reply stays readable.
    static func applyPreRenderedMarkdownRetentionBudget(to messages: inout [ChatMessage]) {
        var newestFirstIndices: [Int] = []
        for i in messages.indices.reversed() {
            guard messages[i].role == .assistant,
                  !messages[i].isFromHistory,
                  messages[i].preRenderedMarkdown != nil else { continue }
            newestFirstIndices.append(i)
        }

        var retainedChars = 0
        var retainedCount = 0

        for idx in newestFirstIndices {
            let len = messages[idx].content.count
            let keep: Bool
            if retainedCount == 0 {
                keep = true
            } else if retainedCount < maxRetainedPreRenderedMessages,
                      retainedChars + len <= maxRetainedPreRenderedCharacters {
                keep = true
            } else {
                keep = false
            }

            if keep {
                retainedChars += len
                retainedCount += 1
            } else {
                messages[idx].preRenderedMarkdown = nil
            }
        }
    }
}

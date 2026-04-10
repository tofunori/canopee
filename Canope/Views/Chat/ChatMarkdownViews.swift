import SwiftUI

// MARK: - Inline Markdown Cache (lightweight, for history messages)

@MainActor
final class InlineMarkdownCache {
    static let shared = InlineMarkdownCache()
    private var cache: [String: AttributedString] = [:]
    private var insertionOrder: [String] = []
    private var approximateBytes: Int = 0

    func get(_ text: String) -> AttributedString {
        if let cached = cache[text] {
            bump(text)
            return cached
        }
        let converted = MarkdownFormatter.normalizedMarkdownForRendering(text)
        let result = (try? AttributedString(markdown: converted, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(converted)
        cache[text] = result
        insertionOrder.append(text)
        approximateBytes += text.utf8.count + result.characters.count * 3
        evictIfNeeded()
        return result
    }

    private func bump(_ key: String) {
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)
    }

    private func evictIfNeeded() {
        while insertionOrder.count > ChatMarkdownPolicy.maxInlineCacheEntries
            || approximateBytes > ChatMarkdownPolicy.maxApproximateCacheBytes
        {
            guard let oldest = insertionOrder.first else { break }
            insertionOrder.removeFirst()
            if let attr = cache.removeValue(forKey: oldest) {
                approximateBytes -= oldest.utf8.count + attr.characters.count * 3
            }
        }
    }
}

// MARK: - Deferred Markdown (inline first, full render after visible)

/// Shows inline markdown instantly; optional upgrade to full block markdown after a delay.
struct DeferredMarkdownView: View {
    let text: String
    let skipFullRender: Bool
    /// When false, only inline markdown is used until `preRenderedMarkdown` is set by the provider.
    let allowPromoteToFullBlock: Bool
    let promotionDelayNanoseconds: UInt64

    init(
        text: String,
        skipFullRender: Bool = false,
        allowPromoteToFullBlock: Bool = true,
        promotionDelayNanoseconds: UInt64 = 450_000_000
    ) {
        self.text = text
        self.skipFullRender = skipFullRender
        self.allowPromoteToFullBlock = allowPromoteToFullBlock
        self.promotionDelayNanoseconds = promotionDelayNanoseconds
    }

    @State private var showFull = false

    private var effectiveSkipFull: Bool {
        skipFullRender
            || ChatMarkdownPolicy.shouldSkipFullMarkdown(for: text)
            || !allowPromoteToFullBlock
    }

    var body: some View {
        if showFull && !effectiveSkipFull {
            MarkdownBlockView(text: text)
        } else {
            Text(InlineMarkdownCache.shared.get(text))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .task(id: text) {
                    guard !effectiveSkipFull else { return }
                    try? await Task.sleep(nanoseconds: promotionDelayNanoseconds)
                    guard !Task.isCancelled else { return }
                    showFull = true
                }
        }
    }
}

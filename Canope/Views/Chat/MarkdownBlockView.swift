import SwiftUI

// MARK: - Markdown Block Renderer

// Global cache so LazyVStack recycling doesn't re-parse
let markdownCache = MarkdownBlockCache()

@MainActor
final class MarkdownBlockCache {
    private var blockCache: [String: [MarkdownBlockView.Block]] = [:]
    private var blockInsertionOrder: [String] = []
    private var attrCache: [String: AttributedString] = [:]
    private var attrInsertionOrder: [String] = []
    private var attrKeysBySourceText: [String: Set<String>] = [:]
    private var approximateBytes: Int = 0

    func blocks(for text: String) -> [MarkdownBlockView.Block] {
        if let cached = blockCache[text] {
            bumpBlockOrder(text)
            return cached
        }
        let parsed = MarkdownBlockView.parseBlocks(text)
        blockCache[text] = parsed
        bumpBlockOrder(text)
        approximateBytes += Self.estimatedBlockEntryBytes(text: text, blocks: parsed)
        evictBlockCacheIfNeeded(retaining: text)
        return parsed
    }

    /// Cache key includes source `text` so evictions can drop related attributed runs.
    func cacheKeyForTextRun(text: String, groupIndex: Int) -> String {
        "\(text.hashValue)_\(groupIndex)"
    }

    func attributedString(
        for text: String,
        segments: [MarkdownBlockView.Block],
        groupIndex: Int,
        builder: () -> AttributedString
    ) -> AttributedString {
        let key = cacheKeyForTextRun(text: text, groupIndex: groupIndex)
        if let cached = attrCache[key] { return cached }
        let result = builder()
        attrCache[key] = result
        attrInsertionOrder.append(key)
        if attrKeysBySourceText[text] == nil { attrKeysBySourceText[text] = [] }
        attrKeysBySourceText[text]?.insert(key)
        approximateBytes += key.utf8.count + result.characters.count * 3
        evictAttrCacheIfNeeded(retainingKey: key)
        return result
    }

    private func bumpBlockOrder(_ text: String) {
        blockInsertionOrder.removeAll { $0 == text }
        blockInsertionOrder.append(text)
    }

    private func evictBlockCacheIfNeeded(retaining text: String) {
        while (blockCache.count > ChatMarkdownPolicy.maxBlockTextKeys
            || approximateBytes > ChatMarkdownPolicy.maxApproximateCacheBytes),
            blockCache.count > 1
        {
            let victim = blockInsertionOrder.first { $0 != text } ?? blockInsertionOrder.first!
            removeBlockEntry(victim)
        }
    }

    private func removeBlockEntry(_ text: String) {
        blockInsertionOrder.removeAll { $0 == text }
        if let blocks = blockCache.removeValue(forKey: text) {
            approximateBytes -= Self.estimatedBlockEntryBytes(text: text, blocks: blocks)
        }
        if let keys = attrKeysBySourceText.removeValue(forKey: text) {
            for k in keys {
                removeAttrEntry(k)
            }
        }
    }

    private func evictAttrCacheIfNeeded(retainingKey: String) {
        while attrCache.count > ChatMarkdownPolicy.maxAttributedRunCacheEntries
            || approximateBytes > ChatMarkdownPolicy.maxApproximateCacheBytes
        {
            if attrInsertionOrder.count == 1, attrInsertionOrder.first == retainingKey { break }
            guard let victim = attrInsertionOrder.first(where: { $0 != retainingKey }) else { break }
            removeAttrEntry(victim)
        }
    }

    private func removeAttrEntry(_ key: String) {
        attrInsertionOrder.removeAll { $0 == key }
        guard let attr = attrCache.removeValue(forKey: key) else { return }
        approximateBytes -= key.utf8.count + attr.characters.count * 3
        for (src, var keys) in attrKeysBySourceText where keys.contains(key) {
            keys.remove(key)
            attrKeysBySourceText[src] = keys
        }
    }

    private static func estimatedBlockEntryBytes(text: String, blocks: [MarkdownBlockView.Block]) -> Int {
        var n = text.utf8.count
        for b in blocks {
            switch b {
            case .heading(_, let t): n += t.utf8.count
            case .code(_, let c): n += c.utf8.count
            case .table(let rows): n += rows.flatMap { $0 }.joined().utf8.count
            case .insight(let lines): n += lines.joined().utf8.count
            case .list(let items, _): n += items.joined().utf8.count
            case .blockquote(let t): n += t.utf8.count
            case .paragraph(let t): n += t.utf8.count
            case .rule: break
            }
        }
        return max(n, text.utf8.count * 2)
    }
}

struct MarkdownBlockView: View {
    let text: String

    private var blocks: [Block] { markdownCache.blocks(for: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let groups = Self.groupBlocks(blocks)
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                switch group {
                case .textRun(let segments):
                    Text(markdownCache.attributedString(for: text, segments: segments, groupIndex: groupIndex) {
                        Self.buildAttributedString(segments: segments, inlineMarkdown: inlineMarkdown)
                    })
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                case .special(let block):
                    blockView(block)
                }
            }
        }
    }

    private enum BlockGroup {
        case textRun(segments: [Block])  // paragraphs, headings, insights merged into one Text
        case special(Block)              // code, table, rule — need custom rendering
    }

    nonisolated private static func groupBlocks(_ blocks: [Block]) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        var currentRun: [Block] = []

        func flushRun() {
            if !currentRun.isEmpty {
                groups.append(.textRun(segments: currentRun))
                currentRun = []
            }
        }

        for block in blocks {
            switch block {
            case .paragraph, .heading, .insight, .list, .blockquote:
                currentRun.append(block)
            case .code, .table, .rule:
                flushRun()
                groups.append(.special(block))
            }
        }
        flushRun()
        return groups
    }

    nonisolated private static func buildAttributedString(
        segments: [Block],
        inlineMarkdown: (String) -> AttributedString
    ) -> AttributedString {
        var result = AttributedString()
        for (i, block) in segments.enumerated() {
            if i > 0 {
                result += AttributedString("\n\n")
            }
            switch block {
            case .heading(let level, let text):
                var attr = inlineMarkdown(text)
                let size: CGFloat = level == 1 ? 18 : level == 2 ? 15 : 13
                attr.font = .system(size: size, weight: .bold)
                if level <= 2 {
                    attr.foregroundColor = .orange
                }
                result += attr

            case .paragraph(let text):
                result += inlineMarkdown(text)

            case .insight(let lines):
                var header = AttributedString("★ Insight ─────────────────────────────────────\n")
                header.font = .system(size: 12, weight: .medium).monospaced()
                header.foregroundColor = .purple
                result += header
                for (j, line) in lines.enumerated() {
                    result += inlineMarkdown(line)
                    if j < lines.count - 1 { result += AttributedString("\n") }
                }
                var footer = AttributedString("\n─────────────────────────────────────────────────")
                footer.font = .system(size: 12).monospaced()
                footer.foregroundColor = .purple
                result += footer

            case .list(let items, let ordered):
                for (j, item) in items.enumerated() {
                    let bullet = ordered ? "\(j + 1). " : "  •  "
                    result += AttributedString(bullet)
                    result += inlineMarkdown(item)
                    if j < items.count - 1 { result += AttributedString("\n") }
                }

            case .blockquote(let text):
                var bar = AttributedString("  ┃  ")
                bar.foregroundColor = .secondary
                result += bar
                var quoted = inlineMarkdown(text)
                quoted.foregroundColor = .secondary
                result += quoted

            default:
                break
            }
        }
        return result
    }

    enum Block {
        case heading(level: Int, text: String)
        case code(language: String, content: String)
        case table(rows: [[String]])
        case rule
        case insight(lines: [String])
        case list(items: [String], ordered: Bool)
        case blockquote(text: String)
        case paragraph(text: String)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .code(let lang, let content):
            codeBlockView(language: lang, content: content)
        case .table(let rows):
            tableView(rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        case .insight(let lines):
            insightView(lines: lines)
        case .paragraph(let text):
            paragraphView(text: text)
        case .list, .blockquote:
            EmptyView() // Rendered in textRun via buildAttributedString
        }
    }

    private func insightView(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("★ Insight ─────────────────────────────────────")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.purple)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(inlineMarkdown(line))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }

            Text("─────────────────────────────────────────────────")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.purple)
        }
    }

    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = level == 1 ? 18 : level == 2 ? 15 : 13
        return Text(inlineMarkdown(text))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(level <= 2 ? Color.orange : .primary)
            .padding(.top, level <= 2 ? 8 : 4)
            .padding(.bottom, 2)
    }

    private func codeBlockView(language: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: .init(white: 0.85, alpha: 1)))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .init(white: 0.1, alpha: 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func tableView(rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        Text(inlineMarkdown(cell.trimmingCharacters(in: .whitespaces)))
                            .font(.system(size: 12, weight: rowIdx == 0 ? .semibold : .regular))
                            .foregroundStyle(rowIdx == 0 ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        if colIdx < row.count - 1 {
                            Divider()
                        }
                    }
                }
                if rowIdx < rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppChromePalette.surfaceSubbar.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
        )
    }

    private func paragraphView(text: String) -> some View {
        Text(inlineMarkdown(text))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        // Convert LaTeX math before markdown parsing
        let converted = text.contains("$") ? LaTeXUnicode.convert(text) : text
        return (try? AttributedString(markdown: converted, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(converted)
    }

    // MARK: - Parser

    nonisolated static func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Insight block (★ Insight ──── ... ────)
            if line.contains("★") && line.contains("─") {
                var insightLines: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    // Closing border line (all ─)
                    if l.contains("─") && !l.contains("★") && l.filter({ $0 == "─" }).count > 5 {
                        i += 1
                        break
                    }
                    insightLines.append(l)
                    i += 1
                }
                if !insightLines.isEmpty {
                    blocks.append(.insight(lines: insightLines))
                }
                continue
            }

            // Heading
            if let match = line.range(of: #"^(#{1,3})\s+(.+)$"#, options: .regularExpression) {
                let full = String(line[match])
                let level = full.prefix(while: { $0 == "#" }).count
                let text = String(full.drop(while: { $0 == "#" }).dropFirst())
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces).range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                blocks.append(.code(language: lang, content: codeLines.joined(separator: "\n")))
                continue
            }

            // Table
            if line.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---") {
                var tableRows: [[String]] = []
                while i < lines.count && lines[i].contains("|") {
                    let cells = lines[i]
                        .split(separator: "|", omittingEmptySubsequences: false)
                        .map(String.init)
                        .dropFirst()
                        .dropLast()
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    // Skip separator row
                    if !cells.allSatisfy({ $0.range(of: #"^-+$"#, options: .regularExpression) != nil }) {
                        tableRows.append(Array(cells))
                    }
                    i += 1
                }
                if !tableRows.isEmpty {
                    blocks.append(.table(rows: tableRows))
                }
                continue
            }

            // Blockquote
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix(">") {
                    let content = String(lines[i].dropFirst()).trimmingCharacters(in: .init(charactersIn: " "))
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // List (unordered: - or * ; ordered: 1. 2. etc.)
            if line.range(of: #"^\s*[-*]\s+\S"#, options: .regularExpression) != nil ||
               line.range(of: #"^\s*\d+\.\s+\S"#, options: .regularExpression) != nil
            {
                let isOrdered = line.range(of: #"^\s*\d+\."#, options: .regularExpression) != nil
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if let match = l.range(of: #"^\s*[-*]\s+(.*)"#, options: .regularExpression) {
                        let content = String(l[match]).replacingOccurrences(
                            of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
                        items.append(content)
                        i += 1
                    } else if let match = l.range(of: #"^\s*\d+\.\s+(.*)"#, options: .regularExpression) {
                        let content = String(l[match]).replacingOccurrences(
                            of: #"^\s*\d+\.\s+"#, with: "", options: .regularExpression)
                        items.append(content)
                        i += 1
                    } else {
                        break
                    }
                }
                if !items.isEmpty {
                    blocks.append(.list(items: items, ordered: isOrdered))
                }
                continue
            }

            // Empty line — skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```")
                    || (trimmed.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---"))
                    || trimmed.range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil
                {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(text: paraLines.joined(separator: "\n")))
            }
        }
        return blocks
    }

    // MARK: - Single attributed preview (shared with ChatMessage / tests)

    /// Rich-text preview using the same parse path and text-run styling as the block view.
    @MainActor
    static func attributedPreview(for text: String) -> AttributedString {
        let blocks = markdownCache.blocks(for: text)
        let groups = groupBlocks(blocks)
        var combined = AttributedString()
        for (groupIndex, group) in groups.enumerated() {
            switch group {
            case .textRun(let segments):
                let piece = markdownCache.attributedString(for: text, segments: segments, groupIndex: groupIndex) {
                    buildAttributedString(segments: segments, inlineMarkdown: inlineMarkdownStatic)
                }
                combined += piece
            case .special(let block):
                combined += AttributedString("\n")
                combined += fallbackAttributed(for: block)
            }
        }
        return combined
    }

    /// Same output as `attributedPreview` but does not use `markdownCache`; safe for background pre-render.
    nonisolated static func renderAttributedPreviewForBackground(_ text: String) -> AttributedString {
        let blocks = parseBlocks(text)
        let groups = groupBlocks(blocks)
        var combined = AttributedString()
        for group in groups {
            switch group {
            case .textRun(let segments):
                combined += buildAttributedString(segments: segments, inlineMarkdown: inlineMarkdownStatic)
            case .special(let block):
                combined += AttributedString("\n")
                combined += fallbackAttributed(for: block)
            }
        }
        return combined
    }

    nonisolated private static func inlineMarkdownStatic(_ text: String) -> AttributedString {
        let converted = text.contains("$") ? LaTeXUnicode.convert(text) : text
        return (try? AttributedString(markdown: converted, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(converted)
    }

    nonisolated private static func fallbackAttributed(for block: Block) -> AttributedString {
        switch block {
        case .code(_, let content):
            var a = AttributedString(content)
            a.font = .system(size: 12).monospaced()
            return a
        case .table(let rows):
            return AttributedString(rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))
        case .rule:
            var r = AttributedString("────────────────────────")
            r.foregroundColor = .secondary
            return r
        default:
            return AttributedString("")
        }
    }
}

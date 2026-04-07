import AppKit
import SwiftUI

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case code(language: String, content: String)
    case table(rows: [[String]])
    case rule
    case insight(lines: [String])
    case list(items: [String], ordered: Bool)
    case blockquote(text: String)
    case paragraph(text: String)
}

struct MarkdownTheme: Equatable {
    let backgroundColor: NSColor
    let primaryTextColor: NSColor
    let secondaryTextColor: NSColor
    let accentColor: NSColor
    let headingColor: NSColor
    let blockquoteColor: NSColor
    let codeTextColor: NSColor
    let codeBackgroundColor: NSColor
    let codeBorderColor: NSColor
    let syntaxMarkerColor: NSColor

    static let dark = MarkdownTheme(
        backgroundColor: NSColor(srgbRed: 0.082, green: 0.078, blue: 0.106, alpha: 1),
        primaryTextColor: NSColor(srgbRed: 0.929, green: 0.925, blue: 0.933, alpha: 1),
        secondaryTextColor: NSColor(srgbRed: 0.70, green: 0.70, blue: 0.74, alpha: 1),
        accentColor: NSColor(srgbRed: 0.37, green: 0.66, blue: 1.0, alpha: 1),
        headingColor: NSColor(srgbRed: 1.0, green: 0.79, blue: 0.52, alpha: 1),
        blockquoteColor: NSColor(srgbRed: 0.76, green: 0.78, blue: 0.84, alpha: 1),
        codeTextColor: NSColor(srgbRed: 0.85, green: 0.88, blue: 0.92, alpha: 1),
        codeBackgroundColor: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
        codeBorderColor: NSColor.white.withAlphaComponent(0.08),
        syntaxMarkerColor: NSColor(srgbRed: 0.48, green: 0.48, blue: 0.54, alpha: 1)
    )
}

@MainActor
final class MarkdownFormattingCache {
    private var blockCache: [String: [MarkdownBlock]] = [:]
    private var blockInsertionOrder: [String] = []
    private var attrCache: [String: AttributedString] = [:]
    private var attrInsertionOrder: [String] = []
    private var attrKeysBySourceText: [String: Set<String>] = [:]
    private var approximateBytes: Int = 0

    func blocks(for text: String) -> [MarkdownBlock] {
        if let cached = blockCache[text] {
            bumpBlockOrder(text)
            return cached
        }
        let parsed = MarkdownFormatter.parseBlocks(text)
        blockCache[text] = parsed
        bumpBlockOrder(text)
        approximateBytes += Self.estimatedBlockEntryBytes(text: text, blocks: parsed)
        evictBlockCacheIfNeeded(retaining: text)
        return parsed
    }

    func cacheKeyForTextRun(text: String, groupIndex: Int) -> String {
        "\(text.hashValue)_\(groupIndex)"
    }

    func attributedString(
        for text: String,
        segments: [MarkdownBlock],
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
            for key in keys { removeAttrEntry(key) }
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
        for (source, var keys) in attrKeysBySourceText where keys.contains(key) {
            keys.remove(key)
            attrKeysBySourceText[source] = keys
        }
    }

    private static func estimatedBlockEntryBytes(text: String, blocks: [MarkdownBlock]) -> Int {
        var bytes = text.utf8.count
        for block in blocks {
            switch block {
            case .heading(_, let text): bytes += text.utf8.count
            case .code(_, let content): bytes += content.utf8.count
            case .table(let rows): bytes += rows.flatMap { $0 }.joined().utf8.count
            case .insight(let lines): bytes += lines.joined().utf8.count
            case .list(let items, _): bytes += items.joined().utf8.count
            case .blockquote(let text): bytes += text.utf8.count
            case .paragraph(let text): bytes += text.utf8.count
            case .rule: break
            }
        }
        return max(bytes, text.utf8.count * 2)
    }
}

enum MarkdownFormatter {
    enum BlockGroup {
        case textRun(segments: [MarkdownBlock])
        case special(MarkdownBlock)
    }

    static func groupBlocks(_ blocks: [MarkdownBlock]) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        var currentRun: [MarkdownBlock] = []

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

    static func buildAttributedString(
        segments: [MarkdownBlock],
        theme: MarkdownTheme = .dark,
        baseFontSize: CGFloat = 13
    ) -> AttributedString {
        var result = AttributedString()
        for (index, block) in segments.enumerated() {
            if index > 0 {
                result += AttributedString("\n\n")
            }
            switch block {
            case .heading(let level, let text):
                var attr = inlineMarkdown(text, theme: theme, baseFontSize: baseFontSize)
                let size = headingFontSize(level: level, baseFontSize: baseFontSize)
                attr.font = .system(size: size, weight: .bold)
                attr.foregroundColor = Color(theme.headingColor)
                result += attr

            case .paragraph(let text):
                result += inlineMarkdown(text, theme: theme, baseFontSize: baseFontSize)

            case .insight(let lines):
                var header = AttributedString("★ Insight ─────────────────────────────────────\n")
                header.font = .system(size: max(baseFontSize - 1, 12), weight: .medium).monospaced()
                header.foregroundColor = Color(theme.accentColor)
                result += header
                for (lineIndex, line) in lines.enumerated() {
                    result += inlineMarkdown(line, theme: theme, baseFontSize: baseFontSize)
                    if lineIndex < lines.count - 1 {
                        result += AttributedString("\n")
                    }
                }
                var footer = AttributedString("\n─────────────────────────────────────────────────")
                footer.font = .system(size: max(baseFontSize - 1, 12)).monospaced()
                footer.foregroundColor = Color(theme.accentColor)
                result += footer

            case .list(let items, let ordered):
                for (itemIndex, item) in items.enumerated() {
                    var bullet = AttributedString(ordered ? "\(itemIndex + 1). " : "  •  ")
                    bullet.foregroundColor = Color(theme.secondaryTextColor)
                    result += bullet
                    result += inlineMarkdown(item, theme: theme, baseFontSize: baseFontSize)
                    if itemIndex < items.count - 1 {
                        result += AttributedString("\n")
                    }
                }

            case .blockquote(let text):
                var bar = AttributedString("  ┃  ")
                bar.foregroundColor = Color(theme.secondaryTextColor)
                result += bar
                var quoted = inlineMarkdown(text, theme: theme, baseFontSize: baseFontSize)
                quoted.foregroundColor = Color(theme.blockquoteColor)
                result += quoted

            default:
                break
            }
        }
        return result
    }

    @MainActor
    static func attributedPreview(
        for text: String,
        theme: MarkdownTheme = .dark,
        cache: MarkdownFormattingCache? = nil
    ) -> AttributedString {
        let blocks = cache?.blocks(for: text) ?? parseBlocks(text)
        let groups = groupBlocks(blocks)
        var combined = AttributedString()

        for (groupIndex, group) in groups.enumerated() {
            switch group {
            case .textRun(let segments):
                let piece: AttributedString
                if let cache {
                    piece = cache.attributedString(for: text, segments: segments, groupIndex: groupIndex) {
                        buildAttributedString(segments: segments, theme: theme)
                    }
                } else {
                    piece = buildAttributedString(segments: segments, theme: theme)
                }
                combined += piece

            case .special(let block):
                combined += AttributedString("\n")
                combined += fallbackAttributed(for: block, theme: theme)
            }
        }

        return combined
    }

    static func renderAttributedPreviewForBackground(
        _ text: String,
        theme: MarkdownTheme = .dark
    ) -> AttributedString {
        let blocks = parseBlocks(text)
        let groups = groupBlocks(blocks)
        var combined = AttributedString()
        for group in groups {
            switch group {
            case .textRun(let segments):
                combined += buildAttributedString(segments: segments, theme: theme)
            case .special(let block):
                combined += AttributedString("\n")
                combined += fallbackAttributed(for: block, theme: theme)
            }
        }
        return combined
    }

    static func inlineMarkdown(
        _ text: String,
        theme: MarkdownTheme = .dark,
        baseFontSize: CGFloat = 13
    ) -> AttributedString {
        let converted = text.contains("$") ? LaTeXUnicode.convert(text) : text
        var attr = (try? AttributedString(markdown: converted, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(converted)
        attr.font = .system(size: baseFontSize)
        attr.foregroundColor = Color(theme.primaryTextColor)
        return attr
    }

    static func parseBlocks(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.contains("★") && line.contains("─") {
                var insightLines: [String] = []
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.contains("─") && !current.contains("★") && current.filter({ $0 == "─" }).count > 5 {
                        index += 1
                        break
                    }
                    insightLines.append(current)
                    index += 1
                }
                if !insightLines.isEmpty {
                    blocks.append(.insight(lines: insightLines))
                }
                continue
            }

            if let match = line.range(of: #"^(#{1,3})\s+(.+)$"#, options: .regularExpression) {
                let full = String(line[match])
                let level = full.prefix(while: { $0 == "#" }).count
                let headingText = String(full.drop(while: { $0 == "#" }).dropFirst())
                blocks.append(.heading(level: level, text: headingText))
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil {
                blocks.append(.rule)
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language, content: codeLines.joined(separator: "\n")))
                continue
            }

            if index + 1 < lines.count,
               let headerCells = parseMarkdownTableRow(line),
               isMarkdownTableSeparator(lines[index + 1], expectedColumnCount: headerCells.count)
            {
                var tableRows = [headerCells]
                index += 2
                while index < lines.count,
                      let cells = parseMarkdownTableRow(lines[index]),
                      cells.count == headerCells.count {
                    tableRows.append(cells)
                    index += 1
                }
                blocks.append(.table(rows: normalizeMarkdownTableRows(tableRows)))
                continue
            }

            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count && lines[index].hasPrefix(">") {
                    let content = String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces)
                    quoteLines.append(content)
                    index += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            if line.range(of: #"^\s*[-*]\s+\S"#, options: .regularExpression) != nil
                || line.range(of: #"^\s*\d+\.\s+\S"#, options: .regularExpression) != nil {
                let ordered = line.range(of: #"^\s*\d+\."#, options: .regularExpression) != nil
                var items: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if let match = current.range(of: #"^\s*[-*]\s+(.*)"#, options: .regularExpression) {
                        let content = String(current[match]).replacingOccurrences(
                            of: #"^\s*[-*]\s+"#,
                            with: "",
                            options: .regularExpression
                        )
                        items.append(content)
                        index += 1
                    } else if let match = current.range(of: #"^\s*\d+\.\s+(.*)"#, options: .regularExpression) {
                        let content = String(current[match]).replacingOccurrences(
                            of: #"^\s*\d+\.\s+"#,
                            with: "",
                            options: .regularExpression
                        )
                        items.append(content)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items: items, ordered: ordered))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let current = lines[index]
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```")
                    || (index + 1 < lines.count
                        && parseMarkdownTableRow(current) != nil
                        && isMarkdownTableSeparator(lines[index + 1], expectedColumnCount: parseMarkdownTableRow(current)?.count ?? 0))
                    || trimmed.range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil {
                    break
                }
                paragraphLines.append(current)
                index += 1
            }
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(text: paragraphLines.joined(separator: "\n")))
            }
        }

        return blocks
    }

    static func styleSource(
        text: String,
        storage: NSTextStorage,
        fontSize: CGFloat,
        theme: MarkdownTheme,
        displayMode: MarkdownEditorDisplayMode,
        selectedRange: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let headingFonts: [Int: NSFont] = [
            1: .systemFont(ofSize: fontSize + 9, weight: .bold),
            2: .systemFont(ofSize: fontSize + 5, weight: .bold),
            3: .systemFont(ofSize: fontSize + 2, weight: .semibold),
        ]
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(fontSize - 1, 12), weight: .regular)
        let hiddenMarkerFont = NSFont.systemFont(ofSize: 0.1)
        let nsText = text as NSString

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: theme.primaryTextColor,
        ], range: fullRange)

        if displayMode == .source {
            storage.endEditing()
            return
        }

        let activeLineRange = selectedRange.flatMap { range -> NSRange? in
            guard range.location != NSNotFound else { return nil }
            return nsText.lineRange(for: NSRange(location: min(range.location, nsText.length), length: 0))
        }
        let activeMarkerColor = theme.syntaxMarkerColor.withAlphaComponent(0.82)

        func isActiveMarker(_ range: NSRange) -> Bool {
            guard let activeLineRange else { return false }
            return NSIntersectionRange(activeLineRange, range).length > 0
        }

        func markerAttributes(for range: NSRange, base: NSFont = baseFont) -> [NSAttributedString.Key: Any] {
            if isActiveMarker(range) {
                return [
                    .foregroundColor: activeMarkerColor,
                    .font: base,
                    .kern: 0,
                ]
            }
            return [
                .foregroundColor: NSColor.clear,
                .font: hiddenMarkerFont,
                .kern: -CGFloat(range.length) * max(fontSize * 0.55, 6),
            ]
        }

        var codeBlockRanges: [NSRange] = []
        var offset = 0
        var insideCodeBlock = false
        for line in text.components(separatedBy: "\n") {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: offset, length: lineLength)
            let fullLineRange = NSRange(location: offset, length: lineLength + (offset + lineLength < nsText.length ? 1 : 0))

            if line.hasPrefix("```") || insideCodeBlock {
                storage.addAttributes([
                    .font: monoFont,
                    .foregroundColor: theme.codeTextColor,
                    .backgroundColor: theme.codeBackgroundColor,
                ], range: lineRange)
                codeBlockRanges.append(fullLineRange)
            }

            if line.hasPrefix("```") {
                storage.addAttributes(markerAttributes(for: lineRange, base: monoFont), range: lineRange)
                insideCodeBlock.toggle()
                offset += lineLength + 1
                continue
            }

            if insideCodeBlock {
                offset += lineLength + 1
                continue
            }

            if let match = line.range(of: #"^(#{1,3})(\s+)(.+)$"#, options: .regularExpression) {
                let full = String(line[match]) as NSString
                let markerCount = full.range(of: #"^#{1,3}"#, options: .regularExpression).length
                let markerRange = NSRange(location: offset, length: markerCount)
                let contentLocation = offset + markerCount + 1
                let contentLength = max(0, lineLength - markerCount - 1)
                storage.addAttributes(markerAttributes(for: markerRange), range: markerRange)
                storage.addAttributes([
                    .font: headingFonts[markerCount] ?? baseFont,
                    .foregroundColor: theme.headingColor,
                ], range: NSRange(location: contentLocation, length: contentLength))
            } else if line.hasPrefix(">") {
                let prefixRange = NSRange(location: offset, length: 1)
                storage.addAttributes(markerAttributes(for: prefixRange), range: prefixRange)
                storage.addAttributes([
                    .foregroundColor: theme.blockquoteColor,
                    .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask),
                ], range: NSRange(location: min(offset + 1, offset + lineLength), length: max(0, lineLength - 1)))
            } else if line.range(of: #"^\s*[-*]\s+\S"#, options: .regularExpression) != nil,
                      let bulletRange = (line as NSString).range(of: #"^\s*[-*]\s+"#, options: .regularExpression).toOptional() {
                let absoluteRange = NSRange(location: offset + bulletRange.location, length: bulletRange.length)
                storage.addAttributes(markerAttributes(for: absoluteRange), range: absoluteRange)
            } else if line.range(of: #"^\s*\d+\.\s+\S"#, options: .regularExpression) != nil,
                      let bulletRange = (line as NSString).range(of: #"^\s*\d+\.\s+"#, options: .regularExpression).toOptional() {
                let absoluteRange = NSRange(location: offset + bulletRange.location, length: bulletRange.length)
                storage.addAttributes(markerAttributes(for: absoluteRange), range: absoluteRange)
            } else if line.trimmingCharacters(in: .whitespaces).range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil {
                storage.addAttributes(markerAttributes(for: lineRange), range: lineRange)
            }

            offset += lineLength + 1
        }

        applyInlinePattern(#"`([^`\n]+)`"#, in: storage, text: text, excluded: codeBlockRanges) { match in
            [
                (match.range(at: 0), [.font: monoFont, .backgroundColor: theme.codeBackgroundColor, .foregroundColor: theme.codeTextColor]),
                (NSRange(location: match.range.location, length: 1), markerAttributes(for: NSRange(location: match.range.location, length: 1), base: monoFont)),
                (NSRange(location: match.range.location + match.range.length - 1, length: 1), markerAttributes(for: NSRange(location: match.range.location + match.range.length - 1, length: 1), base: monoFont)),
            ]
        }

        applyInlinePattern(#"\*\*([^\*\n]+)\*\*"#, in: storage, text: text, excluded: codeBlockRanges) { match in
            let inner = match.range(at: 1)
            let leading = NSRange(location: match.range.location, length: 2)
            let trailing = NSRange(location: match.range.location + match.range.length - 2, length: 2)
            return [
                (leading, markerAttributes(for: leading)),
                (trailing, markerAttributes(for: trailing)),
                (inner, [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: theme.primaryTextColor]),
            ]
        }

        applyInlinePattern(#"(?<!\*)\*([^\*\n]+)\*(?!\*)"#, in: storage, text: text, excluded: codeBlockRanges) { match in
            let leading = NSRange(location: match.range.location, length: 1)
            let trailing = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            return [
                (leading, markerAttributes(for: leading)),
                (trailing, markerAttributes(for: trailing)),
                (match.range(at: 1), [
                    .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask),
                    .foregroundColor: theme.primaryTextColor,
                ]),
            ]
        }

        applyInlinePattern(#"\[([^\]]+)\]\(([^)]+)\)"#, in: storage, text: text, excluded: codeBlockRanges) { match in
            let full = match.range(at: 0)
            let label = match.range(at: 1)
            let url = match.range(at: 2)
            let leading = NSRange(location: full.location, length: 1)
            let middle = NSRange(location: label.location + label.length, length: 3)
            let trailing = NSRange(location: full.location + full.length - 1, length: 1)
            return [
                (leading, markerAttributes(for: leading)),
                (middle, markerAttributes(for: middle)),
                (trailing, markerAttributes(for: trailing)),
                (label, [.foregroundColor: theme.accentColor, .underlineStyle: NSUnderlineStyle.single.rawValue]),
                (url, markerAttributes(for: url)),
            ]
        }

        storage.endEditing()
    }

    static func fallbackAttributed(for block: MarkdownBlock, theme: MarkdownTheme = .dark) -> AttributedString {
        switch block {
        case .code(_, let content):
            var attr = AttributedString(content)
            attr.font = .system(size: 12).monospaced()
            attr.foregroundColor = Color(theme.codeTextColor)
            return attr
        case .table(let rows):
            return AttributedString(rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))
        case .rule:
            var rule = AttributedString("────────────────────────")
            rule.foregroundColor = Color(theme.secondaryTextColor)
            return rule
        default:
            return AttributedString("")
        }
    }

    static func parseMarkdownTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        let rawCells: [Substring]
        if trimmed.hasPrefix("|") || trimmed.hasSuffix("|") {
            rawCells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst(trimmed.hasPrefix("|") ? 1 : 0)
                .dropLast(trimmed.hasSuffix("|") ? 1 : 0)
        } else {
            rawCells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        }

        let cells = rawCells.map { String($0).trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2, cells.contains(where: { !$0.isEmpty }) else { return nil }
        return cells
    }

    static func isMarkdownTableSeparator(_ line: String, expectedColumnCount: Int) -> Bool {
        guard expectedColumnCount >= 2,
              let cells = parseMarkdownTableRow(line),
              cells.count == expectedColumnCount else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            return trimmed.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func normalizeMarkdownTableRows(_ rows: [[String]]) -> [[String]] {
        let maxColumns = rows.map(\.count).max() ?? 0
        guard maxColumns > 0 else { return rows }
        return rows.map { row in
            row + Array(repeating: "", count: max(0, maxColumns - row.count))
        }
    }

    static func shouldUseLightweightTableFallback(rows: [[String]]) -> Bool {
        let rowCount = rows.count
        let columnCount = rows.map(\.count).max() ?? 0
        let cellCount = rows.reduce(0) { $0 + $1.count }
        let characterCount = rows.flatMap { $0 }.reduce(0) { $0 + $1.count }
        return rowCount > 20 || columnCount > 8 || cellCount > 120 || characterCount > 3_000
    }

    static func preferredTableColumnWidths(rows: [[String]]) -> [CGFloat] {
        let maxColumns = rows.map(\.count).max() ?? 0
        guard maxColumns > 0 else { return [] }
        return (0..<maxColumns).map { column in
            let maxChars = rows.reduce(0) { width, row in
                max(width, row[column].replacingOccurrences(of: "\n", with: " ").count)
            }
            let clampedChars = min(max(maxChars, 8), 28)
            return CGFloat(clampedChars) * 7.2
        }
    }

    static func lightweightTableText(rows: [[String]]) -> String {
        let maxColumns = rows.map(\.count).max() ?? 0
        guard maxColumns > 0 else { return "" }

        let paddedRows = normalizeMarkdownTableRows(rows)
        let columnWidths = (0..<maxColumns).map { column in
            paddedRows.reduce(1) { width, row in
                max(width, min(28, row[column].count))
            }
        }

        func clipped(_ text: String, width: Int) -> String {
            guard text.count > width else { return text }
            guard width > 1 else { return String(text.prefix(width)) }
            return String(text.prefix(width - 1)) + "…"
        }

        func renderRow(_ row: [String]) -> String {
            row.enumerated().map { index, cell in
                let width = columnWidths[index]
                let value = clipped(cell.replacingOccurrences(of: "\n", with: " "), width: width)
                return value.padding(toLength: width, withPad: " ", startingAt: 0)
            }
            .joined(separator: " | ")
        }

        var lines: [String] = []
        if let header = paddedRows.first {
            lines.append(renderRow(header))
            let separator = columnWidths.map { String(repeating: "-", count: max(3, $0)) }.joined(separator: "-|-")
            lines.append(separator)
            for row in paddedRows.dropFirst() { lines.append(renderRow(row)) }
        }
        return lines.joined(separator: "\n")
    }

    private static func headingFontSize(level: Int, baseFontSize: CGFloat) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 9
        case 2: return baseFontSize + 5
        default: return baseFontSize + 2
        }
    }

    private static func applyInlinePattern(
        _ pattern: String,
        in storage: NSTextStorage,
        text: String,
        excluded: [NSRange],
        attributes: (NSTextCheckingResult) -> [(NSRange, [NSAttributedString.Key: Any])]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let fullMatch = match.range(at: 0)
            guard !excluded.contains(where: { NSIntersectionRange(fullMatch, $0).length > 0 }) else { return }
            for (range, attrs) in attributes(match) where range.location != NSNotFound && range.length > 0 {
                storage.addAttributes(attrs, range: range)
            }
        }
    }
}

private extension NSRange {
    func toOptional() -> NSRange? {
        location == NSNotFound ? nil : self
    }
}

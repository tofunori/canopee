import AppKit
import SwiftUI

struct MarkdownEditorPreviewView: View {
    let text: String

    private var blocks: [MarkdownBlockView.Block] {
        markdownCache.blocks(for: text)
    }

    var body: some View {
        ScrollView {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Aperçu Markdown",
                    systemImage: "doc.richtext",
                    description: Text("Écris du Markdown pour voir le rendu.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, isFirst: index == 0)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
        .background(AppChromePalette.surfaceBar)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlockView.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text, isFirst: isFirst)
        case .paragraph(let text):
            paragraphView(text: text)
        case .list(let items, let ordered):
            listView(items: items, ordered: ordered)
        case .blockquote(let text):
            blockquoteView(text: text)
        case .code(let language, let content):
            codeBlockView(language: language, content: content)
        case .table(let rows):
            tableView(rows: rows)
        case .rule:
            Divider()
                .overlay(AppChromePalette.dividerSoft)
                .padding(.vertical, 2)
        case .insight(let lines):
            insightView(lines: lines)
        }
    }

    private func headingView(level: Int, text: String, isFirst: Bool) -> some View {
        let size: CGFloat = switch level {
        case 1: 24
        case 2: 19
        default: 16
        }

        return VStack(alignment: .leading, spacing: level <= 2 ? 8 : 4) {
            Text(inlineMarkdown(text))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)

            if level <= 2 {
                Rectangle()
                    .fill(level == 1 ? Color.orange.opacity(0.28) : AppChromePalette.dividerSoft)
                    .frame(height: 1)
            }
        }
        .padding(.top, isFirst ? 0 : (level == 1 ? 8 : 4))
    }

    private func paragraphView(text: String) -> some View {
        Text(inlineMarkdown(text))
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func listView(items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.orange)
                        .frame(width: 18, alignment: .trailing)

                    Text(inlineMarkdown(item))
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func blockquoteView(text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.orange.opacity(0.65))
                .frame(width: 3)

            Text(inlineMarkdown(text))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .italic()
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppChromePalette.surfaceSubbar.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
        )
    }

    private func insightView(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Insight", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(inlineMarkdown(line))
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func codeBlockView(language: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.codeHeaderFill)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: content)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Self.codeForeground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Self.codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Self.codeBorder, lineWidth: 0.5)
        )
    }

    private func tableView(rows: [[String]]) -> some View {
        let normalizedRows = normalizeTableRows(rows)
        let columnWidths = preferredTableColumnWidths(rows: normalizedRows)

        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                            Text(verbatim: cell)
                                .font(.system(size: 12.5, weight: rowIndex == 0 ? .semibold : .regular))
                                .foregroundStyle(rowIndex == 0 ? .primary : .secondary)
                                .frame(width: columnWidths[columnIndex], alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(rowIndex == 0 ? AppChromePalette.surfaceBar.opacity(0.95) : Color.clear)

                            if columnIndex < row.count - 1 {
                                Divider()
                                    .overlay(AppChromePalette.dividerSoft)
                            }
                        }
                    }

                    if rowIndex < normalizedRows.count - 1 {
                        Divider()
                            .overlay(AppChromePalette.dividerSoft)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppChromePalette.surfaceSubbar.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
        )
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        InlineMarkdownCache.shared.get(text)
    }

    private func normalizeTableRows(_ rows: [[String]]) -> [[String]] {
        let maxColumns = rows.map(\.count).max() ?? 0
        guard maxColumns > 0 else { return rows }
        return rows.map { row in
            row + Array(repeating: "", count: max(0, maxColumns - row.count))
        }
    }

    private func preferredTableColumnWidths(rows: [[String]]) -> [CGFloat] {
        let maxColumns = rows.map(\.count).max() ?? 0
        guard maxColumns > 0 else { return [] }
        return (0..<maxColumns).map { column in
            let maxChars = rows.reduce(0) { width, row in
                max(width, row[column].replacingOccurrences(of: "\n", with: " ").count)
            }
            let clampedChars = min(max(maxChars, 10), 30)
            return CGFloat(clampedChars) * 7.4
        }
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
                return bestMatch == .darkAqua ? dark : light
            }
        )
    }

    private static let codeBackground = adaptiveColor(
        light: NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.99, alpha: 1),
        dark: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1)
    )

    private static let codeHeaderFill = adaptiveColor(
        light: NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.17, alpha: 1)
    )

    private static let codeBorder = adaptiveColor(
        light: NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.93, alpha: 1),
        dark: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.31, alpha: 1)
    )

    private static let codeForeground = adaptiveColor(
        light: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1),
        dark: NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.97, alpha: 1)
    )
}

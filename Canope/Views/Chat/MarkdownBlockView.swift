import SwiftUI

// MARK: - Markdown Block Renderer

let markdownCache = MarkdownFormattingCache()

struct MarkdownBlockView: View {
    typealias Block = MarkdownBlock
    typealias BlockGroup = MarkdownFormatter.BlockGroup

    let text: String

    private var blocks: [Block] { markdownCache.blocks(for: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let groups = MarkdownFormatter.groupBlocks(blocks)
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                switch group {
                case .textRun(let segments):
                    Text(markdownCache.attributedString(for: text, segments: segments, groupIndex: groupIndex) {
                        MarkdownFormatter.buildAttributedString(segments: segments)
                    })
                    .font(.system(size: 13))
                    .textSelection(.enabled)

                case .special(let block):
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .code(let language, let content):
            codeBlockView(language: language, content: content)
        case .table(let rows):
            tableView(rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        case .insight(let lines):
            insightView(lines: lines)
        case .paragraph(let text):
            paragraphView(text: text)
        case .list, .blockquote:
            EmptyView()
        }
    }

    private func insightView(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("★ Insight ─────────────────────────────────────")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.purple)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(MarkdownFormatter.inlineMarkdown(line))
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
        return Text(MarkdownFormatter.inlineMarkdown(text))
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
        let normalizedRows = rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        return Group {
            if MarkdownFormatter.shouldUseLightweightTableFallback(rows: normalizedRows) {
                lightweightTableView(rows: normalizedRows)
            } else {
                let columnWidths = MarkdownFormatter.preferredTableColumnWidths(rows: normalizedRows)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                                    Text(verbatim: cell)
                                        .font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                                        .foregroundStyle(rowIndex == 0 ? .primary : .secondary)
                                        .frame(width: columnWidths[columnIndex], alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(rowIndex == 0 ? AppChromePalette.surfaceBar.opacity(0.45) : Color.clear)
                                    if columnIndex < row.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            if rowIndex < normalizedRows.count - 1 {
                                Divider()
                            }
                        }
                    }
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

    private func lightweightTableView(rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: MarkdownFormatter.lightweightTableText(rows: rows))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func paragraphView(text: String) -> some View {
        Text(MarkdownFormatter.inlineMarkdown(text))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
    }

    nonisolated static func parseBlocks(_ text: String) -> [Block] {
        MarkdownFormatter.parseBlocks(text)
    }

    @MainActor
    static func attributedPreview(for text: String) -> AttributedString {
        MarkdownFormatter.attributedPreview(for: text, cache: markdownCache)
    }

    nonisolated static func renderAttributedPreviewForBackground(_ text: String) -> AttributedString {
        MarkdownFormatter.renderAttributedPreviewForBackground(text)
    }
}

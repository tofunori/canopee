import Foundation
import diff_match_patch

enum LineDiffType: Equatable {
    case unchanged
    case added
    case removed
    case modified(oldLine: String)
}

struct TextDiffSegment: Equatable {
    let oldRange: Range<Int>
    let newRange: Range<Int>
}

enum TextDiffBlockKind: Equatable {
    case added
    case removed
    case modified
}

struct TextDiffBlock: Identifiable, Equatable {
    let id = UUID()
    let startLine: Int
    let endLine: Int
    let oldLineRange: Range<Int>
    let newLineRange: Range<Int>
    let oldLines: [String]
    let newLines: [String]
    let kind: TextDiffBlockKind
}

struct InlineDiffPresentation: Equatable {
    struct DeletedWidget: Equatable {
        let anchorOffset: Int
        let text: String
    }

    let insertedRanges: [NSRange]
    let deletedWidgets: [DeletedWidget]
}

enum ReviewInlineSpanKind: Equatable {
    case equal
    case insert
    case delete
}

struct ReviewInlineSpan: Equatable {
    let kind: ReviewInlineSpanKind
    let text: String
}

struct ReviewDiffRow: Equatable {
    enum Kind: Equatable {
        case added
        case removed
        case modified
    }

    let kind: Kind
    let oldLineOffset: Int?
    let newLineOffset: Int?
    let oldSpans: [ReviewInlineSpan]
    let newSpans: [ReviewInlineSpan]
    let revealColumn: Int
    let revealLength: Int
}

struct ReviewDiffBlock: Identifiable, Equatable {
    let block: TextDiffBlock
    let rows: [ReviewDiffRow]
    let preferredRevealLine: Int
    let preferredRevealColumn: Int
    let preferredRevealLength: Int

    var id: String {
        [
            String(block.startLine),
            String(block.endLine),
            String(block.oldLineRange.lowerBound),
            String(block.oldLineRange.upperBound),
            String(block.newLineRange.lowerBound),
            String(block.newLineRange.upperBound),
            String(describing: block.kind),
        ].joined(separator: ":")
    }
}

struct LineDiff: Identifiable, Equatable {
    let id = UUID()
    let lineNumber: Int
    let type: LineDiffType
    let text: String

    static func == (lhs: LineDiff, rhs: LineDiff) -> Bool {
        lhs.lineNumber == rhs.lineNumber && lhs.type == rhs.type && lhs.text == rhs.text
    }
}

struct DiffEngine {
    struct LineDocument: Equatable {
        let lines: [String]
        let endsWithNewline: Bool

        static func parse(_ text: String) -> LineDocument {
            let nsText = text as NSString
            guard nsText.length > 0 else {
                return LineDocument(lines: [], endsWithNewline: false)
            }

            var lines: [String] = []
            var index = 0

            while index < nsText.length {
                var lineStart = 0
                var lineEnd = 0
                var contentsEnd = 0
                nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
                let contentRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
                lines.append(nsText.substring(with: contentRange))
                index = lineEnd
            }

            let endsWithNewline = nsText.character(at: nsText.length - 1) == 0x0A
            return LineDocument(lines: lines, endsWithNewline: endsWithNewline)
        }

        func replacingLines(in range: Range<Int>, with replacement: [String]) -> String {
            var updatedLines = lines
            let lowerBound = min(max(range.lowerBound, 0), updatedLines.count)
            let upperBound = min(max(range.upperBound, lowerBound), updatedLines.count)
            updatedLines.replaceSubrange(lowerBound..<upperBound, with: replacement)
            return LineDocument(lines: updatedLines, endsWithNewline: endsWithNewline).string
        }

        var string: String {
            let joined = lines.joined(separator: "\n")
            guard endsWithNewline else { return joined }
            return joined + "\n"
        }
    }

    static func lineSegments(old: [String], new: [String]) -> [TextDiffSegment] {
        let dp = lcsMatrix(old: old, new: new)
        var segments: [TextDiffSegment] = []
        var i = 0
        var j = 0
        var oldStart: Int?
        var newStart: Int?

        func flush(upToOld oldEnd: Int, newEnd: Int) {
            guard let oldStart, let newStart else { return }
            segments.append(TextDiffSegment(oldRange: oldStart..<oldEnd, newRange: newStart..<newEnd))
            selfReset()
        }

        func selfReset() {
            oldStart = nil
            newStart = nil
        }

        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                flush(upToOld: i, newEnd: j)
                i += 1
                j += 1
            } else if j < new.count, i < old.count {
                if oldStart == nil {
                    oldStart = i
                    newStart = j
                }
                if dp[i][j + 1] >= dp[i + 1][j] {
                    j += 1
                } else {
                    i += 1
                }
            } else if j < new.count {
                if oldStart == nil {
                    oldStart = i
                    newStart = j
                }
                j += 1
            } else if i < old.count {
                if oldStart == nil {
                    oldStart = i
                    newStart = j
                }
                i += 1
            }
        }

        flush(upToOld: i, newEnd: j)
        return segments
    }

    static func blocks(old: String, new: String) -> [TextDiffBlock] {
        let oldDocument = LineDocument.parse(old)
        let newDocument = LineDocument.parse(new)
        let oldLines = oldDocument.lines
        let newLines = newDocument.lines

        return lineSegments(old: oldLines, new: newLines).compactMap { segment in
            let removedLines = Array(oldLines[segment.oldRange])
            let addedLines = Array(newLines[segment.newRange])
            guard !removedLines.isEmpty || !addedLines.isEmpty else { return nil }

            let kind: TextDiffBlockKind
            if removedLines.isEmpty {
                kind = .added
            } else if addedLines.isEmpty {
                kind = .removed
            } else {
                kind = .modified
            }

            let fallbackLineCount = max(newLines.count, 1)
            let anchorLine = max(1, min(segment.newRange.lowerBound + 1, fallbackLineCount))
            let span = max(removedLines.count, addedLines.count, 1)

            return TextDiffBlock(
                startLine: anchorLine,
                endLine: max(anchorLine, anchorLine + span - 1),
                oldLineRange: segment.oldRange,
                newLineRange: segment.newRange,
                oldLines: removedLines,
                newLines: addedLines,
                kind: kind
            )
        }
    }

    static func replacingOldBlock(in baselineText: String, with block: TextDiffBlock) -> String {
        LineDocument.parse(baselineText).replacingLines(in: block.oldLineRange, with: block.newLines)
    }

    static func replacingNewBlock(in currentText: String, with block: TextDiffBlock) -> String {
        LineDocument.parse(currentText).replacingLines(in: block.newLineRange, with: block.oldLines)
    }

    static func reviewBlocks(old: String, new: String) -> [ReviewDiffBlock] {
        blocks(old: old, new: new).map(reviewBlock(for:))
    }

    static func reviewBlock(for block: TextDiffBlock) -> ReviewDiffBlock {
        let rows: [ReviewDiffRow]
        switch block.kind {
        case .added:
            rows = block.newLines.enumerated().map { offset, line in
                ReviewDiffRow(
                    kind: .added,
                    oldLineOffset: nil,
                    newLineOffset: offset,
                    oldSpans: [],
                    newSpans: [.init(kind: .insert, text: line)],
                    revealColumn: 0,
                    revealLength: max(1, min((line as NSString).length, 24))
                )
            }
        case .removed:
            rows = block.oldLines.enumerated().map { offset, line in
                ReviewDiffRow(
                    kind: .removed,
                    oldLineOffset: offset,
                    newLineOffset: nil,
                    oldSpans: [.init(kind: .delete, text: line)],
                    newSpans: [],
                    revealColumn: 0,
                    revealLength: 1
                )
            }
        case .modified:
            if block.oldLines.count == block.newLines.count {
                rows = zip(block.oldLines.enumerated(), block.newLines.enumerated()).map { oldEntry, newEntry in
                    let oldLine = oldEntry.element
                    let newLine = newEntry.element
                    let spans = reviewInlineSpans(old: oldLine, new: newLine)
                    let presentation = inlinePresentation(old: oldLine, new: newLine)
                    let revealColumn = presentation.insertedRanges.first?.location
                        ?? presentation.deletedWidgets.first?.anchorOffset
                        ?? 0
                    let revealLength = max(
                        1,
                        min(presentation.insertedRanges.first?.length ?? 1, 24)
                    )

                    return ReviewDiffRow(
                        kind: .modified,
                        oldLineOffset: oldEntry.offset,
                        newLineOffset: newEntry.offset,
                        oldSpans: spans.old,
                        newSpans: spans.new,
                        revealColumn: revealColumn,
                        revealLength: revealLength
                    )
                }
            } else {
                let removedRows = block.oldLines.enumerated().map { offset, line in
                    ReviewDiffRow(
                        kind: .removed,
                        oldLineOffset: offset,
                        newLineOffset: nil,
                        oldSpans: [.init(kind: .delete, text: line)],
                        newSpans: [],
                        revealColumn: 0,
                        revealLength: 1
                    )
                }
                let addedRows = block.newLines.enumerated().map { offset, line in
                    ReviewDiffRow(
                        kind: .added,
                        oldLineOffset: nil,
                        newLineOffset: offset,
                        oldSpans: [],
                        newSpans: [.init(kind: .insert, text: line)],
                        revealColumn: 0,
                        revealLength: max(1, min((line as NSString).length, 24))
                    )
                }
                rows = removedRows + addedRows
            }
        }

        let preferredRow = rows.first(where: { $0.newLineOffset != nil }) ?? rows.first
        let preferredRevealLine: Int
        if let newLineOffset = preferredRow?.newLineOffset {
            preferredRevealLine = block.newLineRange.lowerBound + newLineOffset + 1
        } else {
            preferredRevealLine = max(block.startLine, 1)
        }

        return ReviewDiffBlock(
            block: block,
            rows: rows,
            preferredRevealLine: preferredRevealLine,
            preferredRevealColumn: preferredRow?.revealColumn ?? 0,
            preferredRevealLength: preferredRow?.revealLength ?? 1
        )
    }

    static func inlinePresentation(old: String, new: String) -> InlineDiffPresentation {
        guard old != new else {
            return InlineDiffPresentation(insertedRanges: [], deletedWidgets: [])
        }

        guard let diffs = semanticDiffs(old: old, new: new) else {
            return InlineDiffPresentation(insertedRanges: [], deletedWidgets: [])
        }

        var insertedRanges: [NSRange] = []
        var deletedWidgets: [InlineDiffPresentation.DeletedWidget] = []
        var oldOffset = 0
        var newOffset = 0

        for diff in diffs {
            let text = diff.text ?? ""
            let utf16Length = (text as NSString).length
            guard utf16Length > 0 else { continue }

            switch diff.operation {
            case DIFF_EQUAL:
                oldOffset += utf16Length
                newOffset += utf16Length
            case DIFF_INSERT:
                insertedRanges.append(NSRange(location: newOffset, length: utf16Length))
                newOffset += utf16Length
            case DIFF_DELETE:
                if let lastIndex = deletedWidgets.indices.last,
                   deletedWidgets[lastIndex].anchorOffset == newOffset {
                    let last = deletedWidgets[lastIndex]
                    deletedWidgets[lastIndex] = .init(
                        anchorOffset: last.anchorOffset,
                        text: last.text + text
                    )
                } else {
                    deletedWidgets.append(.init(anchorOffset: newOffset, text: text))
                }
                oldOffset += utf16Length
            default:
                oldOffset += utf16Length
                newOffset += utf16Length
            }
        }

        return InlineDiffPresentation(
            insertedRanges: insertedRanges,
            deletedWidgets: deletedWidgets
        )
    }

    static func reviewInlineSpans(old: String, new: String) -> (old: [ReviewInlineSpan], new: [ReviewInlineSpan]) {
        guard let diffs = semanticDiffs(old: old, new: new) else {
            return (
                old: old.isEmpty ? [] : [.init(kind: .equal, text: old)],
                new: new.isEmpty ? [] : [.init(kind: .equal, text: new)]
            )
        }

        var oldSpans: [ReviewInlineSpan] = []
        var newSpans: [ReviewInlineSpan] = []

        for diff in diffs {
            let text = diff.text ?? ""
            guard !text.isEmpty else { continue }

            switch diff.operation {
            case DIFF_EQUAL:
                appendReviewSpan(.init(kind: .equal, text: text), to: &oldSpans)
                appendReviewSpan(.init(kind: .equal, text: text), to: &newSpans)
            case DIFF_INSERT:
                appendReviewSpan(.init(kind: .insert, text: text), to: &newSpans)
            case DIFF_DELETE:
                appendReviewSpan(.init(kind: .delete, text: text), to: &oldSpans)
            default:
                appendReviewSpan(.init(kind: .equal, text: text), to: &oldSpans)
                appendReviewSpan(.init(kind: .equal, text: text), to: &newSpans)
            }
        }

        return (oldSpans, newSpans)
    }

    /// Compare old and new text, return diffs indexed by new line numbers.
    static func diff(old: String, new: String) -> [LineDiff] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        let lcs = longestCommonSubsequence(oldLines, newLines)

        var diffs: [LineDiff] = []
        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            if oldIdx < oldLines.count && newIdx < newLines.count
                && lcsIdx < lcs.count && oldLines[oldIdx] == lcs[lcsIdx] && newLines[newIdx] == lcs[lcsIdx] {
                // Unchanged line
                diffs.append(LineDiff(lineNumber: newIdx + 1, type: .unchanged, text: newLines[newIdx]))
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            } else if newIdx < newLines.count
                && (lcsIdx >= lcs.count || newLines[newIdx] != lcs[lcsIdx]) {
                if oldIdx < oldLines.count && (lcsIdx >= lcs.count || oldLines[oldIdx] != lcs[lcsIdx]) {
                    // Modified line (old replaced by new)
                    diffs.append(LineDiff(lineNumber: newIdx + 1, type: .modified(oldLine: oldLines[oldIdx]), text: newLines[newIdx]))
                    oldIdx += 1
                    newIdx += 1
                } else {
                    // Added line
                    diffs.append(LineDiff(lineNumber: newIdx + 1, type: .added, text: newLines[newIdx]))
                    newIdx += 1
                }
            } else if oldIdx < oldLines.count
                && (lcsIdx >= lcs.count || oldLines[oldIdx] != lcs[lcsIdx]) {
                // Removed line — mark at current new position
                diffs.append(LineDiff(lineNumber: newIdx + 1, type: .removed, text: oldLines[oldIdx]))
                oldIdx += 1
            } else {
                break
            }
        }

        return diffs
    }

    /// Count of changed lines (added + modified + removed)
    static func changeCount(_ diffs: [LineDiff]) -> Int {
        diffs.filter { $0.type != .unchanged }.count
    }

    /// Get changed line numbers for gutter markers
    static func changedLineNumbers(_ diffs: [LineDiff]) -> [Int: LineDiffType] {
        var result: [Int: LineDiffType] = [:]
        for d in diffs where d.type != .unchanged {
            result[d.lineNumber] = d.type
        }
        return result
    }

    // MARK: - LCS Algorithm

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...max(m, 1) {
            for j in 1...max(n, 1) {
                guard i <= m, j <= n else { continue }
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return result.reversed()
    }

    fileprivate static func lcsMatrix(old: [String], new: [String]) -> [[Int]] {
        let oldCount = old.count
        let newCount = new.count
        var dp = Array(repeating: Array(repeating: 0, count: newCount + 1), count: oldCount + 1)

        guard oldCount > 0, newCount > 0 else { return dp }

        for i in stride(from: oldCount - 1, through: 0, by: -1) {
            for j in stride(from: newCount - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        return dp
    }

    private static func semanticDiffs(old: String, new: String) -> [Diff]? {
        let dmp = DiffMatchPatch()
        let mutableDiffs = dmp.diff_main(ofOldString: old, andNewString: new)
        dmp.diff_cleanupSemantic(mutableDiffs)
        return mutableDiffs as? [Diff]
    }

    private static func appendReviewSpan(_ span: ReviewInlineSpan, to spans: inout [ReviewInlineSpan]) {
        guard !span.text.isEmpty else { return }
        if let lastIndex = spans.indices.last, spans[lastIndex].kind == span.kind {
            spans[lastIndex] = .init(kind: span.kind, text: spans[lastIndex].text + span.text)
        } else {
            spans.append(span)
        }
    }
}

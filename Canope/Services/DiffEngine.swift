import Foundation

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
    let oldLines: [String]
    let newLines: [String]
    let kind: TextDiffBlockKind
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
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

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
            let span = max(addedLines.count, 1)

            return TextDiffBlock(
                startLine: anchorLine,
                endLine: max(anchorLine, anchorLine + span - 1),
                oldLines: removedLines,
                newLines: addedLines,
                kind: kind
            )
        }
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
}

import Foundation

enum LineDiffType: Equatable {
    case unchanged
    case added
    case removed
    case modified(oldLine: String)
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
}

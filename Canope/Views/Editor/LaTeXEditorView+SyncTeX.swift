import SwiftUI

// MARK: - SyncTeX & Editor Navigation

extension LaTeXEditorView {
    func forwardSync(line: Int) {
        let pdfPath = fileURL.deletingPathExtension().appendingPathExtension("pdf").path
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        let texFile = fileURL.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = SyncTeXService.forwardSync(line: line, texFile: texFile, pdfPath: pdfPath) {
                DispatchQueue.main.async {
                    syncTarget = result
                    // Clear after a moment so it can be re-triggered
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        syncTarget = nil
                    }
                }
            }
        }
    }

    func scrollEditorToLine(_ lineNumber: Int, selectingLine: Bool = true) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += (lines[i] as NSString).length + 1
        }
        let lineLength = (lines[lineNumber - 1] as NSString).length
        let range = NSRange(location: charOffset, length: lineLength)
        NotificationCenter.default.post(
            name: .syncTeXScrollToLine,
            object: nil,
            userInfo: [
                "range": range,
                "select": selectingLine,
            ]
        )
    }

    func scrollEditorToInverseSyncResult(_ result: SyncTeXInverseResult) {
        let lines = text.components(separatedBy: "\n")
        guard result.line > 0 && result.line <= lines.count else { return }

        let lineText = lines[result.line - 1]
        let lineNSString = lineText as NSString
        let column = resolvedInverseSyncColumn(in: lineText, result: result)
        let clampedColumn = min(max(column, 0), lineNSString.length)
        revealEditorLocationForLine(
            result.line,
            columnOffset: clampedColumn,
            highlightLength: inverseSyncHighlightLength(in: lineText, result: result)
        )
    }

    func resolvedInverseSyncColumn(in lineText: String, result: SyncTeXInverseResult) -> Int {
        let lineNSString = lineText as NSString
        if let column = result.column, column >= 0 {
            return min(column, lineNSString.length)
        }

        guard let context = result.context?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              context.isEmpty == false,
              let offset = result.offset,
              offset >= 0 else {
            return 0
        }

        if let fullContextRange = lineText.range(of: context, options: [.caseInsensitive]) {
            let utf16Range = NSRange(fullContextRange, in: lineText)
            return min(utf16Range.location + offset, lineNSString.length)
        }

        let anchor = syncHintAnchor(in: context, offset: offset)
        if anchor.isEmpty == false,
           let anchorRange = lineText.range(of: anchor, options: [.caseInsensitive]) {
            return NSRange(anchorRange, in: lineText).location
        }

        return 0
    }

    func syncHintAnchor(in context: String, offset: Int) -> String {
        let nsContext = context as NSString
        let length = nsContext.length
        guard length > 0 else { return "" }
        let clampedOffset = min(max(offset, 0), max(length - 1, 0))
        let wordSeparators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var start = clampedOffset
        var end = clampedOffset

        while start > 0 {
            let scalar = UnicodeScalar(nsContext.character(at: start - 1))
            if let scalar, wordSeparators.contains(scalar) { break }
            start -= 1
        }
        while end < length {
            let scalar = UnicodeScalar(nsContext.character(at: end))
            if let scalar, wordSeparators.contains(scalar) { break }
            end += 1
        }

        return nsContext.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    func inverseSyncHighlightLength(in lineText: String, result: SyncTeXInverseResult) -> Int {
        guard let context = result.context?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              context.isEmpty == false,
              let offset = result.offset,
              offset >= 0 else {
            return 1
        }

        let anchor = syncHintAnchor(in: context, offset: offset)
        guard anchor.isEmpty == false,
              let anchorRange = lineText.range(of: anchor, options: [.caseInsensitive]) else {
            return 1
        }

        return max(1, NSRange(anchorRange, in: lineText).length)
    }

    func revealEditorLocation(for group: DiffGroup) {
        revealEditorLocationForLine(
            max(group.preferredRevealLine, 1),
            columnOffset: group.preferredRevealColumn,
            highlightLength: group.preferredRevealLength
        )
    }

    func revealEditorLocationForLine(
        _ lineNumber: Int,
        columnOffset: Int = 0,
        highlightLength: Int = 1
    ) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += (lines[i] as NSString).length + 1
        }
        let lineNSString = lines[lineNumber - 1] as NSString
        let clampedColumnOffset = min(max(columnOffset, 0), lineNSString.length)
        NotificationCenter.default.post(
            name: .editorRevealLocation,
            object: nil,
            userInfo: [
                "location": charOffset + clampedColumnOffset,
                "length": max(1, highlightLength),
            ]
        )
    }
}

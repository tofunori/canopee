import Foundation

struct ClaudeIDESelectionState: Codable, Equatable {
    struct SelectionPoint: Codable, Equatable {
        let line: Int
        let character: Int
    }

    struct SelectionRange: Codable, Equatable {
        let start: SelectionPoint
        let end: SelectionPoint
    }

    let selection: SelectionRange
    let text: String
    let filePath: String

    static func make(text: String, fileURL: URL, range: NSRange) -> ClaudeIDESelectionState? {
        let nsText = text as NSString
        let normalizedRange = normalized(range, maxLength: nsText.length)
        guard normalizedRange.location != NSNotFound else { return nil }

        let startOffset = normalizedRange.location
        let endOffset = normalizedRange.location + normalizedRange.length

        return ClaudeIDESelectionState(
            selection: SelectionRange(
                start: point(forUTF16Offset: startOffset, in: nsText),
                end: point(forUTF16Offset: endOffset, in: nsText)
            ),
            text: normalizedRange.length > 0 ? nsText.substring(with: normalizedRange) : "",
            filePath: fileURL.path
        )
    }

    static func makeSnapshot(selectedText: String, fileURL: URL) -> ClaudeIDESelectionState {
        let nsText = selectedText as NSString

        return ClaudeIDESelectionState(
            selection: SelectionRange(
                start: SelectionPoint(line: 0, character: 0),
                end: point(forUTF16Offset: nsText.length, in: nsText)
            ),
            text: selectedText,
            filePath: fileURL.path
        )
    }

    private static func normalized(_ range: NSRange, maxLength: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }

        let location = min(max(range.location, 0), maxLength)
        let remainingLength = max(0, maxLength - location)
        let length = min(max(range.length, 0), remainingLength)
        return NSRange(location: location, length: length)
    }

    private static func point(forUTF16Offset offset: Int, in text: NSString) -> SelectionPoint {
        let clampedOffset = min(max(offset, 0), text.length)
        var line = 0
        var character = 0
        var index = 0

        while index < clampedOffset {
            if text.character(at: index) == 0x0A {
                line += 1
                character = 0
            } else {
                character += 1
            }
            index += 1
        }

        return SelectionPoint(line: line, character: character)
    }
}

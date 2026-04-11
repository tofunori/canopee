import Foundation
@preconcurrency import PDFKit

enum PDFPageTextFormatter {
    struct Options {
        let trimsPageText: Bool
        let skipsEmptyPages: Bool
        let appendsTrailingBlankLine: Bool

        static let chatAttachment = Options(
            trimsPageText: true,
            skipsEmptyPages: true,
            appendsTrailingBlankLine: false
        )

        static let paperContext = Options(
            trimsPageText: false,
            skipsEmptyPages: false,
            appendsTrailingBlankLine: true
        )
    }

    static func formattedText(from document: PDFDocument, options: Options) -> String {
        var parts: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let rawText = page.string else {
                continue
            }

            let pageText = options.trimsPageText
                ? rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                : rawText

            if options.skipsEmptyPages && pageText.isEmpty {
                continue
            }

            parts.append("--- Page \(pageIndex + 1) ---\n\(pageText)")
        }

        guard !parts.isEmpty else { return "" }

        let joined = parts.joined(separator: "\n\n")
        if options.appendsTrailingBlankLine {
            return joined + "\n\n"
        }
        return joined
    }
}

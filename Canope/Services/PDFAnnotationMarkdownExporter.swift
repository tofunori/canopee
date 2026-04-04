import Foundation
import PDFKit
import AppKit
import CryptoKit

enum PDFAnnotationExportTarget: Equatable {
    case activeMarkdown(URL)
    case companionFile(URL)

    var url: URL {
        switch self {
        case .activeMarkdown(let url), .companionFile(let url):
            return url
        }
    }
}

enum PDFAnnotationMarkdownExportSource: Equatable {
    case compiled(documentURL: URL, pdfURL: URL)
    case reference(pdfURL: URL)

    var keySeed: String {
        switch self {
        case .compiled(let documentURL, _):
            return "compiled:\(documentURL.standardizedFileURL.path)"
        case .reference(let pdfURL):
            return "reference:\(pdfURL.standardizedFileURL.path)"
        }
    }

    var pdfDisplayName: String {
        switch self {
        case .compiled(_, let pdfURL), .reference(let pdfURL):
            return pdfURL.lastPathComponent
        }
    }

    var fallbackCompanionURL: URL {
        switch self {
        case .compiled(let documentURL, _):
            return PDFAnnotationMarkdownExporter.companionURL(for: documentURL)
        case .reference(let pdfURL):
            return PDFAnnotationMarkdownExporter.companionURL(for: pdfURL)
        }
    }
}

struct PDFAnnotationMarkdownExportResult {
    let targetURL: URL
    let updatedMarkdown: String
    let annotationCount: Int
}

enum PDFAnnotationMarkdownExporter {
    static func companionURL(for sourceURL: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName).annotations.md")
    }

    static func export(
        document: PDFDocument,
        source: PDFAnnotationMarkdownExportSource,
        target: PDFAnnotationExportTarget,
        existingMarkdown: String? = nil
    ) throws -> PDFAnnotationMarkdownExportResult {
        let key = blockKey(for: source)
        let entries = uniqueSortedEntries(from: document)
        let block = renderManagedBlock(entries: entries, key: key, pdfDisplayName: source.pdfDisplayName)
        let currentMarkdown = existingMarkdown ?? (try? String(contentsOf: target.url, encoding: .utf8)) ?? ""
        let updatedMarkdown = upsertManagedBlock(in: currentMarkdown, block: block, key: key)

        let directoryURL = target.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try updatedMarkdown.write(to: target.url, atomically: true, encoding: .utf8)

        return PDFAnnotationMarkdownExportResult(
            targetURL: target.url,
            updatedMarkdown: updatedMarkdown,
            annotationCount: entries.count
        )
    }

    private struct ExportEntry {
        let fingerprint: String
        let pageNumber: Int
        let sortY: CGFloat
        let sortX: CGFloat
        let title: String
        let colorDescription: String?
        let contentLabel: String?
        let content: String?
    }

    private static let colorNames: [(String, NSColor)] = [
        ("Jaune", AnnotationColor.yellow),
        ("Vert", AnnotationColor.green),
        ("Rouge", AnnotationColor.red),
        ("Bleu", AnnotationColor.blue),
        ("Violet", AnnotationColor.purple),
    ]

    private static func blockKey(for source: PDFAnnotationMarkdownExportSource) -> String {
        let digest = SHA256.hash(data: Data(source.keySeed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func uniqueSortedEntries(from document: PDFDocument) -> [ExportEntry] {
        var entries: [ExportEntry] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where shouldExport(annotation) {
                let entry = makeEntry(for: annotation, pageNumber: pageIndex + 1)
                entries.append(entry)
            }
        }

        let sorted = entries.sorted {
            if $0.pageNumber != $1.pageNumber { return $0.pageNumber < $1.pageNumber }
            if abs($0.sortY - $1.sortY) > 0.01 { return $0.sortY > $1.sortY }
            return $0.sortX < $1.sortX
        }

        var seen = Set<String>()
        return sorted.filter { seen.insert($0.fingerprint).inserted }
    }

    private static func shouldExport(_ annotation: PDFAnnotation) -> Bool {
        annotation.type != "Link" && annotation.type != "Widget"
    }

    private static func makeEntry(for annotation: PDFAnnotation, pageNumber: Int) -> ExportEntry {
        let bounds = annotation.bounds
        let typeTitle = displayType(for: annotation)
        let colorDescription = colorDescription(for: annotation)
        let content = normalizedContent(from: annotation.contents)
        let contentLabel = contentLabel(for: annotation, content: content)
        let fingerprintSource = [
            String(pageNumber),
            typeFingerprint(for: annotation),
            geometryFingerprint(for: annotation),
            content ?? "",
            annotation.modificationDate?.ISO8601Format() ?? "",
        ].joined(separator: "|")

        return ExportEntry(
            fingerprint: SHA256.hash(data: Data(fingerprintSource.utf8)).map { String(format: "%02x", $0) }.joined(),
            pageNumber: pageNumber,
            sortY: bounds.maxY,
            sortX: bounds.minX,
            title: typeTitle,
            colorDescription: colorDescription,
            contentLabel: contentLabel,
            content: content
        )
    }

    private static func renderManagedBlock(
        entries: [ExportEntry],
        key: String,
        pdfDisplayName: String
    ) -> String {
        var lines: [String] = [
            managedBlockStartMarker(for: key),
            "## Annotations PDF - \(pdfDisplayName)",
            ""
        ]

        if entries.isEmpty {
            lines.append("_Aucune annotation pour l’instant._")
        } else {
            for (index, entry) in entries.enumerated() {
                lines.append("### Annotation \(index + 1)")
                lines.append("- Page: \(entry.pageNumber)")
                lines.append("- Type: \(entry.title)")
                if let colorDescription = entry.colorDescription {
                    lines.append("- Couleur: \(colorDescription)")
                }
                if let contentLabel = entry.contentLabel,
                   let content = entry.content,
                   !content.isEmpty {
                    lines.append("- \(contentLabel): \(content)")
                }
                lines.append("")
            }
            if lines.last?.isEmpty == true {
                _ = lines.popLast()
            }
        }

        lines.append(managedBlockEndMarker(for: key))
        return lines.joined(separator: "\n")
    }

    private static func upsertManagedBlock(in markdown: String, block: String, key: String) -> String {
        let matches = managedBlockRanges(in: markdown, key: key)
        if matches.isEmpty {
            return appendManagedBlock(block, to: markdown)
        }

        let mutable = NSMutableString(string: markdown)
        for range in matches.dropFirst().sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: "")
        }

        mutable.replaceCharacters(in: matches[0], with: block)
        return collapseExcessBlankLines(in: mutable as String)
    }

    private static func appendManagedBlock(_ block: String, to markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return block + "\n"
        }
        return trimmed + "\n\n" + block + "\n"
    }

    private static func managedBlockRanges(in markdown: String, key: String) -> [NSRange] {
        let startMarker = managedBlockStartMarker(for: key)
        let endMarker = managedBlockEndMarker(for: key)
        let nsMarkdown = markdown as NSString
        var searchLocation = 0
        var ranges: [NSRange] = []

        while searchLocation < nsMarkdown.length {
            let searchRange = NSRange(location: searchLocation, length: nsMarkdown.length - searchLocation)
            let startRange = nsMarkdown.range(of: startMarker, options: [], range: searchRange)
            guard startRange.location != NSNotFound else { break }

            let endSearchLocation = NSMaxRange(startRange)
            let endSearchRange = NSRange(location: endSearchLocation, length: nsMarkdown.length - endSearchLocation)
            let endRange = nsMarkdown.range(of: endMarker, options: [], range: endSearchRange)
            guard endRange.location != NSNotFound else { break }

            var lowerBound = startRange.location
            var upperBound = NSMaxRange(endRange)
            while upperBound < nsMarkdown.length, isNewline(nsMarkdown.character(at: upperBound)) {
                upperBound += 1
            }
            if lowerBound > 0, isNewline(nsMarkdown.character(at: lowerBound - 1)) {
                lowerBound -= 1
            }

            ranges.append(NSRange(location: lowerBound, length: upperBound - lowerBound))
            searchLocation = upperBound
        }

        return ranges
    }

    private static func collapseExcessBlankLines(in markdown: String) -> String {
        var result = markdown
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func managedBlockStartMarker(for key: String) -> String {
        "<!-- canope:pdf-annotations:start key=\"\(key)\" -->"
    }

    private static func managedBlockEndMarker(for key: String) -> String {
        "<!-- canope:pdf-annotations:end key=\"\(key)\" -->"
    }

    private static func isNewline(_ codeUnit: unichar) -> Bool {
        codeUnit == 10 || codeUnit == 13
    }

    private static func displayType(for annotation: PDFAnnotation) -> String {
        if annotation.isTextBoxAnnotation { return "Zone de texte" }
        if annotation.isCanopeHighlightBlock || annotation.type == "Highlight" { return "Surlignage" }

        switch annotation.type {
        case "Underline":
            return "Soulignement"
        case "StrikeOut":
            return "Barré"
        case "Text":
            return "Note"
        case "Ink":
            return "Dessin"
        case "Square":
            return "Rectangle"
        case "Circle":
            return "Ovale"
        case "Line":
            return annotation.endLineStyle == .openArrow ? "Flèche" : "Ligne"
        default:
            return annotation.type ?? "Annotation"
        }
    }

    private static func typeFingerprint(for annotation: PDFAnnotation) -> String {
        if annotation.isTextBoxAnnotation { return "textbox" }
        if annotation.isCanopeHighlightBlock { return "highlight-block" }
        if annotation.type == "Line", annotation.endLineStyle == .openArrow { return "arrow" }
        return annotation.type ?? "annotation"
    }

    private static func geometryFingerprint(for annotation: PDFAnnotation) -> String {
        if annotation.isCanopeHighlightBlock, let segmentString = annotation.userName {
            return segmentString
        }

        if annotation.type == "Line" {
            return [
                rounded(annotation.startPoint.x),
                rounded(annotation.startPoint.y),
                rounded(annotation.endPoint.x),
                rounded(annotation.endPoint.y)
            ].joined(separator: ",")
        }

        let bounds = annotation.bounds
        return [
            rounded(bounds.origin.x),
            rounded(bounds.origin.y),
            rounded(bounds.size.width),
            rounded(bounds.size.height)
        ].joined(separator: ",")
    }

    private static func rounded(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private static func normalizedContent(from rawContent: String?) -> String? {
        guard let rawContent else { return nil }
        let collapsed = rawContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func contentLabel(for annotation: PDFAnnotation, content: String?) -> String? {
        guard content != nil else { return nil }
        if annotation.isCanopeHighlightBlock || annotation.type == "Highlight" || annotation.type == "Underline" || annotation.type == "StrikeOut" {
            return "Extrait"
        }
        return "Contenu"
    }

    private static func colorDescription(for annotation: PDFAnnotation) -> String? {
        let candidateColor: NSColor?
        if annotation.isTextBoxAnnotation {
            candidateColor = annotation.textBoxFillColor
        } else {
            candidateColor = annotation.color
        }

        guard let candidateColor else { return nil }
        let normalized = AnnotationColor.normalized(candidateColor)

        for (name, swatch) in colorNames {
            if colorsMatch(normalized, AnnotationColor.normalized(swatch)) {
                return "\(name) (\(hexString(for: normalized)))"
            }
        }

        return hexString(for: normalized)
    }

    private static func colorsMatch(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance &&
        abs(lhs.greenComponent - rhs.greenComponent) <= tolerance &&
        abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }

    private static func hexString(for color: NSColor) -> String {
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

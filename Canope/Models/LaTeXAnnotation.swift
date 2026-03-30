import Foundation

struct LaTeXAnnotation: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var selectedText: String
    var note: String
    var utf16Location: Int
    var utf16Length: Int
    var prefixContext: String
    var suffixContext: String
    var createdAt: Date
    var updatedAt: Date

    var utf16Range: NSRange {
        NSRange(location: utf16Location, length: utf16Length)
    }
}

struct LaTeXAnnotationDraft: Equatable {
    var selectedText: String
    var note: String
    var utf16Range: NSRange
    var prefixContext: String
    var suffixContext: String
}

enum LaTeXAnnotationStore {
    private static let sidecarSuffix = ".canope-annotations.json"
    private static let contextRadius = 80

    static func sidecarURL(for fileURL: URL) -> URL {
        let hiddenName = ".\(fileURL.lastPathComponent)\(sidecarSuffix)"
        return fileURL.deletingLastPathComponent().appendingPathComponent(hiddenName)
    }

    static func load(for fileURL: URL) -> [LaTeXAnnotation] {
        let url = sidecarURL(for: fileURL)
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LaTeXAnnotation].self, from: data)) ?? []
    }

    static func save(_ annotations: [LaTeXAnnotation], for fileURL: URL) throws {
        let url = sidecarURL(for: fileURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(annotations)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func deleteSidecar(for fileURL: URL) throws {
        let url = sidecarURL(for: fileURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func createAnnotation(from draft: LaTeXAnnotationDraft) -> LaTeXAnnotation {
        let now = Date()
        return LaTeXAnnotation(
            id: UUID(),
            selectedText: draft.selectedText,
            note: draft.note,
            utf16Location: draft.utf16Range.location,
            utf16Length: draft.utf16Range.length,
            prefixContext: draft.prefixContext,
            suffixContext: draft.suffixContext,
            createdAt: now,
            updatedAt: now
        )
    }

    static func update(_ annotation: LaTeXAnnotation, note: String, in text: String) -> LaTeXAnnotation {
        var updated = annotation
        updated.note = note

        if let refreshedContext = contextSnapshot(for: annotation.utf16Range, in: text) {
            updated.selectedText = refreshedContext.selectedText
            updated.prefixContext = refreshedContext.prefixContext
            updated.suffixContext = refreshedContext.suffixContext
            updated.utf16Location = refreshedContext.range.location
            updated.utf16Length = refreshedContext.range.length
        }

        updated.updatedAt = Date()
        return updated
    }

    static func makeDraft(from range: NSRange, in text: String, note: String = "") -> LaTeXAnnotationDraft? {
        guard let snapshot = contextSnapshot(for: range, in: text) else { return nil }

        return LaTeXAnnotationDraft(
            selectedText: snapshot.selectedText,
            note: note,
            utf16Range: snapshot.range,
            prefixContext: snapshot.prefixContext,
            suffixContext: snapshot.suffixContext
        )
    }

    private static func contextSnapshot(for range: NSRange, in text: String) -> (selectedText: String, range: NSRange, prefixContext: String, suffixContext: String)? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard range.location != NSNotFound,
              range.length > 0,
              NSLocationInRange(range.location, fullRange),
              NSMaxRange(range) <= nsText.length else {
            return nil
        }

        let selectedText = nsText.substring(with: range)
        let prefixStart = max(0, range.location - contextRadius)
        let prefixRange = NSRange(location: prefixStart, length: range.location - prefixStart)
        let suffixLength = min(contextRadius, nsText.length - NSMaxRange(range))
        let suffixRange = NSRange(location: NSMaxRange(range), length: suffixLength)

        return (
            selectedText: selectedText,
            range: range,
            prefixContext: nsText.substring(with: prefixRange),
            suffixContext: nsText.substring(with: suffixRange)
        )
    }
}

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

struct ResolvedLaTeXAnnotation: Identifiable, Equatable {
    var annotation: LaTeXAnnotation
    var resolvedRange: NSRange?
    var isDetached: Bool

    var id: UUID { annotation.id }
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

    static func resolve(_ annotations: [LaTeXAnnotation], in text: String) -> [ResolvedLaTeXAnnotation] {
        let nsText = text as NSString
        return annotations.map { annotation in
            guard let range = resolvedRange(for: annotation, in: nsText) else {
                return ResolvedLaTeXAnnotation(annotation: annotation, resolvedRange: nil, isDetached: true)
            }

            return ResolvedLaTeXAnnotation(annotation: annotation, resolvedRange: range, isDetached: false)
        }
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

    private static func resolvedRange(for annotation: LaTeXAnnotation, in text: NSString) -> NSRange? {
        let fullRange = NSRange(location: 0, length: text.length)
        let preferredRange = annotation.utf16Range

        if preferredRange.location != NSNotFound,
           NSMaxRange(preferredRange) <= text.length,
           text.substring(with: preferredRange) == annotation.selectedText {
            return preferredRange
        }

        let candidates = allRanges(of: annotation.selectedText, in: text)
        guard !candidates.isEmpty else { return nil }

        if candidates.count == 1 {
            return candidates[0]
        }

        return candidates.max { lhs, rhs in
            candidateScore(lhs, for: annotation, in: text) < candidateScore(rhs, for: annotation, in: text)
        }
        .flatMap { NSIntersectionRange($0, fullRange).length == $0.length ? $0 : nil }
    }

    private static func allRanges(of needle: String, in text: NSString) -> [NSRange] {
        guard !needle.isEmpty else { return [] }

        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)

        while true {
            let found = text.range(of: needle, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)

            let nextLocation = NSMaxRange(found)
            guard nextLocation < text.length else { break }
            searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
        }

        return ranges
    }

    private static func candidateScore(_ range: NSRange, for annotation: LaTeXAnnotation, in text: NSString) -> Int {
        var score = 0
        let prefixLength = min(annotation.prefixContext.count, range.location)
        let suffixLength = min(annotation.suffixContext.count, text.length - NSMaxRange(range))

        if prefixLength > 0 {
            let prefixRange = NSRange(location: range.location - prefixLength, length: prefixLength)
            let prefix = text.substring(with: prefixRange)
            if prefix.hasSuffix(annotation.prefixContext.suffix(prefixLength)) {
                score += prefixLength
            }
        }

        if suffixLength > 0 {
            let suffixRange = NSRange(location: NSMaxRange(range), length: suffixLength)
            let suffix = text.substring(with: suffixRange)
            if suffix.hasPrefix(annotation.suffixContext.prefix(suffixLength)) {
                score += suffixLength
            }
        }

        let distance = abs(range.location - annotation.utf16Location)
        return score - distance
    }
}

import AppKit
import Foundation
import UniformTypeIdentifiers

enum BibliographyExportService {
    static func records(
        for papers: [Paper],
        allPapers: [Paper],
        assignMissingKeys: Bool = true
    ) -> [BibliographicRecord] {
        var existingKeys = Set(
            allPapers
                .filter { candidate in !papers.contains(where: { $0.id == candidate.id }) }
                .compactMap { normalizedCiteKey($0.citeKey) }
        )

        return papers.map { paper in
            let citeKey: String
            if let existing = normalizedCiteKey(paper.citeKey) {
                citeKey = existing
            } else {
                citeKey = CitationKeyService.uniqueKey(for: paper, existingKeys: existingKeys)
                if assignMissingKeys {
                    paper.citeKey = citeKey
                }
            }
            existingKeys.insert(citeKey.lowercased())
            return BibliographicRecord(paper: paper, citeKey: citeKey)
        }
    }

    static func bibTeX(for papers: [Paper], allPapers: [Paper]) -> String {
        BibTeXSerializer.serialize(records(for: papers, allPapers: allPapers, assignMissingKeys: true))
    }

    @MainActor
    @discardableResult
    static func exportBibTeX(
        papers: [Paper],
        allPapers: [Paper],
        suggestedFileName: String = "references.bib"
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let bibTeX = bibTeX(for: papers, allPapers: allPapers)
        do {
            try bibTeX.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    @discardableResult
    static func appendToProjectBibliography(
        papers: [Paper],
        allPapers: [Paper],
        projectRoot: URL,
        fileName: String = "references.bib"
    ) -> URL? {
        let records = records(for: papers, allPapers: allPapers, assignMissingKeys: true)
        let fileURL = projectRoot.appendingPathComponent(fileName)

        do {
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let updated = upsert(records: records, into: existing)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    private static func upsert(records: [BibliographicRecord], into existingBibTeX: String) -> String {
        guard !records.isEmpty else { return existingBibTeX }

        let entries = parseEntries(in: existingBibTeX)
        let mutable = NSMutableString(string: existingBibTeX)
        let replacements = Dictionary(uniqueKeysWithValues: records.map { ($0.citeKey.lowercased(), BibTeXSerializer.serialize($0)) })

        for entry in entries.sorted(by: { $0.range.location > $1.range.location }) {
            guard let replacement = replacements[entry.citeKey.lowercased()] else { continue }
            mutable.replaceCharacters(in: entry.range, with: replacement)
        }

        let replacedKeys = Set(entries.map { $0.citeKey.lowercased() })
        let missingEntries = records
            .filter { !replacedKeys.contains($0.citeKey.lowercased()) }
            .map(BibTeXSerializer.serialize)

        let trimmed = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
        if missingEntries.isEmpty {
            return trimmed.isEmpty ? "" : trimmed + "\n"
        }

        let appended = ([trimmed].filter { !$0.isEmpty } + missingEntries).joined(separator: "\n\n")
        return appended + "\n"
    }

    private static func normalizedCiteKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseEntries(in bibTeX: String) -> [ParsedEntry] {
        let characters = Array(bibTeX)
        var entries: [ParsedEntry] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "@" else {
                index += 1
                continue
            }

            let start = index
            guard let braceIndex = characters[start...].firstIndex(of: "{") else {
                break
            }

            var citeKeyStart = braceIndex + 1
            while citeKeyStart < characters.count, characters[citeKeyStart].isWhitespace {
                citeKeyStart += 1
            }

            var cursor = citeKeyStart
            while cursor < characters.count, characters[cursor] != "," && characters[cursor] != "}" {
                cursor += 1
            }

            guard cursor < characters.count, characters[cursor] == "," else {
                index = braceIndex + 1
                continue
            }

            let citeKey = String(characters[citeKeyStart..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !citeKey.isEmpty else {
                index = cursor + 1
                continue
            }

            var depth = 1
            var end = cursor + 1
            while end < characters.count, depth > 0 {
                if characters[end] == "{" {
                    depth += 1
                } else if characters[end] == "}" {
                    depth -= 1
                }
                end += 1
            }

            guard depth == 0 else { break }

            let range = NSRange(location: start, length: end - start)
            entries.append(ParsedEntry(citeKey: citeKey, range: range))
            index = end
        }

        return entries
    }
}

private struct ParsedEntry {
    let citeKey: String
    let range: NSRange
}

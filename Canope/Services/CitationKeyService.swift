import Foundation

enum CitationKeyService {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "de", "des", "du", "for", "in", "la", "le", "les",
        "of", "on", "sur", "the", "to", "un", "une", "with"
    ]

    static func uniqueKey(for paper: Paper, existingKeys: Set<String>) -> String {
        let base = baseKey(for: paper)
        var candidate = base
        var suffixIndex = 0

        while existingKeys.contains(candidate.lowercased()) {
            suffixIndex += 1
            candidate = base + suffix(for: suffixIndex)
        }

        return candidate
    }

    private static func baseKey(for paper: Paper) -> String {
        let authorSeed = sanitize(BibliographyNameParser.firstFamilyName(from: paper.authors) ?? "ref")
        let yearSeed = paper.year.map(String.init) ?? "nd"
        let titleSeed = sanitize(significantTitleToken(from: paper.title) ?? "untitled")
        return authorSeed + yearSeed + titleSeed
    }

    private static func significantTitleToken(from title: String) -> String? {
        let tokens = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !stopWords.contains($0) }

        return tokens.first ?? title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { !$0.isEmpty }
    }

    private static func sanitize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let sanitized = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).joined().lowercased()
        return sanitized.isEmpty ? "ref" : sanitized
    }

    private static func suffix(for index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        if index <= letters.count {
            return String(letters[index - 1])
        }
        return String(index)
    }
}

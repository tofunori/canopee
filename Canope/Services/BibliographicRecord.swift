import Foundation

struct BibliographicRecord: Equatable {
    let citeKey: String
    let entryType: String
    let title: String
    let authors: [String]
    let year: Int?
    let doi: String?
    let journal: String?
    let url: String?
    let volume: String?
    let issue: String?
    let pages: String?
    let publisher: String?
    let booktitle: String?

    init(paper: Paper, citeKey: String) {
        self.citeKey = citeKey
        self.entryType = Self.resolveEntryType(for: paper)
        self.title = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authors = BibliographyNameParser.parseAuthors(from: paper.authors)
        self.year = paper.year
        self.doi = Self.trimmed(paper.doi)
        self.journal = Self.trimmed(paper.journal)
        self.url = Self.trimmed(paper.url)
        self.volume = Self.trimmed(paper.volume)
        self.issue = Self.trimmed(paper.issue)
        self.pages = Self.trimmed(paper.pages)
        self.publisher = Self.trimmed(paper.publisher)
        self.booktitle = Self.trimmed(paper.booktitle)
    }

    private static func resolveEntryType(for paper: Paper) -> String {
        if let explicit = trimmed(paper.entryType), !explicit.isEmpty {
            return explicit
        }
        if trimmed(paper.journal) != nil {
            return "article"
        }
        if trimmed(paper.booktitle) != nil {
            return "inproceedings"
        }
        if trimmed(paper.publisher) != nil {
            return "book"
        }
        return "misc"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

enum BibliographyNameParser {
    static func parseAuthors(from rawAuthors: String) -> [String] {
        let trimmed = rawAuthors.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains(" and ") {
            return splitAndTrim(trimmed.components(separatedBy: " and "))
        }

        if trimmed.contains(";") {
            return splitAndTrim(trimmed.components(separatedBy: ";"))
        }

        let commaSeparated = trimmed
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if commaSeparated.count >= 2 {
            let looksLikeFamilyGivenPairs = commaSeparated.count.isMultiple(of: 2)
                && commaSeparated.allSatisfy { !$0.contains(" ") }
            if looksLikeFamilyGivenPairs {
                return stride(from: 0, to: commaSeparated.count, by: 2).map { index in
                    "\(commaSeparated[index]), \(commaSeparated[index + 1])"
                }
            }
            return commaSeparated
        }

        if trimmed.contains("\n") {
            return splitAndTrim(trimmed.components(separatedBy: .newlines))
        }

        return [trimmed]
    }

    static func firstFamilyName(from rawAuthors: String) -> String? {
        guard let firstAuthor = parseAuthors(from: rawAuthors).first else { return nil }
        if firstAuthor.contains(",") {
            return firstAuthor
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return firstAuthor
            .components(separatedBy: .whitespaces)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitAndTrim(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

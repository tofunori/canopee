import Foundation

enum BibTeXSerializer {
    static func serialize(_ record: BibliographicRecord) -> String {
        var lines = ["@\(record.entryType){\(record.citeKey),"]

        appendField("title", value: protectTitle(record.title), to: &lines)
        appendField("author", value: authorField(from: record.authors), to: &lines)
        appendField("year", value: record.year.map(String.init), to: &lines)
        appendField("journal", value: record.journal, to: &lines)
        appendField("booktitle", value: record.booktitle, to: &lines)
        appendField("volume", value: record.volume, to: &lines)
        appendField("number", value: record.issue, to: &lines)
        appendField("pages", value: record.pages, to: &lines)
        appendField("publisher", value: record.publisher, to: &lines)
        appendField("doi", value: record.doi, to: &lines)
        appendField("url", value: record.url, to: &lines)

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    static func serialize(_ records: [BibliographicRecord]) -> String {
        records.map(serialize).joined(separator: "\n\n")
    }

    private static func appendField(_ key: String, value: String?, to lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        lines.append("  \(key) = {\(escape(value))},")
    }

    private static func protectTitle(_ title: String) -> String {
        title
    }

    private static func authorField(from authors: [String]) -> String? {
        guard !authors.isEmpty else { return nil }
        return authors.joined(separator: " and ")
    }

    static func escape(_ value: String) -> String {
        value.reduce(into: "") { partialResult, character in
            switch character {
            case "{":
                partialResult += "\\{"
            case "}":
                partialResult += "\\}"
            case "&":
                partialResult += "\\&"
            case "%":
                partialResult += "\\%"
            case "$":
                partialResult += "\\$"
            case "#":
                partialResult += "\\#"
            case "_":
                partialResult += "\\_"
            case "~":
                partialResult += "\\textasciitilde{}"
            case "^":
                partialResult += "\\textasciicircum{}"
            default:
                partialResult.append(character)
            }
        }
    }
}

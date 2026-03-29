import Foundation
import PDFKit

struct PaperMetadata {
    var title: String?
    var authors: String?
    var year: Int?
    var doi: String?
    var journal: String?
}

struct MetadataExtractor {

    /// Extract metadata locally from a PDF file (fast, no network).
    /// Uses: 1) PDF attributes, 2) text heuristics, 3) DOI extraction.
    static func extractLocal(from url: URL) -> PaperMetadata {
        guard let document = PDFDocument(url: url) else { return PaperMetadata() }

        var metadata = PaperMetadata()

        // Get text from first 2 pages
        var fullText = ""
        for i in 0..<min(2, document.pageCount) {
            if let page = document.page(at: i), let text = page.string {
                fullText += text + "\n"
            }
        }

        // DOI
        metadata.doi = extractDOI(from: fullText)

        // PDF document attributes
        if let attrs = document.documentAttributes {
            if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String,
               !title.isEmpty, title.count > 5 {
                metadata.title = title
            }
            if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String,
               !author.isEmpty {
                metadata.authors = author
            }
        }

        // Text heuristics on first page
        if let firstPage = document.page(at: 0), let text = firstPage.string {
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if metadata.year == nil {
                let header = lines.prefix(20).joined(separator: " ")
                metadata.year = extractYear(from: header)
            }

            if metadata.title == nil {
                metadata.title = extractTitleHeuristic(lines: lines)
            }

            if metadata.authors == nil, let titleLine = metadata.title {
                metadata.authors = extractAuthorsHeuristic(lines: lines, afterTitle: titleLine)
            }
        }

        return metadata
    }

    /// Look up metadata via CrossRef API (async). Calls completion on main thread.
    static func enrichWithCrossRef(doi: String, completion: @MainActor @escaping @Sendable (PaperMetadata?) -> Void) {
        let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(encodedDOI)") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Canopee/0.1 (mailto:canopee@example.com)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: PaperMetadata?
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                result = parseCrossRefResponse(data)
            } else {
                result = nil
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - CrossRef Response Parser

    private static func parseCrossRefResponse(_ data: Data) -> PaperMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return nil }

        var meta = PaperMetadata()

        if let titles = message["title"] as? [String], let title = titles.first {
            meta.title = title
        }

        if let authors = message["author"] as? [[String: Any]] {
            let names = authors.compactMap { author -> String? in
                let given = author["given"] as? String ?? ""
                let family = author["family"] as? String ?? ""
                if family.isEmpty { return nil }
                if given.isEmpty { return family }
                return "\(given) \(family)"
            }
            if !names.isEmpty {
                meta.authors = names.joined(separator: ", ")
            }
        }

        for dateKey in ["published-print", "published-online", "issued"] {
            if let dateParts = message[dateKey] as? [String: Any],
               let parts = dateParts["date-parts"] as? [[Int]],
               let firstPart = parts.first,
               let year = firstPart.first {
                meta.year = year
                break
            }
        }

        if let journals = message["container-title"] as? [String], let journal = journals.first {
            meta.journal = journal
        }

        return meta
    }

    // MARK: - DOI Extraction

    private static func extractDOI(from text: String) -> String? {
        let pattern = #"(10\.\d{4,9}/[^\s,;\"'<>\])}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var doi = String(text[range])
        while let last = doi.last, ".)]}>".contains(last) { doi.removeLast() }
        return doi
    }

    // MARK: - Year Extraction

    private static func extractYear(from text: String) -> Int? {
        let pattern = #"\b(19[89]\d|20[0-3]\d)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    // MARK: - Heuristic Extraction

    private static func extractTitleHeuristic(lines: [String]) -> String? {
        for line in lines.prefix(10) {
            if line.count > 10, line.count < 200,
               !line.contains("http"), !line.lowercased().contains("doi"),
               !line.lowercased().hasPrefix("abstract"),
               !line.contains("@"), !line.contains("©"),
               !line.lowercased().contains("license"),
               !line.lowercased().contains("journal"),
               !line.lowercased().contains("volume") {
                return line
            }
        }
        return nil
    }

    private static func extractAuthorsHeuristic(lines: [String], afterTitle: String) -> String? {
        guard let titleIndex = lines.firstIndex(of: afterTitle) else { return nil }
        var authorLines: [String] = []
        for line in lines.dropFirst(titleIndex + 1).prefix(5) {
            let lower = line.lowercased()
            if lower.hasPrefix("abstract") || lower.hasPrefix("introduction")
                || lower.hasPrefix("keywords") || line.count > 300
                || lower.contains("©") || lower.contains("license") {
                break
            }
            if line.contains(",") || line.contains(" and ") || line.contains("&") || line.count < 100 {
                authorLines.append(line)
            } else {
                break
            }
        }
        if authorLines.isEmpty { return nil }
        return authorLines.joined(separator: ", ")
    }
}

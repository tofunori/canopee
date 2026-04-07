import Foundation
import SwiftData
import AppKit

@Model
final class Paper {
    var id: UUID
    var title: String
    var authors: String
    var year: Int?
    var doi: String?
    var journal: String?
    var citeKey: String?
    var entryType: String?
    var url: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var publisher: String?
    var booktitle: String?
    var rating: Int = 0
    var notes: String?

    var fileName: String
    var dateAdded: Date
    var dateModified: Date

    var isFavorite: Bool = false
    var isRead: Bool = false
    var isFlagged: Bool = false
    var labelColor: String?  // "red", "orange", "yellow", "green", "blue", "purple"
    var labelShape: String = "circle" // "circle", "square", "diamond", "star", "triangle", "heart"

    var collections: [PaperCollection]

    init(title: String, fileName: String) {
        self.id = UUID()
        self.title = title
        self.authors = ""
        self.fileName = fileName
        self.dateAdded = Date()
        self.dateModified = Date()
        self.collections = []
    }

    /// Full URL to the PDF file in app support directory
    var fileURL: URL {
        PDFFileManager.storageDirectory.appendingPathComponent(fileName)
    }

    static let labelColors: [(name: String, key: String, color: NSColor)] = [
        ("Rouge", "red", .systemRed),
        ("Orange", "orange", .systemOrange),
        ("Jaune", "yellow", .systemYellow),
        ("Vert", "green", .systemGreen),
        ("Bleu", "blue", .systemBlue),
        ("Violet", "purple", .systemPurple),
    ]

    static let labelShapes: [(name: String, key: String, icon: String)] = [
        ("Cercle", "circle", "circle.fill"),
        ("Carré", "square", "square.fill"),
        ("Losange", "diamond", "diamond.fill"),
        ("Étoile", "star", "star.fill"),
        ("Triangle", "triangle", "triangle.fill"),
        ("Cœur", "heart", "heart.fill"),
    ]

    /// SF Symbol name for this paper's label shape
    var labelIconName: String {
        Paper.labelShapes.first(where: { $0.key == labelShape })?.icon ?? "circle.fill"
    }

    /// Short author list: "Smith, Jones, ..." format
    var authorsShort: String {
        guard !authors.isEmpty else { return "—" }
        let names = authors.components(separatedBy: ", ")
        let lastNames = names.prefix(3).compactMap { fullName -> String? in
            let parts = fullName.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            return parts.last
        }
        var result = lastNames.joined(separator: ", ")
        if names.count > 3 { result += ", …" }
        return result
    }

    /// Last author's name
    var lastAuthor: String {
        guard !authors.isEmpty else { return "—" }
        let names = authors.components(separatedBy: ", ")
        guard let last = names.last?.trimmingCharacters(in: .whitespaces) else { return "—" }
        let parts = last.components(separatedBy: " ")
        if parts.count >= 2 {
            return "\(parts.last ?? ""), \(parts.first ?? "")"
        }
        return last
    }
}

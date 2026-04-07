import SwiftData
import XCTest
@testable import Canope

final class SwiftDataAndExportTests: XCTestCase {
    @MainActor
    func testPaperInsertAndFetchInMemory() throws {
        let schema = Schema([Paper.self, PaperCollection.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let paper = Paper(title: "Glacier albedo", fileName: "test.pdf")
        paper.authors = "Smith, Jane, Doe, John"
        context.insert(paper)
        try context.save()

        let descriptor = FetchDescriptor<Paper>()
        let items = try context.fetch(descriptor)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Glacier albedo")
        XCTAssertEqual(items.first?.authorsShort, "Smith, Jane, Doe, …")
    }

    @MainActor
    func testPaperCollectionLinksPaper() throws {
        let schema = Schema([Paper.self, PaperCollection.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let collection = PaperCollection(name: "Thesis")
        let paper = Paper(title: "Chapitre 1", fileName: "c1.pdf")
        paper.collections = [collection]
        collection.papers.append(paper)

        context.insert(collection)
        context.insert(paper)
        try context.save()

        let colFetch = FetchDescriptor<PaperCollection>()
        let cols = try context.fetch(colFetch)
        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols.first?.papers.count, 1)
        XCTAssertEqual(cols.first?.papers.first?.title, "Chapitre 1")
    }

    func testPDFAnnotationCompanionURL() {
        let url = URL(fileURLWithPath: "/tmp/project/main.tex")
        let companion = PDFAnnotationMarkdownExporter.companionURL(for: url)
        XCTAssertEqual(companion.deletingLastPathComponent().path, "/tmp/project")
        XCTAssertEqual(companion.lastPathComponent, "main.annotations.md")
    }

    func testCitationKeyGenerationIsStable() {
        let paper = Paper(title: "Glacier albedo trends", fileName: "test.pdf")
        paper.authors = "Jane Smith"
        paper.year = 2024

        let first = CitationKeyService.uniqueKey(for: paper, existingKeys: [])
        let second = CitationKeyService.uniqueKey(for: paper, existingKeys: [])

        XCTAssertEqual(first, "smith2024glacier")
        XCTAssertEqual(second, first)
    }

    func testCitationKeyCollisionHandlingAddsSuffix() {
        let paper = Paper(title: "Glacier albedo trends", fileName: "test.pdf")
        paper.authors = "Jane Smith"
        paper.year = 2024

        let duplicate = CitationKeyService.uniqueKey(for: paper, existingKeys: ["smith2024glacier"])

        XCTAssertEqual(duplicate, "smith2024glaciera")
    }

    func testBibTeXSerializerEscapesSpecialCharacters() {
        let paper = Paper(title: "Étude {alpha} & beta_1", fileName: "alpha.pdf")
        paper.authors = "Jane Smith"
        paper.year = 2024
        paper.journal = "Cryosphere & Climate"
        let record = BibliographicRecord(paper: paper, citeKey: "smith2024etude")

        let bibTeX = BibTeXSerializer.serialize(record)

        XCTAssertTrue(bibTeX.contains("@article{smith2024etude"))
        XCTAssertTrue(bibTeX.contains("title = {Étude \\{alpha\\} \\& beta\\_1}"))
        XCTAssertTrue(bibTeX.contains("journal = {Cryosphere \\& Climate}"))
    }

    func testBibliographyExportHandlesIncompleteMetadata() {
        let paper = Paper(title: "Untitled note", fileName: "note.pdf")
        let records = BibliographyExportService.records(for: [paper], allPapers: [], assignMissingKeys: false)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.entryType, "misc")

        let bibTeX = BibTeXSerializer.serialize(records[0])
        XCTAssertTrue(bibTeX.contains("@misc{refnduntitled"))
        XCTAssertTrue(bibTeX.contains("title = {Untitled note}"))
    }

    @MainActor
    func testPaperPersistsBibliographyFields() throws {
        let schema = Schema([Paper.self, PaperCollection.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let paper = Paper(title: "Glacier albedo", fileName: "test.pdf")
        paper.citeKey = "smith2024glacier"
        paper.entryType = "article"
        paper.url = "https://example.org/paper"
        paper.volume = "12"
        paper.issue = "3"
        paper.pages = "45-57"
        paper.publisher = "ACME Press"
        paper.booktitle = "Conference on Snow"
        context.insert(paper)
        try context.save()

        let items = try context.fetch(FetchDescriptor<Paper>())
        let saved = try XCTUnwrap(items.first)
        XCTAssertEqual(saved.citeKey, "smith2024glacier")
        XCTAssertEqual(saved.entryType, "article")
        XCTAssertEqual(saved.url, "https://example.org/paper")
        XCTAssertEqual(saved.volume, "12")
        XCTAssertEqual(saved.issue, "3")
        XCTAssertEqual(saved.pages, "45-57")
        XCTAssertEqual(saved.publisher, "ACME Press")
        XCTAssertEqual(saved.booktitle, "Conference on Snow")
    }

    func testAppendToProjectBibliographyUpdatesExistingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bibURL = root.appendingPathComponent("references.bib")
        try """
        @article{smith2024glacier,
          title = {Old title},
        }
        """.write(to: bibURL, atomically: true, encoding: .utf8)

        let paper = Paper(title: "New title", fileName: "test.pdf")
        paper.authors = "Jane Smith"
        paper.year = 2024
        paper.journal = "Cryosphere"
        paper.citeKey = "smith2024glacier"

        let writtenURL = BibliographyExportService.appendToProjectBibliography(
            papers: [paper],
            allPapers: [paper],
            projectRoot: root
        )

        XCTAssertEqual(writtenURL, bibURL)
        let contents = try String(contentsOf: bibURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("title = {New title}"))
        XCTAssertEqual(contents.components(separatedBy: "@article{smith2024glacier").count - 1, 1)
    }
}

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
}

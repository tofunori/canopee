import XCTest
import AppKit
import PDFKit
@testable import Canope

final class PaperContextWriterTests: XCTestCase {
    actor WrittenPaperRecorder {
        private var contents: [String] = []

        func append(_ content: String) {
            contents.append(content)
        }

        func snapshot() -> [String] {
            contents
        }
    }

    func testComposeContextTextPreservesHeaderAndPageMarkers() {
        let metadata = PaperContextMetadata(
            fileURL: URL(fileURLWithPath: "/tmp/paper.pdf"),
            title: "Titre test",
            authors: "Alice; Bob",
            year: "2026",
            journal: "Journal test",
            doi: "10.1234/test"
        )
        let content = PaperContextDocumentContent(
            pageCount: 2,
            extractedText: "--- Page 1 ---\nBonjour\n\n--- Page 2 ---\nMonde\n\n"
        )

        let text = PaperContextWriter.composeContextText(metadata: metadata, content: content)

        XCTAssertTrue(text.contains("CURRENTLY OPEN PAPER IN CANOPÉE"))
        XCTAssertTrue(text.contains("Title: Titre test"))
        XCTAssertTrue(text.contains("Pages: 2"))
        XCTAssertTrue(text.contains("--- Page 1 ---"))
        XCTAssertTrue(text.contains("--- Page 2 ---"))
    }

    @MainActor
    func testNewerWriteContextSupersedesOlderPendingWrite() async {
        let writeExpectation = expectation(description: "latest context written")
        writeExpectation.expectedFulfillmentCount = 1

        let writtenPaperRecorder = WrittenPaperRecorder()
        let sink = PaperContextWriter.Sink(
            writeSelectionState: { _ in },
            clearLegacySelectionMirror: {},
            writePaper: { content in
                Task {
                    await writtenPaperRecorder.append(content)
                    writeExpectation.fulfill()
                }
            }
        )

        let writer = PaperContextWriter(
            sink: sink,
            contentExtractor: { document in
                if document.pageCount == 1 {
                    Thread.sleep(forTimeInterval: 0.15)
                    return PaperContextDocumentContent(pageCount: 1, extractedText: "--- Page 1 ---\nAncien\n\n")
                }
                return PaperContextDocumentContent(pageCount: 2, extractedText: "--- Page 1 ---\nNouveau\n\n")
            }
        )

        writer.writeContext(
            metadata: makeMetadata(title: "Ancien"),
            document: makeDocument(pageCount: 1),
            documentKey: "paper:/tmp/old.pdf"
        )
        writer.writeContext(
            metadata: makeMetadata(title: "Nouveau"),
            document: makeDocument(pageCount: 2),
            documentKey: "paper:/tmp/new.pdf"
        )

        await fulfillment(of: [writeExpectation], timeout: 2.0)

        let writtenPaperContents = await writtenPaperRecorder.snapshot()
        XCTAssertEqual(writtenPaperContents.count, 1)
        XCTAssertTrue(writtenPaperContents[0].contains("Title: Nouveau"))
        XCTAssertFalse(writtenPaperContents[0].contains("Title: Ancien"))
    }

    private func makeMetadata(title: String) -> PaperContextMetadata {
        PaperContextMetadata(
            fileURL: URL(fileURLWithPath: "/tmp/\(title).pdf"),
            title: title,
            authors: "Auteur",
            year: "2026",
            journal: "Journal",
            doi: "10.1234/test"
        )
    }

    private func makeDocument(pageCount: Int) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pageCount {
            document.insert(makeBlankPage(label: "\(index)"), at: index)
        }
        return document
    }

    private func makeBlankPage(label: String) -> PDFPage {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: label).draw(at: NSPoint(x: 20, y: 90), withAttributes: attributes)
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            XCTFail("Expected a PDF page backed by a blank image")
            fatalError("Failed to create PDF page")
        }
        return page
    }
}

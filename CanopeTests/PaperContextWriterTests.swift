import XCTest
import AppKit
import CoreText
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

    func testExtractDocumentContentUsesSharedPaperContextFormatter() throws {
        let document = try makeTextDocument(pages: ["Bonjour", "Monde"])

        let content = PaperContextWriter.extractDocumentContent(document)
        let expected = PDFPageTextFormatter.formattedText(from: document, options: .paperContext)

        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(content.extractedText, expected)
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

    @MainActor
    func testWriteContextLoadsDocumentWhenCurrentDocumentMissing() async throws {
        let writeExpectation = expectation(description: "loaded context written")
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

        let loadedDocument = try makeTextDocument(pages: ["Texte charge"])
        let writer = PaperContextWriter(
            sink: sink,
            documentLoader: { _, _ in
                PaperContextWriter.DocumentBox(document: loadedDocument)
            }
        )

        writer.writeContext(
            metadata: makeMetadata(title: "Charge"),
            document: nil,
            documentKey: "paper:/tmp/loaded.pdf"
        )

        await fulfillment(of: [writeExpectation], timeout: 2.0)

        let writtenPaperContents = await writtenPaperRecorder.snapshot()
        XCTAssertEqual(writtenPaperContents.count, 1)
        XCTAssertTrue(writtenPaperContents[0].contains("Title: Charge"))
        XCTAssertTrue(writtenPaperContents[0].contains("--- Page 1 ---\nTexte charge"))
    }

    @MainActor
    func testCancelPendingWritesSuppressesLateLoadedDocumentWrite() async throws {
        let invertedWriteExpectation = expectation(description: "no write after cancel")
        invertedWriteExpectation.isInverted = true

        let sink = PaperContextWriter.Sink(
            writeSelectionState: { _ in },
            clearLegacySelectionMirror: {},
            writePaper: { _ in
                invertedWriteExpectation.fulfill()
            }
        )

        let delayedDocument = try makeTextDocument(pages: ["Annule"])
        let writer = PaperContextWriter(
            sink: sink,
            documentLoader: { _, _ in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return PaperContextWriter.DocumentBox(document: delayedDocument)
            }
        )

        writer.writeContext(
            metadata: makeMetadata(title: "Annule"),
            document: nil,
            documentKey: "paper:/tmp/cancel.pdf"
        )
        writer.cancelPendingWrites()

        await fulfillment(of: [invertedWriteExpectation], timeout: 0.4)
    }

    @MainActor
    func testNewerLoadedWriteSupersedesOlderDelayedLoad() async throws {
        let writeExpectation = expectation(description: "latest loaded context written")
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

        let oldDocument = try makeTextDocument(pages: ["Ancien charge"])
        let newDocument = try makeTextDocument(pages: ["Nouveau charge"])
        let writer = PaperContextWriter(
            sink: sink,
            documentLoader: { key, _ in
                if key.contains("old") {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return PaperContextWriter.DocumentBox(document: oldDocument)
                }
                return PaperContextWriter.DocumentBox(document: newDocument)
            }
        )

        writer.writeContext(
            metadata: makeMetadata(title: "Ancien"),
            document: nil,
            documentKey: "paper:/tmp/old.pdf"
        )
        writer.writeContext(
            metadata: makeMetadata(title: "Nouveau"),
            document: nil,
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

    private func makeTextDocument(pages: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            XCTFail("Expected a PDF data consumer")
            throw NSError(domain: "PaperContextWriterTests", code: 1)
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 400)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Expected a PDF graphics context")
            throw NSError(domain: "PaperContextWriterTests", code: 2)
        }

        for pageText in pages {
            context.beginPDFPage(nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
            let attributedString = NSAttributedString(string: pageText, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributedString)
            context.textPosition = CGPoint(x: 36, y: 220)
            CTLineDraw(line, context)
            context.endPDFPage()
        }

        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            XCTFail("Expected a text-backed PDF document")
            throw NSError(domain: "PaperContextWriterTests", code: 3)
        }
        return document
    }
}

import XCTest
import AppKit
import PDFKit
@testable import Canope

final class PDFSolidificationTests: XCTestCase {
    @MainActor
    func testPDFSearchControllerClearSearchResultsResetsSearchState() {
        let state = PDFSearchUIState()
        state.matchCount = 4
        state.currentMatchIndex = 2

        let controller = PDFSearchController(searchState: state)
        var clearedCount = 0
        controller.onClearTextSelectionState = {
            clearedCount += 1
        }

        controller.clearSearchResults()

        XCTAssertEqual(state.matchCount, 0)
        XCTAssertEqual(state.currentMatchIndex, 0)
        XCTAssertEqual(clearedCount, 1)
    }

    @MainActor
    func testPDFAnnotationControllerUndoRemovesLastAnnotation() {
        let controller = PDFAnnotationController()
        let page = makeBlankPage()
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
            forType: .square,
            withProperties: nil
        )
        page.addAnnotation(annotation)

        var selectedAnnotation: PDFAnnotation? = annotation
        controller.selectedAnnotationProvider = { selectedAnnotation }
        controller.setSelectedAnnotation = { selectedAnnotation = $0 }

        controller.recordForUndo(page: page, annotation: annotation)
        controller.undo()

        XCTAssertFalse(page.annotations.contains { $0 === annotation })
        XCTAssertNil(selectedAnnotation)
    }

    @MainActor
    func testPDFAnnotationControllerChangeFontSizeUpdatesSelectedTextBox() {
        let controller = PDFAnnotationController()
        let page = makeBlankPage()
        let annotation = AnnotationService.createTextBoxAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 120, height: 40),
            on: page,
            text: "Bonjour",
            color: .systemYellow
        )

        var selectedAnnotation: PDFAnnotation? = annotation
        controller.selectedAnnotationProvider = { selectedAnnotation }
        controller.setSelectedAnnotation = { selectedAnnotation = $0 }

        let item = NSMenuItem()
        item.tag = 18
        controller.changeFontSize(item)

        XCTAssertEqual(Double(annotation.font?.pointSize ?? 0), 18, accuracy: 0.1)
    }

    private func makeBlankPage() -> PDFPage {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            XCTFail("Expected a PDF page backed by a blank image")
            fatalError("Failed to create blank PDF page")
        }
        return page
    }
}

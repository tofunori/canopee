import PDFKit
import AppKit

struct AnnotationService {

    private static func quadPoints(for rects: [CGRect]) -> [NSValue] {
        rects.flatMap { rect in
            [
                NSValue(point: NSPoint(x: rect.minX, y: rect.maxY)),
                NSValue(point: NSPoint(x: rect.maxX, y: rect.maxY)),
                NSValue(point: NSPoint(x: rect.minX, y: rect.minY)),
                NSValue(point: NSPoint(x: rect.maxX, y: rect.minY)),
            ]
        }
    }

    private static func makeMarkupAnnotation(
        type: PDFAnnotationSubtype,
        bounds: CGRect,
        segmentRects: [CGRect],
        color: NSColor,
        contents: String?
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        annotation.setValue(quadPoints(for: segmentRects), forAnnotationKey: .quadPoints)
        annotation.color = AnnotationColor.annotationColor(color, for: type)
        annotation.contents = contents
        return annotation
    }

    // MARK: - Text Markup Annotations (Highlight, Underline, Strikethrough)

    /// Create a single text markup annotation from the current selection.
    /// Returns created (page, annotation) pairs for undo support.
    @discardableResult
    static func createMarkupAnnotation(
        selection: PDFSelection,
        type: PDFAnnotationSubtype,
        color: NSColor,
        on pdfView: PDFView
    ) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        var created: [(page: PDFPage, annotation: PDFAnnotation)] = []

        let lineSelections = selection.selectionsByLine()
        var pageLines: [PDFPage: [PDFSelection]] = [:]
        for line in lineSelections {
            guard let page = line.pages.first else { continue }
            pageLines[page, default: []].append(line)
        }

        for (page, lines) in pageLines {
            var unionBounds: CGRect = .null
            var highlightSegmentRects: [CGRect] = []

            for line in lines {
                let rawBounds = line.bounds(for: page)
                guard rawBounds.width > 0, rawBounds.height > 0 else { continue }
                let inset = rawBounds.height * 0.12
                let bounds = rawBounds.insetBy(dx: 0, dy: inset)
                unionBounds = unionBounds.union(bounds)
                highlightSegmentRects.append(bounds)
            }

            guard !unionBounds.isNull else { continue }

            let annotation = makeMarkupAnnotation(
                type: type,
                bounds: unionBounds,
                segmentRects: highlightSegmentRects,
                color: color,
                contents: selection.string
            )

            page.addAnnotation(annotation)
            created.append((page: page, annotation: annotation))
        }
        return created
    }

    static func normalizeCustomHighlightAnnotations(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let annotations = page.annotations
            for annotation in annotations {
                guard let customHighlight = HighlightMarkupAnnotation.rehydrated(from: annotation) else { continue }
                let migratedHighlight = makeMarkupAnnotation(
                    type: .highlight,
                    bounds: customHighlight.bounds,
                    segmentRects: customHighlight.segmentRects,
                    color: customHighlight.color,
                    contents: customHighlight.contents
                )
                migratedHighlight.modificationDate = customHighlight.modificationDate
                page.removeAnnotation(annotation)
                page.addAnnotation(migratedHighlight)
            }
        }
    }

    private static func normalizeTextBoxAnnotations(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let annotations = page.annotations

            for annotation in annotations {
                if let customTextBox = TextBoxAnnotation.rehydrated(from: annotation) {
                    page.removeAnnotation(annotation)
                    page.addAnnotation(customTextBox)
                    continue
                }

                guard annotation.type == "FreeText" else { continue }

                let migratedTextBox = TextBoxAnnotation(
                    bounds: annotation.bounds,
                    text: annotation.contents ?? "",
                    fillColor: AnnotationColor.storedTextBoxFillColor(annotation.color),
                    font: annotation.font ?? .systemFont(ofSize: 12),
                    fontColor: annotation.fontColor ?? .black,
                    alignment: annotation.alignment,
                    borderWidth: annotation.border?.lineWidth ?? 1.0
                )
                migratedTextBox.modificationDate = annotation.modificationDate
                page.removeAnnotation(annotation)
                page.addAnnotation(migratedTextBox)
            }
        }
    }

    static func normalizeDocumentAnnotations(in document: PDFDocument) {
        normalizeCustomHighlightAnnotations(in: document)
        normalizeTextBoxAnnotations(in: document)
    }

    // MARK: - Text Note Annotation

    /// Create a sticky note annotation at a specific point on a page.
    static func createNoteAnnotation(
        at point: NSPoint,
        on page: PDFPage,
        text: String,
        color: NSColor
    ) -> PDFAnnotation {
        let bounds = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = color
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: - Free Text (Text Box) Annotation

    /// Create a text box annotation at a specific point on a page.
    static func createTextBoxAnnotation(
        at point: NSPoint,
        on page: PDFPage,
        text: String,
        color: NSColor,
        fontSize: CGFloat = 12
    ) -> PDFAnnotation {
        let width: CGFloat = 200
        let height: CGFloat = 40
        let bounds = CGRect(x: point.x, y: point.y - height, width: width, height: height)
        let annotation = TextBoxAnnotation(
            bounds: bounds,
            text: text,
            fillColor: AnnotationColor.annotationColor(color, for: "FreeText"),
            font: .systemFont(ofSize: fontSize),
            fontColor: .black,
            alignment: .left,
            borderWidth: 1.0
        )
        page.addAnnotation(annotation)
        return annotation
    }

    static func createTextBoxAnnotation(
        bounds: CGRect,
        on page: PDFPage,
        text: String,
        color: NSColor,
        fontSize: CGFloat = 12,
        alignment: NSTextAlignment = .left
    ) -> PDFAnnotation {
        let annotation = TextBoxAnnotation(
            bounds: bounds,
            text: text,
            fillColor: AnnotationColor.annotationColor(color, for: "FreeText"),
            font: .systemFont(ofSize: fontSize),
            fontColor: .black,
            alignment: alignment,
            borderWidth: 1.0
        )
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: - Ink Annotation (Freehand Drawing)

    /// Create an ink (freehand) annotation from a bezier path.
    @discardableResult
    static func createInkAnnotation(
        path: NSBezierPath,
        on page: PDFPage,
        color: NSColor,
        lineWidth: CGFloat = 2.0
    ) -> PDFAnnotation {
        let bounds = path.bounds.insetBy(dx: -lineWidth, dy: -lineWidth)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = color

        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border

        // Ink paths are stored in annotation-local coordinates, not page coordinates.
        let normalizedPath = (path.copy() as? NSBezierPath) ?? NSBezierPath()
        let transform = AffineTransform(translationByX: -bounds.origin.x, byY: -bounds.origin.y)
        normalizedPath.transform(using: transform)

        annotation.add(normalizedPath)
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: - Shape Annotations (Rectangle, Oval)

    /// Create a rectangle or oval annotation with custom drawing.
    @discardableResult
    static func createShapeAnnotation(
        bounds: CGRect,
        type: PDFAnnotationSubtype,
        on page: PDFPage,
        color: NSColor,
        lineWidth: CGFloat = 2.0
    ) -> PDFAnnotation {
        let annotation: PDFAnnotation
        if type == .square {
            annotation = RectangleAnnotation(bounds: bounds, color: color, lineWidth: lineWidth)
        } else {
            annotation = OvalAnnotation(bounds: bounds, color: color, lineWidth: lineWidth)
        }
        page.addAnnotation(annotation)
        return annotation
    }

    /// Create an arrow (line) annotation with custom drawing.
    static func createArrowAnnotation(
        from startPoint: CGPoint,
        to endPoint: CGPoint,
        on page: PDFPage,
        color: NSColor,
        lineWidth: CGFloat = 2.0
    ) -> PDFAnnotation {
        let bounds = CGRect(
            x: min(startPoint.x, endPoint.x) - lineWidth,
            y: min(startPoint.y, endPoint.y) - lineWidth,
            width: abs(endPoint.x - startPoint.x) + lineWidth * 2,
            height: abs(endPoint.y - startPoint.y) + lineWidth * 2
        )
        let annotation = ArrowAnnotation(
            bounds: bounds,
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth
        )
        page.addAnnotation(annotation)
        return annotation
    }

    // MARK: - Save

    /// Save the PDF document with all annotations to disk.
    static func save(document: PDFDocument, to url: URL) -> Bool {
        return document.write(to: url)
    }
}

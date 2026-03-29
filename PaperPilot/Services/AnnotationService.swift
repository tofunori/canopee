import PDFKit
import AppKit

struct AnnotationService {

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
            var allQuadPoints: [NSValue] = []
            var unionBounds: CGRect = .null

            for line in lines {
                let rawBounds = line.bounds(for: page)
                guard rawBounds.width > 0, rawBounds.height > 0 else { continue }
                let inset = rawBounds.height * 0.12
                let bounds = rawBounds.insetBy(dx: 0, dy: inset)
                unionBounds = unionBounds.union(bounds)
                allQuadPoints.append(contentsOf: [
                    NSValue(point: NSPoint(x: bounds.minX, y: bounds.maxY)),
                    NSValue(point: NSPoint(x: bounds.maxX, y: bounds.maxY)),
                    NSValue(point: NSPoint(x: bounds.minX, y: bounds.minY)),
                    NSValue(point: NSPoint(x: bounds.maxX, y: bounds.minY)),
                ])
            }

            guard !unionBounds.isNull else { continue }

            let annotation = PDFAnnotation(bounds: unionBounds, forType: type, withProperties: nil)
            annotation.setValue(allQuadPoints, forAnnotationKey: .quadPoints)
            annotation.contents = selection.string

            switch type {
            case .highlight:
                annotation.color = color.withAlphaComponent(0.4)
            default:
                annotation.color = color
            }

            page.addAnnotation(annotation)
            created.append((page: page, annotation: annotation))
        }
        return created
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
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont.systemFont(ofSize: fontSize)
        annotation.fontColor = .black
        annotation.color = color.withAlphaComponent(0.15)

        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border

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

        annotation.add(path)
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

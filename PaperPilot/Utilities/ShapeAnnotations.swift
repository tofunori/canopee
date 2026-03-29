import PDFKit
import AppKit

// MARK: - Rectangle Annotation

class RectangleAnnotation: PDFAnnotation {
    init(bounds: CGRect, color: NSColor, lineWidth: CGFloat = 2.0) {
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        self.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        self.border = border
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        let lw = border?.lineWidth ?? 2
        let drawingRect = bounds.insetBy(dx: lw / 2, dy: lw / 2)
        if let interior = interiorColor {
            context.setFillColor(interior.cgColor)
            context.fill(drawingRect)
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lw)
        context.stroke(drawingRect)
        context.restoreGState()
    }
}

// MARK: - Oval Annotation

class OvalAnnotation: PDFAnnotation {
    init(bounds: CGRect, color: NSColor, lineWidth: CGFloat = 2.0) {
        super.init(bounds: bounds, forType: .circle, withProperties: nil)
        self.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        self.border = border
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        let lw = border?.lineWidth ?? 2
        let drawingRect = bounds.insetBy(dx: lw / 2, dy: lw / 2)
        if let interior = interiorColor {
            context.setFillColor(interior.cgColor)
            context.fillEllipse(in: drawingRect)
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lw)
        context.strokeEllipse(in: drawingRect)
        context.restoreGState()
    }
}

// MARK: - Arrow / Line Annotation

class ArrowAnnotation: PDFAnnotation {
    init(bounds: CGRect, startPoint: CGPoint, endPoint: CGPoint,
         color: NSColor, lineWidth: CGFloat = 2.0) {
        super.init(bounds: bounds, forType: .line, withProperties: nil)
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.endLineStyle = .openArrow
        self.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        self.border = border
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        let lw = border?.lineWidth ?? 2
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lw)
        context.setLineCap(.round)

        // Draw the line
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.strokePath()

        // Draw arrowhead at endPoint
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headLength: CGFloat = max(10, lw * 5)
        let headAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: endPoint.x - headLength * cos(angle - headAngle),
            y: endPoint.y - headLength * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: endPoint.x - headLength * cos(angle + headAngle),
            y: endPoint.y - headLength * sin(angle + headAngle)
        )

        context.move(to: endPoint)
        context.addLine(to: p1)
        context.move(to: endPoint)
        context.addLine(to: p2)
        context.strokePath()

        context.restoreGState()
    }
}

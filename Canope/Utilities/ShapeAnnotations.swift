import PDFKit
import AppKit

// MARK: - Highlight Annotation

final class HighlightMarkupAnnotation: PDFAnnotation {
    static let markerName = "canope.highlight.block"
    private static let userNamePrefix = "canope-highlight:"

    var segmentRects: [CGRect] = []

    init(segmentRects: [CGRect], color: NSColor, contents: String?) {
        self.segmentRects = segmentRects
        let unionBounds = segmentRects.reduce(into: CGRect.null) { partial, rect in
            partial = partial.union(rect)
        }
        super.init(bounds: unionBounds, forType: .square, withProperties: nil)
        self.color = color
        self.contents = contents
        self.interiorColor = AnnotationColor.liveHighlightColor(color)
        let border = PDFBorder()
        border.lineWidth = 0
        self.border = border
        setValue(Self.markerName, forAnnotationKey: .name)
        self.userName = Self.serialize(segmentRects: segmentRects)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    static func rehydrated(from annotation: PDFAnnotation) -> HighlightMarkupAnnotation? {
        guard annotation.isCanopeHighlightBlock,
              let segments = deserialize(segmentString: annotation.userName),
              !segments.isEmpty else { return nil }

        let custom = HighlightMarkupAnnotation(
            segmentRects: segments,
            color: annotation.color,
            contents: annotation.contents
        )
        custom.modificationDate = annotation.modificationDate
        return custom
    }

    private static func serialize(segmentRects: [CGRect]) -> String {
        let payload = segmentRects.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return userNamePrefix
        }
        return userNamePrefix + json
    }

    private static func deserialize(segmentString: String?) -> [CGRect]? {
        guard let segmentString,
              segmentString.hasPrefix(userNamePrefix) else { return nil }

        let json = String(segmentString.dropFirst(userNamePrefix.count))
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [[CGFloat]] else {
            return nil
        }

        return payload.compactMap { values in
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setFillColor(AnnotationColor.liveHighlightColor(color).cgColor)

        if segmentRects.isEmpty {
            context.fill(bounds)
        } else {
            for rect in segmentRects {
                context.fill(rect)
            }
        }
        context.restoreGState()
    }
}

extension PDFAnnotation {
    var isCanopeHighlightBlock: Bool {
        type == "Square" && ((value(forAnnotationKey: .name) as? String) == HighlightMarkupAnnotation.markerName)
    }
}

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

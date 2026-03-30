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

// MARK: - Text Box Annotation

final class TextBoxAnnotation: PDFAnnotation {
    static let userNameMarker = "canope-textbox"
    static let defaultBorderColor = NSColor.black
    private static let lineFragmentPadding: CGFloat = 2.0

    init(
        bounds: CGRect,
        text: String,
        fillColor: NSColor,
        font: NSFont,
        fontColor: NSColor,
        alignment: NSTextAlignment,
        borderWidth: CGFloat = 1.0
    ) {
        super.init(bounds: bounds, forType: .square, withProperties: nil)
        self.contents = text
        self.userName = Self.userNameMarker
        self.font = font
        self.fontColor = fontColor
        self.alignment = alignment
        self.color = Self.defaultBorderColor
        self.interiorColor = fillColor
        let border = PDFBorder()
        border.lineWidth = borderWidth
        self.border = border
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    static func rehydrated(from annotation: PDFAnnotation) -> TextBoxAnnotation? {
        guard annotation.isCanopeTextBox else { return nil }

        let custom = TextBoxAnnotation(
            bounds: annotation.bounds,
            text: annotation.contents ?? "",
            fillColor: annotation.textBoxFillColor,
            font: annotation.font ?? .systemFont(ofSize: 12),
            fontColor: annotation.fontColor ?? .black,
            alignment: annotation.alignment,
            borderWidth: annotation.border?.lineWidth ?? 1.0
        )
        custom.modificationDate = annotation.modificationDate
        return custom
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()

        let borderWidth = max(1.0, border?.lineWidth ?? 1.0)
        let drawingRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        let fill = (interiorColor ?? color).usingColorSpace(.deviceRGB) ?? (interiorColor ?? color)
        context.setFillColor(fill.cgColor)
        context.fill(drawingRect)

        context.setStrokeColor(Self.defaultBorderColor.cgColor)
        context.setLineWidth(borderWidth)
        context.stroke(drawingRect)

        let currentFont = font ?? NSFont.systemFont(ofSize: 12)
        let currentFontColor = fontColor ?? NSColor.black
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        let descent = -currentFont.descender
        let lineHeight = ceil(currentFont.ascender) + ceil(descent)
        paragraphStyle.lineSpacing = -currentFont.leading
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight

        let textVerticalInset = 3.0 + round(descent) - descent
        let textRect = drawingRect.insetBy(dx: Self.lineFragmentPadding, dy: textVerticalInset)
        let attributedString = NSAttributedString(
            string: contents ?? "",
            attributes: [
                .font: currentFont,
                .foregroundColor: currentFontColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext
        attributedString.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }
}

extension PDFAnnotation {
    var isCanopeTextBox: Bool {
        type == "Square" && userName == TextBoxAnnotation.userNameMarker
    }

    var isTextBoxAnnotation: Bool {
        type == "FreeText" || isCanopeTextBox
    }

    var textBoxFillColor: NSColor {
        if isCanopeTextBox {
            return interiorColor ?? color
        }
        return AnnotationColor.storedTextBoxFillColor(color)
    }

    func setTextBoxFillColor(_ fillColor: NSColor) {
        if isCanopeTextBox {
            interiorColor = fillColor
            color = TextBoxAnnotation.defaultBorderColor
        } else {
            color = fillColor
        }
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

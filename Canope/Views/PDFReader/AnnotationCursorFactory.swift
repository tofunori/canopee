import AppKit

enum AnnotationCursorFactory {
    static func cursor(for tool: AnnotationTool, color: NSColor) -> NSCursor {
        switch tool {
        case .underline:
            return markupCursor(color: color, barCenterY: 4.5)
        case .strikethrough:
            return markupCursor(color: color, barCenterY: 11.5)
        default:
            return .iBeam
        }
    }

    private static func markupCursor(color: NSColor, barCenterY: CGFloat) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            let stemRect = NSRect(x: 11, y: 6, width: 2, height: 14)
            let stemPath = NSBezierPath(roundedRect: stemRect, xRadius: 1, yRadius: 1)
            NSColor.black.setFill()
            stemPath.fill()

            let barRect = NSRect(x: 6, y: barCenterY - 1.5, width: 12, height: 3)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            AnnotationColor.normalized(color).withAlphaComponent(0.98).setFill()
            barPath.fill()

            let outlineRect = barRect.insetBy(dx: -0.5, dy: -0.5)
            let outlinePath = NSBezierPath(roundedRect: outlineRect, xRadius: 2, yRadius: 2)
            NSColor.black.withAlphaComponent(0.18).setStroke()
            outlinePath.lineWidth = 1
            outlinePath.stroke()

            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: barCenterY))
    }
}

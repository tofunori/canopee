import AppKit
import PDFKit

enum ResizeHandle {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum CursorMouseDownAction {
    case passThrough
    case handled
    case beginCustomDrag
}

struct TextAnnotationPreviewStyle {
    let text: String
    let fillColor: NSColor
    let borderColor: NSColor
    let font: NSFont
    let fontColor: NSColor
    let alignment: NSTextAlignment
}

class SelectionOverlayView: NSView {
    var selectionRects: [NSRect] = []
    var selectionColor: NSColor = AnnotationColor.previewColor(AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow, for: .highlight)
    var selectionTool: AnnotationTool = .highlight
    var annotationBorderRect: NSRect? = nil
    var isEditingAnnotation = false
    let handleSize: CGFloat = 11
    private let handleHitExpansion: CGFloat = 12

    override var isOpaque: Bool { false }

    // Resize drag state
    private var activeHandle: ResizeHandle?
    private var pendingHandle: ResizeHandle?
    private var isMovingAnnotation = false
    private var isPendingInteriorDrag = false
    private var dragOriginRect: NSRect?
    private var dragStartPoint: NSPoint?
    private var textAnnotationPreviewStyle: TextAnnotationPreviewStyle?
    private var showsTextAnnotationPreview = false
    private let dragActivationDistance: CGFloat = 2.5
    var allowsInteriorDragging = false
    var onInteriorDoubleClick: (() -> Void)?
    var onMoveBegan: (() -> Void)?
    var onResizeBegan: (() -> Void)?
    var onMoveChanged: ((_ newRect: NSRect) -> Void)?
    var onMoveComplete: ((_ newRect: NSRect) -> Void)?
    var onResizeChanged: ((_ newRect: NSRect) -> Void)?
    var onResizeComplete: ((_ newRect: NSRect) -> Void)?
    weak var eventPassthroughView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept if clicking on a resize handle
        if let _ = handleAt(point) {
            return self
        }
        if allowsInteriorDragging,
           let rect = annotationBorderRect,
           rect.contains(point) {
            return self
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.magnify(with: event)
            return
        }
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.smartMagnify(with: event)
            return
        }
        super.smartMagnify(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)

        if !selectionRects.isEmpty {
            switch selectionTool {
            case .underline:
                selectionColor.setStroke()
                for rect in selectionRects {
                    let path = NSBezierPath()
                    let y = rect.minY + max(1.0, rect.height * 0.12)
                    path.move(to: NSPoint(x: rect.minX, y: y))
                    path.line(to: NSPoint(x: rect.maxX, y: y))
                    path.lineWidth = max(1.5, rect.height * 0.08)
                    path.lineCapStyle = .round
                    path.stroke()
                }
            case .strikethrough:
                selectionColor.setStroke()
                for rect in selectionRects {
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: rect.minX, y: rect.midY))
                    path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                    path.lineWidth = max(1.5, rect.height * 0.08)
                    path.lineCapStyle = .round
                    path.stroke()
                }
            default:
                selectionColor.setFill()
                for rect in selectionRects { rect.fill() }
            }
        }
        if let rect = annotationBorderRect {
            if showsTextAnnotationPreview, let preview = textAnnotationPreviewStyle {
                preview.fillColor.setFill()
                rect.fill()

                preview.borderColor.setStroke()
                let previewBorderPath = NSBezierPath(rect: rect)
                previewBorderPath.lineWidth = 1
                previewBorderPath.stroke()

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = preview.alignment
                paragraphStyle.lineBreakMode = .byWordWrapping

                let textRect = rect.insetBy(dx: 4, dy: 4)
                let attributedString = NSAttributedString(
                    string: preview.text,
                    attributes: [
                        .font: preview.font,
                        .foregroundColor: preview.fontColor,
                        .paragraphStyle: paragraphStyle
                    ]
                )
                attributedString.draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }

            NSColor.black.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = isEditingAnnotation ? 1.0 : 1.5
            if !isEditingAnnotation {
                borderPath.setLineDash([4, 3], count: 2, phase: 0)
            }
            borderPath.stroke()

            NSColor.white.setFill()
            NSColor.black.setStroke()
            for handleRect in handleRects(for: rect) {
                let path = NSBezierPath(rect: handleRect)
                path.fill()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func handleRects(for rect: NSRect) -> [NSRect] {
        let hs = handleSize
        return [
            NSRect(x: rect.minX - hs/2, y: rect.minY - hs/2, width: hs, height: hs),
            NSRect(x: rect.maxX - hs/2, y: rect.minY - hs/2, width: hs, height: hs),
            NSRect(x: rect.minX - hs/2, y: rect.maxY - hs/2, width: hs, height: hs),
            NSRect(x: rect.maxX - hs/2, y: rect.maxY - hs/2, width: hs, height: hs),
        ]
    }

    private func handleAt(_ point: NSPoint) -> ResizeHandle? {
        guard let rect = annotationBorderRect else { return nil }
        let handles = handleRects(for: rect)
        let hitRects = handles.map { $0.insetBy(dx: -handleHitExpansion, dy: -handleHitExpansion) }
        if hitRects[0].contains(point) { return .bottomLeft }
        if hitRects[1].contains(point) { return .bottomRight }
        if hitRects[2].contains(point) { return .topLeft }
        if hitRects[3].contains(point) { return .topRight }
        return nil
    }

    func isResizeHandle(at point: NSPoint) -> Bool {
        handleAt(point) != nil
    }

    // MARK: - Resize Drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handleAt(point), let rect = annotationBorderRect else {
            if allowsInteriorDragging, let rect = annotationBorderRect, rect.contains(point) {
                if event.clickCount >= 2 {
                    onInteriorDoubleClick?()
                    return
                }
                pendingHandle = nil
                isPendingInteriorDrag = true
                isMovingAnnotation = false
                showsTextAnnotationPreview = false
                dragOriginRect = rect
                dragStartPoint = point
                return
            }
            super.mouseDown(with: event)
            return
        }
        pendingHandle = handle
        activeHandle = nil
        isPendingInteriorDrag = false
        isMovingAnnotation = false
        showsTextAnnotationPreview = false
        dragOriginRect = rect
        dragStartPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOriginRect, let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        activatePendingInteractionIfNeeded(currentPoint: current)

        guard isMovingAnnotation || activeHandle != nil else { return }

        let dx = current.x - start.x
        let dy = current.y - start.y

        if isMovingAnnotation {
            let newRect = origin.offsetBy(dx: dx, dy: dy)
            annotationBorderRect = newRect
            needsDisplay = true
            onMoveChanged?(newRect)
            return
        }

        guard let handle = activeHandle else {
            super.mouseDragged(with: event)
            return
        }
        var newRect = origin
        switch handle {
        case .bottomRight:
            newRect.size.width = max(30, origin.width + dx)
            newRect.size.height = max(15, origin.height - dy)
            newRect.origin.y = origin.origin.y + dy
        case .bottomLeft:
            newRect.origin.x = origin.origin.x + dx
            newRect.size.width = max(30, origin.width - dx)
            newRect.size.height = max(15, origin.height - dy)
            newRect.origin.y = origin.origin.y + dy
        case .topRight:
            newRect.size.width = max(30, origin.width + dx)
            newRect.size.height = max(15, origin.height + dy)
        case .topLeft:
            newRect.origin.x = origin.origin.x + dx
            newRect.size.width = max(30, origin.width - dx)
            newRect.size.height = max(15, origin.height + dy)
        }

        annotationBorderRect = newRect
        needsDisplay = true
        onResizeChanged?(newRect)
    }

    override func mouseUp(with event: NSEvent) {
        if (pendingHandle != nil || isPendingInteriorDrag) && activeHandle == nil && !isMovingAnnotation {
            pendingHandle = nil
            isPendingInteriorDrag = false
            dragOriginRect = nil
            dragStartPoint = nil
            showsTextAnnotationPreview = false
            NSCursor.arrow.set()
            return
        }

        guard (activeHandle != nil || isMovingAnnotation), let newRect = annotationBorderRect else {
            super.mouseUp(with: event)
            return
        }
        let finishedMoving = isMovingAnnotation
        activeHandle = nil
        pendingHandle = nil
        isMovingAnnotation = false
        isPendingInteriorDrag = false
        dragOriginRect = nil
        dragStartPoint = nil
        showsTextAnnotationPreview = false
        NSCursor.arrow.set()
        needsDisplay = true
        if finishedMoving {
            onMoveComplete?(newRect)
        } else {
            onResizeComplete?(newRect)
        }
    }

    func updateSelection(rects: [NSRect], color: NSColor, tool: AnnotationTool) {
        selectionRects = rects
        selectionColor = color
        selectionTool = tool
        needsDisplay = true
    }

    func updateAnnotationBorder(rect: NSRect?, isEditing: Bool = false) {
        annotationBorderRect = rect
        isEditingAnnotation = isEditing
        if rect == nil {
            showsTextAnnotationPreview = false
        }
        needsDisplay = true
    }

    func updateTextAnnotationPreviewStyle(_ style: TextAnnotationPreviewStyle?) {
        textAnnotationPreviewStyle = style
        if style == nil {
            showsTextAnnotationPreview = false
        }
        needsDisplay = true
    }

    func clear() {
        selectionRects = []
        annotationBorderRect = nil
        isEditingAnnotation = false
        activeHandle = nil
        pendingHandle = nil
        isMovingAnnotation = false
        isPendingInteriorDrag = false
        dragOriginRect = nil
        dragStartPoint = nil
        textAnnotationPreviewStyle = nil
        showsTextAnnotationPreview = false
        needsDisplay = true
    }

    func clearSelection() {
        selectionRects = []
        needsDisplay = true
    }

    private func activatePendingInteractionIfNeeded(currentPoint: NSPoint) {
        guard let start = dragStartPoint else { return }
        let dx = currentPoint.x - start.x
        let dy = currentPoint.y - start.y
        guard hypot(dx, dy) >= dragActivationDistance else { return }

        if isPendingInteriorDrag {
            isPendingInteriorDrag = false
            isMovingAnnotation = true
            showsTextAnnotationPreview = textAnnotationPreviewStyle != nil
            onMoveBegan?()
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        guard activeHandle == nil, let pendingHandle else { return }
        self.pendingHandle = nil
        activeHandle = pendingHandle
        showsTextAnnotationPreview = textAnnotationPreviewStyle != nil
        onResizeBegan?()
        NSCursor.crosshair.set()
        needsDisplay = true
    }
}

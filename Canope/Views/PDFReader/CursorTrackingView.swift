import AppKit

/// View placed over PDFView for cursor control and drawing tool drag interaction.
class CursorTrackingView: NSView {
    var desiredCursor: NSCursor = .arrow
    var interactiveMode = false
    var currentTool: AnnotationTool = .pointer
    var previewColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    var previewScaleFactor: CGFloat = 1.0
    var shouldInterceptPoint: ((_ point: NSPoint) -> Bool)?
    weak var eventPassthroughView: NSView?
    private var trackingArea: NSTrackingArea?

    // Drag state
    private var dragStart: NSPoint?
    private var dragCurrentRect: NSRect?
    private var inkPath: NSBezierPath?
    private var isCustomDragging = false

    // Callbacks
    var onMouseDownAction: ((_ event: NSEvent, _ point: NSPoint) -> CursorMouseDownAction)?
    var onCustomDragChanged: ((_ start: NSPoint, _ current: NSPoint) -> Void)?
    var onCustomDragComplete: ((_ start: NSPoint, _ end: NSPoint) -> Void)?
    var onRectDragComplete: ((_ start: NSPoint, _ end: NSPoint) -> Void)?
    var onInkDragComplete: ((_ path: NSBezierPath) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveMode else { return nil }
        if shouldInterceptPoint?(point) == false {
            return nil
        }
        return self
    }


    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { desiredCursor.set() }
    override func mouseMoved(with event: NSEvent) { desiredCursor.set() }
    override func mouseEntered(with event: NSEvent) { desiredCursor.set() }

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

    // MARK: - Draw feedback

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let strokeColor = AnnotationColor.normalized(previewColor)
        let fillColor = AnnotationColor.normalized(previewColor).withAlphaComponent(0.12)
        let previewStrokeWidth = max(1.5, 2.0 * previewScaleFactor)

        if let rect = dragCurrentRect {
            strokeColor.setStroke()
            fillColor.setFill()
            let path: NSBezierPath
            switch currentTool {
            case .oval:
                path = NSBezierPath(ovalIn: rect)
            case .arrow:
                path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                // Arrowhead
                let angle = atan2(rect.minY - rect.maxY, rect.maxX - rect.minX)
                let headLen: CGFloat = 12
                let p1 = NSPoint(x: rect.maxX - headLen * cos(angle - .pi/6),
                                 y: rect.minY - headLen * sin(angle - .pi/6))
                let p2 = NSPoint(x: rect.maxX - headLen * cos(angle + .pi/6),
                                 y: rect.minY - headLen * sin(angle + .pi/6))
                path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: p1)
                path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: p2)
            default:
                path = NSBezierPath(rect: rect)
            }
            path.lineWidth = previewStrokeWidth
            path.setLineDash([4, 3], count: 2, phase: 0)
            if currentTool != .arrow { path.fill() }
            path.stroke()
        }

        if let ink = inkPath {
            strokeColor.withAlphaComponent(0.9).setStroke()
            ink.lineWidth = previewStrokeWidth
            ink.lineCapStyle = .round
            ink.lineJoinStyle = .round
            ink.stroke()
        }
    }

    // MARK: - Drag interaction

    override func mouseDown(with event: NSEvent) {
        guard interactiveMode else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let action = onMouseDownAction?(event, point) ?? .passThrough
        if action == .handled {
            return
        }

        if action == .beginCustomDrag {
            dragStart = point
            dragCurrentRect = nil
            inkPath = nil
            isCustomDragging = true
            desiredCursor.set()
            return
        }

        dragStart = point
        dragCurrentRect = nil
        if currentTool == .ink {
            let path = NSBezierPath()
            path.move(to: point)
            inkPath = path
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactiveMode, let start = dragStart else { super.mouseDragged(with: event); return }
        let current = convert(event.locationInWindow, from: nil)

        if isCustomDragging {
            onCustomDragChanged?(start, current)
            desiredCursor.set()
            return
        }

        if currentTool == .ink {
            inkPath?.line(to: current)
        } else {
            dragCurrentRect = NSRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y)
            )
        }
        needsDisplay = true
        desiredCursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactiveMode, let start = dragStart else { super.mouseUp(with: event); return }

        let end = convert(event.locationInWindow, from: nil)

        if isCustomDragging {
            dragStart = nil
            isCustomDragging = false
            onCustomDragComplete?(start, end)
            return
        }

        if currentTool == .ink, let path = inkPath {
            dragStart = nil
            if path.bounds.width > 3 || path.bounds.height > 3 {
                onInkDragComplete?(path)
            }
            clearDragPreviewAsync()
            return
        }

        dragStart = nil

        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        guard width > 5 || height > 5 else {
            dragCurrentRect = nil
            needsDisplay = true
            return
        }

        onRectDragComplete?(start, end)
        clearDragPreviewAsync()
    }

    private func clearDragPreviewAsync() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dragCurrentRect = nil
            self.inkPath = nil
            self.needsDisplay = true
        }
    }
}

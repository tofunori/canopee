import SwiftUI
import PDFKit

// MARK: - Selection Overlay

enum ResizeHandle {
    case topLeft, topRight, bottomLeft, bottomRight
}

class SelectionOverlayView: NSView {
    var selectionRects: [NSRect] = []
    var selectionColor: NSColor = AnnotationColor.loadFavorites().first?.withAlphaComponent(0.4) ?? NSColor.yellow.withAlphaComponent(0.4)
    var annotationBorderRect: NSRect? = nil
    let handleSize: CGFloat = 7

    // Resize drag state
    private var activeHandle: ResizeHandle?
    private var dragOriginRect: NSRect?
    private var dragStartPoint: NSPoint?
    var onResizeComplete: ((_ newRect: NSRect) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept if clicking on a resize handle
        if let _ = handleAt(convert(point, from: superview)) {
            return self
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if !selectionRects.isEmpty {
            selectionColor.setFill()
            for rect in selectionRects { rect.fill() }
        }
        if let rect = annotationBorderRect {
            NSColor.black.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = 1.5
            borderPath.setLineDash([4, 3], count: 2, phase: 0)
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
        let hitSize: CGFloat = 10 // larger hit area
        let hitRects = handles.map { $0.insetBy(dx: -hitSize/2, dy: -hitSize/2) }
        if hitRects[0].contains(point) { return .bottomLeft }
        if hitRects[1].contains(point) { return .bottomRight }
        if hitRects[2].contains(point) { return .topLeft }
        if hitRects[3].contains(point) { return .topRight }
        return nil
    }

    // MARK: - Resize Drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handleAt(point), let rect = annotationBorderRect else {
            super.mouseDown(with: event)
            return
        }
        activeHandle = handle
        dragOriginRect = rect
        dragStartPoint = point

        switch handle {
        case .topLeft, .bottomLeft: NSCursor.crosshair.set()
        case .topRight, .bottomRight: NSCursor.crosshair.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = activeHandle, let origin = dragOriginRect, let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y

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
    }

    override func mouseUp(with event: NSEvent) {
        guard activeHandle != nil, let newRect = annotationBorderRect else {
            super.mouseUp(with: event)
            return
        }
        activeHandle = nil
        dragOriginRect = nil
        dragStartPoint = nil
        NSCursor.arrow.set()
        onResizeComplete?(newRect)
    }

    func updateSelection(rects: [NSRect], color: NSColor) {
        selectionRects = rects
        selectionColor = color
        needsDisplay = true
    }

    func updateAnnotationBorder(rect: NSRect?) {
        annotationBorderRect = rect
        needsDisplay = true
    }

    func clear() {
        selectionRects = []
        annotationBorderRect = nil
        needsDisplay = true
    }

    func clearSelection() {
        selectionRects = []
        needsDisplay = true
    }
}

// MARK: - Cursor Tracking View

/// View placed over PDFView for cursor control and drawing tool drag interaction.
class CursorTrackingView: NSView {
    var desiredCursor: NSCursor = .arrow
    var interactiveMode = false
    var currentTool: AnnotationTool = .pointer
    private var trackingArea: NSTrackingArea?

    // Drag state
    private var dragStart: NSPoint?
    private var dragCurrentRect: NSRect?
    private var inkPath: NSBezierPath?

    // Callbacks
    var onRectDragComplete: ((_ start: NSPoint, _ end: NSPoint) -> Void)?
    var onInkDragComplete: ((_ path: NSBezierPath) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveMode ? self : nil
    }

    override var acceptsFirstResponder: Bool { interactiveMode }
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

    // MARK: - Draw feedback

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemBlue.setStroke()

        if let rect = dragCurrentRect {
            NSColor.systemBlue.withAlphaComponent(0.08).setFill()
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
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            if currentTool != .arrow { path.fill() }
            path.stroke()
        }

        if let ink = inkPath {
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
            ink.lineWidth = 2
            ink.lineCapStyle = .round
            ink.lineJoinStyle = .round
            ink.stroke()
        }
    }

    // MARK: - Drag interaction

    override func mouseDown(with event: NSEvent) {
        guard interactiveMode else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
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

        if currentTool == .ink, let path = inkPath {
            inkPath = nil
            needsDisplay = true
            dragStart = nil
            if path.bounds.width > 3 || path.bounds.height > 3 {
                onInkDragComplete?(path)
            }
            return
        }

        dragCurrentRect = nil
        needsDisplay = true
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil

        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        guard width > 5 || height > 5 else { return }

        onRectDragComplete?(start, end)
    }
}

// MARK: - NSViewRepresentable

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentTool: AnnotationTool
    @Binding var currentColor: NSColor
    @Binding var selectedAnnotation: PDFAnnotation?
    @Binding var selectedText: String
    let onDocumentChanged: @MainActor () -> Void
    @Binding var undoAction: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = PDFView()
        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.backgroundColor = .controlBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let overlay = SelectionOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = .clear

        let cursorView = CursorTrackingView()
        cursorView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(pdfView)
        container.addSubview(overlay)
        container.addSubview(cursorView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cursorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cursorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cursorView.topAnchor.constraint(equalTo: container.topAnchor),
            cursorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.pdfView = pdfView
        context.coordinator.overlay = overlay
        context.coordinator.cursorView = cursorView
        context.coordinator.installMouseUpMonitor()
        context.coordinator.updateCursor(for: currentTool)
        context.coordinator.setupDrawingCallbacks()
        context.coordinator.setupResizeCallback()

        // Expose undo to parent view
        DispatchQueue.main.async {
            self.undoAction = { [weak coordinator = context.coordinator] in
                coordinator?.undo()
            }
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleSelectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleViewChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleViewChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: pdfView.documentView
        )

        let clickGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        clickGesture.numberOfClicksRequired = 1
        clickGesture.delegate = context.coordinator
        pdfView.addGestureRecognizer(clickGesture)

        // Double-click to edit FreeText annotations
        let doubleClickGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClickGesture.numberOfClicksRequired = 2
        pdfView.addGestureRecognizer(doubleClickGesture)

        let rightClickGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClickGesture.buttonMask = 0x2
        pdfView.addGestureRecognizer(rightClickGesture)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.currentTool = currentTool
        context.coordinator.currentColor = currentColor

        if let pdfView = context.coordinator.pdfView, pdfView.document !== document {
            pdfView.document = document
        }

        context.coordinator.updateCursor(for: currentTool)
        context.coordinator.updateAnnotationBorder()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMouseUpMonitor()
        coordinator.dismissTextBoxEditing()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSGestureRecognizerDelegate, NSTextViewDelegate {
        let parent: PDFKitView
        weak var pdfView: PDFView?
        weak var overlay: SelectionOverlayView?
        weak var cursorView: CursorTrackingView?
        var currentTool: AnnotationTool = .pointer
        var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
        private var hasActiveSelection = false
        private var isDragging = false
        private var mouseUpMonitor: Any?

        // Undo support
        private var undoStack: [(page: PDFPage, annotation: PDFAnnotation)] = []

        // TextBox editing state
        private var editingScrollView: NSScrollView? = nil
        private var editingTextView: NSTextView? = nil
        private var editingAnnotation: PDFAnnotation? = nil

        init(parent: PDFKitView) {
            self.parent = parent
        }

        // MARK: - Cursor

        func updateCursor(for tool: AnnotationTool) {
            let cursor: NSCursor
            switch tool {
            case .highlight, .underline, .strikethrough:
                cursor = .iBeam
            case .note, .textBox, .ink, .rectangle, .oval, .arrow:
                cursor = .crosshair
            case .pointer:
                cursor = .arrow
            }
            cursorView?.desiredCursor = cursor
            // Drawing tools: make cursorView interactive
            cursorView?.interactiveMode = tool.needsDragInteraction
            cursorView?.currentTool = tool
            cursor.set()
        }

        // MARK: - Undo

        func recordForUndo(page: PDFPage, annotation: PDFAnnotation) {
            undoStack.append((page: page, annotation: annotation))
            // Keep max 50 undo steps
            if undoStack.count > 50 { undoStack.removeFirst() }
        }

        func undo() {
            guard let last = undoStack.popLast() else { return }
            last.page.removeAnnotation(last.annotation)
            if parent.selectedAnnotation === last.annotation {
                parent.selectedAnnotation = nil
            }
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        // MARK: - TextBox Drag-to-Create (via CursorTrackingView)

        func setupDrawingCallbacks() {
            cursorView?.onRectDragComplete = { [weak self] start, end in
                self?.handleRectDragComplete(start: start, end: end)
            }
            cursorView?.onInkDragComplete = { [weak self] path in
                self?.handleInkDragComplete(viewPath: path)
            }
        }

        func setupResizeCallback() {
            overlay?.onResizeComplete = { [weak self] newOverlayRect in
                self?.handleResizeComplete(newOverlayRect)
            }
        }

        private func handleResizeComplete(_ newOverlayRect: NSRect) {
            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let annotation = parent.selectedAnnotation,
                  let page = annotation.page else { return }

            // Convert overlay rect → pdfView rect → page rect
            let viewRect = pdfView.convert(newOverlayRect, from: overlay)
            let pageRect = pdfView.convert(viewRect, to: page)

            annotation.bounds = pageRect
            pdfView.setNeedsDisplay(pdfView.bounds)
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        private func handleRectDragComplete(start: NSPoint, end: NSPoint) {
            guard let pdfView = pdfView, let cursorView = cursorView else { return }
            dismissTextBoxEditing()

            let startView = cursorView.convert(start, to: pdfView)
            let endView = cursorView.convert(end, to: pdfView)

            guard let page = pdfView.page(for: startView, nearest: true) else { return }
            let startPage = pdfView.convert(startView, to: page)
            let endPage = pdfView.convert(endView, to: page)

            let bounds = CGRect(
                x: min(startPage.x, endPage.x), y: min(startPage.y, endPage.y),
                width: abs(endPage.x - startPage.x), height: abs(endPage.y - startPage.y)
            )
            guard bounds.width > 5, bounds.height > 5 else { return }

            switch currentTool {
            case .textBox:
                let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                annotation.contents = ""
                annotation.font = NSFont.systemFont(ofSize: 12)
                annotation.fontColor = .black
                annotation.color = currentColor.withAlphaComponent(0.15)
                let border = PDFBorder()
                border.lineWidth = 1.5
                annotation.border = border
                page.addAnnotation(annotation)
                recordForUndo(page: page, annotation: annotation)
                parent.onDocumentChanged()
                beginEditingTextBox(annotation, on: page)

            case .rectangle:
                let annotation = AnnotationService.createShapeAnnotation(
                    bounds: bounds, type: .square, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                parent.onDocumentChanged()

            case .oval:
                let annotation = AnnotationService.createShapeAnnotation(
                    bounds: bounds, type: .circle, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                parent.onDocumentChanged()

            case .arrow:
                let startPt = CGPoint(x: startPage.x, y: startPage.y)
                let endPt = CGPoint(x: endPage.x, y: endPage.y)
                let annotation = AnnotationService.createArrowAnnotation(
                    from: startPt, to: endPt, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                parent.onDocumentChanged()

            default:
                break
            }
        }

        private func handleInkDragComplete(viewPath: NSBezierPath) {
            guard let pdfView = pdfView, let cursorView = cursorView else { return }

            // Convert path from cursorView coordinates to page coordinates
            let midPoint = NSPoint(x: viewPath.bounds.midX, y: viewPath.bounds.midY)
            let midInPDF = cursorView.convert(midPoint, to: pdfView)
            guard let page = pdfView.page(for: midInPDF, nearest: true) else { return }

            // Build a new path in page coordinates
            let pagePath = NSBezierPath()
            let elements = viewPath.elementCount
            var points = [NSPoint](repeating: .zero, count: 3)
            for i in 0..<elements {
                let type = viewPath.element(at: i, associatedPoints: &points)
                let viewPt = cursorView.convert(points[0], to: pdfView)
                let pagePt = pdfView.convert(viewPt, to: page)
                switch type {
                case .moveTo: pagePath.move(to: pagePt)
                case .lineTo: pagePath.line(to: pagePt)
                default: pagePath.line(to: pagePt)
                }
            }

            let annotation = AnnotationService.createInkAnnotation(
                path: pagePath, on: page,
                color: currentColor, lineWidth: 2
            )
            recordForUndo(page: page, annotation: annotation)
            parent.onDocumentChanged()
        }

        /// Start inline editing of a FreeText annotation using NSTextView
        func beginEditingTextBox(_ annotation: PDFAnnotation, on page: PDFPage) {
            guard let pdfView = pdfView, let documentView = pdfView.documentView else { return }
            dismissTextBoxEditing()

            let viewRect = pdfView.convert(annotation.bounds, from: page)
            let docRect = documentView.convert(viewRect, from: pdfView)

            // NSTextView in NSScrollView for proper text editing
            let insetDocRect = docRect.insetBy(dx: 2, dy: 2)
            let scrollView = NSScrollView(frame: insetDocRect)
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false

            // Inset the text view slightly inside the annotation bounds
            let insetRect = docRect.insetBy(dx: 2, dy: 2)
            let textView = NSTextView(frame: NSRect(origin: .zero, size: insetRect.size))
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = annotation.font ?? NSFont.systemFont(ofSize: 12)
            textView.textColor = annotation.fontColor ?? .black
            textView.backgroundColor = .white
            textView.drawsBackground = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.string = annotation.contents ?? ""
            textView.alignment = annotation.alignment
            textView.delegate = self
            textView.textContainerInset = NSSize(width: 2, height: 2)

            // Select all text for easy replacement
            textView.selectAll(nil)

            scrollView.documentView = textView

            editingAnnotation = annotation
            editingScrollView = scrollView
            editingTextView = textView
            documentView.addSubview(scrollView)
            pdfView.window?.makeFirstResponder(textView)
        }

        // NSTextViewDelegate — commit on Escape or when focus lost
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape → commit and close
                commitTextBoxEditing()
                return true
            }
            return false
        }

        func textDidEndEditing(_ notification: Notification) {
            commitTextBoxEditing()
        }

        func commitTextBoxEditing() {
            guard let annotation = editingAnnotation,
                  let textView = editingTextView else { return }

            let text = textView.string
            annotation.contents = text

            editingScrollView?.removeFromSuperview()
            editingScrollView = nil
            editingTextView = nil
            editingAnnotation = nil

            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        func dismissTextBoxEditing() {
            if editingTextView != nil {
                commitTextBoxEditing()
            }
        }

        // MARK: - Mouse Up Monitor

        func installMouseUpMonitor() {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.handleMouseUp()
                return event
            }
        }

        func removeMouseUpMonitor() {
            if let monitor = mouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                mouseUpMonitor = nil
            }
        }

        private func handleMouseUp() {
            guard isDragging else { return }
            isDragging = false
            overlay?.clearSelection()

            guard [.highlight, .underline, .strikethrough].contains(currentTool),
                  hasActiveSelection else { return }

            applyTextMarkup()
        }

        // MARK: - Annotation Selection Border

        func updateAnnotationBorder() {
            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let annotation = parent.selectedAnnotation,
                  let page = annotation.page else {
                overlay?.updateAnnotationBorder(rect: nil)
                return
            }
            let viewRect = pdfView.convert(annotation.bounds, from: page)
            let overlayRect = overlay.convert(viewRect, from: pdfView)
            overlay.updateAnnotationBorder(rect: overlayRect)
        }

        @objc func handleViewChanged(_ notification: Notification) {
            updateAnnotationBorder()
        }

        // MARK: - Selection Overlay

        private func updateSelectionOverlay() {
            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let selection = pdfView.currentSelection,
                  [.highlight, .underline, .strikethrough].contains(currentTool) else {
                overlay?.clearSelection()
                return
            }
            let lineSelections = selection.selectionsByLine()
            var viewRects: [NSRect] = []
            for line in lineSelections {
                guard let page = line.pages.first else { continue }
                let pageBounds = line.bounds(for: page)
                guard pageBounds.width > 0, pageBounds.height > 0 else { continue }
                let viewRect = pdfView.convert(pageBounds, from: page)
                let overlayRect = overlay.convert(viewRect, from: pdfView)
                viewRects.append(overlayRect)
            }
            let color: NSColor = currentTool == .highlight
                ? currentColor.withAlphaComponent(0.4)
                : currentColor.withAlphaComponent(0.6)
            overlay.updateSelection(rects: viewRects, color: color)
        }

        // MARK: - Hit Testing

        private func annotationAtPoint(_ viewPoint: NSPoint) -> PDFAnnotation? {
            guard let pdfView = pdfView,
                  let page = pdfView.page(for: viewPoint, nearest: false) else { return nil }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            for annotation in page.annotations.reversed() {
                if annotation.type == "Link" || annotation.type == "Widget" { continue }
                if annotation.bounds.contains(pagePoint) { return annotation }
            }
            return nil
        }

        // MARK: - Text Selection

        @objc func handleSelectionChanged(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let selection = pdfView.currentSelection,
                  let text = selection.string,
                  !text.isEmpty else {
                hasActiveSelection = false
                parent.selectedText = ""
                if isDragging { overlay?.clearSelection() }
                return
            }
            hasActiveSelection = true
            isDragging = true
            parent.selectedText = text
            // Write selection to temp file so Claude Code can read it
            try? text.write(toFile: "/tmp/canopee_selection.txt", atomically: true, encoding: .utf8)
            updateSelectionOverlay()
        }

        func applyTextMarkup() {
            guard let pdfView = pdfView,
                  let selection = pdfView.currentSelection,
                  hasActiveSelection else { return }

            let annotationType: PDFAnnotationSubtype
            switch currentTool {
            case .highlight: annotationType = .highlight
            case .underline: annotationType = .underline
            case .strikethrough: annotationType = .strikeOut
            default: return
            }

            let annotations = AnnotationService.createMarkupAnnotation(
                selection: selection,
                type: annotationType,
                color: currentColor,
                on: pdfView
            )

            // Record for undo
            for (page, annotation) in annotations {
                recordForUndo(page: page, annotation: annotation)
            }

            pdfView.clearSelection()
            hasActiveSelection = false
            parent.onDocumentChanged()
        }

        // MARK: - Click Handling

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }
            let locationInView = gesture.location(in: pdfView)

            if currentTool == .pointer {
                if let annotation = annotationAtPoint(locationInView) {
                    parent.selectedAnnotation = annotation
                } else {
                    parent.selectedAnnotation = nil
                }
                updateAnnotationBorder()
                return
            }

            if currentTool == .note {
                guard let page = pdfView.page(for: locationInView, nearest: true) else { return }
                let pagePoint = pdfView.convert(locationInView, to: page)
                let annotation = AnnotationService.createNoteAnnotation(
                    at: pagePoint, on: page, text: "", color: currentColor
                )
                recordForUndo(page: page, annotation: annotation)
                parent.selectedAnnotation = annotation
                parent.onDocumentChanged()
                return
            }

            // textBox is handled by drag monitors, not click
        }

        // MARK: - Double Click (edit FreeText)

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }
            let locationInView = gesture.location(in: pdfView)
            guard let annotation = annotationAtPoint(locationInView),
                  annotation.type == "FreeText",
                  let page = annotation.page else { return }
            beginEditingTextBox(annotation, on: page)
        }

        // MARK: - Right Click

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }
            let locationInView = gesture.location(in: pdfView)
            guard let annotation = annotationAtPoint(locationInView) else { return }
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()

            let menu = NSMenu()
            let colorMenu = NSMenu()
            for item in AnnotationColor.all {
                let menuItem = NSMenuItem(title: item.name, action: #selector(changeAnnotationColor(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.color
                let image = NSImage(size: NSSize(width: 12, height: 12))
                image.lockFocus()
                item.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
                image.unlockFocus()
                menuItem.image = image
                colorMenu.addItem(menuItem)
            }
            let colorItem = NSMenuItem(title: "Couleur", action: nil, keyEquivalent: "")
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)

            let editItem = NSMenuItem(title: "Modifier la note…", action: #selector(editAnnotationNote(_:)), keyEquivalent: "")
            editItem.target = self
            editItem.representedObject = annotation
            menu.addItem(editItem)

            // FreeText-specific formatting options
            if annotation.type == "FreeText" {
                menu.addItem(NSMenuItem.separator())

                // Font size submenu
                let sizeMenu = NSMenu()
                for size in [8, 10, 12, 14, 16, 18, 20, 24, 28, 32] {
                    let item = NSMenuItem(title: "\(size) pt", action: #selector(changeFontSize(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = size
                    if Int(annotation.font?.pointSize ?? 12) == size {
                        item.state = .on
                    }
                    sizeMenu.addItem(item)
                }
                let sizeItem = NSMenuItem(title: "Taille", action: nil, keyEquivalent: "")
                sizeItem.submenu = sizeMenu
                menu.addItem(sizeItem)

                // Text color submenu
                let textColorMenu = NSMenu()
                for (name, nsColor) in [("Noir", NSColor.black), ("Blanc", NSColor.white),
                    ("Rouge", NSColor.systemRed), ("Bleu", NSColor.systemBlue),
                    ("Vert", NSColor.systemGreen), ("Orange", NSColor.systemOrange)] {
                    let item = NSMenuItem(title: name, action: #selector(changeFontColor(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = nsColor
                    let img = NSImage(size: NSSize(width: 12, height: 12))
                    img.lockFocus()
                    nsColor.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
                    img.unlockFocus()
                    item.image = img
                    textColorMenu.addItem(item)
                }
                let textColorItem = NSMenuItem(title: "Couleur du texte", action: nil, keyEquivalent: "")
                textColorItem.submenu = textColorMenu
                menu.addItem(textColorItem)

                // Alignment submenu
                let alignMenu = NSMenu()
                for (name, alignment) in [("Gauche", NSTextAlignment.left),
                    ("Centre", NSTextAlignment.center),
                    ("Droite", NSTextAlignment.right),
                    ("Justifié", NSTextAlignment.justified)] {
                    let item = NSMenuItem(title: name, action: #selector(changeAlignment(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = alignment.rawValue
                    if annotation.alignment == alignment {
                        item.state = .on
                    }
                    alignMenu.addItem(item)
                }
                let alignItem = NSMenuItem(title: "Alignement", action: nil, keyEquivalent: "")
                alignItem.submenu = alignMenu
                menu.addItem(alignItem)
            }

            menu.addItem(NSMenuItem.separator())

            let deleteItem = NSMenuItem(title: "Supprimer", action: #selector(deleteSelectedAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = annotation
            menu.addItem(deleteItem)

            menu.popUp(positioning: nil, at: gesture.location(in: pdfView), in: pdfView)
        }

        @objc func changeAnnotationColor(_ sender: NSMenuItem) {
            guard let color = sender.representedObject as? NSColor,
                  let annotation = parent.selectedAnnotation else { return }
            annotation.color = annotation.type == "Highlight" ? color.withAlphaComponent(0.4) : color
            pdfView?.setNeedsDisplay(annotation.bounds)
            parent.onDocumentChanged()
        }

        @objc func changeFontSize(_ sender: NSMenuItem) {
            guard let annotation = parent.selectedAnnotation, annotation.type == "FreeText" else { return }
            let size = CGFloat(sender.tag)
            annotation.font = NSFont.systemFont(ofSize: size)
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func changeFontColor(_ sender: NSMenuItem) {
            guard let color = sender.representedObject as? NSColor,
                  let annotation = parent.selectedAnnotation, annotation.type == "FreeText" else { return }
            annotation.fontColor = color
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func changeAlignment(_ sender: NSMenuItem) {
            guard let annotation = parent.selectedAnnotation, annotation.type == "FreeText" else { return }
            annotation.alignment = NSTextAlignment(rawValue: sender.tag) ?? .left
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func editAnnotationNote(_ sender: NSMenuItem) {
            guard let annotation = sender.representedObject as? PDFAnnotation else { return }
            parent.selectedAnnotation = annotation
            parent.onDocumentChanged()
        }

        @objc func deleteSelectedAnnotation(_ sender: NSMenuItem) {
            guard let annotation = sender.representedObject as? PDFAnnotation,
                  let page = annotation.page else { return }
            page.removeAnnotation(annotation)
            parent.selectedAnnotation = nil
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        // MARK: - Gesture Delegate

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            if event.type == .rightMouseDown { return true }
            return currentTool == .pointer || currentTool == .note || currentTool == .textBox
        }
    }
}

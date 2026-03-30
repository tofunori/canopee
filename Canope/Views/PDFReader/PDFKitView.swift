import SwiftUI
import PDFKit

// MARK: - Selection Overlay

enum ResizeHandle {
    case topLeft, topRight, bottomLeft, bottomRight
}

class SelectionOverlayView: NSView {
    var selectionRects: [NSRect] = []
    var selectionColor: NSColor = AnnotationColor.previewColor(AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow, for: .highlight)
    var selectionTool: AnnotationTool = .highlight
    var annotationBorderRect: NSRect? = nil
    let handleSize: CGFloat = 7

    override var isOpaque: Bool { false }

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

    func updateSelection(rects: [NSRect], color: NSColor, tool: AnnotationTool) {
        selectionRects = rects
        selectionColor = color
        selectionTool = tool
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
    var previewColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    var previewScaleFactor: CGFloat = 1.0
    private var trackingArea: NSTrackingArea?

    // Drag state
    private var dragStart: NSPoint?
    private var dragCurrentRect: NSRect?
    private var inkPath: NSBezierPath?

    // Callbacks
    var onMouseDownIntercept: ((_ event: NSEvent, _ point: NSPoint) -> Bool)?
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
        if onMouseDownIntercept?(event, point) == true {
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
            dragStart = nil
            if path.bounds.width > 3 || path.bounds.height > 3 {
                onInkDragComplete?(path)
            }
            clearDragPreviewAsync()
            return
        }

        let end = convert(event.locationInWindow, from: nil)
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

final class InteractivePDFView: PDFView {
    var onPreMouseDown: ((NSEvent, NSPoint, InteractivePDFView) -> Bool)?
    var onPostMouseUp: ((NSPoint) -> Void)?
    var selectionPreviewTool: AnnotationTool = .pointer
    var selectionPreviewColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow

    private func preferredSelectionColor() -> NSColor? {
        switch selectionPreviewTool {
        case .highlight:
            return AnnotationColor.annotationColor(selectionPreviewColor, for: .highlight)
        case .underline, .strikethrough:
            return .clear
        default:
            return nil
        }
    }

    private func prepareSelectionAppearance(_ selection: PDFSelection?) {
        selection?.color = preferredSelectionColor()
    }

    func refreshCurrentSelectionAppearance() {
        currentSelection?.color = preferredSelectionColor()
    }

    override var currentSelection: PDFSelection? {
        get { super.currentSelection }
        set {
            prepareSelectionAppearance(newValue)
            super.currentSelection = newValue
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if onPreMouseDown?(event, location, self) == true {
            return
        }
        super.mouseDown(with: event)
        refreshCurrentSelectionAppearance()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        refreshCurrentSelectionAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        refreshCurrentSelectionAppearance()

        guard event.type == .leftMouseUp, event.clickCount == 1 else { return }
        onPostMouseUp?(convert(event.locationInWindow, from: nil))
    }

    override func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {
        prepareSelectionAppearance(selection)
        super.setCurrentSelection(selection, animate: animate)
        refreshCurrentSelectionAppearance()
    }
}

// MARK: - NSViewRepresentable

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentTool: AnnotationTool
    @Binding var currentColor: NSColor
    @Binding var selectedAnnotation: PDFAnnotation?
    @Binding var selectedText: String
    let restoredPageIndex: Int?
    let onDocumentChanged: @MainActor () -> Void
    let onCurrentPageChanged: @MainActor (Int) -> Void
    let onMarkupAppearanceNeedsRefresh: @MainActor () -> Void
    @Binding var clearSelectionAction: (() -> Void)?
    @Binding var undoAction: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = InteractivePDFView()
        pdfView.document = document
        pdfView.selectionPreviewTool = currentTool
        pdfView.selectionPreviewColor = currentColor
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.backgroundColor = .controlBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        if let restoredPageIndex,
           let restoredPage = document.page(at: restoredPageIndex) {
            pdfView.go(to: restoredPage)
        }

        let overlay = SelectionOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = .clear

        let cursorView = CursorTrackingView()
        cursorView.translatesAutoresizingMaskIntoConstraints = false
        cursorView.previewColor = currentColor
        cursorView.previewScaleFactor = pdfView.scaleFactor

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
        cursorView.onMouseDownIntercept = { [weak coordinator = context.coordinator] event, location in
            coordinator?.handleInteractiveMouseDown(event: event, at: location) ?? false
        }
        pdfView.onPreMouseDown = { [weak coordinator = context.coordinator] event, location, pdfView in
            coordinator?.handlePreMouseDown(event: event, at: location, in: pdfView) ?? false
        }
        pdfView.onPostMouseUp = { [weak coordinator = context.coordinator] location in
            coordinator?.handlePostMouseUp(at: location)
        }
        context.coordinator.installMouseUpMonitor()
        context.coordinator.updateCursor(for: currentTool)
        context.coordinator.setupDrawingCallbacks()
        context.coordinator.setupResizeCallback()

        // Expose undo to parent view
        DispatchQueue.main.async {
            self.undoAction = { [weak coordinator = context.coordinator] in
                coordinator?.undo()
            }
            self.clearSelectionAction = { [weak coordinator = context.coordinator] in
                coordinator?.clearCurrentTextSelection()
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
            selector: #selector(Coordinator.handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleViewChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: pdfView.documentView
        )

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
            let viewState = context.coordinator.captureViewState()
            context.coordinator.clearTransientInteractionState()
            pdfView.document = nil
            pdfView.document = document
            pdfView.layoutDocumentView()
            context.coordinator.restoreViewState(viewState)
        }

        context.coordinator.pdfView?.selectionPreviewTool = currentTool
        context.coordinator.pdfView?.selectionPreviewColor = currentColor
        context.coordinator.cursorView?.previewColor = currentColor
        context.coordinator.cursorView?.previewScaleFactor = context.coordinator.pdfView?.scaleFactor ?? 1.0

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
        private static let selectionFileQueue = DispatchQueue(label: "canope.selection-file", qos: .utility)

        struct ViewState {
            let pageIndex: Int
            let pagePoint: NSPoint
            let scaleFactor: CGFloat
        }

        let parent: PDFKitView
        weak var pdfView: InteractivePDFView?
        weak var overlay: SelectionOverlayView?
        weak var cursorView: CursorTrackingView?
        var currentTool: AnnotationTool = .pointer
        var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
        private var hasActiveSelection = false
        private var isDragging = false
        private var isApplyingTextMarkup = false
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

        func captureViewState() -> ViewState? {
            guard let pdfView = pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return nil }

            let pageIndex = document.index(for: page)
            let scaleFactor = pdfView.scaleFactor

            guard let documentView = pdfView.documentView else {
                return ViewState(pageIndex: pageIndex, pagePoint: .zero, scaleFactor: scaleFactor)
            }

            let visibleRect = documentView.visibleRect
            let centerInDocumentView = NSPoint(x: visibleRect.midX, y: visibleRect.midY)
            let centerInPDFView = pdfView.convert(centerInDocumentView, from: documentView)
            let pagePoint = pdfView.convert(centerInPDFView, to: page)

            return ViewState(pageIndex: pageIndex, pagePoint: pagePoint, scaleFactor: scaleFactor)
        }

        func restoreViewState(_ state: ViewState?) {
            guard let state,
                  let pdfView = pdfView,
                  let document = pdfView.document,
                  let page = document.page(at: state.pageIndex) else { return }

            pdfView.go(to: PDFDestination(page: page, at: state.pagePoint))
            pdfView.scaleFactor = state.scaleFactor
            pdfView.layoutDocumentView()
            pdfView.go(to: PDFDestination(page: page, at: state.pagePoint))
        }

        func updateCursor(for tool: AnnotationTool) {
            pdfView?.selectionPreviewTool = tool
            pdfView?.selectionPreviewColor = currentColor
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
            cursorView?.interactiveMode = tool.needsDragInteraction && editingTextView == nil
            cursorView?.currentTool = tool
            cursorView?.previewColor = currentColor
            cursorView?.previewScaleFactor = pdfView?.scaleFactor ?? 1.0
            cursorView?.needsDisplay = true
            cursor.set()
            updateSelectionDismissInterception()
            refreshSelectionAppearance()
        }

        private func syncCursorViewInteractivity() {
            cursorView?.interactiveMode = currentTool.needsDragInteraction && editingTextView == nil
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
                annotation.color = AnnotationColor.annotationColor(currentColor, for: "FreeText")
                let border = PDFBorder()
                border.lineWidth = 1.5
                annotation.border = border
                page.addAnnotation(annotation)
                recordForUndo(page: page, annotation: annotation)
                parent.selectedAnnotation = annotation
                updateAnnotationBorder()
                parent.onDocumentChanged()
                beginEditingTextBox(annotation, on: page)

            case .rectangle:
                let annotation = AnnotationService.createShapeAnnotation(
                    bounds: bounds, type: .square, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                finishCreatingDrawableAnnotation(annotation)
                parent.onDocumentChanged()

            case .oval:
                let annotation = AnnotationService.createShapeAnnotation(
                    bounds: bounds, type: .circle, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                finishCreatingDrawableAnnotation(annotation)
                parent.onDocumentChanged()

            case .arrow:
                let startPt = CGPoint(x: startPage.x, y: startPage.y)
                let endPt = CGPoint(x: endPage.x, y: endPage.y)
                let annotation = AnnotationService.createArrowAnnotation(
                    from: startPt, to: endPt, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                finishCreatingDrawableAnnotation(annotation)
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
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        private func finishCreatingDrawableAnnotation(_ annotation: PDFAnnotation) {
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            parent.currentTool = .pointer
            currentTool = .pointer
            updateCursor(for: .pointer)
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
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            documentView.addSubview(scrollView)
            syncCursorViewInteractivity()
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

            syncCursorViewInteractivity()
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        func dismissTextBoxEditing() {
            if editingTextView != nil {
                commitTextBoxEditing()
            }
        }

        func handleInteractiveMouseDown(event: NSEvent, at locationInCursorView: NSPoint) -> Bool {
            guard currentTool == .textBox,
                  let cursorView = cursorView,
                  let pdfView = pdfView else { return false }

            let locationInPDFView = cursorView.convert(locationInCursorView, to: pdfView)
            guard let annotation = annotationAtPoint(locationInPDFView),
                  annotation.type == "FreeText",
                  let page = annotation.page else {
                return false
            }

            dismissTextBoxEditing()
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()

            if event.clickCount >= 2 {
                beginEditingTextBox(annotation, on: page)
            }

            return true
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

            guard [.highlight, .underline, .strikethrough].contains(currentTool),
                  let pdfView = pdfView,
                  let liveSelection = pdfView.currentSelection,
                  let selection = liveSelection.copy() as? PDFSelection,
                  hasActiveSelection else {
                overlay?.clearSelection()
                return
            }

            isApplyingTextMarkup = true

            DispatchQueue.main.async { [weak self] in
                self?.applyTextMarkup(using: selection)
            }
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
            cursorView?.previewScaleFactor = pdfView?.scaleFactor ?? 1.0
            cursorView?.needsDisplay = true
            updateAnnotationBorder()
        }

        @objc func handlePageChanged(_ notification: Notification) {
            guard let pdfView = pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            parent.onCurrentPageChanged(document.index(for: page))
        }

        // MARK: - Selection Overlay

        private func updateSelectionOverlay() {
            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let selection = pdfView.currentSelection,
                  [.underline, .strikethrough].contains(currentTool) else {
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
            overlay.updateSelection(
                rects: viewRects,
                color: AnnotationColor.previewColor(currentColor, for: currentTool),
                tool: currentTool
            )
        }

        private func refreshSelectionAppearance() {
            guard let pdfView = pdfView else { return }

            guard pdfView.currentSelection != nil else {
                overlay?.clearSelection()
                return
            }

            switch currentTool {
            case .highlight:
                pdfView.refreshCurrentSelectionAppearance()
                overlay?.clearSelection()
            case .underline, .strikethrough:
                pdfView.refreshCurrentSelectionAppearance()
                updateSelectionOverlay()
            default:
                pdfView.refreshCurrentSelectionAppearance()
                overlay?.clearSelection()
            }

            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true
        }

        private func writeSelectionSnapshot(_ text: String) {
            Self.selectionFileQueue.async {
                try? text.write(toFile: "/tmp/canope_selection.txt", atomically: true, encoding: .utf8)
            }
        }

        private func clearNativePDFSelection() {
            guard let pdfView = pdfView else { return }

            if let selection = pdfView.currentSelection?.copy() as? PDFSelection {
                // Make the native PDFKit highlight disappear before the selection
                // object is fully cleared; this avoids the last visible lag frame.
                selection.color = .clear
                pdfView.setCurrentSelection(selection, animate: false)
                pdfView.documentView?.displayIfNeeded()
                pdfView.displayIfNeeded()
            }

            pdfView.clearSelection()
            pdfView.setCurrentSelection(nil, animate: false)
            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true
        }

        private func clearTextSelectionState() {
            hasActiveSelection = false
            isDragging = false
            overlay?.clearSelection()
            parent.selectedText = ""
            writeSelectionSnapshot("(no text currently selected)")

            clearNativePDFSelection()
            updateSelectionDismissInterception()
        }

        func clearTransientInteractionState() {
            clearTextSelectionState()
            dismissTextBoxEditing()
            parent.selectedAnnotation = nil
            overlay?.clear()
        }

        func clearCurrentTextSelection() {
            clearTextSelectionState()
        }

        private func updateSelectionDismissInterception() {
            // Keep API surface stable for callers; selection dismissal is now handled
            // by clearing native PDFView selection on mouseDown, following Skim's pattern.
        }

        func handlePreMouseDown(event: NSEvent, at locationInView: NSPoint, in pdfView: InteractivePDFView) -> Bool {
            guard currentTool == .pointer else { return false }

            pdfView.window?.makeFirstResponder(pdfView)

            guard hasActiveSelection || pdfView.currentSelection != nil else { return false }

            let area = pdfView.areaOfInterest(for: locationInView)
            let clickedText = area.contains(.textArea)
            let clickedAnnotation = area.contains(.annotationArea) || annotationAtPoint(locationInView) != nil

            if clickedText {
                return false
            }

            clearTextSelectionState()

            if clickedAnnotation, let annotation = annotationAtPoint(locationInView) {
                parent.selectedAnnotation = annotation
                updateAnnotationBorder()
            } else {
                parent.selectedAnnotation = nil
                updateAnnotationBorder()
            }

            return true
        }

        func handlePostMouseUp(at locationInView: NSPoint) {
            guard let pdfView = pdfView else { return }

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

            guard currentTool == .pointer else { return }

            if let annotation = annotationAtPoint(locationInView) {
                clearTextSelectionState()
                parent.selectedAnnotation = annotation
                updateAnnotationBorder()
                return
            }

            guard hasActiveSelection || pdfView.currentSelection != nil || parent.selectedAnnotation != nil else { return }
            clearTextSelectionState()
            parent.selectedAnnotation = nil
            updateAnnotationBorder()
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
            if isApplyingTextMarkup {
                return
            }

            guard let pdfView = pdfView,
                  let selection = pdfView.currentSelection,
                  let text = selection.string,
                  !text.isEmpty else {
                hasActiveSelection = false
                parent.selectedText = ""
                // Clear selection file
                writeSelectionSnapshot("(no text currently selected)")
                overlay?.clearSelection()
                updateSelectionDismissInterception()
                return
            }
            hasActiveSelection = true
            isDragging = true
            parent.selectedText = text
            // Write selection to temp file so Claude Code can read it
            let content = "[Source: PDF reader]\n\(text)"
            writeSelectionSnapshot(content)
            refreshSelectionAppearance()
            updateSelectionDismissInterception()
        }

        func applyTextMarkup(using selection: PDFSelection) {
            let annotationType: PDFAnnotationSubtype
            switch currentTool {
            case .highlight: annotationType = .highlight
            case .underline: annotationType = .underline
            case .strikethrough: annotationType = .strikeOut
            default:
                isApplyingTextMarkup = false
                return
            }

            guard let pdfView = pdfView else {
                isApplyingTextMarkup = false
                return
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

            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true
            pdfView.documentView?.displayIfNeeded()
            pdfView.displayIfNeeded()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearTextSelectionState()
                self.isApplyingTextMarkup = false
                pdfView.setNeedsDisplay(pdfView.bounds)
                self.parent.onDocumentChanged()
            }
        }

        // MARK: - Double Click (edit FreeText)

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView else { return }
            let locationInView = gesture.location(in: pdfView)
            guard let annotation = annotationAtPoint(locationInView),
                  annotation.type == "FreeText",
                  let page = annotation.page else { return }
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
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
            annotation.color = AnnotationColor.annotationColor(color, for: annotation.type ?? "")
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

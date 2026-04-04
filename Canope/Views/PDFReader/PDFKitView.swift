import SwiftUI
import PDFKit

// MARK: - NSViewRepresentable

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let fileURL: URL
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
    @Binding var applyBridgeAnnotation: ((_ selection: PDFSelection, _ type: PDFAnnotationSubtype, _ color: NSColor) -> Void)?
    let onUserInteraction: @MainActor () -> Void

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
        overlay.eventPassthroughView = pdfView

        let cursorView = CursorTrackingView()
        cursorView.translatesAutoresizingMaskIntoConstraints = false
        cursorView.previewColor = currentColor
        cursorView.previewScaleFactor = pdfView.scaleFactor
        cursorView.eventPassthroughView = pdfView

        container.addSubview(pdfView)
        container.addSubview(cursorView)
        container.addSubview(overlay)

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
        cursorView.onMouseDownAction = { [weak coordinator = context.coordinator] event, location in
            coordinator?.handleInteractiveMouseDown(event: event, at: location) ?? .passThrough
        }
        cursorView.shouldInterceptPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.shouldCursorViewIntercept(pointInCursorView: point) ?? true
        }
        pdfView.onPreMouseDown = { [weak coordinator = context.coordinator] event, location, pdfView in
            coordinator?.handlePreMouseDown(event: event, at: location, in: pdfView) ?? false
        }
        pdfView.onPostMouseUp = { [weak coordinator = context.coordinator] location in
            coordinator?.handlePostMouseUp(at: location)
        }
        pdfView.onUserInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.recordUserInteraction()
        }
        context.coordinator.installMouseUpMonitor()
        context.coordinator.installMagnifyMonitor()
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
            self.applyBridgeAnnotation = { [weak coordinator = context.coordinator] selection, type, color in
                coordinator?.applyBridgeAnnotation(selection: selection, type: type, color: color)
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
        context.coordinator.syncEditingViewAppearance()
        context.coordinator.updateAnnotationBorder()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMouseUpMonitor()
        coordinator.removeMagnifyMonitor()
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
        private var magnifyMonitor: Any?

        // Undo support
        private var undoStack: [(page: PDFPage, annotation: PDFAnnotation)] = []

        // TextBox editing state
        private var editingEditorView: TextNoteEditorView? = nil
        private var editingTextView: NSTextView? = nil
        private var editingAnnotation: PDFAnnotation? = nil
        private var shouldRestoreTextEditingAfterResize = false
        private var cursorDragOriginOverlayRect: NSRect?
        private var isManipulatingSelectedTextAnnotation = false

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
            case .highlight:
                cursor = .iBeam
            case .underline, .strikethrough:
                cursor = AnnotationCursorFactory.cursor(for: tool, color: currentColor)
            case .note, .textBox, .ink, .rectangle, .oval, .arrow:
                cursor = .crosshair
            case .pointer:
                cursor = .arrow
            }
            cursorView?.desiredCursor = cursor
            // Keep PDFView in charge of trackpad zoom/scroll when a text box is selected.
            cursorView?.interactiveMode = shouldEnableCursorInteraction(for: tool)
            cursorView?.currentTool = tool
            cursorView?.previewColor = currentColor
            cursorView?.previewScaleFactor = pdfView?.scaleFactor ?? 1.0
            cursorView?.needsDisplay = true
            cursor.set()
            updateSelectionDismissInterception()
            refreshSelectionAppearance()
        }

        private func syncCursorViewInteractivity() {
            cursorView?.interactiveMode = shouldEnableCursorInteraction(for: currentTool)
        }

        private func shouldEnableCursorInteraction(for tool: AnnotationTool) -> Bool {
            guard tool.needsDragInteraction, editingTextView == nil else { return false }

            if tool == .textBox,
               let selectedAnnotation = parent.selectedAnnotation,
               selectedAnnotation.isTextBoxAnnotation {
                return false
            }

            return true
        }

        func shouldCursorViewIntercept(pointInCursorView: NSPoint) -> Bool {
            guard let cursorView = cursorView else { return true }

            if let overlay = overlay {
                let pointInOverlay = overlay.convert(pointInCursorView, from: cursorView)
                if currentTool == .textBox,
                   editingTextView == nil,
                   let selectedAnnotation = parent.selectedAnnotation,
                   selectedAnnotation.isTextBoxAnnotation,
                   let overlayRect = overlay.annotationBorderRect {
                    let interactionRect = overlayRect.insetBy(dx: -(overlay.handleSize + 10), dy: -(overlay.handleSize + 10))
                    if interactionRect.contains(pointInOverlay) {
                        return false
                    }
                }
            }

            guard currentTool == .textBox,
                  editingTextView == nil,
                  let selectedAnnotation = parent.selectedAnnotation,
                  selectedAnnotation.isTextBoxAnnotation,
                  let pdfView = pdfView,
                  let page = selectedAnnotation.page else {
                return true
            }

            let pointInPDFView = cursorView.convert(pointInCursorView, to: pdfView)
            let pointInPage = pdfView.convert(pointInPDFView, to: page)
            return selectedAnnotation.bounds.contains(pointInPage) == false
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

        // MARK: - Bridge Annotation

        func applyBridgeAnnotation(selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor) {
            guard let pdfView = pdfView else { return }

            let annotations = AnnotationService.createMarkupAnnotation(
                selection: selection,
                type: type,
                color: color,
                on: pdfView
            )

            for (page, annotation) in annotations {
                recordForUndo(page: page, annotation: annotation)
            }

            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true
            parent.onDocumentChanged()
        }

        // MARK: - TextBox Drag-to-Create (via CursorTrackingView)

        func setupDrawingCallbacks() {
            cursorView?.onCustomDragChanged = { [weak self] start, current in
                self?.handleCursorDragChanged(start: start, current: current)
            }
            cursorView?.onCustomDragComplete = { [weak self] start, end in
                self?.handleCursorDragComplete(start: start, end: end)
            }
            cursorView?.onRectDragComplete = { [weak self] start, end in
                self?.handleRectDragComplete(start: start, end: end)
            }
            cursorView?.onInkDragComplete = { [weak self] path in
                self?.handleInkDragComplete(viewPath: path)
            }
        }

        func setupResizeCallback() {
            overlay?.onInteriorDoubleClick = { [weak self] in
                self?.beginEditingSelectedTextBoxIfNeeded()
            }
            overlay?.onMoveBegan = { [weak self] in
                self?.beginSelectedTextAnnotationManipulation()
            }
            overlay?.onResizeBegan = { [weak self] in
                self?.beginSelectedTextAnnotationManipulation()
            }
            overlay?.onMoveChanged = { [weak self] newOverlayRect in
                self?.handleMoveChanged(newOverlayRect)
            }
            overlay?.onMoveComplete = { [weak self] newOverlayRect in
                self?.handleMoveComplete(newOverlayRect)
            }
            overlay?.onResizeChanged = { [weak self] newOverlayRect in
                self?.handleResizeChanged(newOverlayRect)
            }
            overlay?.onResizeComplete = { [weak self] newOverlayRect in
                self?.handleResizeComplete(newOverlayRect)
            }
        }

        private func beginEditingSelectedTextBoxIfNeeded() {
            guard let annotation = parent.selectedAnnotation,
                  annotation.isTextBoxAnnotation,
                  let page = annotation.page else { return }
            beginEditingTextBox(annotation, on: page)
        }

        private func pageRect(fromOverlayRect overlayRect: NSRect) -> CGRect? {
            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let annotation = parent.selectedAnnotation,
                  let page = annotation.page else { return nil }

            // Convert overlay rect → pdfView rect → page rect
            let viewRect = pdfView.convert(overlayRect, from: overlay)
            return pdfView.convert(viewRect, to: page)
        }

        private func editorFrameInDocumentView(for annotation: PDFAnnotation, on page: PDFPage) -> NSRect? {
            guard let pdfView = pdfView,
                  let documentView = pdfView.documentView else { return nil }
            let viewRect = pdfView.convert(annotation.bounds, from: page)
            let alignedRect = pdfView.backingAlignedRect(viewRect, options: .alignAllEdgesNearest)
            return documentView.convert(alignedRect, from: pdfView)
        }

        private func syncEditingViewFrame(with annotation: PDFAnnotation, on page: PDFPage) {
            guard let editorView = editingEditorView,
                  let editorFrame = editorFrameInDocumentView(for: annotation, on: page) else { return }
            editorView.syncFrame(editorFrame)
        }

        private func updateEditingAnnotationBoundsFromEditorFrame() {
            guard let pdfView = pdfView,
                  let documentView = pdfView.documentView,
                  let annotation = editingAnnotation,
                  let page = annotation.page,
                  let editorView = editingEditorView else { return }
            let viewRect = pdfView.convert(editorView.frame, from: documentView)
            annotation.bounds = pdfView.convert(viewRect, to: page)
        }

        private func invalidatePDFRegion(for annotation: PDFAnnotation?, padding: CGFloat = 12) {
            guard let pdfView = pdfView,
                  let annotation,
                  let page = annotation.page else {
                pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
                return
            }

            let viewRect = pdfView.convert(annotation.bounds, from: page).insetBy(dx: -padding, dy: -padding)
            pdfView.setNeedsDisplay(viewRect)
            if let documentView = pdfView.documentView {
                let documentRect = documentView.convert(viewRect, from: pdfView)
                documentView.setNeedsDisplay(documentRect)
            }
        }

        func syncEditingViewAppearance(updateString: Bool = false) {
            guard let annotation = editingAnnotation,
                  let editorView = editingEditorView else { return }
            editorView.applyAnnotationStyle(annotation, updateString: updateString)
            if let page = annotation.page {
                syncEditingViewFrame(with: annotation, on: page)
            }
        }

        private func adjustEditingTextBoxToFitContentIfNeeded() {
            guard let pdfView = pdfView,
                  let documentView = pdfView.documentView,
                  let annotation = editingAnnotation,
                  let page = annotation.page,
                  let editorView = editingEditorView else { return }

            let currentFrame = editorView.frame
            let targetHeight = max(currentFrame.height, ceil(editorView.fittingHeight()))
            guard targetHeight > currentFrame.height + 0.5 else { return }

            var grownFrame = currentFrame
            let delta = targetHeight - currentFrame.height
            if documentView.isFlipped {
                grownFrame.size.height = targetHeight
            } else {
                grownFrame.origin.y -= delta
                grownFrame.size.height = targetHeight
            }

            editorView.syncFrame(grownFrame)

            let viewRect = pdfView.convert(grownFrame, from: documentView)
            annotation.bounds = pdfView.convert(viewRect, to: page)
            updateAnnotationBorder()
            pdfView.setNeedsDisplay(pdfView.bounds)
        }

        private func updateSelectedAnnotationBounds(using overlayRect: NSRect) {
            guard let annotation = parent.selectedAnnotation,
                  let pageRect = pageRect(fromOverlayRect: overlayRect) else { return }
            annotation.bounds = pageRect
            if editingAnnotation === annotation, let page = annotation.page {
                syncEditingViewFrame(with: annotation, on: page)
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        }

        private func beginSelectedTextAnnotationManipulation() {
            guard let annotation = parent.selectedAnnotation,
                  annotation.isTextBoxAnnotation,
                  editingAnnotation == nil else { return }
            isManipulatingSelectedTextAnnotation = true
            annotation.shouldDisplay = false
            invalidatePDFRegion(for: annotation)
        }

        private func endSelectedTextAnnotationManipulation() {
            guard let annotation = parent.selectedAnnotation,
                  annotation.isTextBoxAnnotation else {
                isManipulatingSelectedTextAnnotation = false
                return
            }
            annotation.shouldDisplay = true
            isManipulatingSelectedTextAnnotation = false
            invalidatePDFRegion(for: annotation)
        }

        private func handleResizeChanged(_ newOverlayRect: NSRect) {
            if isManipulatingSelectedTextAnnotation {
                return
            }
            updateSelectedAnnotationBounds(using: newOverlayRect)
        }

        private func handleMoveChanged(_ newOverlayRect: NSRect) {
            if isManipulatingSelectedTextAnnotation {
                return
            }
            updateSelectedAnnotationBounds(using: newOverlayRect)
        }

        private func handleMoveComplete(_ newOverlayRect: NSRect) {
            updateSelectedAnnotationBounds(using: newOverlayRect)
            endSelectedTextAnnotationManipulation()
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        private func handleResizeComplete(_ newOverlayRect: NSRect) {
            updateSelectedAnnotationBounds(using: newOverlayRect)
            endSelectedTextAnnotationManipulation()
            updateAnnotationBorder()
            if shouldRestoreTextEditingAfterResize, let textView = editingTextView {
                shouldRestoreTextEditingAfterResize = false
                pdfView?.window?.makeFirstResponder(textView)
            }
            parent.onDocumentChanged()
        }

        private func handleCursorDragChanged(start: NSPoint, current: NSPoint) {
            guard let overlay = overlay else { return }
            if cursorDragOriginOverlayRect == nil {
                cursorDragOriginOverlayRect = overlay.annotationBorderRect
            }
            guard let originRect = cursorDragOriginOverlayRect else { return }

            let startInOverlay = overlay.convert(start, from: cursorView)
            let currentInOverlay = overlay.convert(current, from: cursorView)
            let dx = currentInOverlay.x - startInOverlay.x
            let dy = currentInOverlay.y - startInOverlay.y
            let movedRect = originRect.offsetBy(dx: dx, dy: dy)
            overlay.updateAnnotationBorder(rect: movedRect)
            handleMoveChanged(movedRect)
        }

        private func handleCursorDragComplete(start: NSPoint, end: NSPoint) {
            defer { cursorDragOriginOverlayRect = nil }
            guard let overlay = overlay else { return }
            let startInOverlay = overlay.convert(start, from: cursorView)
            let endInOverlay = overlay.convert(end, from: cursorView)

            guard let originRect = cursorDragOriginOverlayRect else { return }
            let dx = endInOverlay.x - startInOverlay.x
            let dy = endInOverlay.y - startInOverlay.y
            let movedRect = originRect.offsetBy(dx: dx, dy: dy)
            overlay.updateAnnotationBorder(rect: movedRect)
            handleMoveComplete(movedRect)
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
                let annotation = AnnotationService.createTextBoxAnnotation(
                    bounds: bounds,
                    on: page,
                    text: "",
                    color: currentColor,
                    fontSize: 12
                )
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

        /// Start inline editing of a Canope text box using an overlay editor
        func beginEditingTextBox(_ annotation: PDFAnnotation, on page: PDFPage) {
            guard let pdfView = pdfView, let documentView = pdfView.documentView else { return }
            dismissTextBoxEditing()

            guard let docRect = editorFrameInDocumentView(for: annotation, on: page) else { return }

            let editorView = TextNoteEditorView(annotation: annotation)
            editorView.syncFrame(docRect)
            let textView = editorView.textView
            textView.delegate = self

            let existingText = annotation.contents ?? ""
            if existingText.isEmpty {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else {
                let insertionLocation = existingText.utf16.count
                textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
            }

            editingAnnotation = annotation
            editingEditorView = editorView
            editingTextView = textView
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            documentView.addSubview(editorView)
            pdfView.window?.recalculateKeyViewLoop()
            annotation.shouldDisplay = false
            syncCursorViewInteractivity()
            pdfView.setNeedsDisplay(pdfView.bounds)
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
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown,
               let overlay = overlay {
                let pointInOverlay = overlay.convert(event.locationInWindow, from: nil)
                if overlay.isResizeHandle(at: pointInOverlay) {
                    shouldRestoreTextEditingAfterResize = true
                    return
                }
            }
            commitTextBoxEditing()
        }

        func textDidChange(_ notification: Notification) {
            adjustEditingTextBoxToFitContentIfNeeded()
        }

        func commitTextBoxEditing() {
            guard let annotation = editingAnnotation,
                  let textView = editingTextView else { return }

            updateEditingAnnotationBoundsFromEditorFrame()
            annotation.contents = textView.string
            annotation.font = textView.font ?? annotation.font
            annotation.fontColor = textView.textColor ?? annotation.fontColor
            annotation.alignment = textView.alignment

            let wasFirstResponder = pdfView?.window?.firstResponder === textView
            editingEditorView?.removeFromSuperview()
            editingEditorView = nil
            editingTextView = nil
            annotation.shouldDisplay = true
            editingAnnotation = nil

            syncCursorViewInteractivity()
            if wasFirstResponder {
                pdfView?.window?.makeFirstResponder(pdfView)
            }
            invalidatePDFRegion(for: annotation)
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        func dismissTextBoxEditing() {
            if editingTextView != nil {
                commitTextBoxEditing()
            }
        }

        func recordUserInteraction() {
            parent.onUserInteraction()
        }

        func handleInteractiveMouseDown(event: NSEvent, at locationInCursorView: NSPoint) -> CursorMouseDownAction {
            recordUserInteraction()
            guard currentTool == .textBox,
                  let cursorView = cursorView,
                  let pdfView = pdfView else { return .passThrough }

            let locationInPDFView = cursorView.convert(locationInCursorView, to: pdfView)
            guard let annotation = annotationAtPoint(locationInPDFView),
                  annotation.isTextBoxAnnotation,
                  let page = annotation.page else {
                return .passThrough
            }

            let wasSelected = parent.selectedAnnotation === annotation
            dismissTextBoxEditing()
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()

            if event.clickCount >= 2 {
                beginEditingTextBox(annotation, on: page)
                return .handled
            }

            if wasSelected, let overlay = overlay {
                let pointInOverlay = overlay.convert(locationInCursorView, from: cursorView)
                if let overlayRect = overlay.annotationBorderRect,
                   overlayRect.contains(pointInOverlay),
                   overlay.isResizeHandle(at: pointInOverlay) == false {
                    cursorDragOriginOverlayRect = overlayRect
                    return .beginCustomDrag
                }
            }

            return .handled
        }

        // MARK: - Mouse Up Monitor

        func installMouseUpMonitor() {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.handleMouseUp()
                return event
            }
        }

        func installMagnifyMonitor() {
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
                guard let self else { return event }
                if self.shouldHandleTextBoxMagnify(event) {
                    self.handleTextBoxMagnify(event)
                    return nil
                }
                return event
            }
        }

        func removeMouseUpMonitor() {
            if let monitor = mouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                mouseUpMonitor = nil
            }
        }

        func removeMagnifyMonitor() {
            if let monitor = magnifyMonitor {
                NSEvent.removeMonitor(monitor)
                magnifyMonitor = nil
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

        private func shouldHandleTextBoxMagnify(_ event: NSEvent) -> Bool {
            guard let pdfView = pdfView,
                  event.window === pdfView.window else { return false }

            if editingTextView != nil {
                return true
            }

            if parent.selectedAnnotation?.isTextBoxAnnotation == true {
                return true
            }

            return currentTool == .textBox
        }

        private func handleTextBoxMagnify(_ event: NSEvent) {
            guard let pdfView = pdfView else { return }

            let locationInView = pdfView.convert(event.locationInWindow, from: nil)
            let anchorPage = pdfView.page(for: locationInView, nearest: true)
            let anchorPoint = anchorPage.map { pdfView.convert(locationInView, to: $0) }

            let minScale = pdfView.minScaleFactor > 0 ? pdfView.minScaleFactor : 0.1
            let maxScale = pdfView.maxScaleFactor > minScale ? pdfView.maxScaleFactor : 8.0
            let scaleDelta = max(0.2, 1.0 + event.magnification)
            let newScale = min(maxScale, max(minScale, pdfView.scaleFactor * scaleDelta))

            guard abs(newScale - pdfView.scaleFactor) > 0.0001 else { return }

            pdfView.scaleFactor = newScale
            pdfView.layoutDocumentView()

            if let anchorPage, let anchorPoint {
                pdfView.go(to: PDFDestination(page: anchorPage, at: anchorPoint))
            }

            cursorView?.previewScaleFactor = newScale
            updateAnnotationBorder()
        }

        // MARK: - Annotation Selection Border

        func updateAnnotationBorder() {
            syncCursorViewInteractivity()

            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let annotation = parent.selectedAnnotation,
                  let page = annotation.page else {
                overlay?.allowsInteriorDragging = false
                overlay?.updateTextAnnotationPreviewStyle(nil)
                overlay?.updateAnnotationBorder(rect: nil)
                return
            }

            let viewRect = pdfView.convert(annotation.bounds, from: page)
            let overlayRect = overlay.convert(viewRect, from: pdfView)
            overlay.allowsInteriorDragging = editingAnnotation == nil && annotation.isTextBoxAnnotation
            if annotation.isTextBoxAnnotation {
                overlay.updateTextAnnotationPreviewStyle(
                    TextAnnotationPreviewStyle(
                        text: annotation.contents ?? "",
                        fillColor: annotation.textBoxFillColor,
                        borderColor: .black,
                        font: annotation.font ?? .systemFont(ofSize: 12),
                        fontColor: annotation.fontColor ?? .black,
                        alignment: annotation.alignment
                    )
                )
            } else {
                overlay.updateTextAnnotationPreviewStyle(nil)
            }
            overlay.updateAnnotationBorder(rect: overlayRect, isEditing: editingAnnotation === annotation)
        }

        @objc func handleViewChanged(_ notification: Notification) {
            cursorView?.previewScaleFactor = pdfView?.scaleFactor ?? 1.0
            cursorView?.needsDisplay = true
            if let annotation = editingAnnotation, let page = annotation.page {
                syncEditingViewFrame(with: annotation, on: page)
            }
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
            let fileURL = parent.fileURL
            Self.selectionFileQueue.async {
                let state = ClaudeIDESelectionState.makeSnapshot(
                    selectedText: text,
                    fileURL: fileURL
                )
                CanopeContextFiles.writeIDESelectionState(state)
                CanopeContextFiles.clearLegacySelectionMirror()
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
            recordUserInteraction()
            if editingTextView != nil {
                commitTextBoxEditing()
                pdfView.window?.makeFirstResponder(pdfView)

                if let annotation = annotationAtPoint(locationInView) {
                    parent.selectedAnnotation = annotation
                    updateAnnotationBorder()

                    if currentTool == .textBox,
                       annotation.isTextBoxAnnotation,
                       event.clickCount >= 2,
                       let page = annotation.page {
                        beginEditingTextBox(annotation, on: page)
                    }
                } else if currentTool == .pointer {
                    parent.selectedAnnotation = nil
                    updateAnnotationBorder()
                }

                return true
            }

            if currentTool == .textBox {
                pdfView.window?.makeFirstResponder(pdfView)

                if let annotation = annotationAtPoint(locationInView),
                   annotation.isTextBoxAnnotation {
                    parent.selectedAnnotation = annotation
                    updateAnnotationBorder()
                    syncCursorViewInteractivity()

                    if event.clickCount >= 2,
                       let page = annotation.page {
                        beginEditingTextBox(annotation, on: page)
                    }

                    return true
                }
            }

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
            recordUserInteraction()
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

            if currentTool == .textBox {
                if let annotation = annotationAtPoint(locationInView) {
                    parent.selectedAnnotation = annotation
                } else if parent.selectedAnnotation != nil {
                    parent.selectedAnnotation = nil
                }
                updateAnnotationBorder()
                syncCursorViewInteractivity()
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
                writeSelectionSnapshot("")
                overlay?.clearSelection()
                updateSelectionDismissInterception()
                return
            }
            hasActiveSelection = true
            isDragging = true
            parent.selectedText = text
            writeSelectionSnapshot(text)
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

        // MARK: - Double Click (edit Text Box)

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            recordUserInteraction()
            guard let pdfView = pdfView else { return }
            let locationInView = gesture.location(in: pdfView)
            guard let annotation = annotationAtPoint(locationInView),
                  annotation.isTextBoxAnnotation,
                  let page = annotation.page else { return }
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            beginEditingTextBox(annotation, on: page)
        }

        // MARK: - Right Click

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            recordUserInteraction()
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

            // Text-box-specific formatting options
            if annotation.isTextBoxAnnotation {
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
            AnnotationService.applyColor(color, to: annotation)
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(annotation.bounds)
            parent.onDocumentChanged()
        }

        @objc func changeFontSize(_ sender: NSMenuItem) {
            guard let annotation = parent.selectedAnnotation, annotation.isTextBoxAnnotation else { return }
            let size = CGFloat(sender.tag)
            annotation.font = NSFont.systemFont(ofSize: size)
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func changeFontColor(_ sender: NSMenuItem) {
            guard let color = sender.representedObject as? NSColor,
                  let annotation = parent.selectedAnnotation, annotation.isTextBoxAnnotation else { return }
            annotation.fontColor = color
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func changeAlignment(_ sender: NSMenuItem) {
            guard let annotation = parent.selectedAnnotation, annotation.isTextBoxAnnotation else { return }
            annotation.alignment = NSTextAlignment(rawValue: sender.tag) ?? .left
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
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

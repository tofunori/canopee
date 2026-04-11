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
    @ObservedObject var searchState: PDFSearchUIState
    let onDocumentChanged: @MainActor () -> Void
    let onCurrentPageChanged: @MainActor (Int) -> Void
    let onMarkupAppearanceNeedsRefresh: @MainActor () -> Void
    @Binding var clearSelectionAction: (() -> Void)?
    @Binding var undoAction: (() -> Void)?
    @Binding var fitToWidthAction: (() -> Void)?
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
        context.coordinator.currentTool = currentTool
        context.coordinator.currentColor = currentColor
        context.coordinator.assignControllerViews()
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
        context.coordinator.searchState = searchState
        context.coordinator.configureSearchState()
        context.coordinator.syncSearchQuery(force: true)

        // Expose undo to parent view
        DispatchQueue.main.async {
            self.undoAction = { [weak coordinator = context.coordinator] in
                coordinator?.undo()
            }
            self.clearSelectionAction = { [weak coordinator = context.coordinator] in
                coordinator?.clearCurrentTextSelection()
            }
            self.fitToWidthAction = { [weak coordinator = context.coordinator] in
                coordinator?.fitToWidth()
            }
            self.applyBridgeAnnotation = { [weak coordinator = context.coordinator] selection, type, color in
                coordinator?.applyBridgeAnnotation(selection: selection, type: type, color: color)
            }
        }

        // Auto fit-to-width once the view has its layout size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            context.coordinator.fitToWidth()
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
        context.coordinator.searchState = searchState
        context.coordinator.assignControllerViews()

        if let pdfView = context.coordinator.pdfView, pdfView.document !== document {
            let viewState = context.coordinator.captureViewState()
            context.coordinator.clearTransientInteractionState()
            pdfView.document = nil
            pdfView.document = document
            pdfView.layoutDocumentView()
            context.coordinator.restoreViewState(viewState)
            context.coordinator.resetSearchQueryCache()
            context.coordinator.assignControllerViews()
        }

        context.coordinator.pdfView?.selectionPreviewTool = currentTool
        context.coordinator.pdfView?.selectionPreviewColor = currentColor
        context.coordinator.cursorView?.previewColor = currentColor
        context.coordinator.cursorView?.previewScaleFactor = context.coordinator.pdfView?.scaleFactor ?? 1.0

        context.coordinator.updateCursor(for: currentTool)
        context.coordinator.syncEditingViewAppearance()
        context.coordinator.updateAnnotationBorder()
        context.coordinator.configureSearchState()
        context.coordinator.syncSearchQuery(force: false)
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
    class Coordinator: NSObject, NSGestureRecognizerDelegate {
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
        var searchState: PDFSearchUIState?
        var currentTool: AnnotationTool = .pointer
        var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
        private var hasActiveSelection = false
        private var isDragging = false
        private var mouseUpMonitor: Any?
        private var magnifyMonitor: Any?
        private let searchController: PDFSearchController
        private let annotationController: PDFAnnotationController
        private let textBoxController: PDFTextBoxEditingController

        init(parent: PDFKitView) {
            self.parent = parent
            self.searchState = parent.searchState
            self.currentTool = parent.currentTool
            self.currentColor = parent.currentColor
            self.searchController = PDFSearchController(searchState: parent.searchState)
            self.annotationController = PDFAnnotationController()
            self.textBoxController = PDFTextBoxEditingController()
            super.init()
            configureControllers()
        }

        func configureSearchState() {
            searchController.searchState = searchState
            searchController.configureSearchState()
        }

        func resetSearchQueryCache() {
            searchController.resetSearchQueryCache()
        }

        func syncSearchQuery(force: Bool) {
            searchController.searchState = searchState
            searchController.syncSearchQuery(force: force)
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
            annotationController.currentTool = tool
            annotationController.currentColor = currentColor
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
            guard tool.needsDragInteraction, textBoxController.isEditing == false else { return false }

            if tool == .textBox,
               let selectedAnnotation = parent.selectedAnnotation,
               selectedAnnotation.isTextBoxAnnotation {
                return false
            }

            return true
        }

        func shouldCursorViewIntercept(pointInCursorView: NSPoint) -> Bool {
            guard currentTool == .textBox else { return true }
            return textBoxController.shouldCursorViewIntercept(pointInCursorView: pointInCursorView)
        }

        func undo() {
            annotationController.undo()
        }

        func applyBridgeAnnotation(selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor) {
            annotationController.applyBridgeAnnotation(selection: selection, type: type, color: color)
        }

        // MARK: - TextBox Drag-to-Create (via CursorTrackingView)

        func setupDrawingCallbacks() {
            cursorView?.onCustomDragChanged = { [weak self] start, current in
                self?.textBoxController.handleCursorDragChanged(start: start, current: current)
            }
            cursorView?.onCustomDragComplete = { [weak self] start, end in
                self?.textBoxController.handleCursorDragComplete(start: start, end: end)
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
                self?.textBoxController.beginEditingSelectedTextBoxIfNeeded()
            }
            overlay?.onMoveBegan = { [weak self] in
                self?.textBoxController.beginSelectedTextAnnotationManipulationIfNeeded()
            }
            overlay?.onResizeBegan = { [weak self] in
                self?.textBoxController.beginSelectedTextAnnotationManipulationIfNeeded()
            }
            overlay?.onMoveChanged = { [weak self] newOverlayRect in
                self?.textBoxController.handleMoveChanged(newOverlayRect)
            }
            overlay?.onMoveComplete = { [weak self] newOverlayRect in
                self?.textBoxController.handleMoveComplete(newOverlayRect)
            }
            overlay?.onResizeChanged = { [weak self] newOverlayRect in
                self?.textBoxController.handleResizeChanged(newOverlayRect)
            }
            overlay?.onResizeComplete = { [weak self] newOverlayRect in
                self?.textBoxController.handleResizeComplete(newOverlayRect)
            }
        }

        private func handleRectDragComplete(start: NSPoint, end: NSPoint) {
            textBoxController.dismissTextBoxEditing()
            annotationController.handleRectDragComplete(start: start, end: end)
        }

        private func handleInkDragComplete(viewPath: NSBezierPath) {
            annotationController.handleInkDragComplete(viewPath: viewPath)
        }

        func syncEditingViewAppearance(updateString: Bool = false) {
            textBoxController.syncEditingViewAppearance(updateString: updateString)
        }

        func recordUserInteraction() {
            parent.onUserInteraction()
        }

        func handleInteractiveMouseDown(event: NSEvent, at locationInCursorView: NSPoint) -> CursorMouseDownAction {
            recordUserInteraction()
            guard currentTool == .textBox else { return .passThrough }
            return textBoxController.handleInteractiveMouseDown(event: event, at: locationInCursorView)
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
                let shouldHandle = self.textBoxController.shouldHandleMagnify(event)
                    || (self.currentTool == .textBox && event.window === self.pdfView?.window)
                if shouldHandle {
                    self.textBoxController.handleMagnify(event)
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

            DispatchQueue.main.async { [weak self] in
                self?.annotationController.applyTextMarkup(using: selection)
            }
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
            overlay.allowsInteriorDragging = textBoxController.isEditing == false && annotation.isTextBoxAnnotation
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
            overlay.updateAnnotationBorder(rect: overlayRect, isEditing: textBoxController.editingAnnotation === annotation)
        }

        @objc func handleViewChanged(_ notification: Notification) {
            cursorView?.previewScaleFactor = pdfView?.scaleFactor ?? 1.0
            cursorView?.needsDisplay = true
            textBoxController.handleViewChanged()
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
            textBoxController.dismissTextBoxEditing()
            parent.selectedAnnotation = nil
            overlay?.clear()
        }

        func clearCurrentTextSelection() {
            clearTextSelectionState()
        }

        func fitToWidth() {
            guard let pdfView,
                  let page = pdfView.currentPage else { return }
            let pageWidth = page.bounds(for: pdfView.displayBox).width
            guard pageWidth > 0 else { return }
            let viewWidth = pdfView.bounds.width - pdfView.safeAreaInsets.left - pdfView.safeAreaInsets.right
            pdfView.scaleFactor = viewWidth / pageWidth
        }

        private func updateSelectionDismissInterception() {
            // Keep API surface stable for callers; selection dismissal is now handled
            // by clearing native PDFView selection on mouseDown, following Skim's pattern.
        }

        private func resetProgrammaticSelectionStateForSearch() {
            hasActiveSelection = false
            isDragging = false
            overlay?.clearSelection()
            parent.selectedText = ""
            writeSelectionSnapshot("(no text currently selected)")
        }

        func handlePreMouseDown(event: NSEvent, at locationInView: NSPoint, in pdfView: InteractivePDFView) -> Bool {
            recordUserInteraction()
            if textBoxController.isEditing {
                textBoxController.dismissTextBoxEditing()
                pdfView.window?.makeFirstResponder(pdfView)

                if let annotation = annotationAtPoint(locationInView) {
                    parent.selectedAnnotation = annotation
                    updateAnnotationBorder()

                    if currentTool == .textBox,
                       annotation.isTextBoxAnnotation,
                       event.clickCount >= 2,
                       let page = annotation.page {
                        textBoxController.beginEditingTextBox(annotation, on: page)
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
                        textBoxController.beginEditingTextBox(annotation, on: page)
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
                annotationController.createNote(at: locationInView)
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
            if annotationController.isApplyingTextMarkup || searchController.isUpdatingSearchSelection {
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
            textBoxController.beginEditingTextBox(annotation, on: page)
        }

        // MARK: - Right Click

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            recordUserInteraction()
            annotationController.handleRightClick(gesture)
        }

        // MARK: - Gesture Delegate

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            if event.type == .rightMouseDown { return true }
            return currentTool == .pointer || currentTool == .note || currentTool == .textBox
        }

        func dismissTextBoxEditing() {
            textBoxController.dismissTextBoxEditing()
        }

        private func configureControllers() {
            searchController.onClearTextSelectionState = { [weak self] in
                self?.clearTextSelectionState()
            }
            searchController.onResetProgrammaticSelectionState = { [weak self] in
                self?.resetProgrammaticSelectionStateForSearch()
            }

            annotationController.selectedAnnotationProvider = { [weak self] in
                self?.parent.selectedAnnotation
            }
            annotationController.setSelectedAnnotation = { [weak self] annotation in
                self?.parent.selectedAnnotation = annotation
            }
            annotationController.onAnnotationBorderNeedsUpdate = { [weak self] in
                self?.updateAnnotationBorder()
            }
            annotationController.onDocumentChanged = { [weak self] in
                self?.parent.onDocumentChanged()
            }
            annotationController.onBeginTextBoxEditing = { [weak self] annotation, page in
                self?.textBoxController.beginEditingTextBox(annotation, on: page)
            }
            annotationController.onResetToolToPointer = { [weak self] in
                self?.setToolToPointer()
            }
            annotationController.onSyncEditingAppearance = { [weak self] updateString in
                self?.textBoxController.syncEditingViewAppearance(updateString: updateString)
            }
            annotationController.editingAnnotationProvider = { [weak self] in
                self?.textBoxController.editingAnnotation
            }
            annotationController.annotationAtPoint = { [weak self] point in
                self?.annotationAtPoint(point)
            }
            annotationController.onClearTextSelectionState = { [weak self] in
                self?.clearTextSelectionState()
            }

            textBoxController.selectedAnnotationProvider = { [weak self] in
                self?.parent.selectedAnnotation
            }
            textBoxController.setSelectedAnnotation = { [weak self] annotation in
                self?.parent.selectedAnnotation = annotation
            }
            textBoxController.onDocumentChanged = { [weak self] in
                self?.parent.onDocumentChanged()
            }
            textBoxController.onAnnotationBorderNeedsUpdate = { [weak self] in
                self?.updateAnnotationBorder()
            }
            textBoxController.onCursorInteractivityChanged = { [weak self] in
                self?.syncCursorViewInteractivity()
            }
            textBoxController.annotationAtPoint = { [weak self] point in
                self?.annotationAtPoint(point)
            }
        }

        func assignControllerViews() {
            searchController.pdfView = pdfView
            searchController.searchState = searchState

            annotationController.pdfView = pdfView
            annotationController.cursorView = cursorView
            annotationController.currentTool = currentTool
            annotationController.currentColor = currentColor

            textBoxController.pdfView = pdfView
            textBoxController.overlay = overlay
            textBoxController.cursorView = cursorView
        }

        private func setToolToPointer() {
            parent.currentTool = .pointer
            currentTool = .pointer
            annotationController.currentTool = .pointer
            updateCursor(for: .pointer)
        }
    }
}

import AppKit
import PDFKit

@MainActor
final class PDFTextBoxEditingController: NSObject, NSTextViewDelegate {
    weak var pdfView: InteractivePDFView?
    weak var overlay: SelectionOverlayView?
    weak var cursorView: CursorTrackingView?
    var selectedAnnotationProvider: (() -> PDFAnnotation?)?
    var setSelectedAnnotation: ((PDFAnnotation?) -> Void)?
    var onDocumentChanged: (() -> Void)?
    var onAnnotationBorderNeedsUpdate: (() -> Void)?
    var onCursorInteractivityChanged: (() -> Void)?
    var annotationAtPoint: ((NSPoint) -> PDFAnnotation?)?

    private var editingEditorView: TextNoteEditorView?
    private var editingTextView: NSTextView?
    private(set) var editingAnnotation: PDFAnnotation?
    private var shouldRestoreTextEditingAfterResize = false
    private var cursorDragOriginOverlayRect: NSRect?
    private var isManipulatingSelectedTextAnnotation = false

    var isEditing: Bool {
        editingTextView != nil
    }

    func shouldCursorViewIntercept(pointInCursorView: NSPoint) -> Bool {
        guard let cursorView else { return true }

        if let overlay {
            let pointInOverlay = overlay.convert(pointInCursorView, from: cursorView)
            if let selectedAnnotation = selectedAnnotationProvider?(),
               selectedAnnotation.isTextBoxAnnotation,
               editingTextView == nil,
               let overlayRect = overlay.annotationBorderRect {
                let interactionRect = overlayRect.insetBy(dx: -(overlay.handleSize + 10), dy: -(overlay.handleSize + 10))
                if interactionRect.contains(pointInOverlay) {
                    return false
                }
            }
        }

        guard editingTextView == nil,
              let selectedAnnotation = selectedAnnotationProvider?(),
              selectedAnnotation.isTextBoxAnnotation,
              let pdfView,
              let page = selectedAnnotation.page else {
            return true
        }

        let pointInPDFView = cursorView.convert(pointInCursorView, to: pdfView)
        let pointInPage = pdfView.convert(pointInPDFView, to: page)
        return selectedAnnotation.bounds.contains(pointInPage) == false
    }

    func beginEditingSelectedTextBoxIfNeeded() {
        guard let annotation = selectedAnnotationProvider?(),
              annotation.isTextBoxAnnotation,
              let page = annotation.page else { return }
        beginEditingTextBox(annotation, on: page)
    }

    func syncEditingViewAppearance(updateString: Bool = false) {
        guard let annotation = editingAnnotation,
              let editorView = editingEditorView else { return }
        editorView.applyAnnotationStyle(annotation, updateString: updateString)
        if let page = annotation.page {
            syncEditingViewFrame(with: annotation, on: page)
        }
    }

    func handleViewChanged() {
        if let annotation = editingAnnotation, let page = annotation.page {
            syncEditingViewFrame(with: annotation, on: page)
        }
        onAnnotationBorderNeedsUpdate?()
    }

    func handleMoveChanged(_ newOverlayRect: NSRect) {
        if isManipulatingSelectedTextAnnotation {
            return
        }
        updateSelectedAnnotationBounds(using: newOverlayRect)
    }

    func handleResizeChanged(_ newOverlayRect: NSRect) {
        if isManipulatingSelectedTextAnnotation {
            return
        }
        updateSelectedAnnotationBounds(using: newOverlayRect)
    }

    func handleMoveComplete(_ newOverlayRect: NSRect) {
        updateSelectedAnnotationBounds(using: newOverlayRect)
        endSelectedTextAnnotationManipulation()
        onAnnotationBorderNeedsUpdate?()
        onDocumentChanged?()
    }

    func handleResizeComplete(_ newOverlayRect: NSRect) {
        updateSelectedAnnotationBounds(using: newOverlayRect)
        endSelectedTextAnnotationManipulation()
        onAnnotationBorderNeedsUpdate?()
        if shouldRestoreTextEditingAfterResize, let textView = editingTextView {
            shouldRestoreTextEditingAfterResize = false
            pdfView?.window?.makeFirstResponder(textView)
        }
        onDocumentChanged?()
    }

    func beginSelectedTextAnnotationManipulationIfNeeded() {
        guard let annotation = selectedAnnotationProvider?(),
              annotation.isTextBoxAnnotation,
              editingAnnotation == nil else { return }
        isManipulatingSelectedTextAnnotation = true
        annotation.shouldDisplay = false
        invalidatePDFRegion(for: annotation)
    }

    func handleCursorDragChanged(start: NSPoint, current: NSPoint) {
        guard let overlay else { return }
        if cursorDragOriginOverlayRect == nil {
            cursorDragOriginOverlayRect = overlay.annotationBorderRect
        }
        guard let originRect = cursorDragOriginOverlayRect,
              let cursorView else { return }

        let startInOverlay = overlay.convert(start, from: cursorView)
        let currentInOverlay = overlay.convert(current, from: cursorView)
        let dx = currentInOverlay.x - startInOverlay.x
        let dy = currentInOverlay.y - startInOverlay.y
        let movedRect = originRect.offsetBy(dx: dx, dy: dy)
        overlay.updateAnnotationBorder(rect: movedRect)
        handleMoveChanged(movedRect)
    }

    func handleCursorDragComplete(start: NSPoint, end: NSPoint) {
        defer { cursorDragOriginOverlayRect = nil }
        guard let overlay,
              let originRect = cursorDragOriginOverlayRect,
              let cursorView else { return }
        let startInOverlay = overlay.convert(start, from: cursorView)
        let endInOverlay = overlay.convert(end, from: cursorView)
        let dx = endInOverlay.x - startInOverlay.x
        let dy = endInOverlay.y - startInOverlay.y
        let movedRect = originRect.offsetBy(dx: dx, dy: dy)
        overlay.updateAnnotationBorder(rect: movedRect)
        handleMoveComplete(movedRect)
    }

    func beginEditingTextBox(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard let pdfView,
              let documentView = pdfView.documentView else { return }
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
        setSelectedAnnotation?(annotation)
        onAnnotationBorderNeedsUpdate?()
        documentView.addSubview(editorView)
        pdfView.window?.recalculateKeyViewLoop()
        annotation.shouldDisplay = false
        onCursorInteractivityChanged?()
        pdfView.setNeedsDisplay(pdfView.bounds)
        pdfView.window?.makeFirstResponder(textView)
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

        onCursorInteractivityChanged?()
        if wasFirstResponder {
            pdfView?.window?.makeFirstResponder(pdfView)
        }
        invalidatePDFRegion(for: annotation)
        onAnnotationBorderNeedsUpdate?()
        onDocumentChanged?()
    }

    func dismissTextBoxEditing() {
        if editingTextView != nil {
            commitTextBoxEditing()
        }
    }

    func handleInteractiveMouseDown(event: NSEvent, at locationInCursorView: NSPoint) -> CursorMouseDownAction {
        guard let cursorView,
              let pdfView else { return .passThrough }

        let locationInPDFView = cursorView.convert(locationInCursorView, to: pdfView)
        guard let annotation = annotationAtPoint?(locationInPDFView),
              annotation.isTextBoxAnnotation,
              let page = annotation.page else {
            return .passThrough
        }

        let wasSelected = selectedAnnotationProvider?() === annotation
        dismissTextBoxEditing()
        setSelectedAnnotation?(annotation)
        onAnnotationBorderNeedsUpdate?()

        if event.clickCount >= 2 {
            beginEditingTextBox(annotation, on: page)
            return .handled
        }

        if wasSelected, let overlay {
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

    func shouldHandleMagnify(_ event: NSEvent) -> Bool {
        guard let pdfView,
              event.window === pdfView.window else { return false }

        if editingTextView != nil {
            return true
        }

        if selectedAnnotationProvider?()?.isTextBoxAnnotation == true {
            return true
        }

        return false
    }

    func handleMagnify(_ event: NSEvent) {
        guard let pdfView else { return }

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
        onAnnotationBorderNeedsUpdate?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextBoxEditing()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown,
           let overlay {
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

    private func pageRect(fromOverlayRect overlayRect: NSRect) -> CGRect? {
        guard let pdfView,
              let overlay,
              let annotation = selectedAnnotationProvider?(),
              let page = annotation.page else { return nil }

        let viewRect = pdfView.convert(overlayRect, from: overlay)
        return pdfView.convert(viewRect, to: page)
    }

    private func editorFrameInDocumentView(for annotation: PDFAnnotation, on page: PDFPage) -> NSRect? {
        guard let pdfView,
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
        guard let pdfView,
              let documentView = pdfView.documentView,
              let annotation = editingAnnotation,
              let page = annotation.page,
              let editorView = editingEditorView else { return }
        let viewRect = pdfView.convert(editorView.frame, from: documentView)
        annotation.bounds = pdfView.convert(viewRect, to: page)
    }

    private func invalidatePDFRegion(for annotation: PDFAnnotation?, padding: CGFloat = 12) {
        guard let pdfView,
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

    private func adjustEditingTextBoxToFitContentIfNeeded() {
        guard let pdfView,
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
        onAnnotationBorderNeedsUpdate?()
        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    private func updateSelectedAnnotationBounds(using overlayRect: NSRect) {
        guard let annotation = selectedAnnotationProvider?(),
              let pageRect = pageRect(fromOverlayRect: overlayRect) else { return }
        annotation.bounds = pageRect
        if editingAnnotation === annotation, let page = annotation.page {
            syncEditingViewFrame(with: annotation, on: page)
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
    }

    private func endSelectedTextAnnotationManipulation() {
        guard let annotation = selectedAnnotationProvider?(),
              annotation.isTextBoxAnnotation else {
            isManipulatingSelectedTextAnnotation = false
            return
        }
        annotation.shouldDisplay = true
        isManipulatingSelectedTextAnnotation = false
        invalidatePDFRegion(for: annotation)
    }
}

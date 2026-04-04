import AppKit
import PDFKit

final class InteractivePDFView: PDFView {
    var onPreMouseDown: ((NSEvent, NSPoint, InteractivePDFView) -> Bool)?
    var onPostMouseUp: ((NSPoint) -> Void)?
    var onUserInteraction: (() -> Void)?
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
        onUserInteraction?()
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

    override func rightMouseDown(with event: NSEvent) {
        onUserInteraction?()
        super.rightMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onUserInteraction?()
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onUserInteraction?()
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        onUserInteraction?()
        super.smartMagnify(with: event)
    }
}

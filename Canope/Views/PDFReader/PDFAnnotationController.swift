import AppKit
import PDFKit

@MainActor
final class PDFAnnotationController: NSObject {
    weak var pdfView: InteractivePDFView?
    weak var cursorView: CursorTrackingView?
    var currentTool: AnnotationTool = .pointer
    var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    var selectedAnnotationProvider: (() -> PDFAnnotation?)?
    var setSelectedAnnotation: ((PDFAnnotation?) -> Void)?
    var onAnnotationBorderNeedsUpdate: (() -> Void)?
    var onDocumentChanged: (() -> Void)?
    var onBeginTextBoxEditing: ((PDFAnnotation, PDFPage) -> Void)?
    var onResetToolToPointer: (() -> Void)?
    var onSyncEditingAppearance: ((Bool) -> Void)?
    var editingAnnotationProvider: (() -> PDFAnnotation?)?
    var annotationAtPoint: ((NSPoint) -> PDFAnnotation?)?
    var onClearTextSelectionState: (() -> Void)?

    private var undoStack: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private(set) var isApplyingTextMarkup = false

    func recordForUndo(page: PDFPage, annotation: PDFAnnotation) {
        undoStack.append((page: page, annotation: annotation))
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        last.page.removeAnnotation(last.annotation)
        if selectedAnnotationProvider?() === last.annotation {
            setSelectedAnnotation?(nil)
        }
        onAnnotationBorderNeedsUpdate?()
        onDocumentChanged?()
    }

    func applyBridgeAnnotation(selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor) {
        guard let pdfView else { return }

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
        onDocumentChanged?()
    }

    func createNote(at locationInView: NSPoint) {
        guard let pdfView,
              let page = pdfView.page(for: locationInView, nearest: true) else { return }
        let pagePoint = pdfView.convert(locationInView, to: page)
        let annotation = AnnotationService.createNoteAnnotation(
            at: pagePoint,
            on: page,
            text: "",
            color: currentColor
        )
        recordForUndo(page: page, annotation: annotation)
        setSelectedAnnotation?(annotation)
        onDocumentChanged?()
    }

    func handleRectDragComplete(start: NSPoint, end: NSPoint) {
        guard let pdfView,
              let cursorView else { return }

        let startView = cursorView.convert(start, to: pdfView)
        let endView = cursorView.convert(end, to: pdfView)

        guard let page = pdfView.page(for: startView, nearest: true) else { return }
        let startPage = pdfView.convert(startView, to: page)
        let endPage = pdfView.convert(endView, to: page)

        let bounds = CGRect(
            x: min(startPage.x, endPage.x),
            y: min(startPage.y, endPage.y),
            width: abs(endPage.x - startPage.x),
            height: abs(endPage.y - startPage.y)
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
            setSelectedAnnotation?(annotation)
            onAnnotationBorderNeedsUpdate?()
            onDocumentChanged?()
            onBeginTextBoxEditing?(annotation, page)

        case .rectangle:
            let annotation = AnnotationService.createShapeAnnotation(
                bounds: bounds,
                type: .square,
                on: page,
                color: currentColor,
                lineWidth: 2
            )
            recordForUndo(page: page, annotation: annotation)
            finishCreatingDrawableAnnotation(annotation)
            onDocumentChanged?()

        case .oval:
            let annotation = AnnotationService.createShapeAnnotation(
                bounds: bounds,
                type: .circle,
                on: page,
                color: currentColor,
                lineWidth: 2
            )
            recordForUndo(page: page, annotation: annotation)
            finishCreatingDrawableAnnotation(annotation)
            onDocumentChanged?()

        case .arrow:
            let annotation = AnnotationService.createArrowAnnotation(
                from: CGPoint(x: startPage.x, y: startPage.y),
                to: CGPoint(x: endPage.x, y: endPage.y),
                on: page,
                color: currentColor,
                lineWidth: 2
            )
            recordForUndo(page: page, annotation: annotation)
            finishCreatingDrawableAnnotation(annotation)
            onDocumentChanged?()

        default:
            break
        }
    }

    func handleInkDragComplete(viewPath: NSBezierPath) {
        guard let pdfView,
              let cursorView else { return }

        let midPoint = NSPoint(x: viewPath.bounds.midX, y: viewPath.bounds.midY)
        let midInPDF = cursorView.convert(midPoint, to: pdfView)
        guard let page = pdfView.page(for: midInPDF, nearest: true) else { return }

        let pagePath = NSBezierPath()
        let elements = viewPath.elementCount
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elements {
            let type = viewPath.element(at: index, associatedPoints: &points)
            let viewPoint = cursorView.convert(points[0], to: pdfView)
            let pagePoint = pdfView.convert(viewPoint, to: page)
            switch type {
            case .moveTo:
                pagePath.move(to: pagePoint)
            case .lineTo:
                pagePath.line(to: pagePoint)
            default:
                pagePath.line(to: pagePoint)
            }
        }

        let annotation = AnnotationService.createInkAnnotation(
            path: pagePath,
            on: page,
            color: currentColor,
            lineWidth: 2
        )
        recordForUndo(page: page, annotation: annotation)
        setSelectedAnnotation?(annotation)
        onAnnotationBorderNeedsUpdate?()
        onDocumentChanged?()
    }

    func applyTextMarkup(using selection: PDFSelection) {
        let annotationType: PDFAnnotationSubtype
        switch currentTool {
        case .highlight:
            annotationType = .highlight
        case .underline:
            annotationType = .underline
        case .strikethrough:
            annotationType = .strikeOut
        default:
            isApplyingTextMarkup = false
            return
        }

        guard let pdfView else {
            isApplyingTextMarkup = false
            return
        }

        isApplyingTextMarkup = true
        let annotations = AnnotationService.createMarkupAnnotation(
            selection: selection,
            type: annotationType,
            color: currentColor,
            on: pdfView
        )

        for (page, annotation) in annotations {
            recordForUndo(page: page, annotation: annotation)
        }

        pdfView.documentView?.needsDisplay = true
        pdfView.needsDisplay = true
        pdfView.documentView?.displayIfNeeded()
        pdfView.displayIfNeeded()

        DispatchQueue.main.async { [weak self, weak pdfView] in
            guard let self else { return }
            self.onClearTextSelectionState?()
            self.isApplyingTextMarkup = false
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            self.onDocumentChanged?()
        }
    }

    func handleRightClick(_ gesture: NSClickGestureRecognizer) {
        guard let pdfView else { return }
        let locationInView = gesture.location(in: pdfView)
        guard let annotation = annotationAtPoint?(locationInView) else { return }
        setSelectedAnnotation?(annotation)
        onAnnotationBorderNeedsUpdate?()

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

        if annotation.isTextBoxAnnotation {
            menu.addItem(.separator())

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

            let textColorMenu = NSMenu()
            for (name, color) in [("Noir", NSColor.black), ("Blanc", NSColor.white),
                                  ("Rouge", NSColor.systemRed), ("Bleu", NSColor.systemBlue),
                                  ("Vert", NSColor.systemGreen), ("Orange", NSColor.systemOrange)] {
                let item = NSMenuItem(title: name, action: #selector(changeFontColor(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = color
                let image = NSImage(size: NSSize(width: 12, height: 12))
                image.lockFocus()
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
                image.unlockFocus()
                item.image = image
                textColorMenu.addItem(item)
            }
            let textColorItem = NSMenuItem(title: "Couleur du texte", action: nil, keyEquivalent: "")
            textColorItem.submenu = textColorMenu
            menu.addItem(textColorItem)

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
            let alignItem = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
            alignItem.submenu = alignMenu
            menu.addItem(alignItem)
        }

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: AppStrings.delete, action: #selector(deleteSelectedAnnotation(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        menu.addItem(deleteItem)

        menu.popUp(positioning: nil, at: gesture.location(in: pdfView), in: pdfView)
    }

    @objc func changeAnnotationColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor,
              let annotation = selectedAnnotationProvider?() else { return }
        AnnotationService.applyColor(color, to: annotation)
        if editingAnnotationProvider?() === annotation {
            onSyncEditingAppearance?(false)
        }
        pdfView?.setNeedsDisplay(annotation.bounds)
        onDocumentChanged?()
    }

    @objc func changeFontSize(_ sender: NSMenuItem) {
        guard let annotation = selectedAnnotationProvider?(),
              annotation.isTextBoxAnnotation else { return }
        annotation.font = NSFont.systemFont(ofSize: CGFloat(sender.tag))
        if editingAnnotationProvider?() === annotation {
            onSyncEditingAppearance?(false)
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        onDocumentChanged?()
    }

    @objc func changeFontColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor,
              let annotation = selectedAnnotationProvider?(),
              annotation.isTextBoxAnnotation else { return }
        annotation.fontColor = color
        if editingAnnotationProvider?() === annotation {
            onSyncEditingAppearance?(false)
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        onDocumentChanged?()
    }

    @objc func changeAlignment(_ sender: NSMenuItem) {
        guard let annotation = selectedAnnotationProvider?(),
              annotation.isTextBoxAnnotation else { return }
        annotation.alignment = NSTextAlignment(rawValue: sender.tag) ?? .left
        if editingAnnotationProvider?() === annotation {
            onSyncEditingAppearance?(false)
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        onDocumentChanged?()
    }

    @objc func editAnnotationNote(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        setSelectedAnnotation?(annotation)
        onDocumentChanged?()
    }

    @objc func deleteSelectedAnnotation(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation,
              let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        setSelectedAnnotation?(nil)
        onAnnotationBorderNeedsUpdate?()
        onDocumentChanged?()
    }

    private func finishCreatingDrawableAnnotation(_ annotation: PDFAnnotation) {
        setSelectedAnnotation?(annotation)
        onAnnotationBorderNeedsUpdate?()
        onResetToolToPointer?()
    }
}

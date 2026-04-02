import SwiftUI
import PDFKit

struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument
    var syncTarget: SyncTeXForwardResult?
    var onInverseSync: ((SyncTeXInverseResult) -> Void)?
    var fitToWidthTrigger: Bool = false

    func makeNSView(context: Context) -> NSView {
        let container = PDFPreviewContainerView()
        let pdfView = container.pdfView
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        let deselectionOverlay = container.deselectionOverlay
        deselectionOverlay.shouldConsumeClick = { [weak coordinator = context.coordinator, weak pdfView] point, event in
            guard let coordinator, let pdfView else { return false }
            return coordinator.shouldConsumeDeselectionClick(at: point, event: event, in: pdfView)
        }
        deselectionOverlay.onConsumeClick = { [weak coordinator = context.coordinator, weak pdfView] point, event in
            guard let coordinator, let pdfView else { return }
            coordinator.consumeDeselectionClick(at: point, event: event, in: pdfView)
        }

        // Enable pinch-to-zoom: auto-scale sets the initial fit,
        // then we disable it so manual zoom gestures work.
        DispatchQueue.main.async {
            pdfView.autoScales = false
        }

        // Add ⌘+click gesture for inverse sync
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        clickGesture.numberOfClicksRequired = 1
        pdfView.addGestureRecognizer(clickGesture)
        context.coordinator.configureSelectionObservation(for: pdfView)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? PDFPreviewContainerView else { return }
        let pdfView = container.pdfView
        if pdfView.document !== document {
            pdfView.document = document
            // Fit to view first, then allow manual zoom
            pdfView.autoScales = true
            DispatchQueue.main.async {
                pdfView.autoScales = false
            }
        }
        context.coordinator.onInverseSync = onInverseSync
        context.coordinator.configureSelectionObservation(for: pdfView)

        // Fit to width
        if fitToWidthTrigger != context.coordinator.lastFitTrigger {
            context.coordinator.lastFitTrigger = fitToWidthTrigger
            pdfView.autoScales = true
            DispatchQueue.main.async {
                pdfView.autoScales = false
            }
        }

        // Forward sync: scroll to target
        if let target = syncTarget,
           let page = document.page(at: target.page - 1) {
            let displayBox = pdfView.displayBox
            let pageBounds = page.bounds(for: displayBox)
            let pdfKitX = pageBounds.minX + target.h
            let pdfKitY = pageBounds.maxY - target.v
            let rect = CGRect(
                x: pdfKitX,
                y: pdfKitY,
                width: max(target.width, 100),
                height: max(target.height, 14)
            )
            pdfView.go(to: rect, on: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator: NSObject {
        private static let selectionFileQueue = DispatchQueue(label: "canope.pdf-preview-selection", qos: .utility)

        weak var pdfView: PDFView?
        weak var observedSelectionPDFView: PDFView?
        var onInverseSync: ((SyncTeXInverseResult) -> Void)?
        var lastFitTrigger: Bool = false
        private var hadSelectionAtMouseDown = false
        private var clickedInsideSelectionAtMouseDown = false

        func shouldConsumeDeselectionClick(at locationInView: NSPoint, event: NSEvent, in pdfView: PDFView) -> Bool {
            guard event.type == .leftMouseDown,
                  event.modifierFlags.contains(.command) == false,
                  pdfView.currentSelection != nil else {
                return false
            }

            return isPointInsideCurrentSelection(locationInView, in: pdfView) == false
        }

        func consumeDeselectionClick(at locationInView: NSPoint, event: NSEvent, in pdfView: PDFView) {
            guard shouldConsumeDeselectionClick(at: locationInView, event: event, in: pdfView) else { return }
            clearSelection(in: pdfView)
            hadSelectionAtMouseDown = false
            clickedInsideSelectionAtMouseDown = false
        }

        func configureSelectionObservation(for pdfView: PDFView) {
            self.pdfView = pdfView
            guard observedSelectionPDFView !== pdfView else { return }

            if let observedSelectionPDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: observedSelectionPDFView
                )
            }

            observedSelectionPDFView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChangedNotification(_:)),
                name: Notification.Name.PDFViewSelectionChanged,
                object: pdfView
            )
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView,
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return }

            let locationInView = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: locationInView, nearest: true),
                  let pageIndex = pdfView.document?.index(for: page) else { return }

            let pagePoint = pdfView.convert(locationInView, to: page)
            let displayBox = pdfView.displayBox
            let pageBounds = page.bounds(for: displayBox)

            let synctexX = pagePoint.x - pageBounds.minX
            let synctexY = pageBounds.maxY - pagePoint.y

            let pdfPath = pdfView.document?.documentURL?.path ?? ""
            guard !pdfPath.isEmpty else { return }
            let pg = pageIndex + 1

            let hint = syncTeXHint(for: page, point: pagePoint)
            if let result = SyncTeXService.inverseSync(page: pg, x: synctexX, y: synctexY, pdfPath: pdfPath, hint: hint) {
                onInverseSync?(result)
            }
        }

        private func syncTeXHint(for page: PDFPage, point: CGPoint) -> SyncTeXHint? {
            func normalized(_ string: String?) -> String {
                (string ?? "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let lineText = normalized(page.selectionForLine(at: point)?.string)
            guard lineText.isEmpty == false else { return nil }

            let wordText = normalized(page.selectionForWord(at: point)?.string)
            guard wordText.isEmpty == false else {
                return SyncTeXHint(offset: 0, context: lineText)
            }

            let nsLine = lineText as NSString
            let wordRange = nsLine.range(of: wordText)
            guard wordRange.location != NSNotFound else {
                return SyncTeXHint(offset: 0, context: lineText)
            }

            let contextPadding = 24
            let contextStart = max(0, wordRange.location - contextPadding)
            let contextEnd = min(nsLine.length, wordRange.location + wordRange.length + contextPadding)
            let contextRange = NSRange(location: contextStart, length: contextEnd - contextStart)
            let context = nsLine.substring(with: contextRange)
            let offset = wordRange.location - contextStart

            return SyncTeXHint(offset: offset, context: context)
        }

        @objc
        private func handleSelectionChangedNotification(_ notification: Notification) {
            guard let pdfView,
                  let fileURL = pdfView.document?.documentURL else {
                return
            }

            let selectedText = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let state = ClaudeIDESelectionState.makeSnapshot(selectedText: selectedText, fileURL: fileURL)

            Self.selectionFileQueue.async {
                CanopeContextFiles.writeIDESelectionState(state)
                CanopeContextFiles.clearLegacySelectionMirror()
            }
        }

        func handlePreMouseDown(event: NSEvent, at locationInView: NSPoint, in pdfView: SelectablePDFPreviewView) -> Bool {
            let canHandleDeselection = event.modifierFlags.contains(.command) == false && pdfView.currentSelection != nil
            let clickedInsideSelection = canHandleDeselection && isPointInsideCurrentSelection(locationInView, in: pdfView)

            hadSelectionAtMouseDown = canHandleDeselection
            clickedInsideSelectionAtMouseDown = clickedInsideSelection

            guard canHandleDeselection, clickedInsideSelection == false else {
                return false
            }

            clearSelection(in: pdfView)
            hadSelectionAtMouseDown = false
            clickedInsideSelectionAtMouseDown = false
            return true
        }

        func handlePostMouseUp(
            event: NSEvent,
            at locationInView: NSPoint,
            didDrag: Bool,
            in pdfView: SelectablePDFPreviewView
        ) {
            defer {
                hadSelectionAtMouseDown = false
                clickedInsideSelectionAtMouseDown = false
            }

            guard event.modifierFlags.contains(.command) == false,
                  event.clickCount == 1,
                  hadSelectionAtMouseDown,
                  clickedInsideSelectionAtMouseDown == false,
                  didDrag == false else {
                return
            }
            let clickedPoint = locationInView
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                if self.isPointInsideCurrentSelection(clickedPoint, in: pdfView) {
                    return
                }
                self.clearSelection(in: pdfView)
            }
        }

        private func isPointInsideCurrentSelection(_ locationInView: NSPoint, in pdfView: PDFView) -> Bool {
            guard let selection = pdfView.currentSelection else { return false }

            for lineSelection in selection.selectionsByLine() {
                for page in lineSelection.pages {
                    let pageBounds = lineSelection.bounds(for: page)
                    guard pageBounds.isNull == false, pageBounds.isEmpty == false else { continue }
                    let selectionRect = pdfView.convert(pageBounds, from: page).insetBy(dx: -4, dy: -4)
                    if selectionRect.contains(locationInView) {
                        return true
                    }
                }
            }

            return false
        }

        private func clearSelection(in pdfView: PDFView) {
            if let selection = pdfView.currentSelection?.copy() as? PDFSelection {
                selection.color = .clear
                pdfView.setCurrentSelection(selection, animate: false)
                pdfView.documentView?.displayIfNeeded()
                pdfView.displayIfNeeded()
            }

            pdfView.clearSelection()
            pdfView.setCurrentSelection(nil, animate: false)
            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true

            guard let fileURL = pdfView.document?.documentURL else { return }
            let state = ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: fileURL)
            Self.selectionFileQueue.async {
                CanopeContextFiles.writeIDESelectionState(state)
                CanopeContextFiles.clearLegacySelectionMirror()
            }
        }
    }
}

final class PDFPreviewContainerView: NSView {
    let pdfView = SelectablePDFPreviewView()
    let deselectionOverlay = PDFPreviewDeselectionOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        deselectionOverlay.translatesAutoresizingMaskIntoConstraints = false

        addSubview(pdfView)
        addSubview(deselectionOverlay)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            deselectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            deselectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            deselectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            deselectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SelectablePDFPreviewView: PDFView {
    var onPreMouseDown: ((NSEvent, NSPoint, SelectablePDFPreviewView) -> Bool)?
    var onPostMouseUp: ((NSEvent, NSPoint, Bool, SelectablePDFPreviewView) -> Void)?
    private var didDragDuringMouseSession = false

    override func mouseDown(with event: NSEvent) {
        didDragDuringMouseSession = false
        let location = convert(event.locationInWindow, from: nil)
        if onPreMouseDown?(event, location, self) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        didDragDuringMouseSession = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let location = convert(event.locationInWindow, from: nil)
        onPostMouseUp?(event, location, didDragDuringMouseSession, self)
        didDragDuringMouseSession = false
    }
}

final class PDFPreviewDeselectionOverlayView: NSView {
    var shouldConsumeClick: ((NSPoint, NSEvent) -> Bool)?
    var onConsumeClick: ((NSPoint, NSEvent) -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent ?? NSApp.currentEvent,
              shouldConsumeClick?(point, event) == true else {
            return nil
        }

        return self
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onConsumeClick?(location, event)
    }
}

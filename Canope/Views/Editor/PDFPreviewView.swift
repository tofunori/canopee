import AppKit
import SwiftUI
import PDFKit

enum PDFWidthFitSupport {
    static func scaleFactor(
        pageWidth: CGFloat,
        availableWidth: CGFloat,
        horizontalPadding: CGFloat = 16,
        minScaleFactor: CGFloat,
        maxScaleFactor: CGFloat
    ) -> CGFloat? {
        guard pageWidth > 0 else { return nil }
        let usableWidth = availableWidth - horizontalPadding
        guard usableWidth > 0 else { return nil }

        let unclampedScale = usableWidth / pageWidth
        guard unclampedScale.isFinite, unclampedScale > 0 else { return nil }

        let lowerBound = minScaleFactor > 0 ? minScaleFactor : 0.01
        let upperBound = maxScaleFactor > 0 ? maxScaleFactor : .greatestFiniteMagnitude
        return min(max(unclampedScale, lowerBound), upperBound)
    }
}

extension PDFView {
    @discardableResult
    func canopeFitCurrentPageToWidth(horizontalPadding: CGFloat = 16) -> Bool {
        layoutSubtreeIfNeeded()
        enclosingScrollView?.layoutSubtreeIfNeeded()
        documentView?.layoutSubtreeIfNeeded()

        guard let document,
              let page = currentPage ?? document.page(at: 0) else {
            return false
        }

        let availableWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        guard let scale = PDFWidthFitSupport.scaleFactor(
            pageWidth: page.bounds(for: displayBox).width,
            availableWidth: availableWidth,
            horizontalPadding: horizontalPadding,
            minScaleFactor: minScaleFactor,
            maxScaleFactor: maxScaleFactor
        ) else {
            return false
        }

        scaleFactor = scale
        layoutDocumentView()
        return true
    }
}

// MARK: - PDF Preview with SyncTeX inverse sync

struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument
    var syncTarget: SyncTeXForwardResult?
    var onInverseSync: ((SyncTeXInverseResult) -> Void)?
    var allowsInverseSync: Bool = true
    var restoredPageIndex: Int? = nil
    var fitToWidthTrigger: Bool = false
    @ObservedObject var searchState: PDFSearchUIState
    var onCurrentPageChanged: ((Int) -> Void)? = nil

    init(
        document: PDFDocument,
        syncTarget: SyncTeXForwardResult? = nil,
        onInverseSync: ((SyncTeXInverseResult) -> Void)? = nil,
        allowsInverseSync: Bool = true,
        restoredPageIndex: Int? = nil,
        fitToWidthTrigger: Bool = false,
        searchState: PDFSearchUIState = PDFSearchUIState(),
        onCurrentPageChanged: ((Int) -> Void)? = nil
    ) {
        self.document = document
        self.syncTarget = syncTarget
        self.onInverseSync = onInverseSync
        self.allowsInverseSync = allowsInverseSync
        self.restoredPageIndex = restoredPageIndex
        self.fitToWidthTrigger = fitToWidthTrigger
        self._searchState = ObservedObject(wrappedValue: searchState)
        self.onCurrentPageChanged = onCurrentPageChanged
    }

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
            if let restoredPageIndex,
               let restoredPage = document.page(at: restoredPageIndex) {
                pdfView.go(to: restoredPage)
            }
        }

        // Add ⌘+click gesture for inverse sync
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        clickGesture.numberOfClicksRequired = 1
        pdfView.addGestureRecognizer(clickGesture)
        context.coordinator.searchState = searchState
        context.coordinator.onCurrentPageChanged = onCurrentPageChanged
        context.coordinator.configureSelectionObservation(for: pdfView)
        context.coordinator.configurePageObservation(for: pdfView)
        context.coordinator.configureFrameObservation(for: pdfView)
        context.coordinator.configureSearchState(for: pdfView)
        context.coordinator.syncSearchQuery(in: pdfView, force: true)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? PDFPreviewContainerView else { return }
        let pdfView = container.pdfView
        if pdfView.document !== document {
            pdfView.document = document
            context.coordinator.resetSearchQueryCache()
            // Fit to view first, then allow manual zoom
            pdfView.autoScales = true
            DispatchQueue.main.async {
                pdfView.autoScales = false
                if let restoredPageIndex,
                   let restoredPage = document.page(at: restoredPageIndex) {
                    pdfView.go(to: restoredPage)
                }
                context.coordinator.scheduleFitToWidth(in: pdfView)
            }
        }
        context.coordinator.onInverseSync = onInverseSync
        context.coordinator.allowsInverseSync = allowsInverseSync
        context.coordinator.searchState = searchState
        context.coordinator.onCurrentPageChanged = onCurrentPageChanged
        context.coordinator.configureSelectionObservation(for: pdfView)
        context.coordinator.configurePageObservation(for: pdfView)
        context.coordinator.configureFrameObservation(for: pdfView)
        context.coordinator.configureSearchState(for: pdfView)

        // Fit to width
        if fitToWidthTrigger != context.coordinator.lastFitTrigger {
            context.coordinator.lastFitTrigger = fitToWidthTrigger
            context.coordinator.scheduleFitToWidth(in: pdfView)
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

        context.coordinator.syncSearchQuery(in: pdfView, force: false)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator { Coordinator(searchState: searchState) }

    @MainActor
    class Coordinator: NSObject {
        private static let selectionFileQueue = DispatchQueue(label: "canope.pdf-preview-selection", qos: .utility)

        weak var pdfView: PDFView?
        weak var observedSelectionPDFView: PDFView?
        weak var observedPagePDFView: PDFView?
        weak var observedFramePDFView: PDFView?
        var searchState: PDFSearchUIState?
        var onInverseSync: ((SyncTeXInverseResult) -> Void)?
        var onCurrentPageChanged: ((Int) -> Void)?
        var allowsInverseSync = true
        var lastFitTrigger: Bool = false
        private var shouldMaintainFitToWidth = true
        private var pendingFitWorkItem: DispatchWorkItem?
        private var hadSelectionAtMouseDown = false
        private var clickedInsideSelectionAtMouseDown = false
        private var searchMatches: [PDFSelection] = []
        private var lastSearchQuery = ""
        private var isUpdatingSearchSelection = false

        init(searchState: PDFSearchUIState? = nil) {
            self.searchState = searchState
        }

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

        func configurePageObservation(for pdfView: PDFView) {
            self.pdfView = pdfView
            guard observedPagePDFView !== pdfView else { return }

            if let observedPagePDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewPageChanged,
                    object: observedPagePDFView
                )
            }

            observedPagePDFView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChangedNotification(_:)),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
            reportCurrentPage(in: pdfView)
        }

        func configureFrameObservation(for pdfView: PDFView) {
            self.pdfView = pdfView
            guard observedFramePDFView !== pdfView else { return }

            if let observedFramePDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.frameDidChangeNotification,
                    object: observedFramePDFView
                )
            }

            pdfView.postsFrameChangedNotifications = true
            observedFramePDFView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFrameChangedNotification(_:)),
                name: NSView.frameDidChangeNotification,
                object: pdfView
            )
            scheduleFitToWidth(in: pdfView)
        }

        func configureSearchState(for pdfView: PDFView) {
            self.pdfView = pdfView
            searchState?.configureActions(
                next: { [weak self, weak pdfView] in
                    guard let self, let pdfView else { return }
                    self.navigateSearch(step: 1, in: pdfView)
                },
                previous: { [weak self, weak pdfView] in
                    guard let self, let pdfView else { return }
                    self.navigateSearch(step: -1, in: pdfView)
                },
                clear: { [weak self, weak pdfView] in
                    guard let self, let pdfView else { return }
                    self.clearSearchResults(in: pdfView)
                }
            )
        }

        func syncSearchQuery(in pdfView: PDFView, force: Bool) {
            let query = searchState?.query ?? ""
            guard force || query != lastSearchQuery else { return }
            lastSearchQuery = query
            updateSearchResults(for: query, in: pdfView)
        }

        func resetSearchQueryCache() {
            lastSearchQuery = ""
        }

        func cleanup() {
            pendingFitWorkItem?.cancel()
            pendingFitWorkItem = nil
            if let observedSelectionPDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: observedSelectionPDFView
                )
            }
            if let observedPagePDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewPageChanged,
                    object: observedPagePDFView
                )
            }
            if let observedFramePDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.frameDidChangeNotification,
                    object: observedFramePDFView
                )
            }
            observedSelectionPDFView = nil
            observedPagePDFView = nil
            observedFramePDFView = nil
            pdfView = nil
            searchState?.configureActions(next: nil, previous: nil, clear: nil)
        }

        func scheduleFitToWidth(in pdfView: PDFView, retriesRemaining: Int = 5) {
            guard shouldMaintainFitToWidth else { return }

            pendingFitWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                if pdfView.canopeFitCurrentPageToWidth() == false, retriesRemaining > 0 {
                    self.scheduleFitToWidth(in: pdfView, retriesRemaining: retriesRemaining - 1)
                }
            }
            pendingFitWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView,
                  allowsInverseSync,
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
            if isUpdatingSearchSelection {
                return
            }
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

        @objc
        private func handlePageChangedNotification(_ notification: Notification) {
            guard let pdfView else { return }
            reportCurrentPage(in: pdfView)
        }

        @objc
        private func handleFrameChangedNotification(_ notification: Notification) {
            guard let pdfView else { return }
            scheduleFitToWidth(in: pdfView)
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

        private func updateSearchResults(for query: String, in pdfView: PDFView) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedQuery.isEmpty == false else {
                clearSearchResults(in: pdfView)
                return
            }

            searchMatches = pdfView.document?.findString(trimmedQuery, withOptions: [.caseInsensitive]) ?? []
            searchState?.matchCount = searchMatches.count

            guard searchMatches.isEmpty == false else {
                searchState?.currentMatchIndex = 0
                clearSelection(in: pdfView)
                return
            }

            showSearchMatch(at: 0, in: pdfView)
        }

        private func clearSearchResults(in pdfView: PDFView) {
            searchMatches = []
            searchState?.matchCount = 0
            searchState?.currentMatchIndex = 0
            clearSelection(in: pdfView)
        }

        private func navigateSearch(step: Int, in pdfView: PDFView) {
            guard searchMatches.isEmpty == false else { return }
            let currentIndex = max(searchState?.currentMatchIndex ?? 1, 1) - 1
            let nextIndex = (currentIndex + step + searchMatches.count) % searchMatches.count
            showSearchMatch(at: nextIndex, in: pdfView)
        }

        private func showSearchMatch(at index: Int, in pdfView: PDFView) {
            guard searchMatches.indices.contains(index) else { return }
            let selection = searchMatches[index]
            isUpdatingSearchSelection = true
            pdfView.setCurrentSelection(selection, animate: true)
            if let page = selection.pages.first {
                let bounds = selection.bounds(for: page).insetBy(dx: -24, dy: -24)
                if bounds.isNull == false, bounds.isEmpty == false {
                    pdfView.go(to: bounds, on: page)
                }
            }
            isUpdatingSearchSelection = false
            searchState?.currentMatchIndex = index + 1
        }

        private func reportCurrentPage(in pdfView: PDFView) {
            guard let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            onCurrentPageChanged?(document.index(for: page))
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

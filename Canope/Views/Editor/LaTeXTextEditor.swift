import SwiftUI
import AppKit

struct LaTeXTextEditor: NSViewRepresentable {
    let fileURL: URL
    @Binding var text: String
    let errorLines: Set<Int>
    var fontSize: CGFloat = 14
    var theme: (name: String, bg: NSColor, fg: NSColor, comment: NSColor, command: NSColor, math: NSColor, env: NSColor, brace: NSColor)?
    let baselineText: String
    var resolvedAnnotations: [ResolvedLaTeXAnnotation] = []
    let onSelectionChange: (NSRange?) -> Void
    let onAnnotationActivate: (UUID) -> Void
    let onCreateAnnotationFromSelection: () -> Void
    let onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Scroll view stays dark for scrollbar appearance
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.scrollerStyle = .overlay
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textStorage = NSTextStorage()
        let layoutManager = PersistentSelectionLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = ChangeTrackingTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        // Force aqua on textView only — prevents dark mode from dimming syntax colors
        textView.appearance = NSAppearance(named: .aqua)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1)
        textView.textColor = NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1)
        textView.insertionPointColor = NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.gutterWidth = 38
        textView.textContainerInset = NSSize(width: textView.gutterWidth + 6, height: 8)

        // Soft word wrap — text flows to fit pane width, adjusts on resize
        textContainer.lineBreakMode = .byWordWrapping
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textContainer.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        textView.delegate = context.coordinator
        layoutManager.delegate = textView
        context.coordinator.parent = self
        context.coordinator.textView = textView
        textView.changeCoordinator = context.coordinator
        scrollView.documentView = textView

        // Set initial text
        textView.string = text
        context.coordinator.applyTheme(to: textView)
        context.coordinator.applyHighlighting()
        context.coordinator.cacheHighlightInputs(
            themeName: theme?.name,
            fontSize: fontSize,
            resolvedAnnotations: resolvedAnnotations
        )
        context.coordinator.refreshChangeTracking()
        context.coordinator.installSyncTeXObserver(for: textView)

        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeSyncTeXObserver()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChangeTrackingTextView else { return }
        context.coordinator.parent = self
        textView.changeCoordinator = context.coordinator

        let textChanged = textView.string != text
        let baselineChanged = context.coordinator.baselineText != baselineText
        let annotationsChanged = context.coordinator.cachedResolvedAnnotations != resolvedAnnotations
        let themeChanged = context.coordinator.cachedThemeName != theme?.name
        let fontChanged = context.coordinator.cachedFontSize != fontSize

        if textChanged {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let maxLen = (text as NSString).length
            let clampedLoc = min(selectedRange.location, maxLen)
            let clampedLen = min(selectedRange.length, maxLen - clampedLoc)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
        }

        // Always ensure aqua appearance for correct syntax colors
        if textView.appearance?.name != .aqua {
            textView.appearance = NSAppearance(named: .aqua)
        }

        context.coordinator.fontSize = fontSize
        if let theme {
            context.coordinator.theme = theme
        }
        context.coordinator.errorLines = errorLines
        context.coordinator.resolvedAnnotations = resolvedAnnotations
        if themeChanged || fontChanged {
            context.coordinator.applyTheme(to: textView)
        }

        if textChanged || baselineChanged {
            context.coordinator.refreshChangeTracking()
        }

        if textChanged || baselineChanged || annotationsChanged || themeChanged || fontChanged {
            context.coordinator.applyHighlighting()
            context.coordinator.cacheHighlightInputs(
                themeName: theme?.name,
                fontSize: fontSize,
                resolvedAnnotations: resolvedAnnotations
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LaTeXTextEditor
        fileprivate weak var textView: ChangeTrackingTextView?
        var errorLines: Set<Int> = []
        var fontSize: CGFloat = 14
        var theme: (name: String, bg: NSColor, fg: NSColor, comment: NSColor, command: NSColor, math: NSColor, env: NSColor, brace: NSColor)?
        var baselineText: String
        var resolvedAnnotations: [ResolvedLaTeXAnnotation] = []
        var cachedThemeName: String?
        var cachedFontSize: CGFloat = 0
        var cachedResolvedAnnotations: [ResolvedLaTeXAnnotation] = []
        private var changeHunks: [ChangeHunk] = []
        private var isUpdating = false
        private var syncTeXObserver: NSObjectProtocol?
        private var revealObserver: NSObjectProtocol?

        init(parent: LaTeXTextEditor) {
            self.parent = parent
            baselineText = parent.baselineText
        }

        deinit {
            removeSyncTeXObserver()
            removeRevealObserver()
        }

        @MainActor
        fileprivate func installSyncTeXObserver(for textView: ChangeTrackingTextView) {
            removeSyncTeXObserver()
            removeRevealObserver()
            syncTeXObserver = NotificationCenter.default.addObserver(
                forName: .syncTeXScrollToLine,
                object: nil,
                queue: .main
            ) { [weak textView] notification in
                guard let range = notification.userInfo?["range"] as? NSRange,
                      let textView else { return }
                let shouldSelectLine = notification.userInfo?["select"] as? Bool ?? true
                Task { @MainActor in
                    textView.scrollRangeToVisible(range)
                    textView.showFindIndicator(for: range)
                    if shouldSelectLine {
                        textView.setSelectedRange(range)
                    }
                }
            }
            revealObserver = NotificationCenter.default.addObserver(
                forName: .editorRevealLocation,
                object: nil,
                queue: .main
            ) { [weak textView] notification in
                guard let location = notification.userInfo?["location"] as? Int,
                      let textView else { return }
                let requestedLength = notification.userInfo?["length"] as? Int ?? 1
                Task { @MainActor in
                    let maxLength = (textView.string as NSString).length
                    let clampedLocation = min(max(location, 0), maxLength)
                    let revealLength = maxLength == 0 ? 0 : min(max(requestedLength, 1), maxLength - clampedLocation)
                    let revealRange = NSRange(location: clampedLocation, length: revealLength)
                    textView.scrollRangeToVisible(revealRange)
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
                    if revealRange.length > 0 {
                        textView.flashReveal(range: revealRange)
                    }
                }
            }
        }

        fileprivate func removeSyncTeXObserver() {
            if let syncTeXObserver {
                NotificationCenter.default.removeObserver(syncTeXObserver)
                self.syncTeXObserver = nil
            }
        }

        fileprivate func removeRevealObserver() {
            if let revealObserver {
                NotificationCenter.default.removeObserver(revealObserver)
                self.revealObserver = nil
            }
        }

        @MainActor
        fileprivate func applyTheme(to textView: ChangeTrackingTextView) {
            let t = theme
            let fg = t?.fg ?? NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1)
            let bg = t?.bg ?? NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1)
            let cursor = t?.env ?? NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1)
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

            textView.backgroundColor = bg
            // Don't set textView.textColor — it wipes ALL foreground attributes
            textView.insertionPointColor = cursor
            let selectionColor = cursor.withAlphaComponent(0.35)
            textView.selectedTextAttributes = [
                .backgroundColor: selectionColor,
                .foregroundColor: NSColor.white,
            ]
            textView.persistentSelectionBackgroundColor = selectionColor
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: fg,
            ]
            textView.gutterBackgroundColor = bg
            textView.markerColor = NSColor.systemGreen.withAlphaComponent(0.92)
            textView.deletedMarkerColor = NSColor.systemRed.withAlphaComponent(0.92)
            textView.dividerColor = fg.withAlphaComponent(0.025)
            textView.changedLineHighlightColor = NSColor.systemGreen.withAlphaComponent(0.12)
            textView.deletedLineHighlightColor = NSColor.systemRed.withAlphaComponent(0.18)
            textView.changedTextHighlightColor = NSColor.systemGreen.withAlphaComponent(0.34)
        }

        @MainActor
        fileprivate func cacheHighlightInputs(
            themeName: String?,
            fontSize: CGFloat,
            resolvedAnnotations: [ResolvedLaTeXAnnotation]
        ) {
            cachedThemeName = themeName
            cachedFontSize = fontSize
            cachedResolvedAnnotations = resolvedAnnotations
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView, !isUpdating else { return }
            parent.text = textView.string
            refreshChangeTracking()
            applyHighlighting()
            parent.onTextChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = textView else { return }
            let range = textView.selectedRange()
            if let state = ClaudeIDESelectionState.make(
                text: textView.string,
                fileURL: parent.fileURL,
                range: range
            ) {
                CanopeContextFiles.writeIDESelectionState(state)
            }
            CanopeContextFiles.clearLegacySelectionMirror()
            if range.length > 0 {
                parent.onSelectionChange(range)
            } else {
                parent.onSelectionChange(nil)
            }
        }

        @MainActor
        func activateAnnotation(at point: NSPoint) {
            guard let textView else { return }

            let charIndex = textView.characterIndexForInsertion(at: point)
            let candidateIndexes = [charIndex, max(0, charIndex - 1)]

            guard let annotationID = resolvedAnnotations.first(where: { resolved in
                guard let range = resolved.resolvedRange, !resolved.isDetached else { return false }
                return candidateIndexes.contains { index in
                    index >= range.location && index < NSMaxRange(range)
                }
            })?.annotation.id else {
                return
            }

            parent.onAnnotationActivate(annotationID)
        }

        @MainActor
        func canCreateAnnotationFromCurrentSelection() -> Bool {
            guard let textView else { return false }
            let range = textView.selectedRange()
            guard range.location != NSNotFound, range.length > 0 else { return false }

            return !resolvedAnnotations.contains { resolved in
                resolved.resolvedRange == range
            }
        }

        @MainActor
        func createAnnotationFromCurrentSelection() {
            guard canCreateAnnotationFromCurrentSelection() else { return }
            parent.onCreateAnnotationFromSelection()
        }

        @MainActor
        func applyHighlighting() {
            guard let textView = textView else { return }
            isUpdating = true
            defer { isUpdating = false }

            let t = theme
            let fg = t?.fg ?? NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1)
            let commentColor = t?.comment ?? NSColor(red: 0.43, green: 0.43, blue: 0.43, alpha: 1)
            let commandColor = t?.command ?? NSColor(red: 0.37, green: 0.66, blue: 1.0, alpha: 1)
            let mathColor = t?.math ?? NSColor(red: 0.38, green: 1.0, blue: 0.79, alpha: 1)
            let envColor = t?.env ?? NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1)
            let braceColor = t?.brace ?? NSColor(red: 1.0, green: 0.79, blue: 0.52, alpha: 1)

            let text = textView.string
            guard !text.isEmpty else { return }
            let fullRange = NSRange(location: 0, length: text.utf16.count)
            let storage = textView.textStorage!
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: fg], range: fullRange)

            highlight(storage, text: text, pattern: #"%[^\n]*"#, color: commentColor)
            highlight(storage, text: text, pattern: #"\\(begin|end)\{[^}]*\}"#, color: envColor)
            highlight(storage, text: text, pattern: #"\\[a-zA-Z@]+"#, color: commandColor)
            highlight(storage, text: text, pattern: #"\$\$[^$]+\$\$"#, color: mathColor)
            highlight(storage, text: text, pattern: #"\$[^$]+\$"#, color: mathColor)
            highlight(storage, text: text, pattern: #"[{}]"#, color: braceColor)
            highlight(storage, text: text, pattern: #"[\[\]]"#, color: braceColor.withAlphaComponent(0.7))
            applyAnnotationHighlights(to: storage)
            applyChangeTextHighlights(to: storage)
            storage.endEditing()
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: fg,
            ]
        }

        @MainActor
        func refreshChangeTracking() {
            guard let textView = textView else { return }
            baselineText = parent.baselineText

            guard baselineText != textView.string else {
                changeHunks = []
                textView.changeHunks = []
                return
            }

            changeHunks = ChangeHunk.compute(baselineText: baselineText, currentText: textView.string)
            textView.changeHunks = changeHunks
        }

        @MainActor
        func revertChange(id: UUID) {
            guard let textView = textView,
                  let hunk = changeHunks.first(where: { $0.id == id }) else { return }

            if textView.shouldChangeText(in: hunk.currentRange, replacementString: hunk.replacementText) {
                textView.textStorage?.beginEditing()
                textView.textStorage?.replaceCharacters(in: hunk.currentRange, with: hunk.replacementText)
                textView.textStorage?.endEditing()
                textView.didChangeText()

                let nsText = textView.string as NSString
                let insertionLocation = min(hunk.currentRange.location + (hunk.replacementText as NSString).length, nsText.length)
                textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
            }
        }

        private func highlight(_ storage: NSTextStorage, text: String, pattern: String, color: NSColor) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            let range = NSRange(location: 0, length: text.utf16.count)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                if let matchRange = match?.range {
                    storage.addAttribute(.foregroundColor, value: color, range: matchRange)
                }
            }
        }

        @MainActor
        private func applyAnnotationHighlights(to storage: NSTextStorage) {
            let highlightColor = NSColor.systemYellow.withAlphaComponent(0.22)
            let stringLength = storage.length
            let diffRanges = changeHunks
                .compactMap { hunk -> NSRange? in
                    guard hunk.kind == .modifiedOrAdded,
                          let changedRange = textView?.changedCharacterRange(for: hunk) else { return nil }
                    let safeRange = NSIntersectionRange(changedRange, NSRange(location: 0, length: stringLength))
                    return safeRange.length > 0 ? safeRange : nil
                }
                .sorted { lhs, rhs in
                    if lhs.location == rhs.location {
                        return lhs.length < rhs.length
                    }
                    return lhs.location < rhs.location
                }

            for resolved in resolvedAnnotations where !resolved.isDetached {
                guard let range = resolved.resolvedRange else { continue }
                let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: stringLength))
                guard safeRange.length > 0 else { continue }

                for visibleRange in annotationVisibleRanges(in: safeRange, excluding: diffRanges) {
                    storage.addAttribute(.backgroundColor, value: highlightColor, range: visibleRange)
                }
            }
        }

        private func annotationVisibleRanges(in range: NSRange, excluding excludedRanges: [NSRange]) -> [NSRange] {
            guard range.length > 0 else { return [] }
            guard !excludedRanges.isEmpty else { return [range] }

            var visibleRanges: [NSRange] = []
            var cursor = range.location
            let end = NSMaxRange(range)

            for excludedRange in excludedRanges {
                let overlap = NSIntersectionRange(range, excludedRange)
                guard overlap.length > 0 else { continue }

                if overlap.location > cursor {
                    visibleRanges.append(NSRange(location: cursor, length: overlap.location - cursor))
                }
                cursor = max(cursor, NSMaxRange(overlap))
                if cursor >= end {
                    break
                }
            }

            if cursor < end {
                visibleRanges.append(NSRange(location: cursor, length: end - cursor))
            }

            return visibleRanges.filter { $0.length > 0 }
        }

        @MainActor
        private func applyChangeTextHighlights(to storage: NSTextStorage) {
            guard let textView else { return }
            let stringLength = (textView.string as NSString).length

            for hunk in changeHunks where hunk.kind == .modifiedOrAdded && hunk.currentRange.length > 0 {
                guard let changedRange = textView.changedCharacterRange(for: hunk) else { continue }
                let safeRange = NSIntersectionRange(
                    changedRange,
                    NSRange(location: 0, length: stringLength)
                )
                guard safeRange.length > 0 else { continue }
                storage.addAttribute(
                    .backgroundColor,
                    value: textView.changedTextHighlightColor,
                    range: safeRange
                )
            }

            for hunk in changeHunks where hunk.kind == .modifiedOrAdded {
                guard textView.shouldRenderInlineDeletedPreview(for: hunk),
                      let previewLayout = textView.deletedPreviewLayout(for: hunk) else { continue }
                let kernRange = textView.deletedPreviewKerningRange(
                    forAnchorLocation: previewLayout.anchorLocation,
                    stringLength: stringLength
                )
                guard let kernRange else { continue }
                storage.addAttribute(
                    .kern,
                    value: previewLayout.width + 4,
                    range: kernRange
                )
            }
        }

    }
}

private struct ChangeHunk: Identifiable, Equatable {
    enum Kind: Equatable {
        case modifiedOrAdded
        case deleted
    }

    let id = UUID()
    let kind: Kind
    let currentRange: NSRange
    let replacementText: String
    let lineRange: ClosedRange<Int>?
    let anchorLocation: Int

    static func compute(baselineText: String, currentText: String) -> [ChangeHunk] {
        let oldLines = TrackedLine.make(from: baselineText)
        let newLines = TrackedLine.make(from: currentText)
        let oldTexts = oldLines.map(\.text)
        let newTexts = newLines.map(\.text)
        let segments = DiffEngine.lineSegments(old: oldTexts, new: newTexts)
        let oldNSString = baselineText as NSString
        let newNSString = currentText as NSString

        return segments.compactMap { segment in
            let replacementText = oldLines.textSegment(in: segment.oldRange, from: oldNSString)
            let currentRange = newLines.characterRange(in: segment.newRange, stringLength: newNSString.length)
            let anchorLocation = newLines.anchorLocation(for: segment.newRange, stringLength: newNSString.length)

            if replacementText.isEmpty && currentRange.length == 0 {
                return nil
            }

            let kind: Kind = segment.newRange.isEmpty ? .deleted : .modifiedOrAdded
            let lineRange: ClosedRange<Int>? = segment.newRange.isEmpty ? nil : (segment.newRange.lowerBound + 1)...segment.newRange.upperBound

            return ChangeHunk(
                kind: kind,
                currentRange: currentRange,
                replacementText: replacementText,
                lineRange: lineRange,
                anchorLocation: anchorLocation
            )
        }
    }
}

private struct TrackedLine: Equatable {
    let text: String
    let fullRange: NSRange

    static func make(from text: String) -> [TrackedLine] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var lines: [TrackedLine] = []
        var index = 0

        while index < nsText.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            let contentRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let fullRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            lines.append(TrackedLine(text: nsText.substring(with: contentRange), fullRange: fullRange))
            index = lineEnd
        }

        return lines
    }
}

private extension Array where Element == TrackedLine {
    func characterRange(in range: Range<Int>, stringLength: Int) -> NSRange {
        if range.isEmpty {
            let location = anchorLocation(for: range, stringLength: stringLength)
            return NSRange(location: location, length: 0)
        }

        let start = self[range.lowerBound].fullRange.location
        let end = self[range.upperBound - 1].fullRange.location + self[range.upperBound - 1].fullRange.length
        return NSRange(location: start, length: end - start)
    }

    func textSegment(in range: Range<Int>, from text: NSString) -> String {
        guard !range.isEmpty else { return "" }
        let segmentRange = characterRange(in: range, stringLength: text.length)
        guard segmentRange.length > 0 else { return "" }
        return text.substring(with: segmentRange)
    }

    func anchorLocation(for range: Range<Int>, stringLength: Int) -> Int {
        guard !isEmpty else { return 0 }
        if range.lowerBound < count {
            return self[range.lowerBound].fullRange.location
        }
        return stringLength
    }
}

fileprivate final class PersistentSelectionLayoutManager: NSLayoutManager {
    var persistentSelectionBackgroundColor = NSColor.systemPurple.withAlphaComponent(0.35)

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        let fillColor = shouldKeepCustomSelectionColor(for: charRange)
            ? persistentSelectionBackgroundColor
            : color

        // AppKit reads the current graphics-state fill color here; the `color`
        // parameter is informational and passing a replacement to `super` is not enough.
        fillColor.setFill()

        super.fillBackgroundRectArray(
            rectArray,
            count: rectCount,
            forCharacterRange: charRange,
            color: fillColor
        )

        color.setFill()
    }

    private func shouldKeepCustomSelectionColor(for charRange: NSRange) -> Bool {
        guard let textView = textContainers.compactMap({ $0.textView }).first else { return false }

        return MainActor.assumeIsolated {
            guard textView.window?.firstResponder !== textView else { return false }

            return textView.selectedRanges
                .lazy
                .map(\.rangeValue)
                .contains { selectedRange in
                    selectedRange.length > 0 && NSIntersectionRange(selectedRange, charRange).length > 0
                }
        }
    }
}

@MainActor
fileprivate final class ChangeTrackingTextView: NSTextView {
    struct MarkerFrame {
        let id: UUID
        let rect: NSRect
    }

    weak var changeCoordinator: LaTeXTextEditor.Coordinator?
    var gutterWidth: CGFloat = 10
    var changeHunks: [ChangeHunk] = [] {
        didSet { needsDisplay = true }
    }

    var gutterBackgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1)
    var lineNumberColor = NSColor.white.withAlphaComponent(0.25)
    var markerColor = NSColor.systemPurple
    var deletedMarkerColor = NSColor.systemRed
    var dividerColor = NSColor.white.withAlphaComponent(0.08)
    var changedLineHighlightColor = NSColor.systemPurple.withAlphaComponent(0.12)
    var deletedLineHighlightColor = NSColor.systemRed.withAlphaComponent(0.08)
    var changedTextHighlightColor = NSColor.systemGreen.withAlphaComponent(0.20)
    var revealHighlightColor = NSColor.systemYellow.withAlphaComponent(0.34)

    private var markerFrames: [MarkerFrame] = []
    private var selectedMarkerID: UUID?
    private var activeRevealRange: NSRange?
    private var revealClearWorkItem: DispatchWorkItem?
    private var deletedPreviewLineHeight: CGFloat {
        let previewFont = font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let lineHeight = previewFont.ascender - previewFont.descender + 2
        return max(18, ceil(lineHeight))
    }

    private var deletedPreviewVerticalPadding: CGFloat { 4 }

    var persistentSelectionBackgroundColor: NSColor {
        get {
            (layoutManager as? PersistentSelectionLayoutManager)?.persistentSelectionBackgroundColor
                ?? markerColor.withAlphaComponent(0.3)
        }
        set {
            (layoutManager as? PersistentSelectionLayoutManager)?.persistentSelectionBackgroundColor = newValue
            needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawGutter(in: rect)
        drawChangeHighlights(in: rect)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func didChangeText() {
        super.didChangeText()
        clearRevealHighlight()
        needsDisplay = true
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(expandedInvalidationRect(for: invalidRect), avoidAdditionalLayout: flag)
    }


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // ⌘+click → forward SyncTeX (anywhere in text area)
        if event.modifierFlags.contains(.command) && point.x > gutterWidth {
            let charIndex = characterIndexForInsertion(at: point)
            let nsString = string as NSString
            if charIndex < nsString.length {
                // Count which line this character is on
                var lineNumber = 1
                var scanPos = 0
                while scanPos < charIndex {
                    var lineEnd = 0
                    nsString.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: scanPos, length: 0))
                    if lineEnd <= scanPos { break }
                    if lineEnd > charIndex { break }
                    scanPos = lineEnd
                    lineNumber += 1
                }
                NotificationCenter.default.post(name: .syncTeXForwardSync, object: nil, userInfo: ["line": lineNumber])
            }
            return
        }

        guard point.x <= gutterWidth else {
            super.mouseDown(with: event)
            return
        }

        guard let marker = markerFrames.first(where: { $0.rect.insetBy(dx: -3, dy: -2).contains(point) }) else {
            super.mouseDown(with: event)
            return
        }

        selectedMarkerID = marker.id
        let menu = NSMenu()
        let item = NSMenuItem(title: "Revert ce changement", action: #selector(revertSelectedMarker(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseUp(with: event)

        guard event.clickCount == 1,
              !event.modifierFlags.contains(.command),
              point.x > gutterWidth,
              selectedRange().length == 0 else {
            return
        }

        changeCoordinator?.activateAnnotation(at: point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let selectionRange = selectedRange()
        guard selectionRange.location != NSNotFound, selectionRange.length > 0 else {
            return menu
        }

        if menu.items.contains(where: { $0.action == #selector(createAnnotationFromSelection(_:)) }) {
            return menu
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        let item = NSMenuItem(
            title: "Ajouter une annotation...",
            action: #selector(createAnnotationFromSelection(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = changeCoordinator?.canCreateAnnotationFromCurrentSelection() ?? false
        menu.addItem(item)
        return menu
    }

    @objc private func revertSelectedMarker(_ sender: NSMenuItem) {
        guard let selectedMarkerID else { return }
        changeCoordinator?.revertChange(id: selectedMarkerID)
    }

    @objc private func createAnnotationFromSelection(_ sender: NSMenuItem) {
        changeCoordinator?.createAnnotationFromCurrentSelection()
    }

    private func drawGutter(in dirtyRect: NSRect) {
        let gutterRect = NSRect(x: 0, y: dirtyRect.minY, width: min(gutterWidth, bounds.width), height: dirtyRect.height)
        gutterBackgroundColor.setFill()
        gutterRect.fill()

        let dividerRect = NSRect(x: gutterWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height)
        dividerColor.setFill()
        dividerRect.fill()

        // Draw line numbers
        drawLineNumbers(in: dirtyRect)

        // Draw change markers
        markerFrames = visibleMarkerFrames()
        for marker in markerFrames {
            let hunk = changeHunks.first(where: { $0.id == marker.id })
            switch hunk?.kind {
            case .deleted:
                deletedMarkerColor.setFill()
            default:
                markerColor.setFill()
            }

            let barRect: NSRect
            if marker.rect.height <= 4 {
                barRect = NSRect(x: 2, y: marker.rect.minY, width: 3, height: 3)
            } else {
                barRect = NSRect(x: 2, y: marker.rect.minY + 2, width: 3, height: marker.rect.height - 4)
            }

            let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
    }

    private func expandedInvalidationRect(for invalidRect: NSRect) -> NSRect {
        guard gutterWidth > 0 else { return invalidRect }

        let maxX = max(invalidRect.maxX, gutterWidth)
        return NSRect(
            x: 0,
            y: invalidRect.minY,
            width: min(bounds.width, maxX),
            height: invalidRect.height
        )
    }

    private func drawLineNumbers(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textOrigin = textContainerOrigin
        let visible = visibleRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: lineNumberColor,
        ]

        // Number every visual line (wrapped line fragment), not just hard newlines
        var lineNumber = 1
        var glyphIndex = 0
        let totalGlyphs = layoutManager.numberOfGlyphs

        while glyphIndex < totalGlyphs {
            var lineFragmentRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineFragmentRange, withoutAdditionalLayout: false)
            let y = lineRect.minY + textOrigin.y

            if y + lineRect.height >= visible.minY && y <= visible.maxY {
                let label = "\(lineNumber)" as NSString
                let labelSize = label.size(withAttributes: attrs)
                let labelRect = NSRect(
                    x: gutterWidth - labelSize.width - 6,
                    y: y + (lineRect.height - labelSize.height) / 2,
                    width: labelSize.width,
                    height: labelSize.height
                )
                label.draw(in: labelRect, withAttributes: attrs)
            }

            let nextGlyphIndex = NSMaxRange(lineFragmentRange)
            glyphIndex = nextGlyphIndex > glyphIndex ? nextGlyphIndex : glyphIndex + 1
            lineNumber += 1
        }
    }

    private func drawChangeHighlights(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager else { return }
        let textOrigin = textContainerOrigin

        for hunk in changeHunks {
            guard let highlightRect = highlightRect(for: hunk, using: layoutManager, textOrigin: textOrigin) else { continue }
            let previewRect = deletedPreviewRect(for: hunk, using: layoutManager, textOrigin: textOrigin)
            let dirtyCheckRect = previewRect.map { highlightRect.union($0) } ?? highlightRect
            guard dirtyCheckRect.intersects(dirtyRect) else { continue }

            let accentWidth: CGFloat = 2.5
            switch hunk.kind {
            case .deleted:
                deletedLineHighlightColor.setFill()
                let fillRect = highlightRect.insetBy(dx: 6, dy: 2)
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 5, yRadius: 5)
                fillPath.fill()
                deletedMarkerColor.setFill()
                let accentRect = NSRect(x: fillRect.minX, y: fillRect.minY, width: accentWidth, height: fillRect.height)
                NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5).fill()
                drawDeletedPreview(for: hunk, near: fillRect)
            case .modifiedOrAdded:
                markerColor.setFill()
                let accentRect = NSRect(
                    x: highlightRect.minX + 6,
                    y: highlightRect.minY + 2,
                    width: accentWidth,
                    height: max(6, highlightRect.height - 4)
                )
                NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5).fill()

                if shouldRenderInlineDeletedPreview(for: hunk),
                   let previewRect = deletedPreviewRect(for: hunk, using: layoutManager, textOrigin: textOrigin) {
                    drawDeletedPreview(for: hunk, in: previewRect, truncates: true)
                } else if shouldRenderBlockDeletedPreview(for: hunk),
                          let previewRect = blockDeletedPreviewRect(for: hunk, using: layoutManager, textOrigin: textOrigin) {
                    drawDeletedPreview(for: hunk, in: previewRect, truncates: false)
                }
            }
        }
    }

    private func drawDeletedPreview(for hunk: ChangeHunk, near rect: NSRect) {
        guard let previewLayout = deletedPreviewLayout(for: hunk) else { return }
        let label = previewLayout.label
        let labelSize = previewLayout.size
        let lineAlignedY = rect.minY + floor((rect.height - labelSize.height) / 2)
        let reservedGap: CGFloat = 4
        let minimumX = textContainerOrigin.x + 2
        let textRect = NSRect(
            x: max(minimumX, rect.minX - labelSize.width - reservedGap),
            y: max(0, lineAlignedY),
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawDeletedPreview(for hunk: ChangeHunk, in rect: NSRect, truncates: Bool) {
        let wraps = !truncates
        guard let previewLayout = deletedPreviewLayout(
            for: hunk,
            maxWidth: wraps ? rect.width : nil,
            wraps: wraps
        ) else { return }
        let label = previewLayout.label
        var options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if truncates {
            options.insert(.truncatesLastVisibleLine)
        }
        label.draw(with: rect, options: options)
    }

    private func deletedPreviewRect(for hunk: ChangeHunk, using layoutManager: NSLayoutManager, textOrigin: NSPoint) -> NSRect? {
        guard hunk.kind == .modifiedOrAdded,
              shouldRenderInlineDeletedPreview(for: hunk),
              let previewLayout = deletedPreviewLayout(for: hunk) else { return nil }

        let anchorRect = changedInlineRect(for: hunk, using: layoutManager, textOrigin: textOrigin)
            ?? highlightRect(for: hunk, using: layoutManager, textOrigin: textOrigin)
        guard let anchorRect else { return nil }

        let reservedGap: CGFloat = 4
        let minimumX = textOrigin.x + 2
        let drawX = max(minimumX, anchorRect.minX - previewLayout.width - reservedGap)
        let lineAlignedY = anchorRect.minY + floor((anchorRect.height - previewLayout.size.height) / 2)
        return NSRect(
            x: drawX,
            y: max(0, lineAlignedY),
            width: previewLayout.width,
            height: previewLayout.size.height
        )
    }

    private func blockDeletedPreviewRect(for hunk: ChangeHunk, using layoutManager: NSLayoutManager, textOrigin: NSPoint) -> NSRect? {
        guard hunk.kind == .modifiedOrAdded,
              shouldRenderBlockDeletedPreview(for: hunk) else { return nil }

        let anchorRect = changedInlineRect(for: hunk, using: layoutManager, textOrigin: textOrigin)
            ?? highlightRect(for: hunk, using: layoutManager, textOrigin: textOrigin)
        guard let anchorRect else { return nil }

        let availableWidth = max(56, bounds.width - gutterWidth - 18)
        guard let previewLayout = deletedPreviewLayout(
            for: hunk,
            maxWidth: availableWidth,
            wraps: true
        ) else { return nil }
        let reservedHeight = blockDeletedPreviewReservedHeight(for: hunk, availableWidth: availableWidth)
        let lineAlignedY = anchorRect.minY - reservedHeight + deletedPreviewVerticalPadding

        return NSRect(
            x: textOrigin.x + 4,
            y: max(0, lineAlignedY),
            width: previewLayout.width,
            height: previewLayout.size.height
        )
    }

    fileprivate func deletedPreviewLayout(
        for hunk: ChangeHunk,
        maxWidth: CGFloat? = nil,
        wraps: Bool = false
    ) -> (label: NSAttributedString, size: NSSize, width: CGFloat, anchorLocation: Int)? {
        let snippet = deletedPreviewText(for: hunk)
        guard !snippet.isEmpty else { return nil }

        let currentNSString = string as NSString
        let safeRange = NSIntersectionRange(
            hunk.currentRange,
            NSRange(location: 0, length: currentNSString.length)
        )
        guard safeRange.location != NSNotFound else { return nil }

        let newSegment = safeRange.length > 0 ? currentNSString.substring(with: safeRange) : ""
        let diff = diffMiddleRanges(old: hunk.replacementText, new: newSegment)
        let anchorLocation = min(safeRange.location + diff.newStart, currentNSString.length)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        let previewFont = font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let previewColor = NSColor.systemRed.withAlphaComponent(0.96)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: previewFont,
            .foregroundColor: previewColor,
            .paragraphStyle: style,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: previewColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: previewColor,
        ]

        let label = NSAttributedString(string: snippet, attributes: attributes)
        let measuredWidth = maxWidth ?? CGFloat.greatestFiniteMagnitude
        let rawSize = label.boundingRect(
            with: NSSize(width: measuredWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral.size
        let drawWidth = maxWidth ?? rawSize.width

        return (
            label: label,
            size: NSSize(width: drawWidth, height: rawSize.height),
            width: drawWidth,
            anchorLocation: anchorLocation
        )
    }

    private func blockDeletedPreviewReservedHeight(for hunk: ChangeHunk, availableWidth: CGFloat) -> CGFloat {
        guard let previewLayout = deletedPreviewLayout(for: hunk, maxWidth: availableWidth, wraps: true) else {
            return deletedPreviewLineHeight
        }

        return max(
            deletedPreviewLineHeight,
            ceil(previewLayout.size.height) + deletedPreviewVerticalPadding * 2
        )
    }

    fileprivate func deletedPreviewKerningRange(forAnchorLocation anchorLocation: Int, stringLength: Int) -> NSRange? {
        guard stringLength > 0 else { return nil }

        if anchorLocation > 0 {
            return NSRange(location: anchorLocation - 1, length: 1)
        }

        if anchorLocation < stringLength {
            return NSRange(location: anchorLocation, length: 1)
        }

        return nil
    }

    private func deletedPreviewLineStarts() -> Set<Int> {
        Set(
            changeHunks.compactMap { hunk in
                guard shouldRenderBlockDeletedPreview(for: hunk) else { return nil }
                return deletedPreviewLineStart(for: hunk)
            }
        )
    }

    private func blockDeletedPreviewHunk(forLineStart lineStart: Int) -> ChangeHunk? {
        changeHunks.first { hunk in
            guard shouldRenderBlockDeletedPreview(for: hunk) else { return false }
            return deletedPreviewLineStart(for: hunk) == lineStart
        }
    }

    fileprivate func shouldRenderInlineDeletedPreview(for hunk: ChangeHunk) -> Bool {
        guard hunk.kind == .modifiedOrAdded else { return false }
        guard !hunk.replacementText.isEmpty else { return false }

        let deletedSnippet = deletedPreviewText(for: hunk)
        guard !deletedSnippet.isEmpty else { return false }
        guard !deletedSnippet.contains("\\n") else { return false }
        guard deletedSnippet.count <= 28 else { return false }

        let currentNSString = string as NSString
        guard currentNSString.length > 0 else { return false }

        if let changedRange = changedCharacterRange(for: hunk) {
            let safeChangedRange = NSIntersectionRange(
                changedRange,
                NSRange(location: 0, length: currentNSString.length)
            )
            guard safeChangedRange.length > 0 else { return false }
            let changedSegment = currentNSString.substring(with: safeChangedRange)
            guard !changedSegment.contains("\n") else { return false }
            guard safeChangedRange.length <= 40 else { return false }
            guard !changeSpansMultipleVisualLines(for: safeChangedRange) else { return false }
            return true
        }

        let safeRange = NSIntersectionRange(
            hunk.currentRange,
            NSRange(location: 0, length: currentNSString.length)
        )
        guard safeRange.location != NSNotFound else { return false }
        let newSegment = safeRange.length > 0 ? currentNSString.substring(with: safeRange) : ""
        guard !newSegment.contains("\n") else { return false }
        guard safeRange.length <= 40 else { return false }
        guard !changeSpansMultipleVisualLines(for: safeRange) else { return false }

        return true
    }

    fileprivate func shouldRenderBlockDeletedPreview(for hunk: ChangeHunk) -> Bool {
        guard hunk.kind == .modifiedOrAdded else { return false }
        guard !shouldRenderInlineDeletedPreview(for: hunk) else { return false }
        return !deletedPreviewText(for: hunk).isEmpty
    }

    private func deletedPreviewLineStart(for hunk: ChangeHunk) -> Int? {
        guard hunk.kind == .modifiedOrAdded,
              !deletedPreviewText(for: hunk).isEmpty else { return nil }

        let nsString = string as NSString
        guard nsString.length > 0 else { return nil }

        let anchorLocation = changedCharacterRange(for: hunk)?.location ?? hunk.currentRange.location
        let safeLocation = min(max(anchorLocation, 0), max(0, nsString.length - 1))
        var lineStart = 0
        nsString.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: safeLocation, length: 0))
        return lineStart
    }

    fileprivate func changedCharacterRange(for hunk: ChangeHunk) -> NSRange? {
        guard hunk.kind == .modifiedOrAdded, hunk.currentRange.length > 0 else { return nil }
        let currentNSString = string as NSString
        let safeRange = NSIntersectionRange(hunk.currentRange, NSRange(location: 0, length: currentNSString.length))
        guard safeRange.length > 0 else { return nil }

        let newSegment = currentNSString.substring(with: safeRange)
        let diff = diffMiddleRanges(old: hunk.replacementText, new: newSegment)
        guard diff.newLength > 0 else { return nil }

        return NSRange(location: safeRange.location + diff.newStart, length: diff.newLength)
    }

    private func changeSpansMultipleVisualLines(for characterRange: NSRange) -> Bool {
        guard let layoutManager, let textContainer else { return true }

        let currentNSString = string as NSString
        let safeRange = NSIntersectionRange(
            characterRange,
            NSRange(location: 0, length: currentNSString.length)
        )
        guard safeRange.location != NSNotFound else { return true }

        layoutManager.ensureLayout(for: textContainer)

        let glyphRange: NSRange
        if safeRange.length > 0 {
            glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        } else {
            guard layoutManager.numberOfGlyphs > 0 else { return false }
            let anchorLocation = min(safeRange.location, max(0, currentNSString.length - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: anchorLocation)
            glyphRange = NSRange(location: glyphIndex, length: 1)
        }

        guard glyphRange.length > 0 else { return false }

        let firstGlyph = glyphRange.location
        let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)

        let firstRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: firstGlyph,
            effectiveRange: nil,
            withoutAdditionalLayout: false
        )
        let lastRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: lastGlyph,
            effectiveRange: nil,
            withoutAdditionalLayout: false
        )

        return abs(firstRect.minY - lastRect.minY) > 0.5
    }

    private func changedInlineRect(for hunk: ChangeHunk, using layoutManager: NSLayoutManager, textOrigin: NSPoint) -> NSRect? {
        guard hunk.kind == .modifiedOrAdded,
              let textContainer else { return nil }

        let currentNSString = string as NSString
        let safeRange = NSIntersectionRange(
            hunk.currentRange,
            NSRange(location: 0, length: currentNSString.length)
        )
        guard safeRange.location != NSNotFound else { return nil }

        let newSegment = safeRange.length > 0 ? currentNSString.substring(with: safeRange) : ""
        let diff = diffMiddleRanges(old: hunk.replacementText, new: newSegment)
        let anchorLocation = min(safeRange.location + diff.newStart, currentNSString.length)

        layoutManager.ensureLayout(for: textContainer)
        let firstGlyph: Int
        if currentNSString.length == 0 {
            return nil
        } else if anchorLocation >= currentNSString.length {
            firstGlyph = max(0, layoutManager.numberOfGlyphs - 1)
        } else {
            firstGlyph = layoutManager.glyphIndexForCharacter(at: anchorLocation)
        }
        var firstLineGlyphRange = NSRange()
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: firstGlyph,
            effectiveRange: &firstLineGlyphRange,
            withoutAdditionalLayout: false
        )
        let segmentRect: NSRect
        if diff.newLength > 0 {
            let changedRange = NSRange(location: safeRange.location + diff.newStart, length: diff.newLength)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: changedRange, actualCharacterRange: nil)
            let visibleGlyphRange = NSIntersectionRange(glyphRange, firstLineGlyphRange)
            guard visibleGlyphRange.length > 0 else { return nil }
            segmentRect = layoutManager.boundingRect(forGlyphRange: visibleGlyphRange, in: textContainer)
        } else {
            let targetGlyphIndex = min(firstGlyph, max(0, layoutManager.numberOfGlyphs - 1))
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: targetGlyphIndex, length: 1),
                in: textContainer
            )
            segmentRect = NSRect(
                x: glyphRect.minX,
                y: lineRect.minY,
                width: 12,
                height: lineRect.height
            )
        }

        return NSRect(
            x: segmentRect.minX + textOrigin.x,
            y: lineRect.minY + textOrigin.y,
            width: max(12, segmentRect.width),
            height: lineRect.height
        )
    }

    private func deletedPreviewText(for hunk: ChangeHunk) -> String {
        let currentNSString = string as NSString
        let safeRange = NSIntersectionRange(hunk.currentRange, NSRange(location: 0, length: currentNSString.length))
        let newSegment = safeRange.length > 0 ? currentNSString.substring(with: safeRange) : ""
        let diff = diffMiddleRanges(old: hunk.replacementText, new: newSegment)

        let oldNSString = hunk.replacementText as NSString
        guard diff.oldLength > 0,
              diff.oldStart + diff.oldLength <= oldNSString.length else { return "" }

        let deleted = oldNSString.substring(with: NSRange(location: diff.oldStart, length: diff.oldLength))
        return collapsedDeletedPreviewText(for: deleted)
    }

    private func diffMiddleRanges(old: String, new: String) -> (oldStart: Int, oldLength: Int, newStart: Int, newLength: Int) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let sharedCount = min(oldUnits.count, newUnits.count)
        var prefix = 0
        while prefix < sharedCount && oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var oldSuffix = oldUnits.count
        var newSuffix = newUnits.count
        while oldSuffix > prefix && newSuffix > prefix && oldUnits[oldSuffix - 1] == newUnits[newSuffix - 1] {
            oldSuffix -= 1
            newSuffix -= 1
        }

        return (
            oldStart: prefix,
            oldLength: max(0, oldSuffix - prefix),
            newStart: prefix,
            newLength: max(0, newSuffix - prefix)
        )
    }

    private func collapsedDeletedPreviewText(for rawText: String) -> String {
        let flattened = rawText
            .replacingOccurrences(of: "\n", with: " \\n ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !flattened.isEmpty else { return "" }
        if flattened.count <= 96 {
            return flattened
        }
        return String(flattened.prefix(93)) + "..."
    }

    func flashReveal(range: NSRange) {
        guard range.length > 0 else { return }
        clearRevealHighlight()
        layoutManager?.addTemporaryAttribute(
            .backgroundColor,
            value: revealHighlightColor,
            forCharacterRange: range
        )
        activeRevealRange = range
        needsDisplay = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clearRevealHighlight()
        }
        revealClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: workItem)
    }

    private func clearRevealHighlight() {
        revealClearWorkItem?.cancel()
        revealClearWorkItem = nil
        guard let activeRevealRange else { return }
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: activeRevealRange)
        self.activeRevealRange = nil
        needsDisplay = true
    }

    private func visibleMarkerFrames() -> [MarkerFrame] {
        changeHunks.compactMap { hunk in
            guard let rect = markerRect(for: hunk) else { return nil }
            return MarkerFrame(id: hunk.id, rect: rect)
        }
    }

    private func markerRect(for hunk: ChangeHunk) -> NSRect? {
        guard let layoutManager = layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let textOrigin = textContainerOrigin
        let textLength = (string as NSString).length

        if hunk.currentRange.length > 0, textLength > 0 {
            let safeLocation = min(hunk.currentRange.location, max(0, textLength - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeLocation)
            // Only first visual line fragment — not the entire wrapped extent
            let firstLineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            return NSRect(x: 0, y: firstLineRect.minY + textOrigin.y, width: gutterWidth, height: firstLineRect.height)
        }

        guard textLength > 0 else {
            return NSRect(x: 0, y: textOrigin.y, width: gutterWidth, height: 3)
        }

        let clampedLocation = min(hunk.anchorLocation, textLength)
        let yPosition: CGFloat

        if clampedLocation >= textLength {
            let lastGlyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
            let lastRect = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            yPosition = lastRect.maxY + textOrigin.y
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedLocation)
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            yPosition = lineRect.minY + textOrigin.y
        }

        return NSRect(x: 0, y: yPosition - 1, width: gutterWidth, height: 3)
    }

    private func highlightRect(for hunk: ChangeHunk, using layoutManager: NSLayoutManager, textOrigin: NSPoint) -> NSRect? {
        if let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        let textLength = (string as NSString).length
        let fullWidth = max(18, bounds.width - gutterWidth - 12)

        if hunk.currentRange.length > 0, textLength > 0 {
            let safeLocation = min(hunk.currentRange.location, max(0, textLength - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeLocation)
            // Only first visual line — compact highlight
            let firstLineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            let y = firstLineRect.minY + textOrigin.y
            return NSRect(x: gutterWidth + 4, y: y, width: fullWidth, height: firstLineRect.height)
        }

        guard textLength > 0 else {
            return NSRect(x: gutterWidth + 4, y: textOrigin.y, width: 18, height: 4)
        }

        let clampedLocation = min(hunk.anchorLocation, textLength)
        let yPosition: CGFloat

        if clampedLocation >= textLength {
            let lastGlyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
            let lastRect = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            yPosition = lastRect.maxY + textOrigin.y
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedLocation)
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            yPosition = lineRect.minY + textOrigin.y
        }

        return NSRect(x: gutterWidth + 4, y: yPosition, width: fullWidth, height: 18)
    }
}

extension ChangeTrackingTextView: @preconcurrency NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        paragraphSpacingBeforeGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard deletedPreviewLineStarts().contains(charIndex) else { return 0 }
        guard let textView = layoutManager.firstTextView as? ChangeTrackingTextView,
              let hunk = textView.blockDeletedPreviewHunk(forLineStart: charIndex) else { return 0 }

        let availableWidth = max(56, rect.width - textView.gutterWidth - 18)
        return textView.blockDeletedPreviewReservedHeight(for: hunk, availableWidth: availableWidth)
    }
}

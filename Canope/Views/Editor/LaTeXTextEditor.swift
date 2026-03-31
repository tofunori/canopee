import SwiftUI
import AppKit

struct LaTeXTextEditor: NSViewRepresentable {
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

        init(parent: LaTeXTextEditor) {
            self.parent = parent
            baselineText = parent.baselineText
        }

        deinit {
            removeSyncTeXObserver()
        }

        @MainActor
        fileprivate func installSyncTeXObserver(for textView: ChangeTrackingTextView) {
            removeSyncTeXObserver()
            syncTeXObserver = NotificationCenter.default.addObserver(
                forName: .syncTeXScrollToLine,
                object: nil,
                queue: .main
            ) { [weak textView] notification in
                guard let range = notification.userInfo?["range"] as? NSRange,
                      let textView else { return }
                Task { @MainActor in
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    textView.showFindIndicator(for: range)
                }
            }
        }

        fileprivate func removeSyncTeXObserver() {
            if let syncTeXObserver {
                NotificationCenter.default.removeObserver(syncTeXObserver)
                self.syncTeXObserver = nil
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
            textView.markerColor = cursor.withAlphaComponent(0.92)
            textView.deletedMarkerColor = NSColor.systemRed.withAlphaComponent(0.85)
            textView.dividerColor = fg.withAlphaComponent(0.025)
            textView.changedLineHighlightColor = cursor.withAlphaComponent(0.05)
            textView.deletedLineHighlightColor = NSColor.systemRed.withAlphaComponent(0.04)
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
            if range.length > 0 {
                let selected = (textView.string as NSString).substring(with: range)
                let content = "[Source: LaTeX editor]\n\(selected)"
                try? content.write(toFile: "/tmp/canope_selection.txt", atomically: true, encoding: .utf8)
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

        private func applyAnnotationHighlights(to storage: NSTextStorage) {
            let highlightColor = NSColor.systemYellow.withAlphaComponent(0.22)

            for resolved in resolvedAnnotations where !resolved.isDetached {
                guard let range = resolved.resolvedRange else { continue }
                storage.addAttribute(.backgroundColor, value: highlightColor, range: range)
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
        let segments = diffSegments(old: oldTexts, new: newTexts)
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

    private struct DiffSegment {
        let oldRange: Range<Int>
        let newRange: Range<Int>
    }

    private static func diffSegments(old: [String], new: [String]) -> [DiffSegment] {
        let dp = lcsMatrix(old: old, new: new)
        var segments: [DiffSegment] = []
        var i = 0
        var j = 0
        var oldStart: Int?
        var newStart: Int?

        func flush(upToOld oldEnd: Int, newEnd: Int) {
            guard let oldStart, let newStart else { return }
            segments.append(DiffSegment(oldRange: oldStart..<oldEnd, newRange: newStart..<newEnd))
            selfReset()
        }

        func selfReset() {
            oldStart = nil
            newStart = nil
        }

        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                flush(upToOld: i, newEnd: j)
                i += 1
                j += 1
            } else if j < new.count, i < old.count {
                if oldStart == nil {
                    oldStart = i
                    newStart = j
                }
                if dp[i][j + 1] >= dp[i + 1][j] {
                    j += 1
                } else {
                    i += 1
                }
            } else if j < new.count {
                if oldStart == nil {
                    oldStart = i
                    newStart = j
                }
                j += 1
            } else if i < old.count {
                if oldStart == nil {
                    oldStart = i
                    newStart = j
                }
                i += 1
            }
        }

        flush(upToOld: i, newEnd: j)
        return segments
    }

    private static func lcsMatrix(old: [String], new: [String]) -> [[Int]] {
        let oldCount = old.count
        let newCount = new.count
        var dp = Array(repeating: Array(repeating: 0, count: newCount + 1), count: oldCount + 1)

        guard oldCount > 0, newCount > 0 else { return dp }

        for i in stride(from: oldCount - 1, through: 0, by: -1) {
            for j in stride(from: newCount - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        return dp
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

    private var markerFrames: [MarkerFrame] = []
    private var selectedMarkerID: UUID?

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
            guard highlightRect.intersects(dirtyRect) else { continue }

            switch hunk.kind {
            case .deleted:
                deletedLineHighlightColor.setFill()
            case .modifiedOrAdded:
                changedLineHighlightColor.setFill()
            }

            let fillRect = highlightRect.insetBy(dx: 6, dy: 2)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 5, yRadius: 5)
            fillPath.fill()

            let accentWidth: CGFloat = 2.5
            switch hunk.kind {
            case .deleted:
                deletedMarkerColor.setFill()
            case .modifiedOrAdded:
                markerColor.setFill()
            }
            let accentRect = NSRect(x: fillRect.minX, y: fillRect.minY, width: accentWidth, height: fillRect.height)
            NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
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

        if hunk.currentRange.length > 0, textLength > 0 {
            let safeLocation = min(hunk.currentRange.location, max(0, textLength - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeLocation)
            // Only first visual line — compact highlight
            let firstLineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
            let y = firstLineRect.minY + textOrigin.y
            return NSRect(x: gutterWidth + 4, y: y, width: bounds.width - gutterWidth - 12, height: firstLineRect.height)
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

        return NSRect(x: gutterWidth + 4, y: yPosition - 1, width: 18, height: 4)
    }
}

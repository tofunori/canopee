import AppKit
import SwiftUI

@MainActor
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeSyntaxLanguage
    var fontSize: CGFloat = 14
    var theme: CodeSyntaxTheme = .monokai
    let onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.scrollerStyle = .overlay

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = CodeTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        textView.appearance = NSAppearance(named: .aqua)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.backgroundColor = theme.backgroundColor
        textView.textColor = theme.foregroundColor
        textView.insertionPointColor = theme.cursorColor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectionColor,
            .foregroundColor: theme.foregroundColor,
        ]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.gutterWidth = 42
        textView.textContainerInset = NSSize(width: textView.gutterWidth + 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textContainer.lineBreakMode = .byCharWrapping
        textView.minSize = NSSize(width: 0, height: 0)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.parent = self
        scrollView.documentView = textView

        textView.string = text
        context.coordinator.applyTheme()
        context.coordinator.applyHighlighting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        context.coordinator.parent = self
        context.coordinator.textView = textView
        textView.maxSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = scrollView.contentSize.width

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let maxLength = (text as NSString).length
            let clampedLocation = min(selectedRange.location, maxLength)
            let clampedLength = min(selectedRange.length, max(0, maxLength - clampedLocation))
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
        }

        if textView.appearance?.name != .aqua {
            textView.appearance = NSAppearance(named: .aqua)
        }

        context.coordinator.applyTheme()
        context.coordinator.applyHighlighting()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        fileprivate weak var textView: CodeTextView?
        private var isUpdating = false

        init(parent: CodeTextEditor) {
            self.parent = parent
        }

        @MainActor
        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.text = textView.string
            parent.onTextChange()
            applyHighlighting()
        }

        @MainActor
        func applyTheme() {
            guard let textView else { return }
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            textView.font = font
            textView.backgroundColor = parent.theme.backgroundColor
            textView.textColor = parent.theme.foregroundColor
            textView.insertionPointColor = parent.theme.cursorColor
            textView.selectedTextAttributes = [
                .backgroundColor: parent.theme.selectionColor,
                .foregroundColor: parent.theme.foregroundColor,
            ]
            textView.gutterBackgroundColor = parent.theme.backgroundColor.blended(withFraction: 0.16, of: .black) ?? parent.theme.backgroundColor
            textView.lineNumberColor = parent.theme.foregroundColor.withAlphaComponent(0.38)
            textView.dividerColor = parent.theme.foregroundColor.withAlphaComponent(0.10)
        }

        @MainActor
        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            guard fullRange.length > 0 else {
                textView.typingAttributes = [
                    .font: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular),
                    .foregroundColor: parent.theme.foregroundColor,
                ]
                return
            }

            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let spans = CodeSyntaxHighlighter.tokens(for: textView.string, language: parent.language)

            isUpdating = true
            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: parent.theme.foregroundColor,
            ], range: fullRange)

            for span in spans {
                storage.addAttribute(.foregroundColor, value: parent.theme.color(for: span.kind), range: span.range)
            }

            storage.endEditing()
            isUpdating = false

            textView.typingAttributes = [
                .font: font,
                .foregroundColor: parent.theme.foregroundColor,
            ]
        }
    }
}

final class CodeTextView: NSTextView {
    var gutterWidth: CGFloat = 42
    var gutterBackgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    var lineNumberColor = NSColor.white.withAlphaComponent(0.32)
    var dividerColor = NSColor.white.withAlphaComponent(0.08)

    override func drawBackground(in rect: NSRect) {
        // Do NOT call super — NSTextView.drawBackground(in:) resolves
        // backgroundColor through the view's effective appearance (.aqua),
        // which can lighten dark sRGB background colors.
        backgroundColor.setFill()
        rect.fill()
        drawGutter(in: rect)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(expandedInvalidationRect(for: invalidRect), avoidAdditionalLayout: flag)
    }

    private func drawGutter(in dirtyRect: NSRect) {
        let gutterRect = NSRect(x: 0, y: dirtyRect.minY, width: min(gutterWidth, bounds.width), height: dirtyRect.height)
        gutterBackgroundColor.setFill()
        gutterRect.fill()

        let dividerRect = NSRect(x: gutterWidth - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height)
        dividerColor.setFill()
        dividerRect.fill()
        drawLineNumbers(in: dirtyRect)
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
}

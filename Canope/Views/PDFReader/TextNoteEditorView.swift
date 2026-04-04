import AppKit
import PDFKit

final class TextBoxTextView: NSTextView {
    private var targetCaretWidth: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return max(0.5, 1.0 / scale)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
            updateInsertionPointStateAndRestartTimer(true)
        }
        return didBecomeFirstResponder
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        NSGraphicsContext.current?.cgContext.clear(rect)
        var caretRect = rect
        let width = targetCaretWidth
        caretRect.origin.x += (rect.width - width) / 2
        caretRect.size.width = width
        super.drawInsertionPoint(in: caretRect, color: color, turnedOn: flag)
    }
}

final class TextNoteEditorView: NSView {
    private static let lineFragmentPadding: CGFloat = 2.0

    let textView: NSTextView
    private let clipView: NSClipView
    private var fillColor: NSColor = .clear
    private var borderWidth: CGFloat = 1.0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(annotation: PDFAnnotation) {
        textView = TextBoxTextView(frame: .zero)
        clipView = NSClipView(frame: .zero)
        super.init(frame: .zero)

        clipView.drawsBackground = false
        clipView.autoresizingMask = [.width, .height]

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)

        clipView.documentView = textView
        addSubview(clipView)

        applyAnnotationStyle(annotation, updateString: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        clipView.frame = bounds
        updateTextViewFrame()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let drawingRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        fillColor.setFill()
        drawingRect.fill()

        NSColor.black.setStroke()
        let borderPath = NSBezierPath(rect: drawingRect)
        borderPath.lineWidth = borderWidth
        borderPath.stroke()
    }

    func syncFrame(_ frame: NSRect) {
        self.frame = frame
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func applyAnnotationStyle(_ annotation: PDFAnnotation, updateString: Bool = false) {
        let font = annotation.font ?? NSFont.systemFont(ofSize: 12)
        let fontColor = annotation.fontColor ?? .black

        fillColor = annotation.textBoxFillColor
        borderWidth = max(1.0, annotation.border?.lineWidth ?? 1.0)

        textView.font = font
        textView.textColor = fontColor
        textView.insertionPointColor = fontColor
        textView.alignment = annotation.alignment

        if updateString {
            textView.string = annotation.contents ?? ""
        }

        updateParagraphStyle(font: font, alignment: annotation.alignment)
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        if fullRange.length > 0 {
            textView.textStorage?.addAttributes([
                .font: font,
                .foregroundColor: fontColor,
            ], range: fullRange)
        }
        updateTextViewFrame()
        needsDisplay = true
    }

    func fittingHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return max(bounds.height, 15)
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = ceil(usedRect.height)
        let insetHeight = textView.textContainerInset.height * 2
        let minimumHeight = ceil((textView.font?.ascender ?? 0) + abs(textView.font?.descender ?? 0) + insetHeight + borderWidth)
        return max(minimumHeight, contentHeight + insetHeight + borderWidth)
    }

    private func updateParagraphStyle(font: NSFont, alignment: NSTextAlignment) {
        let paragraphStyle = NSMutableParagraphStyle()
        let descent = -font.descender
        let lineHeight = ceil(font.ascender) + ceil(descent)
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = -font.leading
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.alignment = alignment

        textView.defaultParagraphStyle = paragraphStyle
        textView.textContainerInset = NSSize(width: 0.0, height: 3.0 + round(descent) - descent)
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding

        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        if fullRange.length > 0 {
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        }

        var typingAttributes = textView.typingAttributes
        typingAttributes[.font] = font
        typingAttributes[.foregroundColor] = textView.textColor ?? NSColor.black
        typingAttributes[.paragraphStyle] = paragraphStyle
        textView.typingAttributes = typingAttributes
    }

    private func updateTextViewFrame() {
        let availableWidth = max(bounds.width, 30)
        let availableHeight = max(bounds.height, 15)
        textView.textContainer?.containerSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
        textView.minSize = NSSize(width: availableWidth, height: availableHeight)
        textView.maxSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(origin: .zero, size: NSSize(width: availableWidth, height: availableHeight))
    }
}

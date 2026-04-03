import SwiftUI
import PDFKit

private enum AnnotationCursorFactory {
    static func cursor(for tool: AnnotationTool, color: NSColor) -> NSCursor {
        switch tool {
        case .underline:
            return markupCursor(color: color, barCenterY: 4.5)
        case .strikethrough:
            return markupCursor(color: color, barCenterY: 11.5)
        default:
            return .iBeam
        }
    }

    private static func markupCursor(color: NSColor, barCenterY: CGFloat) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            let stemRect = NSRect(x: 11, y: 6, width: 2, height: 14)
            let stemPath = NSBezierPath(roundedRect: stemRect, xRadius: 1, yRadius: 1)
            NSColor.black.setFill()
            stemPath.fill()

            let barRect = NSRect(x: 6, y: barCenterY - 1.5, width: 12, height: 3)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            AnnotationColor.normalized(color).withAlphaComponent(0.98).setFill()
            barPath.fill()

            let outlineRect = barRect.insetBy(dx: -0.5, dy: -0.5)
            let outlinePath = NSBezierPath(roundedRect: outlineRect, xRadius: 2, yRadius: 2)
            NSColor.black.withAlphaComponent(0.18).setStroke()
            outlinePath.lineWidth = 1
            outlinePath.stroke()

            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: barCenterY))
    }
}

// MARK: - Selection Overlay

enum ResizeHandle {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum CursorMouseDownAction {
    case passThrough
    case handled
    case beginCustomDrag
}

struct TextAnnotationPreviewStyle {
    let text: String
    let fillColor: NSColor
    let borderColor: NSColor
    let font: NSFont
    let fontColor: NSColor
    let alignment: NSTextAlignment
}

class SelectionOverlayView: NSView {
    var selectionRects: [NSRect] = []
    var selectionColor: NSColor = AnnotationColor.previewColor(AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow, for: .highlight)
    var selectionTool: AnnotationTool = .highlight
    var annotationBorderRect: NSRect? = nil
    var isEditingAnnotation = false
    let handleSize: CGFloat = 11
    private let handleHitExpansion: CGFloat = 12

    override var isOpaque: Bool { false }

    // Resize drag state
    private var activeHandle: ResizeHandle?
    private var pendingHandle: ResizeHandle?
    private var isMovingAnnotation = false
    private var isPendingInteriorDrag = false
    private var dragOriginRect: NSRect?
    private var dragStartPoint: NSPoint?
    private var textAnnotationPreviewStyle: TextAnnotationPreviewStyle?
    private var showsTextAnnotationPreview = false
    private let dragActivationDistance: CGFloat = 2.5
    var allowsInteriorDragging = false
    var onInteriorDoubleClick: (() -> Void)?
    var onMoveBegan: (() -> Void)?
    var onResizeBegan: (() -> Void)?
    var onMoveChanged: ((_ newRect: NSRect) -> Void)?
    var onMoveComplete: ((_ newRect: NSRect) -> Void)?
    var onResizeChanged: ((_ newRect: NSRect) -> Void)?
    var onResizeComplete: ((_ newRect: NSRect) -> Void)?
    weak var eventPassthroughView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept if clicking on a resize handle
        if let _ = handleAt(point) {
            return self
        }
        if allowsInteriorDragging,
           let rect = annotationBorderRect,
           rect.contains(point) {
            return self
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.magnify(with: event)
            return
        }
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.smartMagnify(with: event)
            return
        }
        super.smartMagnify(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)

        if !selectionRects.isEmpty {
            switch selectionTool {
            case .underline:
                selectionColor.setStroke()
                for rect in selectionRects {
                    let path = NSBezierPath()
                    let y = rect.minY + max(1.0, rect.height * 0.12)
                    path.move(to: NSPoint(x: rect.minX, y: y))
                    path.line(to: NSPoint(x: rect.maxX, y: y))
                    path.lineWidth = max(1.5, rect.height * 0.08)
                    path.lineCapStyle = .round
                    path.stroke()
                }
            case .strikethrough:
                selectionColor.setStroke()
                for rect in selectionRects {
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: rect.minX, y: rect.midY))
                    path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                    path.lineWidth = max(1.5, rect.height * 0.08)
                    path.lineCapStyle = .round
                    path.stroke()
                }
            default:
                selectionColor.setFill()
                for rect in selectionRects { rect.fill() }
            }
        }
        if let rect = annotationBorderRect {
            if showsTextAnnotationPreview, let preview = textAnnotationPreviewStyle {
                preview.fillColor.setFill()
                rect.fill()

                preview.borderColor.setStroke()
                let previewBorderPath = NSBezierPath(rect: rect)
                previewBorderPath.lineWidth = 1
                previewBorderPath.stroke()

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = preview.alignment
                paragraphStyle.lineBreakMode = .byWordWrapping

                let textRect = rect.insetBy(dx: 4, dy: 4)
                let attributedString = NSAttributedString(
                    string: preview.text,
                    attributes: [
                        .font: preview.font,
                        .foregroundColor: preview.fontColor,
                        .paragraphStyle: paragraphStyle
                    ]
                )
                attributedString.draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }

            NSColor.black.setStroke()
            let borderPath = NSBezierPath(rect: rect)
            borderPath.lineWidth = isEditingAnnotation ? 1.0 : 1.5
            if !isEditingAnnotation {
                borderPath.setLineDash([4, 3], count: 2, phase: 0)
            }
            borderPath.stroke()

            NSColor.white.setFill()
            NSColor.black.setStroke()
            for handleRect in handleRects(for: rect) {
                let path = NSBezierPath(rect: handleRect)
                path.fill()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func handleRects(for rect: NSRect) -> [NSRect] {
        let hs = handleSize
        return [
            NSRect(x: rect.minX - hs/2, y: rect.minY - hs/2, width: hs, height: hs),
            NSRect(x: rect.maxX - hs/2, y: rect.minY - hs/2, width: hs, height: hs),
            NSRect(x: rect.minX - hs/2, y: rect.maxY - hs/2, width: hs, height: hs),
            NSRect(x: rect.maxX - hs/2, y: rect.maxY - hs/2, width: hs, height: hs),
        ]
    }

    private func handleAt(_ point: NSPoint) -> ResizeHandle? {
        guard let rect = annotationBorderRect else { return nil }
        let handles = handleRects(for: rect)
        let hitRects = handles.map { $0.insetBy(dx: -handleHitExpansion, dy: -handleHitExpansion) }
        if hitRects[0].contains(point) { return .bottomLeft }
        if hitRects[1].contains(point) { return .bottomRight }
        if hitRects[2].contains(point) { return .topLeft }
        if hitRects[3].contains(point) { return .topRight }
        return nil
    }

    func isResizeHandle(at point: NSPoint) -> Bool {
        handleAt(point) != nil
    }

    // MARK: - Resize Drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handleAt(point), let rect = annotationBorderRect else {
            if allowsInteriorDragging, let rect = annotationBorderRect, rect.contains(point) {
                if event.clickCount >= 2 {
                    onInteriorDoubleClick?()
                    return
                }
                pendingHandle = nil
                isPendingInteriorDrag = true
                isMovingAnnotation = false
                showsTextAnnotationPreview = false
                dragOriginRect = rect
                dragStartPoint = point
                return
            }
            super.mouseDown(with: event)
            return
        }
        pendingHandle = handle
        activeHandle = nil
        isPendingInteriorDrag = false
        isMovingAnnotation = false
        showsTextAnnotationPreview = false
        dragOriginRect = rect
        dragStartPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOriginRect, let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        activatePendingInteractionIfNeeded(currentPoint: current)

        guard isMovingAnnotation || activeHandle != nil else { return }

        let dx = current.x - start.x
        let dy = current.y - start.y

        if isMovingAnnotation {
            let newRect = origin.offsetBy(dx: dx, dy: dy)
            annotationBorderRect = newRect
            needsDisplay = true
            onMoveChanged?(newRect)
            return
        }

        guard let handle = activeHandle else {
            super.mouseDragged(with: event)
            return
        }
        var newRect = origin
        switch handle {
        case .bottomRight:
            newRect.size.width = max(30, origin.width + dx)
            newRect.size.height = max(15, origin.height - dy)
            newRect.origin.y = origin.origin.y + dy
        case .bottomLeft:
            newRect.origin.x = origin.origin.x + dx
            newRect.size.width = max(30, origin.width - dx)
            newRect.size.height = max(15, origin.height - dy)
            newRect.origin.y = origin.origin.y + dy
        case .topRight:
            newRect.size.width = max(30, origin.width + dx)
            newRect.size.height = max(15, origin.height + dy)
        case .topLeft:
            newRect.origin.x = origin.origin.x + dx
            newRect.size.width = max(30, origin.width - dx)
            newRect.size.height = max(15, origin.height + dy)
        }

        annotationBorderRect = newRect
        needsDisplay = true
        onResizeChanged?(newRect)
    }

    override func mouseUp(with event: NSEvent) {
        if (pendingHandle != nil || isPendingInteriorDrag) && activeHandle == nil && !isMovingAnnotation {
            pendingHandle = nil
            isPendingInteriorDrag = false
            dragOriginRect = nil
            dragStartPoint = nil
            showsTextAnnotationPreview = false
            NSCursor.arrow.set()
            return
        }

        guard (activeHandle != nil || isMovingAnnotation), let newRect = annotationBorderRect else {
            super.mouseUp(with: event)
            return
        }
        let finishedMoving = isMovingAnnotation
        activeHandle = nil
        pendingHandle = nil
        isMovingAnnotation = false
        isPendingInteriorDrag = false
        dragOriginRect = nil
        dragStartPoint = nil
        showsTextAnnotationPreview = false
        NSCursor.arrow.set()
        needsDisplay = true
        if finishedMoving {
            onMoveComplete?(newRect)
        } else {
            onResizeComplete?(newRect)
        }
    }

    func updateSelection(rects: [NSRect], color: NSColor, tool: AnnotationTool) {
        selectionRects = rects
        selectionColor = color
        selectionTool = tool
        needsDisplay = true
    }

    func updateAnnotationBorder(rect: NSRect?, isEditing: Bool = false) {
        annotationBorderRect = rect
        isEditingAnnotation = isEditing
        if rect == nil {
            showsTextAnnotationPreview = false
        }
        needsDisplay = true
    }

    func updateTextAnnotationPreviewStyle(_ style: TextAnnotationPreviewStyle?) {
        textAnnotationPreviewStyle = style
        if style == nil {
            showsTextAnnotationPreview = false
        }
        needsDisplay = true
    }

    func clear() {
        selectionRects = []
        annotationBorderRect = nil
        isEditingAnnotation = false
        activeHandle = nil
        pendingHandle = nil
        isMovingAnnotation = false
        isPendingInteriorDrag = false
        dragOriginRect = nil
        dragStartPoint = nil
        textAnnotationPreviewStyle = nil
        showsTextAnnotationPreview = false
        needsDisplay = true
    }

    func clearSelection() {
        selectionRects = []
        needsDisplay = true
    }

    private func activatePendingInteractionIfNeeded(currentPoint: NSPoint) {
        guard let start = dragStartPoint else { return }
        let dx = currentPoint.x - start.x
        let dy = currentPoint.y - start.y
        guard hypot(dx, dy) >= dragActivationDistance else { return }

        if isPendingInteriorDrag {
            isPendingInteriorDrag = false
            isMovingAnnotation = true
            showsTextAnnotationPreview = textAnnotationPreviewStyle != nil
            onMoveBegan?()
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        guard activeHandle == nil, let pendingHandle else { return }
        self.pendingHandle = nil
        activeHandle = pendingHandle
        showsTextAnnotationPreview = textAnnotationPreviewStyle != nil
        onResizeBegan?()
        NSCursor.crosshair.set()
        needsDisplay = true
    }
}

// MARK: - Cursor Tracking View

/// View placed over PDFView for cursor control and drawing tool drag interaction.
class CursorTrackingView: NSView {
    var desiredCursor: NSCursor = .arrow
    var interactiveMode = false
    var currentTool: AnnotationTool = .pointer
    var previewColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    var previewScaleFactor: CGFloat = 1.0
    var shouldInterceptPoint: ((_ point: NSPoint) -> Bool)?
    weak var eventPassthroughView: NSView?
    private var trackingArea: NSTrackingArea?

    // Drag state
    private var dragStart: NSPoint?
    private var dragCurrentRect: NSRect?
    private var inkPath: NSBezierPath?
    private var isCustomDragging = false

    // Callbacks
    var onMouseDownAction: ((_ event: NSEvent, _ point: NSPoint) -> CursorMouseDownAction)?
    var onCustomDragChanged: ((_ start: NSPoint, _ current: NSPoint) -> Void)?
    var onCustomDragComplete: ((_ start: NSPoint, _ end: NSPoint) -> Void)?
    var onRectDragComplete: ((_ start: NSPoint, _ end: NSPoint) -> Void)?
    var onInkDragComplete: ((_ path: NSBezierPath) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveMode else { return nil }
        if shouldInterceptPoint?(point) == false {
            return nil
        }
        return self
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { desiredCursor.set() }
    override func mouseMoved(with event: NSEvent) { desiredCursor.set() }
    override func mouseEntered(with event: NSEvent) { desiredCursor.set() }

    override func scrollWheel(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.magnify(with: event)
            return
        }
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        if let eventPassthroughView {
            eventPassthroughView.smartMagnify(with: event)
            return
        }
        super.smartMagnify(with: event)
    }

    // MARK: - Draw feedback

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let strokeColor = AnnotationColor.normalized(previewColor)
        let fillColor = AnnotationColor.normalized(previewColor).withAlphaComponent(0.12)
        let previewStrokeWidth = max(1.5, 2.0 * previewScaleFactor)

        if let rect = dragCurrentRect {
            strokeColor.setStroke()
            fillColor.setFill()
            let path: NSBezierPath
            switch currentTool {
            case .oval:
                path = NSBezierPath(ovalIn: rect)
            case .arrow:
                path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                // Arrowhead
                let angle = atan2(rect.minY - rect.maxY, rect.maxX - rect.minX)
                let headLen: CGFloat = 12
                let p1 = NSPoint(x: rect.maxX - headLen * cos(angle - .pi/6),
                                 y: rect.minY - headLen * sin(angle - .pi/6))
                let p2 = NSPoint(x: rect.maxX - headLen * cos(angle + .pi/6),
                                 y: rect.minY - headLen * sin(angle + .pi/6))
                path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: p1)
                path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: p2)
            default:
                path = NSBezierPath(rect: rect)
            }
            path.lineWidth = previewStrokeWidth
            path.setLineDash([4, 3], count: 2, phase: 0)
            if currentTool != .arrow { path.fill() }
            path.stroke()
        }

        if let ink = inkPath {
            strokeColor.withAlphaComponent(0.9).setStroke()
            ink.lineWidth = previewStrokeWidth
            ink.lineCapStyle = .round
            ink.lineJoinStyle = .round
            ink.stroke()
        }
    }

    // MARK: - Drag interaction

    override func mouseDown(with event: NSEvent) {
        guard interactiveMode else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let action = onMouseDownAction?(event, point) ?? .passThrough
        if action == .handled {
            return
        }

        if action == .beginCustomDrag {
            dragStart = point
            dragCurrentRect = nil
            inkPath = nil
            isCustomDragging = true
            desiredCursor.set()
            return
        }

        dragStart = point
        dragCurrentRect = nil
        if currentTool == .ink {
            let path = NSBezierPath()
            path.move(to: point)
            inkPath = path
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactiveMode, let start = dragStart else { super.mouseDragged(with: event); return }
        let current = convert(event.locationInWindow, from: nil)

        if isCustomDragging {
            onCustomDragChanged?(start, current)
            desiredCursor.set()
            return
        }

        if currentTool == .ink {
            inkPath?.line(to: current)
        } else {
            dragCurrentRect = NSRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y)
            )
        }
        needsDisplay = true
        desiredCursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactiveMode, let start = dragStart else { super.mouseUp(with: event); return }

        let end = convert(event.locationInWindow, from: nil)

        if isCustomDragging {
            dragStart = nil
            isCustomDragging = false
            onCustomDragComplete?(start, end)
            return
        }

        if currentTool == .ink, let path = inkPath {
            dragStart = nil
            if path.bounds.width > 3 || path.bounds.height > 3 {
                onInkDragComplete?(path)
            }
            clearDragPreviewAsync()
            return
        }

        dragStart = nil

        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        guard width > 5 || height > 5 else {
            dragCurrentRect = nil
            needsDisplay = true
            return
        }

        onRectDragComplete?(start, end)
        clearDragPreviewAsync()
    }

    private func clearDragPreviewAsync() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dragCurrentRect = nil
            self.inkPath = nil
            self.needsDisplay = true
        }
    }
}

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

// MARK: - NSViewRepresentable

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let fileURL: URL
    @Binding var currentTool: AnnotationTool
    @Binding var currentColor: NSColor
    @Binding var selectedAnnotation: PDFAnnotation?
    @Binding var selectedText: String
    let restoredPageIndex: Int?
    let onDocumentChanged: @MainActor () -> Void
    let onCurrentPageChanged: @MainActor (Int) -> Void
    let onMarkupAppearanceNeedsRefresh: @MainActor () -> Void
    @Binding var clearSelectionAction: (() -> Void)?
    @Binding var undoAction: (() -> Void)?
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

        // Expose undo to parent view
        DispatchQueue.main.async {
            self.undoAction = { [weak coordinator = context.coordinator] in
                coordinator?.undo()
            }
            self.clearSelectionAction = { [weak coordinator = context.coordinator] in
                coordinator?.clearCurrentTextSelection()
            }
            self.applyBridgeAnnotation = { [weak coordinator = context.coordinator] selection, type, color in
                coordinator?.applyBridgeAnnotation(selection: selection, type: type, color: color)
            }
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

        if let pdfView = context.coordinator.pdfView, pdfView.document !== document {
            let viewState = context.coordinator.captureViewState()
            context.coordinator.clearTransientInteractionState()
            pdfView.document = nil
            pdfView.document = document
            pdfView.layoutDocumentView()
            context.coordinator.restoreViewState(viewState)
        }

        context.coordinator.pdfView?.selectionPreviewTool = currentTool
        context.coordinator.pdfView?.selectionPreviewColor = currentColor
        context.coordinator.cursorView?.previewColor = currentColor
        context.coordinator.cursorView?.previewScaleFactor = context.coordinator.pdfView?.scaleFactor ?? 1.0

        context.coordinator.updateCursor(for: currentTool)
        context.coordinator.syncEditingViewAppearance()
        context.coordinator.updateAnnotationBorder()
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
    class Coordinator: NSObject, NSGestureRecognizerDelegate, NSTextViewDelegate {
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
        var currentTool: AnnotationTool = .pointer
        var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
        private var hasActiveSelection = false
        private var isDragging = false
        private var isApplyingTextMarkup = false
        private var mouseUpMonitor: Any?
        private var magnifyMonitor: Any?

        // Undo support
        private var undoStack: [(page: PDFPage, annotation: PDFAnnotation)] = []

        // TextBox editing state
        private var editingEditorView: TextNoteEditorView? = nil
        private var editingTextView: NSTextView? = nil
        private var editingAnnotation: PDFAnnotation? = nil
        private var shouldRestoreTextEditingAfterResize = false
        private var cursorDragOriginOverlayRect: NSRect?
        private var isManipulatingSelectedTextAnnotation = false

        init(parent: PDFKitView) {
            self.parent = parent
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
            guard tool.needsDragInteraction, editingTextView == nil else { return false }

            if tool == .textBox,
               let selectedAnnotation = parent.selectedAnnotation,
               selectedAnnotation.isTextBoxAnnotation {
                return false
            }

            return true
        }

        func shouldCursorViewIntercept(pointInCursorView: NSPoint) -> Bool {
            guard let cursorView = cursorView else { return true }

            if let overlay = overlay {
                let pointInOverlay = overlay.convert(pointInCursorView, from: cursorView)
                if currentTool == .textBox,
                   editingTextView == nil,
                   let selectedAnnotation = parent.selectedAnnotation,
                   selectedAnnotation.isTextBoxAnnotation,
                   let overlayRect = overlay.annotationBorderRect {
                    let interactionRect = overlayRect.insetBy(dx: -(overlay.handleSize + 10), dy: -(overlay.handleSize + 10))
                    if interactionRect.contains(pointInOverlay) {
                        return false
                    }
                }
            }

            guard currentTool == .textBox,
                  editingTextView == nil,
                  let selectedAnnotation = parent.selectedAnnotation,
                  selectedAnnotation.isTextBoxAnnotation,
                  let pdfView = pdfView,
                  let page = selectedAnnotation.page else {
                return true
            }

            let pointInPDFView = cursorView.convert(pointInCursorView, to: pdfView)
            let pointInPage = pdfView.convert(pointInPDFView, to: page)
            return selectedAnnotation.bounds.contains(pointInPage) == false
        }

        // MARK: - Undo

        func recordForUndo(page: PDFPage, annotation: PDFAnnotation) {
            undoStack.append((page: page, annotation: annotation))
            // Keep max 50 undo steps
            if undoStack.count > 50 { undoStack.removeFirst() }
        }

        func undo() {
            guard let last = undoStack.popLast() else { return }
            last.page.removeAnnotation(last.annotation)
            if parent.selectedAnnotation === last.annotation {
                parent.selectedAnnotation = nil
            }
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        // MARK: - Bridge Annotation

        func applyBridgeAnnotation(selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor) {
            guard let pdfView = pdfView else { return }

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
            parent.onDocumentChanged()
        }

        // MARK: - TextBox Drag-to-Create (via CursorTrackingView)

        func setupDrawingCallbacks() {
            cursorView?.onCustomDragChanged = { [weak self] start, current in
                self?.handleCursorDragChanged(start: start, current: current)
            }
            cursorView?.onCustomDragComplete = { [weak self] start, end in
                self?.handleCursorDragComplete(start: start, end: end)
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
                self?.beginEditingSelectedTextBoxIfNeeded()
            }
            overlay?.onMoveBegan = { [weak self] in
                self?.beginSelectedTextAnnotationManipulation()
            }
            overlay?.onResizeBegan = { [weak self] in
                self?.beginSelectedTextAnnotationManipulation()
            }
            overlay?.onMoveChanged = { [weak self] newOverlayRect in
                self?.handleMoveChanged(newOverlayRect)
            }
            overlay?.onMoveComplete = { [weak self] newOverlayRect in
                self?.handleMoveComplete(newOverlayRect)
            }
            overlay?.onResizeChanged = { [weak self] newOverlayRect in
                self?.handleResizeChanged(newOverlayRect)
            }
            overlay?.onResizeComplete = { [weak self] newOverlayRect in
                self?.handleResizeComplete(newOverlayRect)
            }
        }

        private func beginEditingSelectedTextBoxIfNeeded() {
            guard let annotation = parent.selectedAnnotation,
                  annotation.isTextBoxAnnotation,
                  let page = annotation.page else { return }
            beginEditingTextBox(annotation, on: page)
        }

        private func pageRect(fromOverlayRect overlayRect: NSRect) -> CGRect? {
            guard let pdfView = pdfView,
                  let overlay = overlay,
                  let annotation = parent.selectedAnnotation,
                  let page = annotation.page else { return nil }

            // Convert overlay rect → pdfView rect → page rect
            let viewRect = pdfView.convert(overlayRect, from: overlay)
            return pdfView.convert(viewRect, to: page)
        }

        private func editorFrameInDocumentView(for annotation: PDFAnnotation, on page: PDFPage) -> NSRect? {
            guard let pdfView = pdfView,
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
            guard let pdfView = pdfView,
                  let documentView = pdfView.documentView,
                  let annotation = editingAnnotation,
                  let page = annotation.page,
                  let editorView = editingEditorView else { return }
            let viewRect = pdfView.convert(editorView.frame, from: documentView)
            annotation.bounds = pdfView.convert(viewRect, to: page)
        }

        private func invalidatePDFRegion(for annotation: PDFAnnotation?, padding: CGFloat = 12) {
            guard let pdfView = pdfView,
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

        func syncEditingViewAppearance(updateString: Bool = false) {
            guard let annotation = editingAnnotation,
                  let editorView = editingEditorView else { return }
            editorView.applyAnnotationStyle(annotation, updateString: updateString)
            if let page = annotation.page {
                syncEditingViewFrame(with: annotation, on: page)
            }
        }

        private func adjustEditingTextBoxToFitContentIfNeeded() {
            guard let pdfView = pdfView,
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
            updateAnnotationBorder()
            pdfView.setNeedsDisplay(pdfView.bounds)
        }

        private func updateSelectedAnnotationBounds(using overlayRect: NSRect) {
            guard let annotation = parent.selectedAnnotation,
                  let pageRect = pageRect(fromOverlayRect: overlayRect) else { return }
            annotation.bounds = pageRect
            if editingAnnotation === annotation, let page = annotation.page {
                syncEditingViewFrame(with: annotation, on: page)
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        }

        private func beginSelectedTextAnnotationManipulation() {
            guard let annotation = parent.selectedAnnotation,
                  annotation.isTextBoxAnnotation,
                  editingAnnotation == nil else { return }
            isManipulatingSelectedTextAnnotation = true
            annotation.shouldDisplay = false
            invalidatePDFRegion(for: annotation)
        }

        private func endSelectedTextAnnotationManipulation() {
            guard let annotation = parent.selectedAnnotation,
                  annotation.isTextBoxAnnotation else {
                isManipulatingSelectedTextAnnotation = false
                return
            }
            annotation.shouldDisplay = true
            isManipulatingSelectedTextAnnotation = false
            invalidatePDFRegion(for: annotation)
        }

        private func handleResizeChanged(_ newOverlayRect: NSRect) {
            if isManipulatingSelectedTextAnnotation {
                return
            }
            updateSelectedAnnotationBounds(using: newOverlayRect)
        }

        private func handleMoveChanged(_ newOverlayRect: NSRect) {
            if isManipulatingSelectedTextAnnotation {
                return
            }
            updateSelectedAnnotationBounds(using: newOverlayRect)
        }

        private func handleMoveComplete(_ newOverlayRect: NSRect) {
            updateSelectedAnnotationBounds(using: newOverlayRect)
            endSelectedTextAnnotationManipulation()
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        private func handleResizeComplete(_ newOverlayRect: NSRect) {
            updateSelectedAnnotationBounds(using: newOverlayRect)
            endSelectedTextAnnotationManipulation()
            updateAnnotationBorder()
            if shouldRestoreTextEditingAfterResize, let textView = editingTextView {
                shouldRestoreTextEditingAfterResize = false
                pdfView?.window?.makeFirstResponder(textView)
            }
            parent.onDocumentChanged()
        }

        private func handleCursorDragChanged(start: NSPoint, current: NSPoint) {
            guard let overlay = overlay else { return }
            if cursorDragOriginOverlayRect == nil {
                cursorDragOriginOverlayRect = overlay.annotationBorderRect
            }
            guard let originRect = cursorDragOriginOverlayRect else { return }

            let startInOverlay = overlay.convert(start, from: cursorView)
            let currentInOverlay = overlay.convert(current, from: cursorView)
            let dx = currentInOverlay.x - startInOverlay.x
            let dy = currentInOverlay.y - startInOverlay.y
            let movedRect = originRect.offsetBy(dx: dx, dy: dy)
            overlay.updateAnnotationBorder(rect: movedRect)
            handleMoveChanged(movedRect)
        }

        private func handleCursorDragComplete(start: NSPoint, end: NSPoint) {
            defer { cursorDragOriginOverlayRect = nil }
            guard let overlay = overlay else { return }
            let startInOverlay = overlay.convert(start, from: cursorView)
            let endInOverlay = overlay.convert(end, from: cursorView)

            guard let originRect = cursorDragOriginOverlayRect else { return }
            let dx = endInOverlay.x - startInOverlay.x
            let dy = endInOverlay.y - startInOverlay.y
            let movedRect = originRect.offsetBy(dx: dx, dy: dy)
            overlay.updateAnnotationBorder(rect: movedRect)
            handleMoveComplete(movedRect)
        }

        private func handleRectDragComplete(start: NSPoint, end: NSPoint) {
            guard let pdfView = pdfView, let cursorView = cursorView else { return }
            dismissTextBoxEditing()

            let startView = cursorView.convert(start, to: pdfView)
            let endView = cursorView.convert(end, to: pdfView)

            guard let page = pdfView.page(for: startView, nearest: true) else { return }
            let startPage = pdfView.convert(startView, to: page)
            let endPage = pdfView.convert(endView, to: page)

            let bounds = CGRect(
                x: min(startPage.x, endPage.x), y: min(startPage.y, endPage.y),
                width: abs(endPage.x - startPage.x), height: abs(endPage.y - startPage.y)
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
                parent.selectedAnnotation = annotation
                updateAnnotationBorder()
                parent.onDocumentChanged()
                beginEditingTextBox(annotation, on: page)

            case .rectangle:
                let annotation = AnnotationService.createShapeAnnotation(
                    bounds: bounds, type: .square, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                finishCreatingDrawableAnnotation(annotation)
                parent.onDocumentChanged()

            case .oval:
                let annotation = AnnotationService.createShapeAnnotation(
                    bounds: bounds, type: .circle, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                finishCreatingDrawableAnnotation(annotation)
                parent.onDocumentChanged()

            case .arrow:
                let startPt = CGPoint(x: startPage.x, y: startPage.y)
                let endPt = CGPoint(x: endPage.x, y: endPage.y)
                let annotation = AnnotationService.createArrowAnnotation(
                    from: startPt, to: endPt, on: page,
                    color: currentColor, lineWidth: 2
                )
                recordForUndo(page: page, annotation: annotation)
                finishCreatingDrawableAnnotation(annotation)
                parent.onDocumentChanged()

            default:
                break
            }
        }

        private func handleInkDragComplete(viewPath: NSBezierPath) {
            guard let pdfView = pdfView, let cursorView = cursorView else { return }

            // Convert path from cursorView coordinates to page coordinates
            let midPoint = NSPoint(x: viewPath.bounds.midX, y: viewPath.bounds.midY)
            let midInPDF = cursorView.convert(midPoint, to: pdfView)
            guard let page = pdfView.page(for: midInPDF, nearest: true) else { return }

            // Build a new path in page coordinates
            let pagePath = NSBezierPath()
            let elements = viewPath.elementCount
            var points = [NSPoint](repeating: .zero, count: 3)
            for i in 0..<elements {
                let type = viewPath.element(at: i, associatedPoints: &points)
                let viewPt = cursorView.convert(points[0], to: pdfView)
                let pagePt = pdfView.convert(viewPt, to: page)
                switch type {
                case .moveTo: pagePath.move(to: pagePt)
                case .lineTo: pagePath.line(to: pagePt)
                default: pagePath.line(to: pagePt)
                }
            }

            let annotation = AnnotationService.createInkAnnotation(
                path: pagePath, on: page,
                color: currentColor, lineWidth: 2
            )
            recordForUndo(page: page, annotation: annotation)
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        private func finishCreatingDrawableAnnotation(_ annotation: PDFAnnotation) {
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            parent.currentTool = .pointer
            currentTool = .pointer
            updateCursor(for: .pointer)
        }

        /// Start inline editing of a Canope text box using an overlay editor
        func beginEditingTextBox(_ annotation: PDFAnnotation, on page: PDFPage) {
            guard let pdfView = pdfView, let documentView = pdfView.documentView else { return }
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
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()
            documentView.addSubview(editorView)
            pdfView.window?.recalculateKeyViewLoop()
            annotation.shouldDisplay = false
            syncCursorViewInteractivity()
            pdfView.setNeedsDisplay(pdfView.bounds)
            pdfView.window?.makeFirstResponder(textView)
        }

        // NSTextViewDelegate — commit on Escape or when focus lost
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape → commit and close
                commitTextBoxEditing()
                return true
            }
            return false
        }

        func textDidEndEditing(_ notification: Notification) {
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown,
               let overlay = overlay {
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

            syncCursorViewInteractivity()
            if wasFirstResponder {
                pdfView?.window?.makeFirstResponder(pdfView)
            }
            invalidatePDFRegion(for: annotation)
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        func dismissTextBoxEditing() {
            if editingTextView != nil {
                commitTextBoxEditing()
            }
        }

        func recordUserInteraction() {
            parent.onUserInteraction()
        }

        func handleInteractiveMouseDown(event: NSEvent, at locationInCursorView: NSPoint) -> CursorMouseDownAction {
            recordUserInteraction()
            guard currentTool == .textBox,
                  let cursorView = cursorView,
                  let pdfView = pdfView else { return .passThrough }

            let locationInPDFView = cursorView.convert(locationInCursorView, to: pdfView)
            guard let annotation = annotationAtPoint(locationInPDFView),
                  annotation.isTextBoxAnnotation,
                  let page = annotation.page else {
                return .passThrough
            }

            let wasSelected = parent.selectedAnnotation === annotation
            dismissTextBoxEditing()
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()

            if event.clickCount >= 2 {
                beginEditingTextBox(annotation, on: page)
                return .handled
            }

            if wasSelected, let overlay = overlay {
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
                if self.shouldHandleTextBoxMagnify(event) {
                    self.handleTextBoxMagnify(event)
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

            isApplyingTextMarkup = true

            DispatchQueue.main.async { [weak self] in
                self?.applyTextMarkup(using: selection)
            }
        }

        private func shouldHandleTextBoxMagnify(_ event: NSEvent) -> Bool {
            guard let pdfView = pdfView,
                  event.window === pdfView.window else { return false }

            if editingTextView != nil {
                return true
            }

            if parent.selectedAnnotation?.isTextBoxAnnotation == true {
                return true
            }

            return currentTool == .textBox
        }

        private func handleTextBoxMagnify(_ event: NSEvent) {
            guard let pdfView = pdfView else { return }

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
            updateAnnotationBorder()
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
            overlay.allowsInteriorDragging = editingAnnotation == nil && annotation.isTextBoxAnnotation
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
            overlay.updateAnnotationBorder(rect: overlayRect, isEditing: editingAnnotation === annotation)
        }

        @objc func handleViewChanged(_ notification: Notification) {
            cursorView?.previewScaleFactor = pdfView?.scaleFactor ?? 1.0
            cursorView?.needsDisplay = true
            if let annotation = editingAnnotation, let page = annotation.page {
                syncEditingViewFrame(with: annotation, on: page)
            }
            updateAnnotationBorder()
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
            dismissTextBoxEditing()
            parent.selectedAnnotation = nil
            overlay?.clear()
        }

        func clearCurrentTextSelection() {
            clearTextSelectionState()
        }

        private func updateSelectionDismissInterception() {
            // Keep API surface stable for callers; selection dismissal is now handled
            // by clearing native PDFView selection on mouseDown, following Skim's pattern.
        }

        func handlePreMouseDown(event: NSEvent, at locationInView: NSPoint, in pdfView: InteractivePDFView) -> Bool {
            recordUserInteraction()
            if editingTextView != nil {
                commitTextBoxEditing()
                pdfView.window?.makeFirstResponder(pdfView)

                if let annotation = annotationAtPoint(locationInView) {
                    parent.selectedAnnotation = annotation
                    updateAnnotationBorder()

                    if currentTool == .textBox,
                       annotation.isTextBoxAnnotation,
                       event.clickCount >= 2,
                       let page = annotation.page {
                        beginEditingTextBox(annotation, on: page)
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
                        beginEditingTextBox(annotation, on: page)
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
                guard let page = pdfView.page(for: locationInView, nearest: true) else { return }
                let pagePoint = pdfView.convert(locationInView, to: page)
                let annotation = AnnotationService.createNoteAnnotation(
                    at: pagePoint, on: page, text: "", color: currentColor
                )
                recordForUndo(page: page, annotation: annotation)
                parent.selectedAnnotation = annotation
                parent.onDocumentChanged()
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
            if isApplyingTextMarkup {
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

        func applyTextMarkup(using selection: PDFSelection) {
            let annotationType: PDFAnnotationSubtype
            switch currentTool {
            case .highlight: annotationType = .highlight
            case .underline: annotationType = .underline
            case .strikethrough: annotationType = .strikeOut
            default:
                isApplyingTextMarkup = false
                return
            }

            guard let pdfView = pdfView else {
                isApplyingTextMarkup = false
                return
            }

            let annotations = AnnotationService.createMarkupAnnotation(
                selection: selection,
                type: annotationType,
                color: currentColor,
                on: pdfView
            )

            // Record for undo
            for (page, annotation) in annotations {
                recordForUndo(page: page, annotation: annotation)
            }

            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true
            pdfView.documentView?.displayIfNeeded()
            pdfView.displayIfNeeded()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearTextSelectionState()
                self.isApplyingTextMarkup = false
                pdfView.setNeedsDisplay(pdfView.bounds)
                self.parent.onDocumentChanged()
            }
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
            beginEditingTextBox(annotation, on: page)
        }

        // MARK: - Right Click

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            recordUserInteraction()
            guard let pdfView = pdfView else { return }
            let locationInView = gesture.location(in: pdfView)
            guard let annotation = annotationAtPoint(locationInView) else { return }
            parent.selectedAnnotation = annotation
            updateAnnotationBorder()

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

            // Text-box-specific formatting options
            if annotation.isTextBoxAnnotation {
                menu.addItem(NSMenuItem.separator())

                // Font size submenu
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

                // Text color submenu
                let textColorMenu = NSMenu()
                for (name, nsColor) in [("Noir", NSColor.black), ("Blanc", NSColor.white),
                    ("Rouge", NSColor.systemRed), ("Bleu", NSColor.systemBlue),
                    ("Vert", NSColor.systemGreen), ("Orange", NSColor.systemOrange)] {
                    let item = NSMenuItem(title: name, action: #selector(changeFontColor(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = nsColor
                    let img = NSImage(size: NSSize(width: 12, height: 12))
                    img.lockFocus()
                    nsColor.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
                    img.unlockFocus()
                    item.image = img
                    textColorMenu.addItem(item)
                }
                let textColorItem = NSMenuItem(title: "Couleur du texte", action: nil, keyEquivalent: "")
                textColorItem.submenu = textColorMenu
                menu.addItem(textColorItem)

                // Alignment submenu
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
                let alignItem = NSMenuItem(title: "Alignement", action: nil, keyEquivalent: "")
                alignItem.submenu = alignMenu
                menu.addItem(alignItem)
            }

            menu.addItem(NSMenuItem.separator())

            let deleteItem = NSMenuItem(title: "Supprimer", action: #selector(deleteSelectedAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = annotation
            menu.addItem(deleteItem)

            menu.popUp(positioning: nil, at: gesture.location(in: pdfView), in: pdfView)
        }

        @objc func changeAnnotationColor(_ sender: NSMenuItem) {
            guard let color = sender.representedObject as? NSColor,
                  let annotation = parent.selectedAnnotation else { return }
            AnnotationService.applyColor(color, to: annotation)
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(annotation.bounds)
            parent.onDocumentChanged()
        }

        @objc func changeFontSize(_ sender: NSMenuItem) {
            guard let annotation = parent.selectedAnnotation, annotation.isTextBoxAnnotation else { return }
            let size = CGFloat(sender.tag)
            annotation.font = NSFont.systemFont(ofSize: size)
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func changeFontColor(_ sender: NSMenuItem) {
            guard let color = sender.representedObject as? NSColor,
                  let annotation = parent.selectedAnnotation, annotation.isTextBoxAnnotation else { return }
            annotation.fontColor = color
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func changeAlignment(_ sender: NSMenuItem) {
            guard let annotation = parent.selectedAnnotation, annotation.isTextBoxAnnotation else { return }
            annotation.alignment = NSTextAlignment(rawValue: sender.tag) ?? .left
            if editingAnnotation === annotation {
                syncEditingViewAppearance()
            }
            pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
            parent.onDocumentChanged()
        }

        @objc func editAnnotationNote(_ sender: NSMenuItem) {
            guard let annotation = sender.representedObject as? PDFAnnotation else { return }
            parent.selectedAnnotation = annotation
            parent.onDocumentChanged()
        }

        @objc func deleteSelectedAnnotation(_ sender: NSMenuItem) {
            guard let annotation = sender.representedObject as? PDFAnnotation,
                  let page = annotation.page else { return }
            page.removeAnnotation(annotation)
            parent.selectedAnnotation = nil
            updateAnnotationBorder()
            parent.onDocumentChanged()
        }

        // MARK: - Gesture Delegate

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            if event.type == .rightMouseDown { return true }
            return currentTool == .pointer || currentTool == .note || currentTool == .textBox
        }
    }
}

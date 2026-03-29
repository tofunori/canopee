import SwiftUI
import AppKit

struct LaTeXTextEditor: NSViewRepresentable {
    @Binding var text: String
    let errorLines: Set<Int>
    var fontSize: CGFloat = 14
    var theme: (name: String, bg: NSColor, fg: NSColor, comment: NSColor, command: NSColor, math: NSColor, env: NSColor, brace: NSColor)?
    let onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Force light appearance so the text system doesn't dim our custom dark-theme colors
        scrollView.appearance = NSAppearance(named: .aqua)
        scrollView.contentView.appearance = scrollView.appearance

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        textView.appearance = scrollView.appearance
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1)
        textView.textColor = NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1)
        textView.insertionPointColor = NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView

        // Set initial text
        textView.string = text
        context.coordinator.applyTheme(to: textView)
        context.coordinator.applyHighlighting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let textChanged = textView.string != text
        let themeChanged = context.coordinator.theme?.name != theme?.name
        let fontChanged = context.coordinator.fontSize != fontSize

        if textChanged {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
        }

        context.coordinator.fontSize = fontSize
        if let theme {
            context.coordinator.theme = theme
        }
        context.coordinator.errorLines = errorLines
        context.coordinator.applyTheme(to: textView)

        if textChanged || themeChanged || fontChanged {
            context.coordinator.applyHighlighting()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: LaTeXTextEditor
        weak var textView: NSTextView?
        var errorLines: Set<Int> = []
        var fontSize: CGFloat = 14
        var theme: (name: String, bg: NSColor, fg: NSColor, comment: NSColor, command: NSColor, math: NSColor, env: NSColor, brace: NSColor)?
        private var isUpdating = false

        init(parent: LaTeXTextEditor) {
            self.parent = parent
        }

        @MainActor
        func applyTheme(to textView: NSTextView) {
            let t = theme
            let fg = t?.fg ?? NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1)
            let bg = t?.bg ?? NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1)
            let cursor = t?.env ?? NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1)
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

            textView.font = font
            textView.backgroundColor = bg
            textView.textColor = fg
            textView.insertionPointColor = cursor
            textView.selectedTextAttributes = [
                .backgroundColor: cursor.withAlphaComponent(0.35),
                .foregroundColor: NSColor.white,
            ]
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: fg,
            ]
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView, !isUpdating else { return }
            parent.text = textView.string
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
            }
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

            storage.endEditing()
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: fg,
            ]
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
    }
}

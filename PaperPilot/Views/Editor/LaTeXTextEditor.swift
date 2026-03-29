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

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1) // Kaku dark bg
        textView.textColor = NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1)
        textView.insertionPointColor = NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1) // Purple cursor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
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
        context.coordinator.applyHighlighting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
        }
        // Update font size
        context.coordinator.fontSize = fontSize
        // Update theme
        if let theme {
            context.coordinator.theme = theme
            textView.backgroundColor = theme.bg
            textView.insertionPointColor = theme.env
        }
        context.coordinator.errorLines = errorLines
        context.coordinator.applyHighlighting()
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
                try? content.write(toFile: "/tmp/canopee_selection.txt", atomically: true, encoding: .utf8)
            }
            // Don't clear — let the PDF reader or editor that was last used keep its selection
        }

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

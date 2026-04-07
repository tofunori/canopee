import AppKit
import SwiftUI

@MainActor
struct MarkdownLiveEditor: NSViewRepresentable {
    enum Command: String {
        case heading
        case list
        case blockquote
        case codeBlock
    }

    let fileURL: URL
    @Binding var text: String
    var fontSize: CGFloat = 14
    var theme: MarkdownTheme = .dark
    var displayMode: MarkdownEditorDisplayMode = .livePreview
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
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = CodeTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        textView.appearance = NSAppearance(named: .aqua)
        textView.backgroundColor = theme.backgroundColor
        textView.textColor = theme.primaryTextColor
        textView.insertionPointColor = theme.accentColor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.accentColor.withAlphaComponent(0.22),
            .foregroundColor: theme.primaryTextColor,
        ]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.gutterWidth = 42
        textView.textContainerInset = NSSize(width: textView.gutterWidth + 12, height: 14)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textContainer.lineBreakMode = .byWordWrapping
        textView.delegate = context.coordinator
        textView.string = text

        context.coordinator.parent = self
        context.coordinator.textView = textView
        context.coordinator.installCommandObserver()
        context.coordinator.applyTheme()
        context.coordinator.applyHighlighting()
        scrollView.documentView = textView
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

        context.coordinator.installCommandObserver()
        context.coordinator.applyTheme()
        context.coordinator.applyHighlighting()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeCommandObserver()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownLiveEditor
        fileprivate weak var textView: CodeTextView?
        private var isUpdating = false
        private var commandObserver: NSObjectProtocol?
        private var observedFilePath: String?

        init(parent: MarkdownLiveEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.text = textView.string
            parent.onTextChange()
            applyHighlighting()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard parent.displayMode == .livePreview else { return }
            applyHighlighting()
        }

        func installCommandObserver() {
            let filePath = parent.fileURL.path
            guard observedFilePath != filePath else { return }
            removeCommandObserver()
            observedFilePath = filePath
            commandObserver = NotificationCenter.default.addObserver(
                forName: .markdownEditorCommand,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let targetPath = notification.userInfo?["filePath"] as? String,
                      targetPath == filePath,
                      let rawValue = notification.userInfo?["command"] as? String,
                      let command = Command(rawValue: rawValue) else { return }
                self.perform(command: command)
            }
        }

        func removeCommandObserver() {
            if let commandObserver {
                NotificationCenter.default.removeObserver(commandObserver)
                self.commandObserver = nil
            }
            observedFilePath = nil
        }

        func applyTheme() {
            guard let textView else { return }
            textView.backgroundColor = parent.theme.backgroundColor
            textView.textColor = parent.theme.primaryTextColor
            textView.insertionPointColor = parent.theme.accentColor
            textView.selectedTextAttributes = [
                .backgroundColor: parent.theme.accentColor.withAlphaComponent(0.22),
                .foregroundColor: parent.theme.primaryTextColor,
            ]
            textView.gutterBackgroundColor = parent.theme.backgroundColor.blended(withFraction: 0.12, of: .black) ?? parent.theme.backgroundColor
            textView.lineNumberColor = parent.theme.secondaryTextColor.withAlphaComponent(0.52)
            textView.dividerColor = parent.theme.codeBorderColor
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            isUpdating = true
            MarkdownFormatter.styleSource(
                text: textView.string,
                storage: storage,
                fontSize: parent.fontSize,
                theme: parent.theme,
                displayMode: parent.displayMode,
                selectedRange: textView.selectedRange()
            )
            isUpdating = false
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: parent.theme.primaryTextColor,
            ]
        }

        private func perform(command: Command) {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()

            switch command {
            case .codeBlock:
                applyCodeBlock(in: textView, selectedRange: selectedRange)
            case .heading:
                prefixSelectedLines(in: textView, selectedRange: selectedRange, prefix: "# ")
            case .list:
                prefixSelectedLines(in: textView, selectedRange: selectedRange, prefix: "- ")
            case .blockquote:
                prefixSelectedLines(in: textView, selectedRange: selectedRange, prefix: "> ")
            }
        }

        private func applyCodeBlock(in textView: NSTextView, selectedRange: NSRange) {
            let source = textView.string as NSString
            if selectedRange.length > 0 {
                let selected = source.substring(with: selectedRange)
                let wrapped = "```\n\(selected)\n```"
                replaceText(in: textView, range: selectedRange, with: wrapped, selection: NSRange(location: selectedRange.location + 4, length: selectedRange.length))
            } else {
                let snippet = "```\n\n```"
                replaceText(in: textView, range: selectedRange, with: snippet, selection: NSRange(location: selectedRange.location + 4, length: 0))
            }
        }

        private func prefixSelectedLines(in textView: NSTextView, selectedRange: NSRange, prefix: String) {
            let source = textView.string as NSString
            let lineRange = source.lineRange(for: selectedRange)
            let block = source.substring(with: lineRange)
            let transformed = block
                .components(separatedBy: "\n")
                .map { line -> String in
                    guard !line.isEmpty else { return line }
                    if line.hasPrefix(prefix) {
                        return String(line.dropFirst(prefix.count))
                    }
                    if prefix == "# ", line.hasPrefix("#") {
                        return line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "# ", options: .regularExpression)
                    }
                    return prefix + line
                }
                .joined(separator: "\n")
            replaceText(in: textView, range: lineRange, with: transformed, selection: NSRange(location: lineRange.location, length: (transformed as NSString).length))
        }

        private func replaceText(in textView: NSTextView, range: NSRange, with replacement: String, selection: NSRange) {
            guard let storage = textView.textStorage else { return }
            storage.replaceCharacters(in: range, with: replacement)
            let fullText = storage.string
            parent.text = fullText
            textView.setSelectedRange(selection)
            parent.onTextChange()
            applyHighlighting()
        }
    }
}

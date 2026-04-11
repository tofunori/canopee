import AppKit
import SwiftUI

enum CodexAttachSubmenu: Equatable {
    case speed
    case plugins
}

struct ChatTranscriptView<RowContent: View, ThinkingContent: View>: View {
    let messages: [ChatMessage]
    let isProcessing: Bool
    let usesCodexVisualStyle: Bool
    let resetID: UUID
    let rowContent: (ChatMessage) -> RowContent
    let thinkingContent: () -> ThinkingContent

    @State private var shouldAutoScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: usesCodexVisualStyle ? 8 : 4) {
                    ForEach(messages) { message in
                        rowContent(message)
                    }

                    if isProcessing,
                       messages.last?.role == .user || messages.last?.isStreaming == false
                    {
                        thinkingContent()
                            .id("thinking")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, usesCodexVisualStyle ? 16 : 12)
            }
            .id(resetID)
            .onAppear {
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: messages.count) { _, _ in
                if shouldAutoScroll {
                    scrollToBottom(using: proxy, animated: true)
                }
            }
            .onChange(of: isProcessing) { _, newValue in
                if newValue { shouldAutoScroll = true }
            }
            .onChange(of: resetID) { _, _ in
                scrollToBottom(using: proxy, animated: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
    }
}

struct CodexAttachPopoverView: View {
    let supportsIDEContextToggle: Bool
    let supportsPlanMode: Bool
    let includeIDEContextBinding: Binding<Bool>
    let planModeBinding: Binding<Bool>
    let codexInstalledPlugins: [String]
    @Binding var selectedSubmenu: CodexAttachSubmenu?
    @Binding var selectedPlugins: Set<String>
    let openAttachmentPicker: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            primaryPanel

            if let submenu = selectedSubmenu {
                secondaryPanel(for: submenu)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(6)
        .background(AppChromePalette.codexCanvas)
        .onDisappear {
            selectedSubmenu = nil
        }
    }

    private var primaryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow(
                title: AppStrings.addPhotosAndFiles,
                systemName: "paperclip",
                isSelected: false,
                showsChevron: false
            ) {
                selectedSubmenu = nil
                openAttachmentPicker()
            }

            divider

            if supportsIDEContextToggle {
                toggleRow(
                    title: AppStrings.includeIDEContext,
                    systemName: "sparkles",
                    isOn: includeIDEContextBinding
                )
            }

            if supportsPlanMode {
                toggleRow(
                    title: AppStrings.planMode,
                    systemName: "checklist",
                    isOn: planModeBinding
                )
            }

            divider

            actionRow(
                title: "Speed",
                systemName: "bolt.fill",
                isSelected: selectedSubmenu == .speed,
                showsChevron: true
            ) {
                selectedSubmenu = .speed
            }

            divider

            actionRow(
                title: "Plugins",
                systemName: "circle.grid.2x2",
                isSelected: selectedSubmenu == .plugins,
                showsChevron: true
            ) {
                selectedSubmenu = .plugins
            }
        }
        .padding(5)
        .frame(width: 196, alignment: .leading)
        .background(panelBackground)
    }

    @ViewBuilder
    private func secondaryPanel(for submenu: CodexAttachSubmenu) -> some View {
        switch submenu {
        case .speed:
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Speed")

                choiceRow(title: "Standard", isSelected: true, isEnabled: true) {}
                choiceRow(title: "Fast", isSelected: false, isEnabled: false) {}

                Text(AppStrings.fastModeUnavailable)
                    .font(.system(size: 9.5))
                    .foregroundStyle(AppChromePalette.codexMutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
            .padding(.vertical, 6)
            .frame(width: 156, alignment: .leading)
            .background(panelBackground)

        case .plugins:
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("\(codexInstalledPlugins.count) installed plugins")

                ForEach(codexInstalledPlugins, id: \.self) { plugin in
                    choiceRow(
                        title: plugin,
                        isSelected: selectedPlugins.contains(plugin),
                        isEnabled: true
                    ) {
                        togglePlugin(plugin)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 230, alignment: .leading)
            .background(panelBackground)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(AppChromePalette.codexPromptShell)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(AppChromePalette.codexPromptStroke, lineWidth: 1)
            )
    }

    private var divider: some View {
        Rectangle()
            .fill(AppChromePalette.codexPromptDivider.opacity(0.75))
            .frame(height: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.bottom, 3)
    }

    private func actionRow(
        title: String,
        systemName: String,
        isSelected: Bool,
        showsChevron: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppChromePalette.codexMutedText)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppChromePalette.codexMutedText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.88) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(
        title: String,
        systemName: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppChromePalette.codexMutedText)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private func choiceRow(
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : Color.clear)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isEnabled ? .primary : AppChromePalette.codexMutedText)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func togglePlugin(_ plugin: String) {
        if selectedPlugins.contains(plugin) {
            selectedPlugins.remove(plugin)
        } else {
            selectedPlugins.insert(plugin)
        }
    }
}

struct LocalCachedImagePreview: View {
    let path: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
        }
        .task(id: path) {
            let url = URL(fileURLWithPath: path)
            image = await ImageArtifactRepository.shared.loadImage(
                forKey: "chat-image:\(path)",
                from: url
            )
        }
    }
}

@MainActor
struct CodexPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let onSubmit: () -> Void
    let onTextChange: () -> Void

    static let placeholderTopInset: CGFloat = 2
    static let placeholderLeadingInset: CGFloat = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = CodexPromptTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .systemBlue
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: Self.placeholderLeadingInset, height: Self.placeholderTopInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textContainer.lineBreakMode = .byWordWrapping
        textView.delegate = context.coordinator
        textView.string = text
        textView.onSubmit = onSubmit
        textView.onFocusChange = { focused in
            if context.coordinator.isFocused != focused {
                context.coordinator.isFocused = focused
                DispatchQueue.main.async {
                    self.isFocused = focused
                }
            }
        }

        context.coordinator.textView = textView
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodexPromptTextView else { return }

        context.coordinator.parent = self
        context.coordinator.textView = textView
        textView.onSubmit = onSubmit
        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.maxSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let maxLength = (text as NSString).length
            let clampedLocation = min(selectedRange.location, maxLength)
            let clampedLength = min(selectedRange.length, max(0, maxLength - clampedLocation))
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexPromptEditor
        weak var textView: CodexPromptTextView?
        var isFocused = false
        private var isUpdating = false

        init(parent: CodexPromptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.text = textView.string
            parent.onTextChange()
        }
    }
}

final class CodexPromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocusChange?(true)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFocusChange?(false)
        }
        return didResignFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

struct ToolCardDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: configuration.isExpanded)
                        .frame(width: 12)

                    configuration.label
                }
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppChromePalette.surfaceSubbar.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
        )
    }
}

import SwiftUI

// MARK: - AI Chat View (Native headless chat panel)

struct AIChatView<Provider: AIHeadlessProvider>: View {
    @ObservedObject var provider: Provider
    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool
    @State private var selectedSlashIndex: Int?
    @State private var showSessionPicker = false
    @State private var cachedSelection: SelectionInfo?
    @State private var scrollMonitor: Any?
    @State private var editingMessageID: UUID?
    @State private var editingText = ""
    @State private var selectionTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()
            messageList
            Divider()
            inputBar
        }
        .background(AppChromePalette.surfaceBar)
        .onAppear {
            if !provider.isConnected {
                provider.start()
            }
            cachedSelection = readSelectionFromDisk()
            selectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    cachedSelection = readSelectionFromDisk()
                }
            }
            // Disable auto-scroll when user scrolls up
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                if event.scrollingDeltaY > 0 {
                    shouldAutoScroll = false
                }
                return event
            }
        }
        .onDisappear {
            selectionTimer?.invalidate()
            selectionTimer = nil
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
        // Cmd+N handled via menu item or button — SwiftUI doesn't support view-level Cmd shortcuts well
        .sheet(isPresented: $showSessionPicker) {
            SessionPickerView { sessionId in
                showSessionPicker = false
                if let p = provider as? ClaudeHeadlessProvider {
                    p.resumeSession(id: sessionId)
                }
            } onCancel: {
                showSessionPicker = false
            }
        }
    }

    // MARK: - Session Header

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.providerIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if let claudeProvider = provider as? ClaudeHeadlessProvider {
                // Model picker
                Menu {
                    ForEach(ClaudeHeadlessProvider.availableModels, id: \.self) { model in
                        Button {
                            claudeProvider.selectedModel = model
                        } label: {
                            HStack {
                                Text(model)
                                if claudeProvider.selectedModel == model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(claudeProvider.selectedModel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))

                // Effort picker
                Menu {
                    ForEach(ClaudeHeadlessProvider.availableEfforts, id: \.self) { effort in
                        Button {
                            claudeProvider.selectedEffort = effort
                        } label: {
                            HStack {
                                Text(effort)
                                if claudeProvider.selectedEffort == effort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(claudeProvider.selectedEffort)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if provider.session.turns > 0 {
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("\(provider.session.turns) turns")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(String(format: "$%.2f", provider.session.costUSD))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if provider.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            Button {
                provider.stop()
            } label: {
                Image(systemName: provider.isProcessing ? "stop.circle.fill" : "stop.fill")
                    .font(.system(size: provider.isProcessing ? 14 : 9))
                    .foregroundStyle(provider.isProcessing ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(provider.isProcessing ? 1 : 0.3)
            .disabled(!provider.isProcessing)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(AppChromePalette.surfaceSubbar)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(provider.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }

                    // Thinking indicator while waiting for response
                    if provider.isProcessing,
                       provider.messages.last?.role == .user || provider.messages.last?.isStreaming == false
                    {
                        thinkingIndicator
                            .id("thinking")
                    }

                    // Invisible anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: provider.messages.count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
            .onChange(of: provider.isProcessing) {
                if provider.isProcessing { shouldAutoScroll = true }
            }
            .onChange(of: provider.messages.last?.content) {
                // Auto-scroll only if user hasn't scrolled away
                if shouldAutoScroll {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Message Rows

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(message)
        case .assistant:
            assistantRow(message)
        case .toolUse:
            toolCard(message)
        case .toolResult:
            toolResultCard(message)
        case .system:
            systemRow(message)
        }
    }

    private func userBubble(_ message: ChatMessage) -> some View {
        HStack {
            Spacer(minLength: 60)
            if editingMessageID == message.id {
                // Inline editor
                VStack(alignment: .trailing, spacing: 6) {
                    TextField("", text: $editingText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.accentColor.opacity(0.3))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        )
                    HStack(spacing: 8) {
                        Button("Annuler") { editingMessageID = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Renvoyer") {
                            let newText = editingText
                            editingMessageID = nil
                            if let p = provider as? ClaudeHeadlessProvider {
                                p.editAndResend(newText: newText)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 11))
                    }
                }
            } else {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.85))
                    )
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copier") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        }
                        Button("Éditer & renvoyer") {
                            editingMessageID = message.id
                            editingText = message.content
                        }
                    }
            }
        }
        .padding(.vertical, 2)
    }

    private var thinkingIndicator: some View {
        SpinnerVerbView()
    }

    private func assistantRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 0) {
                if message.isStreaming {
                    Text(message.content.contains("$") ? LaTeXUnicode.convert(message.content) : message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    streamingCursor
                } else {
                    MarkdownBlockView(text: message.content)
                }
            }

            Spacer(minLength: 20)
        }
        .padding(.vertical, 4)
    }

    private var streamingCursor: some View {
        Text("▊")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.orange.opacity(0.8))
            .blinking()
    }

    private func toolCard(_ message: ChatMessage) -> some View {
        let toolName = message.toolName ?? "Tool"
        let iconName = ClaudeHeadlessProvider.toolIcon(for: toolName)
        let isCollapsed = message.isCollapsed

        return DisclosureGroup(isExpanded: bindingForCollapsed(message)) {
            VStack(alignment: .leading, spacing: 6) {
                if let input = message.toolInput, !input.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                    }
                    .frame(maxHeight: 120)
                }

                if let output = message.toolOutput, !output.isEmpty {
                    Divider()
                    ScrollView {
                        Text(output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(toolAccentColor(toolName))
                    .frame(width: 14)

                Text(toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if message.toolOutput != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green.opacity(0.7))
                }
            }
        }
        .disclosureGroupStyle(ToolCardDisclosureStyle())
        .padding(.leading, 28) // Align with assistant text
        .padding(.vertical, 1)
    }

    private func toolResultCard(_ message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(message.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .padding(.leading, 28)
        .padding(.vertical, 1)
    }

    private func systemRow(_ message: ChatMessage) -> some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(AppChromePalette.surfaceSubbar)
                )
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Selection context indicator
            if let sel = currentSelection {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)

                    Text(sel.fileName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("·")
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("\(sel.lineCount) ligne\(sel.lineCount > 1 ? "s" : "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(AppChromePalette.surfaceSubbar.opacity(0.6))

                Divider()
            }

            // Slash command suggestions
            if showSlashSuggestions, !filteredSlashCommands.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredSlashCommands, id: \.self) { cmd in
                            Button {
                                inputText = "/\(cmd) "
                                selectedSlashIndex = nil
                            } label: {
                                HStack(spacing: 6) {
                                    Text("/")
                                        .foregroundStyle(.orange)
                                    Text(cmd)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedSlashIndex == filteredSlashCommands.firstIndex(of: cmd)
                                        ? AppChromePalette.tabSelectedFill
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(AppChromePalette.surfaceSubbar)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                TextField("Message à \(provider.providerName)…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onSubmit {
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
                            send()
                        }
                    }
                    .onChange(of: inputText) {
                        updateSlashSuggestions()
                    }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AppChromePalette.surfaceSubbar)
    }

    // MARK: - Slash Commands

    private var slashCommands: [String] { [
        "new", "resume", "continue",
        "compact", "context", "cost", "help", "init", "review",
        "commit", "simplify", "research", "plan-review", "diff-review",
        "project-recap", "visual-explainer", "generate-slides",
        "pdf-selection", "pdf-annotations", "style-qc", "revision",
    ] }

    private var showSlashSuggestions: Bool {
        inputText.hasPrefix("/") && inputText.count >= 1
    }

    private var filteredSlashCommands: [String] {
        let query = String(inputText.dropFirst()).lowercased()
        if query.isEmpty { return slashCommands }
        return slashCommands.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func updateSlashSuggestions() {
        selectedSlashIndex = nil
    }

    // MARK: - Selection State

    private struct SelectionInfo {
        let fileName: String
        let lineCount: Int
    }

    private var currentSelection: SelectionInfo? { cachedSelection }

    private func readSelectionFromDisk() -> SelectionInfo? {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let filePath = json["filePath"] as? String ?? ""
        let fileName = (filePath as NSString).lastPathComponent
        let lines = text.components(separatedBy: .newlines).count

        return SelectionInfo(fileName: fileName, lineCount: lines)
    }

    // MARK: - Helpers

    @State private var shouldAutoScroll = false

    private func startAutoScroll(proxy: ScrollViewProxy) {
        shouldAutoScroll = true
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !provider.isProcessing
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !provider.isProcessing else { return }
        inputText = ""

        // /new starts a fresh conversation
        if text == "/new" {
            if let p = provider as? ClaudeHeadlessProvider {
                p.newSession()
            }
            return
        }

        // Handle /continue locally
        if text == "/continue" {
            if let p = provider as? ClaudeHeadlessProvider {
                p.resumeLastSession()
            }
            return
        }

        // /resume shows the session picker
        if text == "/resume" {
            showSessionPicker = true
            return
        }

        provider.sendMessage(text)
    }

    private func markdownContent(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
    }

    private func bindingForCollapsed(_ message: ChatMessage) -> Binding<Bool> {
        Binding(
            get: { !message.isCollapsed },
            set: { expanded in
                if let idx = provider.messages.firstIndex(where: { $0.id == message.id }) {
                    provider.messages[idx].isCollapsed = !expanded
                }
            }
        )
    }

    private func toolAccentColor(_ name: String) -> Color {
        switch name {
        case "Read", "Glob", "Grep": return .blue
        case "Edit", "Write": return .orange
        case "Bash": return .green
        case "WebSearch", "WebFetch": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Tool Card Disclosure Style

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

// MARK: - Blinking Cursor Modifier

extension View {
    func blinking(duration: Double = 0.6) -> some View {
        modifier(BlinkingModifier(duration: duration))
    }
}

struct BlinkingModifier: ViewModifier {
    let duration: Double
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever()) {
                    isVisible = false
                }
            }
    }
}

// MARK: - Thinking Dots Animation

private let spinnerVerbs = [
    "Thinking", "Noodling", "Pondering", "Musing", "Mulling",
    "Ruminating", "Cogitating", "Contemplating", "Orchestrating",
    "Percolating", "Brewing", "Simmering", "Cooking", "Marinating",
    "Fermenting", "Incubating", "Hatching", "Crafting", "Tinkering",
    "Meandering", "Vibing", "Clauding", "Synthesizing", "Harmonizing",
    "Concocting", "Crystallizing", "Churning", "Forging",
    "Crunching", "Gallivanting", "Spelunking", "Perambulating",
    "Lollygagging", "Shenaniganing", "Whatchamacalliting",
    "Combobulating", "Discombobulating", "Recombobulating",
    "Flibbertigibbeting", "Razzmatazzing", "Tomfoolering",
    "Boondoggling", "Canoodling", "Befuddling", "Doodling",
    "Moonwalking", "Philosophising", "Puttering", "Puzzling",
]

struct SpinnerVerbView: View {
    @State private var verb = spinnerVerbs.randomElement() ?? "Thinking"
    @State private var timer: Timer?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .padding(.top, 2)

            HStack(spacing: 6) {
                ThinkingDots()
                Text("\(verb)…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.top, 5)

            Spacer()
        }
        .padding(.vertical, 4)
        .transition(.opacity)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    verb = spinnerVerbs.randomElement() ?? "Thinking"
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - LaTeX to Unicode Converter

enum LaTeXUnicode {
    private static let greekLetters: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
        "\\epsilon": "ε", "\\zeta": "ζ", "\\eta": "η", "\\theta": "θ",
        "\\iota": "ι", "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ",
        "\\nu": "ν", "\\xi": "ξ", "\\pi": "π", "\\rho": "ρ",
        "\\sigma": "σ", "\\tau": "τ", "\\upsilon": "υ", "\\phi": "φ",
        "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω",
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
        "\\Sigma": "Σ", "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
        "\\infty": "∞", "\\partial": "∂", "\\nabla": "∇",
        "\\pm": "±", "\\times": "×", "\\div": "÷", "\\cdot": "·",
        "\\leq": "≤", "\\geq": "≥", "\\neq": "≠", "\\approx": "≈",
        "\\sim": "∼", "\\propto": "∝", "\\sum": "Σ", "\\prod": "Π",
        "\\sqrt": "√", "\\degree": "°", "\\circ": "°",
    ]

    private static let subscriptDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
    ]

    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "-": "⁻", "+": "⁺", "n": "ⁿ",
    ]

    static func convert(_ text: String) -> String {
        var result = text

        // Remove $ delimiters
        result = result.replacingOccurrences(of: "$", with: "")

        // Greek letters and symbols (longer names first to avoid partial matches)
        let sorted = greekLetters.sorted { $0.key.count > $1.key.count }
        for (latex, unicode) in sorted {
            result = result.replacingOccurrences(of: latex, with: unicode)
        }

        // Subscripts: _{...} or _x
        result = replacePattern(in: result, pattern: #"_\{([^}]+)\}"#) { match in
            String(match.map { subscriptDigits[$0] ?? $0 })
        }
        result = replacePattern(in: result, pattern: #"_([0-9a-z])"#) { match in
            String(match.map { subscriptDigits[$0] ?? $0 })
        }

        // Superscripts: ^{...} or ^x
        result = replacePattern(in: result, pattern: #"\^\{([^}]+)\}"#) { match in
            String(match.map { superscriptDigits[$0] ?? $0 })
        }
        result = replacePattern(in: result, pattern: #"\^([0-9n+-])"#) { match in
            String(match.map { superscriptDigits[$0] ?? $0 })
        }

        // \text{...} → just the text
        result = replacePattern(in: result, pattern: #"\\text\{([^}]+)\}"#) { $0 }
        // \mathrm{...} → just the text
        result = replacePattern(in: result, pattern: #"\\mathrm\{([^}]+)\}"#) { $0 }
        // \frac{a}{b} → a/b
        result = result.replacingOccurrences(
            of: #"\\frac\{([^}]+)\}\{([^}]+)\}"#,
            with: "$1/$2",
            options: .regularExpression
        )

        // Clean up remaining backslash commands
        result = result.replacingOccurrences(of: "\\,", with: " ")
        result = result.replacingOccurrences(of: "\\;", with: " ")
        result = result.replacingOccurrences(of: "\\!", with: "")
        result = result.replacingOccurrences(of: "\\quad", with: "  ")

        return result
    }

    private static func replacePattern(in text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: result)
            else { continue }
            let captured = String(result[captureRange])
            result.replaceSubrange(fullRange, with: transform(captured))
        }
        return result
    }
}

// MARK: - Markdown Block Renderer

struct MarkdownBlockView: View {
    let text: String
    @State private var blocks: [Block] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group consecutive text blocks into one selectable Text view
            let groups = Self.groupBlocks(blocks)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case .textRun(let segments):
                    Text(Self.buildAttributedString(segments: segments, inlineMarkdown: inlineMarkdown))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                case .special(let block):
                    blockView(block)
                }
            }
        }
        .onAppear {
            if blocks.isEmpty {
                blocks = Self.parseBlocks(text)
            }
        }
    }

    private enum BlockGroup {
        case textRun(segments: [Block])  // paragraphs, headings, insights merged into one Text
        case special(Block)              // code, table, rule — need custom rendering
    }

    private static func groupBlocks(_ blocks: [Block]) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        var currentRun: [Block] = []

        func flushRun() {
            if !currentRun.isEmpty {
                groups.append(.textRun(segments: currentRun))
                currentRun = []
            }
        }

        for block in blocks {
            switch block {
            case .paragraph, .heading, .insight, .list, .blockquote:
                currentRun.append(block)
            case .code, .table, .rule:
                flushRun()
                groups.append(.special(block))
            }
        }
        flushRun()
        return groups
    }

    private static func buildAttributedString(
        segments: [Block],
        inlineMarkdown: (String) -> AttributedString
    ) -> AttributedString {
        var result = AttributedString()
        for (i, block) in segments.enumerated() {
            if i > 0 {
                result += AttributedString("\n\n")
            }
            switch block {
            case .heading(let level, let text):
                var attr = inlineMarkdown(text)
                let size: CGFloat = level == 1 ? 18 : level == 2 ? 15 : 13
                attr.font = .system(size: size, weight: .bold)
                if level <= 2 {
                    attr.foregroundColor = .orange
                }
                result += attr

            case .paragraph(let text):
                result += inlineMarkdown(text)

            case .insight(let lines):
                var header = AttributedString("★ Insight ─────────────────────────────────────\n")
                header.font = .system(size: 12, weight: .medium).monospaced()
                header.foregroundColor = .purple
                result += header
                for (j, line) in lines.enumerated() {
                    result += inlineMarkdown(line)
                    if j < lines.count - 1 { result += AttributedString("\n") }
                }
                var footer = AttributedString("\n─────────────────────────────────────────────────")
                footer.font = .system(size: 12).monospaced()
                footer.foregroundColor = .purple
                result += footer

            case .list(let items, let ordered):
                for (j, item) in items.enumerated() {
                    let bullet = ordered ? "\(j + 1). " : "  •  "
                    result += AttributedString(bullet)
                    result += inlineMarkdown(item)
                    if j < items.count - 1 { result += AttributedString("\n") }
                }

            case .blockquote(let text):
                var bar = AttributedString("  ┃  ")
                bar.foregroundColor = .secondary
                result += bar
                var quoted = inlineMarkdown(text)
                quoted.foregroundColor = .secondary
                result += quoted

            default:
                break
            }
        }
        return result
    }

    private enum Block {
        case heading(level: Int, text: String)
        case code(language: String, content: String)
        case table(rows: [[String]])
        case rule
        case insight(lines: [String])
        case list(items: [String], ordered: Bool)
        case blockquote(text: String)
        case paragraph(text: String)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .code(let lang, let content):
            codeBlockView(language: lang, content: content)
        case .table(let rows):
            tableView(rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        case .insight(let lines):
            insightView(lines: lines)
        case .paragraph(let text):
            paragraphView(text: text)
        case .list, .blockquote:
            EmptyView() // Rendered in textRun via buildAttributedString
        }
    }

    private func insightView(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("★ Insight ─────────────────────────────────────")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.purple)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(inlineMarkdown(line))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }

            Text("─────────────────────────────────────────────────")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.purple)
        }
    }

    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = level == 1 ? 18 : level == 2 ? 15 : 13
        return Text(inlineMarkdown(text))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(level <= 2 ? Color.orange : .primary)
            .padding(.top, level <= 2 ? 8 : 4)
            .padding(.bottom, 2)
    }

    private func codeBlockView(language: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: .init(white: 0.85, alpha: 1)))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .init(white: 0.1, alpha: 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func tableView(rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        Text(inlineMarkdown(cell.trimmingCharacters(in: .whitespaces)))
                            .font(.system(size: 12, weight: rowIdx == 0 ? .semibold : .regular))
                            .foregroundStyle(rowIdx == 0 ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        if colIdx < row.count - 1 {
                            Divider()
                        }
                    }
                }
                if rowIdx < rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppChromePalette.surfaceSubbar.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
        )
    }

    private func paragraphView(text: String) -> some View {
        Text(inlineMarkdown(text))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        // Convert LaTeX math before markdown parsing
        let converted = text.contains("$") ? LaTeXUnicode.convert(text) : text
        return (try? AttributedString(markdown: converted, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(converted)
    }

    // MARK: - Parser

    private static func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Insight block (★ Insight ──── ... ────)
            if line.contains("★") && line.contains("─") {
                var insightLines: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    // Closing border line (all ─)
                    if l.contains("─") && !l.contains("★") && l.filter({ $0 == "─" }).count > 5 {
                        i += 1
                        break
                    }
                    insightLines.append(l)
                    i += 1
                }
                if !insightLines.isEmpty {
                    blocks.append(.insight(lines: insightLines))
                }
                continue
            }

            // Heading
            if let match = line.range(of: #"^(#{1,3})\s+(.+)$"#, options: .regularExpression) {
                let full = String(line[match])
                let level = full.prefix(while: { $0 == "#" }).count
                let text = String(full.drop(while: { $0 == "#" }).dropFirst())
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces).range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                blocks.append(.code(language: lang, content: codeLines.joined(separator: "\n")))
                continue
            }

            // Table
            if line.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---") {
                var tableRows: [[String]] = []
                while i < lines.count && lines[i].contains("|") {
                    let cells = lines[i]
                        .split(separator: "|", omittingEmptySubsequences: false)
                        .map(String.init)
                        .dropFirst()
                        .dropLast()
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    // Skip separator row
                    if !cells.allSatisfy({ $0.range(of: #"^-+$"#, options: .regularExpression) != nil }) {
                        tableRows.append(Array(cells))
                    }
                    i += 1
                }
                if !tableRows.isEmpty {
                    blocks.append(.table(rows: tableRows))
                }
                continue
            }

            // Blockquote
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix(">") {
                    let content = String(lines[i].dropFirst()).trimmingCharacters(in: .init(charactersIn: " "))
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // List (unordered: - or * ; ordered: 1. 2. etc.)
            if line.range(of: #"^\s*[-*]\s+\S"#, options: .regularExpression) != nil ||
               line.range(of: #"^\s*\d+\.\s+\S"#, options: .regularExpression) != nil
            {
                let isOrdered = line.range(of: #"^\s*\d+\."#, options: .regularExpression) != nil
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if let match = l.range(of: #"^\s*[-*]\s+(.*)"#, options: .regularExpression) {
                        let content = String(l[match]).replacingOccurrences(
                            of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
                        items.append(content)
                        i += 1
                    } else if let match = l.range(of: #"^\s*\d+\.\s+(.*)"#, options: .regularExpression) {
                        let content = String(l[match]).replacingOccurrences(
                            of: #"^\s*\d+\.\s+"#, with: "", options: .regularExpression)
                        items.append(content)
                        i += 1
                    } else {
                        break
                    }
                }
                if !items.isEmpty {
                    blocks.append(.list(items: items, ordered: isOrdered))
                }
                continue
            }

            // Empty line — skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```")
                    || (trimmed.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---"))
                    || trimmed.range(of: #"^-{3,}$|^\*{3,}$"#, options: .regularExpression) != nil
                {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(text: paraLines.joined(separator: "\n")))
            }
        }
        return blocks
    }
}

struct ThinkingDots: View {
    @State private var active = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .opacity(active == i ? 1.0 : 0.25)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    active = (active + 1) % 3
                }
            }
        }
    }
}

// MARK: - Session Picker

struct SessionPickerView: View {
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var sessions: [ClaudeHeadlessProvider.SessionEntry] = []
    @State private var search = ""
    @State private var renamingSession: ClaudeHeadlessProvider.SessionEntry?
    @State private var renameText = ""

    private var filtered: [ClaudeHeadlessProvider.SessionEntry] {
        if search.isEmpty { return sessions }
        let q = search.lowercased()
        return sessions.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.project.lowercased().contains(q) ||
            $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Reprendre une session")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Annuler") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Search
            TextField("Rechercher…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            Divider()

            // Session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        Button {
                            onSelect(entry.id)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text(entry.id.prefix(8))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)

                                        if !entry.project.isEmpty && entry.project != entry.displayName {
                                            Text("·")
                                                .foregroundStyle(.secondary.opacity(0.5))
                                            Text(entry.project)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                Text(entry.dateString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        .contextMenu {
                            Button("Renommer…") {
                                renameText = entry.name
                                renamingSession = entry
                            }
                        }

                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(width: 420, height: 350)
        .background(AppChromePalette.surfaceBar)
        .onAppear {
            sessions = ClaudeHeadlessProvider.listSessions()
        }
        .sheet(item: $renamingSession) { entry in
            VStack(spacing: 12) {
                Text("Renommer la session")
                    .font(.system(size: 13, weight: .semibold))

                TextField("Nom", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                HStack {
                    Button("Annuler") { renamingSession = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Renommer") {
                        ClaudeHeadlessProvider.renameSession(id: entry.id, name: renameText)
                        sessions = ClaudeHeadlessProvider.listSessions()
                        renamingSession = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(20)
            .frame(width: 300)
        }
    }
}

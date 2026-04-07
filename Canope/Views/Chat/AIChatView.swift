import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Attached File

struct AttachedFile: Identifiable {
    enum Kind { case textFile, image }
    let id = UUID()
    let name: String
    let path: String
    let content: String
    let kind: Kind

    init(name: String, path: String, content: String, kind: Kind = .textFile) {
        self.name = name
        self.path = path
        self.content = content
        self.kind = kind
    }
}

// MARK: - AI Chat View (Native headless chat panel)

struct AIChatView<Provider: HeadlessChatProviding>: View {
    @ObservedObject var provider: Provider
    let fileRootURL: URL?
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var selectedSlashIndex: Int?
    @State private var showSessionPicker = false
    @State private var cachedSelection: SelectionInfo?
    @State private var attachedFiles: [AttachedFile] = []
    @State private var imageCounter = 0
    @State private var pasteMonitor: Any?
    @State private var fileListItems: [String] = []
    @State private var editingMessageID: UUID?
    @State private var editingText = ""
    @State private var fileListTask: Task<Void, Never>?
    @State private var isRenamingCurrentSession = false
    @State private var currentSessionNameDraft = ""
    @State private var cachedSelectionModifiedAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()
            messageList
            Divider()
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppChromePalette.surfaceBar)
        .onAppear {
            if !provider.isConnected {
                provider.start()
            }
            refreshSelectionCache(force: true)
        }
        .onDisappear {
            fileListTask?.cancel()
            fileListTask = nil
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            refreshSelectionCache()
        }
        // Cmd+N handled via menu item or button — SwiftUI doesn't support view-level Cmd shortcuts well
        .sheet(isPresented: $showSessionPicker) {
            SessionPickerView(
                loadSessions: { provider.listChatSessions(limit: 15, matchingDirectory: chatFileRootURL) },
                renameSession: { id, name in
                    Provider.renameChatSession(id: id, name: name)
                }
            ) { sessionId in
                showSessionPicker = false
                listResetID = UUID() // Skip diffing — fresh list
                provider.resumeChatSession(id: sessionId)
            } onCancel: {
                showSessionPicker = false
            }
        }
        .sheet(isPresented: $isRenamingCurrentSession) {
            VStack(spacing: 12) {
                Text("Renommer la conversation")
                    .font(.system(size: 13, weight: .semibold))

                TextField("Nom", text: $currentSessionNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                HStack {
                    Button("Annuler") { isRenamingCurrentSession = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Renommer") {
                        provider.renameCurrentChatSession(to: currentSessionNameDraft)
                        isRenamingCurrentSession = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
    }

    private func refreshSelectionCache(force: Bool = false) {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        let modifiedAt = selectionStateModificationDate(at: path)

        if !force, modifiedAt == cachedSelectionModifiedAt {
            return
        }

        cachedSelectionModifiedAt = modifiedAt
        cachedSelection = readSelectionFromDisk(at: path)
    }

    private var chatFileRootURL: URL {
        fileRootURL ?? provider.chatWorkingDirectory
    }

    // MARK: - Session Header

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.providerIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(provider.chatSessionDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            if provider.chatCanRenameCurrentSession {
                Button {
                    currentSessionNameDraft = provider.chatSessionDisplayName
                    isRenamingCurrentSession = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Renommer la conversation")
            }

            // Model picker
            Menu {
                ForEach(provider.chatAvailableModels, id: \.self) { model in
                    Button {
                        provider.chatSelectedModel = model
                    } label: {
                        HStack {
                            Text(model)
                            if provider.chatSelectedModel == model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(provider.chatSelectedModel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text("·")
                .foregroundStyle(.secondary.opacity(0.5))

            // Effort picker
            Menu {
                ForEach(provider.chatAvailableEfforts, id: \.self) { effort in
                    Button {
                        provider.chatSelectedEffort = effort
                    } label: {
                        HStack {
                            Text(effort)
                            if provider.chatSelectedEffort == effort {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(provider.chatSelectedEffort)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if provider.session.turns > 0 {
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("\(provider.session.turns) échanges")
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
                // `LazyVStack` re-estimates off-screen row heights for rich markdown,
                // which makes the scrollbar thumb resize and causes visible jumps.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(provider.messages) { message in
                        messageRow(message)
                    }

                    if provider.isProcessing,
                       provider.messages.last?.role == .user || provider.messages.last?.isStreaming == false
                    {
                        thinkingIndicator
                            .id("thinking")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .id(listResetID)
            .onChange(of: provider.messages.count) {
                if shouldAutoScroll {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("bottom_anchor", anchor: .bottom)
                    }
                }
            }
            .onChange(of: provider.isProcessing) {
                if provider.isProcessing { shouldAutoScroll = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                            provider.editAndResendLastUser(newText: newText)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: 11))
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if let queuePosition = message.queuePosition {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(queuePosition == 1 ? "En attente" : "En attente · #\(queuePosition)")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }

                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(message.isQueued ? 0.42 : 0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(message.isQueued ? 0.45 : 0), lineWidth: 1)
                    )
                    .opacity(message.isQueued ? 0.92 : 1)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copier") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        }
                        if !message.isQueued {
                            Button("Éditer & renvoyer") {
                                editingMessageID = message.id
                                editingText = message.content
                            }
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
        let needsBlockMarkdown = messageNeedsBlockMarkdown(message.content)
        let shouldUseRichMarkdown = !ChatMarkdownPolicy.shouldSkipFullMarkdown(for: message.content)
        return HStack(alignment: .top, spacing: 8) {
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
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    streamingCursor
                } else if shouldUseRichMarkdown {
                    if message.isFromHistory {
                        DeferredRichMarkdownView(
                            text: message.content,
                            promotionDelayNanoseconds: 0
                        )
                    } else {
                        RichMarkdownView(text: message.content)
                    }
                } else if message.isFromHistory {
                    if needsBlockMarkdown {
                        DeferredMarkdownView(
                            text: message.content,
                            skipFullRender: ChatMarkdownPolicy.shouldSkipFullMarkdown(for: message.content),
                            allowPromoteToFullBlock: true,
                            promotionDelayNanoseconds: 0
                        )
                    } else {
                        Text(message.content)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.7))
                            .textSelection(.enabled)
                    }
                } else if let preRenderedMarkdown = message.preRenderedMarkdown,
                          !needsBlockMarkdown {
                    // Pre-rendered in background — instant display with markdown
                    Text(preRenderedMarkdown)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                } else {
                    assistantMarkdownStable(message, needsBlockMarkdown: needsBlockMarkdown)
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

    @ViewBuilder
    private func assistantMarkdownStable(_ message: ChatMessage, needsBlockMarkdown: Bool) -> some View {
        if needsBlockMarkdown && !ChatMarkdownPolicy.shouldSkipFullMarkdown(for: message.content) {
            MarkdownBlockView(text: message.content)
        } else {
            Text(InlineMarkdownCache.shared.get(message.content))
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }

    private func messageNeedsBlockMarkdown(_ text: String) -> Bool {
        if text.contains("```") {
            return true
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return false }

        for idx in 0..<(lines.count - 1) {
            let headerLine = lines[idx]
            let separatorLine = lines[idx + 1]
            guard looksLikeMarkdownTableRow(headerLine) else { continue }
            if isMarkdownTableSeparator(separatorLine, expectedColumnCount: markdownTableColumnCount(headerLine)) {
                return true
            }
        }

        return false
    }

    private func toolCard(_ message: ChatMessage) -> some View {
        let toolName = message.toolName ?? "Tool"
        let iconName = Provider.toolIconName(for: toolName)

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

            // @ file suggestions
            if !fileListItems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(fileListItems, id: \.self) { item in
                            Button {
                                selectFile(item)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: item.hasSuffix("/") ? "folder" : "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundStyle(item.hasSuffix("/") ? .blue : .orange)
                                        .frame(width: 14)
                                    Text(item)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(AppChromePalette.surfaceSubbar)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppChromePalette.dividerSoft, lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
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

            // Attached files indicator
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachedFiles) { file in
                            HStack(spacing: 4) {
                                Image(systemName: file.kind == .image ? "camera" : "doc.text")
                                    .font(.system(size: 9))
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundColor(file.kind == .image ? .secondary : .orange)
                                Text(file.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Button {
                                    attachedFiles.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(AppChromePalette.surfaceSubbar)
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
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
                        updateFileList()
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
        .onAppear { installPasteMonitor() }
        .onDisappear { removePasteMonitor() }
        .onExitCommand {
            if provider.isProcessing {
                provider.stop()
            }
        }
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

    // MARK: - @ File Autocomplete

    private var showFileList: Bool {
        guard let atIdx = inputText.lastIndex(of: "@") else { return false }
        // @ must be at start or after a space
        if atIdx != inputText.startIndex {
            let before = inputText[inputText.index(before: atIdx)]
            if before != " " && before != "\n" { return false }
        }
        return true
    }

    private func updateFileList() {
        guard showFileList else {
            fileListItems = []
            return
        }

        // Extract the query after @
        guard let atIdx = inputText.lastIndex(of: "@") else {
            fileListItems = []
            return
        }
        let query = String(inputText[inputText.index(after: atIdx)...]).lowercased()

        let workDir = chatFileRootURL
        fileListTask?.cancel()
        fileListTask = Task { @MainActor in
            let items = Self.listFiles(at: workDir, query: query)
            guard !Task.isCancelled else { return }
            fileListItems = items
        }
    }

    private static func listFiles(at baseURL: URL, query: String, maxResults: Int = 40) -> [String] {
        // If query contains /, navigate into subdirectory
        let components = query.components(separatedBy: "/")
        var currentURL = baseURL
        var filterQuery = query

        if components.count > 1 {
            let dirPath = components.dropLast().joined(separator: "/")
            currentURL = baseURL.appendingPathComponent(dirPath)
            filterQuery = components.last ?? ""
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: currentURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        let prefix = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""
        let skipNames = Set(["node_modules", ".git", "DerivedData", ".build", "Pods", ".DS_Store"])
        let skipExts = Set(["aux", "bbl", "bcf", "blg", "fdb_latexmk", "fls", "lof", "lot",
                            "out", "toc", "synctex.gz", "synctex", "run.xml", "log"])

        var dirs: [String] = []
        var files: [String] = []

        for entry in entries.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
            let name = entry.lastPathComponent
            if skipNames.contains(name) { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            // Skip LaTeX build artifacts
            if !isDir, let ext = name.components(separatedBy: ".").last, skipExts.contains(ext) { continue }

            if !filterQuery.isEmpty && !name.lowercased().contains(filterQuery.lowercased()) { continue }

            let display = prefix + (isDir ? "\(name)/" : name)
            if isDir { dirs.append(display) } else { files.append(display) }
        }

        // Dirs first, then files
        return Array((dirs + files).prefix(maxResults))
    }

    private func selectFile(_ item: String) {
        let workDir = chatFileRootURL

        if item.hasSuffix("/") {
            // Navigate into directory
            if let atIdx = inputText.lastIndex(of: "@") {
                inputText = String(inputText[..<inputText.index(after: atIdx)]) + item
            }
            return
        }

        // Attach the file
        let filePath = workDir.appendingPathComponent(item)
        let name = (item as NSString).lastPathComponent
        let content = (try? String(contentsOf: filePath, encoding: .utf8)) ?? "[Impossible de lire]"
        attachedFiles.append(AttachedFile(name: name, path: filePath.path, content: content))

        // Remove @query from input
        if let atIdx = inputText.lastIndex(of: "@") {
            inputText = String(inputText[..<atIdx])
        }
        fileListItems = []
    }

    // MARK: - Selection State

    private struct SelectionInfo {
        let fileName: String
        let lineCount: Int
    }

    private var currentSelection: SelectionInfo? { cachedSelection }

    private func selectionStateModificationDate(at path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }

    private func readSelectionFromDisk(at path: String) -> SelectionInfo? {
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

    private func looksLikeMarkdownTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        return markdownTableColumnCount(trimmed) >= 2
    }

    private func markdownTableColumnCount(_ line: String) -> Int {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return 0 }

        let rawCells: [Substring]
        if trimmed.hasPrefix("|") || trimmed.hasSuffix("|") {
            rawCells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst(trimmed.hasPrefix("|") ? 1 : 0)
                .dropLast(trimmed.hasSuffix("|") ? 1 : 0)
        } else {
            rawCells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        }

        let cells = rawCells.map { String($0).trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2, cells.contains(where: { !$0.isEmpty }) else { return 0 }
        return cells.count
    }

    private func isMarkdownTableSeparator(_ line: String, expectedColumnCount: Int) -> Bool {
        guard expectedColumnCount >= 2 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }

        let rawCells: [Substring]
        if trimmed.hasPrefix("|") || trimmed.hasSuffix("|") {
            rawCells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst(trimmed.hasPrefix("|") ? 1 : 0)
                .dropLast(trimmed.hasSuffix("|") ? 1 : 0)
        } else {
            rawCells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        }

        let cells = rawCells.map { String($0).trimmingCharacters(in: .whitespaces) }
        guard cells.count == expectedColumnCount else { return false }
        return cells.allSatisfy { cell in
            let content = cell.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return false }
            return content.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    // MARK: - Image Paste

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "v",
                  isInputFocused else { return event }
            if pasteImageFromClipboard() { return nil }
            return event
        }
    }

    private func removePasteMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
            pasteMonitor = nil
        }
    }

    @discardableResult
    private func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        guard let types = pb.types,
              types.contains(where: { [.png, .tiff].contains($0) }) else { return false }

        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let nsImage = NSImage(data: data) else { return false }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return false }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canope-chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        imageCounter += 1
        let fileName = "image_\(String(format: "%03d", imageCounter)).png"
        let filePath = tempDir.appendingPathComponent(fileName)
        try? pngData.write(to: filePath)

        attachedFiles.append(AttachedFile(
            name: "Image #\(imageCounter)",
            path: filePath.path,
            content: "[Pasted image saved at: \(filePath.path)]",
            kind: .image
        ))
        return true
    }

    // MARK: - Helpers

    @State private var shouldAutoScroll = false
    @State private var listResetID = UUID()

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }
        inputText = ""
        refreshSelectionCache()

        // /new starts a fresh conversation
        if text == "/new" {
            provider.newChatSession()
            return
        }

        // Handle /continue locally
        if text == "/continue" {
            provider.resumeLastChatSession(matchingDirectory: chatFileRootURL)
            return
        }

        // /resume shows the session picker
        if text == "/resume" {
            showSessionPicker = true
            return
        }

        if !attachedFiles.isEmpty {
            // Show clean message in UI, send full content to Claude
            let fileNames = attachedFiles.map { $0.kind == .image ? "[\($0.name)]" : "📎 \($0.name)" }.joined(separator: " ")
            let displayText = "\(text)\n\(fileNames)"

            var fileContext = ""
            for file in attachedFiles {
                let truncated = file.content.count > 8000
                    ? String(file.content.prefix(8000)) + "\n… (tronqué)"
                    : file.content
                fileContext += "\n[@\(file.name)]\n\(truncated)\n[/@\(file.name)]\n"
            }
            let fullPrompt = fileContext + "\n" + text
            attachedFiles.removeAll()

            provider.sendMessageWithDisplay(displayText: displayText, prompt: fullPrompt)
        } else {
            provider.sendMessage(text)
        }
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

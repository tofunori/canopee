import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Attached File

struct AttachedFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let content: String
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
    @State private var fileListItems: [String] = []
    @State private var editingMessageID: UUID?
    @State private var editingText = ""
    @State private var fileListTask: Task<Void, Never>?
    @State private var isRenamingCurrentSession = false
    @State private var currentSessionNameDraft = ""

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
            refreshSelectionCache()
        }
        .onDisappear {
            fileListTask?.cancel()
            fileListTask = nil
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
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

    private func refreshSelectionCache() {
        cachedSelection = readSelectionFromDisk()
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
                LazyVStack(alignment: .leading, spacing: 4) {
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
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    streamingCursor
                } else if message.isFromHistory {
                    if messageNeedsBlockMarkdown(message.content) {
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
                          !messageNeedsBlockMarkdown(message.content) {
                    // Pre-rendered in background — instant display with markdown
                    Text(preRenderedMarkdown)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                } else {
                    assistantMarkdownDeferred(message)
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
    private func assistantMarkdownDeferred(_ message: ChatMessage) -> some View {
        let overLimit = ChatMarkdownPolicy.shouldSkipFullMarkdown(for: message.content)
        DeferredMarkdownView(
            text: message.content,
            skipFullRender: overLimit,
            // If pre-render was evicted, visible older messages can still upgrade to full block markdown on demand.
            allowPromoteToFullBlock: !overLimit,
            promotionDelayNanoseconds: messageNeedsBlockMarkdown(message.content) ? 0 : 450_000_000
        )
    }

    private func messageNeedsBlockMarkdown(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text.contains("```") }

        for idx in 0..<(lines.count - 1) {
            let line = lines[idx]
            let nextLine = lines[idx + 1]
            if MarkdownBlockView.parseBlocks([line, nextLine].joined(separator: "\n")).contains(where: {
                if case .table = $0 { return true }
                return false
            }) {
                return true
            }
        }

        return text.contains("```")
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
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
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
    @State private var listResetID = UUID()

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
            let fileNames = attachedFiles.map { "📎 \($0.name)" }.joined(separator: " ")
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

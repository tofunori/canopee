import Combine
import AppKit
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

extension AttachedFile {
    var chatInputItem: ChatInputItem {
        switch kind {
        case .textFile:
            return .textFile(name: name, path: path, content: content)
        case .image:
            return .localImage(path: path)
        }
    }

    static func chatDisplayText(userText: String, attachedFiles: [AttachedFile]) -> String {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentSummary = chatDisplaySummary(for: attachedFiles)

        if trimmedText.isEmpty {
            return attachmentSummary ?? ""
        }

        guard let attachmentSummary else {
            return trimmedText
        }
        return "\(trimmedText)\n\(attachmentSummary)"
    }

    static func chatDisplaySummary(for attachedFiles: [AttachedFile]) -> String? {
        guard !attachedFiles.isEmpty else { return nil }

        let imageCount = attachedFiles.filter { $0.kind == .image }.count
        let textFiles = attachedFiles.filter { $0.kind == .textFile }
        var parts: [String] = []

        if imageCount == 1 {
            parts.append("🖼 1 image jointe")
        } else if imageCount > 1 {
            parts.append("🖼 \(imageCount) images jointes")
        }

        switch textFiles.count {
        case 0:
            break
        case 1:
            parts.append("📎 1 fichier joint")
        default:
            parts.append("📎 \(textFiles.count) fichiers")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private enum CodexAttachSubmenu: Equatable {
    case speed
    case plugins
}

private struct ChatTranscriptView<RowContent: View, ThinkingContent: View>: View {
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

private struct CodexAttachPopoverView: View {
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
            .frame(width: 156, alignment: .leading)
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

private struct LocalCachedImagePreview: View {
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
    @State private var selectionStateMonitor: DirectoryEventMonitor?
    @State private var modeStatusFlash = false
    @State private var approvalFieldValues: [String: String] = [:]
    @State private var hoveredUserMessageID: UUID?
    @State private var hoveredUserMessageHideTask: Task<Void, Never>?
    @State private var showCustomInstructionsEditor = false
    @State private var globalCustomInstructionsDraft = ""
    @State private var sessionCustomInstructionsDraft = ""
    @State private var showCodexAttachPopover = false
    @State private var codexAttachSubmenu: CodexAttachSubmenu?
    @State private var selectedCodexPlugins: Set<String> = []

    private var visibleMessages: [ChatMessage] {
        provider.messages.filter { !$0.isLegacyAcceptEditsApprovalNotice }
    }

    private var usesCodexVisualStyle: Bool {
        provider.chatVisualStyle == .codex
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()
            messageList
            Divider()
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(usesCodexVisualStyle ? AppChromePalette.codexCanvas : AppChromePalette.surfaceBar)
        .onAppear {
            if !provider.isConnected {
                provider.start()
            }
            configureSelectionStateMonitor()
            refreshSelectionCache(force: true)
            syncPendingApprovalFormState()
        }
        .onDisappear {
            fileListTask?.cancel()
            fileListTask = nil
            selectionStateMonitor?.stop()
            selectionStateMonitor = nil
            hoveredUserMessageHideTask?.cancel()
            hoveredUserMessageHideTask = nil
        }
        .onChange(of: provider.pendingApprovalRequest?.id) { _, _ in
            syncPendingApprovalFormState()
        }
        // Cmd+N handled via menu item or button — SwiftUI doesn't support view-level Cmd shortcuts well
        .sheet(isPresented: $showSessionPicker) {
            SessionPickerView(
                loadSessions: { await provider.listChatSessionsAsync(limit: 15, matchingDirectory: chatFileRootURL) },
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
        .sheet(isPresented: $showCustomInstructionsEditor) {
            customInstructionsEditorSheet
        }
        .sheet(isPresented: $isRenamingCurrentSession) {
            VStack(spacing: 12) {
                Text(AppStrings.renameConversation)
                    .font(.system(size: 13, weight: .semibold))

                TextField(AppStrings.name, text: $currentSessionNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                HStack {
                    Button(AppStrings.cancel) { isRenamingCurrentSession = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppStrings.rename) {
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

    private func configureSelectionStateMonitor() {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        let fileURL = URL(fileURLWithPath: path)
        let directoryURL = fileURL.deletingLastPathComponent()

        selectionStateMonitor?.stop()
        selectionStateMonitor = DirectoryEventMonitor(directoryURL: directoryURL) {
            Task { @MainActor in
                refreshSelectionCache()
            }
        }
        selectionStateMonitor?.start()
    }

    private var chatFileRootURL: URL {
        fileRootURL ?? provider.chatWorkingDirectory
    }

    private var currentSelection: SelectionInfo? { cachedSelection }

    private var visibleSelection: SelectionInfo? {
        provider.chatIncludesIDEContext ? currentSelection : nil
    }

    private var includeIDEContextBinding: Binding<Bool> {
        Binding(
            get: { provider.chatIncludesIDEContext },
            set: { provider.chatIncludesIDEContext = $0 }
        )
    }

    private var planModeBinding: Binding<Bool> {
        Binding(
            get: { provider.chatInteractionMode == .plan },
            set: { isEnabled in
                let targetMode: ChatInteractionMode = isEnabled ? .plan : .agent
                guard provider.chatInteractionMode != targetMode else { return }
                provider.chatInteractionMode = targetMode
                flashModeChange()
            }
        )
    }

    private var codexInstalledPlugins: [String] {
        ["Build macOS Apps", "Canva", "Figma", "GitHub"]
    }

    // MARK: - Session Header

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.providerIcon)
                .font(.system(size: usesCodexVisualStyle ? 9 : 10, weight: .semibold))
                .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)

            Text(provider.chatSessionDisplayName)
                .font(.system(size: usesCodexVisualStyle ? 10 : 11, weight: .semibold))
                .lineLimit(1)

            if provider.chatCanRenameCurrentSession {
                Button {
                    currentSessionNameDraft = provider.chatSessionDisplayName
                    isRenamingCurrentSession = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
                }
                .buttonStyle(.plain)
                .help(AppStrings.renameConversation)
            }

            if !provider.chatUsesBottomPromptControls {
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

                Menu {
                    ForEach(provider.chatAvailableEfforts, id: \.self) { effort in
                        Button {
                            provider.chatSelectedEffort = effort
                        } label: {
                            HStack {
                                Text(effortDisplayLabel(effort))
                                if provider.chatSelectedEffort == effort {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(effortDisplayLabel(provider.chatSelectedEffort))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if provider.session.turns > 0 {
                if !provider.chatUsesBottomPromptControls {
                    Text("·")
                        .foregroundStyle((usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary).opacity(0.5))
                }
                Text("\(provider.session.turns) turns")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
            }

            ForEach(provider.chatStatusBadges) { badge in
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.5))
                statusBadgeView(badge)
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
        .frame(height: usesCodexVisualStyle ? AppChromeMetrics.codexHeaderHeight : 28)
        .background(usesCodexVisualStyle ? AppChromePalette.codexHeaderFill : AppChromePalette.surfaceSubbar)
    }

    // MARK: - Message List

    private var messageList: some View {
        ChatTranscriptView(
            messages: visibleMessages,
            isProcessing: provider.isProcessing,
            usesCodexVisualStyle: usesCodexVisualStyle,
            resetID: listResetID,
            rowContent: { message in
                messageRow(message)
            },
            thinkingContent: {
                thinkingIndicator
            }
        )
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
            Spacer(minLength: usesCodexVisualStyle ? 88 : 60)
            VStack(alignment: .trailing, spacing: usesCodexVisualStyle ? 6 : 4) {
                if editingMessageID == message.id {
                    VStack(alignment: .trailing, spacing: usesCodexVisualStyle ? 10 : 6) {
                        TextField("", text: $editingText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, usesCodexVisualStyle ? 16 : 12)
                            .padding(.vertical, usesCodexVisualStyle ? 14 : 8)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptInner : Color.accentColor.opacity(0.3))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(usesCodexVisualStyle ? AppChromePalette.codexPromptStroke : Color.accentColor, lineWidth: 1)
                            )
                        HStack(spacing: 8) {
                            if usesCodexVisualStyle {
                                Button(AppStrings.cancel) {
                                    editingMessageID = nil
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .font(.system(size: 11, weight: .medium))
                            } else {
                                Button(AppStrings.cancel) {
                                    editingMessageID = nil
                                }
                                .buttonStyle(.plain)
                                .controlSize(.regular)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            }

                            Button(isLatestEditableUserMessage(message) ? "Renvoyer" : "Fork & renvoyer") {
                                commitEditedUserMessage(message)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(usesCodexVisualStyle ? .regular : .small)
                            .font(.system(size: 11))
                        }
                    }
                    .padding(usesCodexVisualStyle ? 12 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexPromptCornerRadius : 14, style: .continuous)
                            .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptShell : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexPromptCornerRadius : 14, style: .continuous)
                            .strokeBorder(usesCodexVisualStyle ? AppChromePalette.codexPromptStroke : Color.clear, lineWidth: usesCodexVisualStyle ? 1 : 0)
                    )
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
                    .padding(.horizontal, usesCodexVisualStyle ? 16 : 12)
                    .padding(.vertical, usesCodexVisualStyle ? 11 : 8)
                    .fixedSize(horizontal: shouldUseCompactUserBubbleLayout(for: message), vertical: true)
                    .frame(maxWidth: codexUserBubbleMaxWidth(for: message), alignment: .trailing)
                    .background(
                        RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexUserBubbleCornerRadius : 14, style: .continuous)
                            .fill(
                                usesCodexVisualStyle
                                    ? AppChromePalette.codexRequestFill.opacity(message.isQueued ? 0.88 : 1)
                                    : Color.accentColor.opacity(message.isQueued ? 0.42 : 0.85)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexUserBubbleCornerRadius : 14, style: .continuous)
                            .strokeBorder(
                                usesCodexVisualStyle
                                    ? AppChromePalette.codexRequestStroke.opacity(message.isQueued ? 0.65 : 1)
                                    : Color.accentColor.opacity(message.isQueued ? 0.45 : 0),
                                lineWidth: 1
                            )
                    )
                    .opacity(message.isQueued ? 0.92 : 1)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copier") {
                            copyUserMessage(message)
                        }
                        if !message.isQueued {
                            Button("Fork") {
                                forkUserMessage(message)
                            }
                            Button(isLatestEditableUserMessage(message) ? "Éditer & renvoyer" : "Éditer & forker") {
                                editingMessageID = message.id
                                editingText = message.content
                            }
                        }
                    }
                }

                userMessageActionBar(message)
                    .opacity(shouldShowUserMessageActions(for: message) ? 1 : 0)
                    .allowsHitTesting(shouldShowUserMessageActions(for: message))
            }
            .frame(maxWidth: usesCodexVisualStyle ? 540 : .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { isHovering in
                setUserMessageHover(isHovering, for: message.id)
            }
        }
        .padding(.vertical, usesCodexVisualStyle ? 4 : 2)
    }

    private func userMessageActionBar(_ message: ChatMessage) -> some View {
        HStack(spacing: 12) {
            Text(formattedUserMessageTime(message.timestamp))
                .font(.system(size: usesCodexVisualStyle ? 10 : 10, weight: .medium))
                .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)

            Button {
                copyUserMessage(message)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
            .help("Copier")

            Button {
                forkUserMessage(message)
            } label: {
                Image(systemName: "point.3.connected.trianglepath")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
            .help("Fork")

            Button {
                editingMessageID = message.id
                editingText = message.content
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
            .help("Éditer")
        }
        .padding(.horizontal, usesCodexVisualStyle ? 6 : 0)
        .padding(.top, 2)
        .frame(height: 18)
        .onHover { isHovering in
            setUserMessageHover(isHovering, for: message.id)
        }
    }

    private func codexUserBubbleMaxWidth(for message: ChatMessage) -> CGFloat? {
        guard usesCodexVisualStyle else { return nil }
        if shouldUseCompactUserBubbleLayout(for: message) {
            return nil
        }
        return 460
    }

    private func shouldUseCompactUserBubbleLayout(for message: ChatMessage) -> Bool {
        guard usesCodexVisualStyle else { return false }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lines = trimmed.components(separatedBy: .newlines)
        let longestLine = lines.map(\.count).max() ?? 0

        if lines.count == 1 {
            return longestLine <= 88
        }

        if lines.count == 2 {
            return trimmed.count <= 120 && longestLine <= 72
        }

        return false
    }

    private func shouldShowUserMessageActions(for message: ChatMessage) -> Bool {
        !message.isQueued && hoveredUserMessageID == message.id && editingMessageID != message.id
    }

    private func setUserMessageHover(_ isHovering: Bool, for messageID: UUID) {
        hoveredUserMessageHideTask?.cancel()
        if isHovering {
            hoveredUserMessageID = messageID
            return
        }

        guard hoveredUserMessageID == messageID else { return }
        hoveredUserMessageHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, hoveredUserMessageID == messageID else { return }
            hoveredUserMessageID = nil
        }
    }

    private func isLatestEditableUserMessage(_ message: ChatMessage) -> Bool {
        provider.messages.last(where: { $0.role == .user && !$0.isQueued })?.id == message.id
    }

    private func commitEditedUserMessage(_ message: ChatMessage) {
        let newText = editingText
        editingMessageID = nil
        if isLatestEditableUserMessage(message) {
            provider.editAndResendLastUser(newText: newText)
        } else {
            provider.forkChatFromUserMessage(newText: newText)
        }
    }

    private func copyUserMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func forkUserMessage(_ message: ChatMessage) {
        provider.forkChatFromUserMessage(newText: message.content)
    }

    private func formattedUserMessageTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private var thinkingIndicator: some View {
        SpinnerVerbView()
    }

    private func codexTimelineGlyph(_ systemName: String, tint: Color = AppChromePalette.codexMutedText) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 16, alignment: .center)
            .padding(.top, 2)
    }

    private func codexToolStatus(for message: ChatMessage) -> String? {
        if message.isStreaming { return "running" }
        if message.toolOutput != nil { return "completed" }
        return nil
    }

    @ViewBuilder
    private func assistantRow(_ message: ChatMessage) -> some View {
        if message.presentationKind == .plan {
            planAssistantCard(message)
        } else if message.presentationKind == .reviewFinding {
            reviewFindingCard(message)
        } else {
            let needsBlockMarkdown = messageNeedsBlockMarkdown(message.content)
            let shouldUseRichMarkdown = !ChatMarkdownPolicy.shouldSkipFullMarkdown(for: message.content)
            HStack(alignment: .top, spacing: usesCodexVisualStyle ? 10 : 8) {
                if usesCodexVisualStyle {
                    codexTimelineGlyph("sparkles")
                } else {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Image(systemName: "sparkle")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: usesCodexVisualStyle ? 4 : 0) {
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
                                .foregroundStyle(.primary.opacity(usesCodexVisualStyle ? 0.9 : 0.7))
                                .textSelection(.enabled)
                        }
                    } else if let preRenderedMarkdown = message.preRenderedMarkdown,
                              !needsBlockMarkdown {
                        Text(preRenderedMarkdown)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    } else {
                        assistantMarkdownStable(message, needsBlockMarkdown: needsBlockMarkdown)
                    }
                }
                .frame(maxWidth: usesCodexVisualStyle ? 680 : .infinity, alignment: .leading)

                Spacer(minLength: 20)
            }
            .padding(.vertical, usesCodexVisualStyle ? 3 : 4)
        }
    }

    private func planAssistantCard(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: usesCodexVisualStyle ? 10 : 8) {
            if usesCodexVisualStyle {
                codexTimelineGlyph("list.bullet.clipboard", tint: .blue)
            } else {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Plan")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text(AppStrings.noActionsApplied)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
                }

                if message.isStreaming {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    streamingCursor
                } else if ChatMarkdownPolicy.shouldSkipFullMarkdown(for: message.content) {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    MarkdownBlockView(text: message.content)
                }
            }
            .padding(usesCodexVisualStyle ? 0 : 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(usesCodexVisualStyle ? Color.clear : Color.blue.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(usesCodexVisualStyle ? Color.clear : Color.blue.opacity(0.18), lineWidth: 0.8)
            )
            .frame(maxWidth: usesCodexVisualStyle ? 680 : .infinity, alignment: .leading)

            Spacer(minLength: 20)
        }
        .padding(.vertical, usesCodexVisualStyle ? 3 : 4)
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

                if let imagePath = imagePreviewPath(for: message) {
                    LocalCachedImagePreview(path: imagePath, maxWidth: 240, maxHeight: 140)
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
                if usesCodexVisualStyle {
                    codexTimelineGlyph(iconName, tint: toolAccentColor(toolName))
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(toolAccentColor(toolName))
                        .frame(width: 14)
                }

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

                if let status = codexToolStatus(for: message) {
                    if usesCodexVisualStyle {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppChromePalette.codexMutedText)
                    } else if message.toolOutput != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green.opacity(0.7))
                    }
                }
            }
        }
        .disclosureGroupStyle(ToolCardDisclosureStyle())
        .padding(.leading, usesCodexVisualStyle ? 0 : 28)
        .padding(.horizontal, usesCodexVisualStyle ? 10 : 0)
        .padding(.vertical, usesCodexVisualStyle ? 6 : 1)
        .background(
            RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexEventCornerRadius : 0, style: .continuous)
                .fill(usesCodexVisualStyle ? AppChromePalette.codexEventFill : Color.clear)
        )
    }

    private func toolResultCard(_ message: ChatMessage) -> some View {
        HStack(spacing: 6) {
            if usesCodexVisualStyle {
                codexTimelineGlyph("arrow.turn.down.right", tint: AppChromePalette.codexMutedText)
            } else {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text(message.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
                .lineLimit(3)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.leading, usesCodexVisualStyle ? 0 : 28)
        .padding(.horizontal, usesCodexVisualStyle ? 10 : 0)
        .padding(.vertical, usesCodexVisualStyle ? 6 : 1)
    }

    @ViewBuilder
    private func systemRow(_ message: ChatMessage) -> some View {
        if usesCodexVisualStyle {
            HStack(spacing: 6) {
                codexTimelineGlyph("point.topleft.down.curvedto.point.bottomright.up")
                Text(message.content)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppChromePalette.codexMutedText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        } else {
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
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        Group {
            if usesCodexVisualStyle {
                codexInputBar
            } else {
                standardInputBar
            }
        }
        .onAppear { installPasteMonitor() }
        .onDisappear { removePasteMonitor() }
        .onExitCommand {
            if provider.isProcessing {
                provider.stop()
            }
        }
    }

    private var standardInputBar: some View {
        VStack(spacing: 0) {
            if let sel = visibleSelection {
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

            if let approval = provider.pendingApprovalRequest {
                approvalRequestCard(approval)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.08))

                Divider()
            }

            if !fileListItems.isEmpty {
                promptFileSuggestionsList
            }

            if showSlashSuggestions, !filteredSlashCommands.isEmpty {
                promptSlashSuggestionsList
            }

            if !attachedFiles.isEmpty {
                attachedFilesStrip
            }

            HStack(spacing: 8) {
                attachButton(isCodexPrompt: false)

                promptTextField

                sendButton(isCodexPrompt: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                if provider.chatUsesBottomPromptControls {
                    modelPromptMenu
                    effortPromptMenu
                }

                interactionModePromptMenu(style: .standard)

                if let environmentLabel = provider.chatPromptEnvironmentLabel {
                    environmentPromptMenu(environmentLabel)
                }

                if let configurationLabel = provider.chatPromptConfigurationLabel {
                    configurationPromptMenu(configurationLabel)
                }

                Spacer()
            }
            .frame(height: 22)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(AppChromePalette.surfaceSubbar)
    }

    private var codexInputBar: some View {
        VStack(spacing: 6) {
            if let approval = provider.pendingApprovalRequest {
                approvalRequestCard(approval)
                    .padding(.horizontal, 14)
            }

            if !fileListItems.isEmpty {
                promptFileSuggestionsList
                    .padding(.horizontal, 8)
            }

            if showSlashSuggestions, !filteredSlashCommands.isEmpty {
                promptSlashSuggestionsList
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 0) {
                if let sel = visibleSelection {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppChromePalette.codexIDEContext)

                        Text(sel.fileName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppChromePalette.codexMutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("·")
                            .foregroundStyle(AppChromePalette.codexMutedText.opacity(0.4))

                        Text("\(sel.lineCount) ligne\(sel.lineCount > 1 ? "s" : "")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppChromePalette.codexMutedText)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }

                if !attachedFiles.isEmpty {
                    attachedFilesStrip
                        .padding(.top, visibleSelection == nil ? 8 : 5)
                }

                promptTextField
                    .padding(.horizontal, 18)
                    .padding(.top, (visibleSelection == nil && attachedFiles.isEmpty) ? 10 : 7)
                    .padding(.bottom, 8)

                Rectangle()
                    .fill(AppChromePalette.codexPromptDivider.opacity(0.55))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    attachButton(isCodexPrompt: true)

                    if provider.chatUsesBottomPromptControls {
                        codexPrimaryMenuLabel(title: provider.chatSelectedModel, iconName: nil) {
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
                        }
                        codexPromptFooterDivider
                        codexPrimaryMenuLabel(title: effortDisplayLabel(provider.chatSelectedEffort), iconName: nil) {
                            ForEach(provider.chatAvailableEfforts, id: \.self) { effort in
                                Button {
                                    provider.chatSelectedEffort = effort
                                } label: {
                                    HStack {
                                        Text(effortDisplayLabel(effort))
                                        if provider.chatSelectedEffort == effort {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        codexPromptFooterDivider
                    }

                    codexIDEContextControl

                    Spacer(minLength: 6)

                    sendButton(isCodexPrompt: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppChromePalette.codexPromptShell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(AppChromePalette.codexPromptStroke, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)

            HStack(spacing: 16) {
                interactionModePromptMenu(style: .codexSecondary)

                if let environmentLabel = provider.chatPromptEnvironmentLabel {
                    codexSecondaryMenuLabel(title: environmentLabel, iconName: "laptopcomputer") {
                        Button {} label: {
                            HStack {
                                Text(environmentLabel)
                                Image(systemName: "checkmark")
                            }
                        }
                        .disabled(true)

                        Divider()

                        Button {} label: {
                            Text(environmentExecutionLabel)
                        }
                        .disabled(true)

                        Button {} label: {
                            Text("Reseau actif")
                        }
                        .disabled(true)

                        Button {} label: {
                            Text(provider.chatWorkingDirectory.path)
                                .lineLimit(1)
                        }
                        .disabled(true)
                    }
                }

                if let configurationLabel = provider.chatPromptConfigurationLabel {
                    if provider.chatSupportsCustomInstructions {
                        Button {
                            openCustomInstructionsEditor()
                        } label: {
                            codexSecondaryButtonLabel(
                                title: configurationLabel,
                                iconName: "gearshape",
                                showsIndicator: provider.chatCustomInstructions.hasAny
                            )
                        }
                        .buttonStyle(.plain)
                        .help("\(AppStrings.customInstructions) · \(provider.chatCustomInstructions.summaryLabel)")
                    } else {
                        codexSecondaryMenuLabel(title: configurationLabel, iconName: "gearshape") {
                            Button {} label: {
                                HStack {
                                    Text(configurationLabel)
                                    Image(systemName: "checkmark")
                                }
                            }
                            .disabled(true)

                            Divider()

                            Button {} label: {
                                Text("\(AppStrings.modelLabel): \(provider.chatSelectedModel.uppercased())")
                            }
                            .disabled(true)

                            Button {} label: {
                                Text("\(AppStrings.reasoningLabel): \(effortDisplayLabel(provider.chatSelectedEffort))")
                            }
                            .disabled(true)
                        }
                    }
                }

                Spacer(minLength: 0)

                if provider.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppChromePalette.codexMutedText)
                        .scaleEffect(0.7)
                } else {
                    Circle()
                        .strokeBorder(AppChromePalette.codexPromptDivider.opacity(0.65), lineWidth: 2)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 0)
        .padding(.vertical, 6)
        .background(AppChromePalette.codexCanvas)
    }

    private var promptFileSuggestionsList: some View {
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

    private var promptSlashSuggestionsList: some View {
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

    private var attachedFilesStrip: some View {
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
                            .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptInner.opacity(0.95) : AppChromePalette.surfaceSubbar)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var promptTextField: some View {
        if usesCodexVisualStyle {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .focused($isInputFocused)
                    .onChange(of: inputText) {
                        updateSlashSuggestions()
                        updateFileList()
                    }
                    .onKeyPress(phases: .down) { press in
                        if press.key == .return && !press.modifiers.contains(.shift) {
                            send()
                            return .handled
                        }
                        return .ignored
                    }

                if inputText.isEmpty {
                    Text(chatInputPlaceholder)
                        .font(.system(size: 14))
                        .foregroundStyle(AppChromePalette.codexMutedText.opacity(0.72))
                        .padding(.top, 6)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: codexPromptEditorHeight, alignment: .topLeading)
        } else {
            TextField(chatInputPlaceholder, text: $inputText, axis: .vertical)
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
                .foregroundStyle(.primary)
        }
    }

    private var codexPromptEditorHeight: CGFloat {
        let lineBreaks = inputText.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let wrappedLines = max(1, Int(ceil(Double(max(inputText.count, 1)) / 72.0)))
        let estimatedLines = max(lineBreaks, wrappedLines)

        switch estimatedLines {
        case ...1:
            return 34
        case 2:
            return 52
        case 3:
            return 70
        default:
            return min(110, 70 + CGFloat(estimatedLines - 3) * 18)
        }
    }

    @ViewBuilder
    private func attachButton(isCodexPrompt: Bool) -> some View {
        if isCodexPrompt {
            Button {
                showCodexAttachPopover.toggle()
                if !showCodexAttachPopover {
                    codexAttachSubmenu = nil
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppChromePalette.codexMutedText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(AppStrings.addOrConfigureMessage)
            .popover(isPresented: $showCodexAttachPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                codexAttachPopover
            }
        } else {
            Button {
                openAttachmentPicker()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(AppStrings.attachFile)
        }
    }

    private func sendButton(isCodexPrompt: Bool) -> some View {
        Button {
            send()
        } label: {
            Image(systemName: provider.chatInteractionMode.sendButtonSymbolName)
                .font(.system(size: isCodexPrompt ? 16 : 22, weight: .semibold))
                .foregroundStyle(
                    canSend
                        ? (isCodexPrompt ? AppChromePalette.codexSendGlyph : provider.chatInteractionMode.tint)
                        : Color.secondary.opacity(0.45)
                )
                .frame(width: isCodexPrompt ? 30 : 24, height: isCodexPrompt ? 30 : 24)
                .background(
                    Circle()
                        .fill(canSend
                              ? (isCodexPrompt ? AppChromePalette.codexSendFill : .clear)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(sendButtonHelp)
        .frame(width: isCodexPrompt ? 32 : 28, height: isCodexPrompt ? 32 : 28)
    }

    private enum PromptControlStyle {
        case standard
        case codexSecondary
    }

    private func interactionModePromptMenu(style: PromptControlStyle) -> some View {
        Menu {
            ForEach(ChatInteractionMode.allCases, id: \.self) { mode in
                Button {
                    provider.chatInteractionMode = mode
                    flashModeChange()
                } label: {
                    HStack {
                        Text(mode.badgeLabel)
                        if provider.chatInteractionMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            switch style {
            case .standard:
                HStack(spacing: 5) {
                    Image(systemName: provider.chatInteractionMode.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 12)

                    Text(provider.chatInteractionMode.badgeLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 8, height: 8)
                }
                .foregroundStyle(provider.chatInteractionMode.tint)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(provider.chatInteractionMode.tint.opacity(0.12))
                .clipShape(Capsule())
                .overlay {
                    if modeStatusFlash {
                        Capsule()
                            .strokeBorder(provider.chatInteractionMode.tint.opacity(0.45), lineWidth: 1)
                    }
                }

            case .codexSecondary:
                HStack(spacing: 4) {
                    Image(systemName: provider.chatInteractionMode.iconName)
                        .font(.system(size: 10, weight: .medium))
                    Text(provider.chatInteractionMode.badgeLabel)
                        .font(.system(size: 8.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(AppChromePalette.codexMutedText)
            }
        }
        .menuStyle(.borderlessButton)
        .help(AppStrings.currentMode)
    }

    @ViewBuilder
    private func codexPrimaryMenuLabel<Content: View>(
        title: String,
        iconName: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 9, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(AppChromePalette.codexMutedText)
            .frame(minWidth: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var codexPromptFooterDivider: some View {
        Rectangle()
            .fill(AppChromePalette.codexPromptDivider.opacity(0.75))
            .frame(width: 1, height: 14)
    }

    private var codexIDEContextControl: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
            Text("IDE context")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle((provider.chatIncludesIDEContext && currentSelection != nil) ? AppChromePalette.codexIDEContext : AppChromePalette.codexMutedText)
    }

    private var codexAttachPopover: some View {
        CodexAttachPopoverView(
            supportsIDEContextToggle: provider.chatSupportsIDEContextToggle,
            supportsPlanMode: provider.chatSupportsPlanMode,
            includeIDEContextBinding: includeIDEContextBinding,
            planModeBinding: planModeBinding,
            codexInstalledPlugins: codexInstalledPlugins,
            selectedSubmenu: $codexAttachSubmenu,
            selectedPlugins: $selectedCodexPlugins
        ) {
            showCodexAttachPopover = false
            openAttachmentPicker()
        }
    }

    private func codexSecondaryButtonLabel(
        title: String,
        iconName: String,
        showsIndicator: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
            if showsIndicator {
                Circle()
                    .fill(AppChromePalette.codexIDEContext)
                    .frame(width: 4, height: 4)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(AppChromePalette.codexMutedText)
        .frame(minWidth: 68, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func codexSecondaryMenuLabel<Content: View>(
        title: String,
        iconName: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            codexSecondaryButtonLabel(title: title, iconName: iconName)
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    private func approvalRequestCard(_ approval: ChatApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if let actionLabel = approval.actionLabel {
                    Text(actionLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.14))
                        )
                } else {
                    Image(systemName: approval.requiresFormInput ? "square.and.pencil" : "checkmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Text(approval.message ?? "Autoriser l’action \(approval.toolName) ?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 8)
            }

            if approval.requiresFormInput {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(approval.fields) { field in
                        approvalFieldRow(field)
                    }
                }

                HStack(spacing: 8) {
                    Button(AppStrings.cancel) {
                        provider.dismissPendingApprovalRequest()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Send") {
                        provider.submitPendingApprovalRequest(fieldValues: approvalFieldValues)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(!canSubmitApprovalRequest(approval))
                }
            } else {
                if let preview = approval.preview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preview.title)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(preview.body)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptInner.opacity(0.85) : Color.white.opacity(0.05))
                        )
                    }
                }

                if !approval.details.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(approval.details, id: \.self) { detail in
                            Text(detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(usesCodexVisualStyle ? AppChromePalette.codexPromptInner.opacity(0.7) : Color.white.opacity(0.04))
                                )
                        }
                    }
                }

                HStack {
                    Spacer(minLength: 0)

                    Button("Refuser") {
                        provider.dismissPendingApprovalRequest()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)

                    Button("Autoriser") {
                        provider.approvePendingApprovalRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(usesCodexVisualStyle ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexEventCornerRadius : 0, style: .continuous)
                .fill(usesCodexVisualStyle ? AppChromePalette.codexEventFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: usesCodexVisualStyle ? AppChromeMetrics.codexEventCornerRadius : 0, style: .continuous)
                .strokeBorder(usesCodexVisualStyle ? AppChromePalette.codexPromptStroke.opacity(0.75) : Color.clear, lineWidth: usesCodexVisualStyle ? 0.8 : 0)
        )
    }

    @ViewBuilder
    private func approvalFieldRow(_ field: ChatInteractiveField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                if field.isRequired {
                    Text("*")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }

            if let prompt = field.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch field.kind {
            case .boolean:
                Toggle(isOn: approvalBoolBinding(for: field)) {
                    Text(approvalBoolBinding(for: field).wrappedValue ? "Oui" : "Non")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

            case .singleChoice:
                Picker("", selection: approvalTextBinding(for: field)) {
                    ForEach(field.options) { option in
                        Text(option.label).tag(option.label)
                    }
                    if field.supportsCustomValue {
                        Text("Autre…").tag("__other__")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if approvalTextBinding(for: field).wrappedValue == "__other__" {
                    TextField("Autre valeur", text: approvalOtherTextBinding(for: field))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

            case .secureText:
                SecureField(field.placeholder ?? "Valeur", text: approvalTextBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

            case .text, .integer, .number:
                TextField(field.placeholder ?? "Valeur", text: approvalTextBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
    }

    private func syncPendingApprovalFormState() {
        guard let approval = provider.pendingApprovalRequest else {
            approvalFieldValues = [:]
            return
        }

        var values: [String: String] = [:]
        for field in approval.fields {
            values[field.id] = field.defaultValue
            if field.supportsCustomValue {
                values["\(field.id)__other"] = ""
            }
        }
        approvalFieldValues = values
    }

    private func approvalTextBinding(for field: ChatInteractiveField) -> Binding<String> {
        Binding(
            get: { approvalFieldValues[field.id] ?? field.defaultValue },
            set: { approvalFieldValues[field.id] = $0 }
        )
    }

    private func approvalOtherTextBinding(for field: ChatInteractiveField) -> Binding<String> {
        Binding(
            get: { approvalFieldValues["\(field.id)__other"] ?? "" },
            set: { approvalFieldValues["\(field.id)__other"] = $0 }
        )
    }

    private func approvalBoolBinding(for field: ChatInteractiveField) -> Binding<Bool> {
        Binding(
            get: { (approvalFieldValues[field.id] ?? field.defaultValue) == "true" },
            set: { approvalFieldValues[field.id] = $0 ? "true" : "false" }
        )
    }

    private func resolvedApprovalValue(for field: ChatInteractiveField) -> String {
        let raw = (approvalFieldValues[field.id] ?? field.defaultValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if field.supportsCustomValue && raw == "__other__" {
            return (approvalFieldValues["\(field.id)__other"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private func canSubmitApprovalRequest(_ approval: ChatApprovalRequest) -> Bool {
        for field in approval.fields {
            let value = resolvedApprovalValue(for: field)
            if field.isRequired && value.isEmpty {
                return false
            }
            switch field.kind {
            case .integer where !value.isEmpty && Int(value) == nil:
                return false
            case .number where !value.isEmpty && Double(value) == nil:
                return false
            default:
                break
            }
        }
        return true
    }

    // MARK: - Slash Commands

    private var slashCommands: [String] { [
        "agent", "plan",
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
        let content = (try? String(contentsOf: filePath, encoding: .utf8)) ?? AppStrings.couldNotRead
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
            guard isInputFocused else { return event }
            let relevantModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 48,
               relevantModifiers == [.shift] {
                provider.chatInteractionMode = provider.chatInteractionMode.next
                flashModeChange()
                return nil
            }
            guard relevantModifiers.contains(.command),
                  event.charactersIgnoringModifiers == "v" else { return event }
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
        if let image = clipboardBitmapImage(from: pb) {
            return attachClipboardImage(image, preferredFileName: nil)
        }

        if let fileURL = clipboardImageFileURL(from: pb) {
            let preferredName = fileURL.deletingPathExtension().lastPathComponent
            if let image = NSImage(contentsOf: fileURL) {
                return attachClipboardImage(image, preferredFileName: preferredName)
            }
        }

        return false
    }

    private func clipboardBitmapImage(from pasteboard: NSPasteboard) -> NSImage? {
        guard let types = pasteboard.types,
              types.contains(where: { [.png, .tiff].contains($0) }) else { return nil }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
        return NSImage(data: data)
    }

    private func clipboardImageFileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           let imageURL = urls.first(where: isSupportedPastedImageURL) {
            return imageURL
        }

        if let rawString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           rawString.isEmpty == false {
            if rawString.hasPrefix("file://"),
               let url = URL(string: rawString),
               isSupportedPastedImageURL(url) {
                return url
            }

            let fileURL = URL(fileURLWithPath: rawString)
            if isSupportedPastedImageURL(fileURL) {
                return fileURL
            }
        }

        return nil
    }

    private func isSupportedPastedImageURL(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"].contains(ext)
    }

    @discardableResult
    private func attachClipboardImage(_ nsImage: NSImage, preferredFileName: String?) -> Bool {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return false }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canope-chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        imageCounter += 1
        let baseName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedBaseName = {
            guard let baseName, !baseName.isEmpty else {
                return "image_\(String(format: "%03d", imageCounter))"
            }
            let cleanedScalars = baseName.unicodeScalars.map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                    return Character(scalar)
                }
                return "_"
            }
            let cleaned = String(cleanedScalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            return cleaned.isEmpty ? "image_\(String(format: "%03d", imageCounter))" : cleaned
        }()
        let fileName = "\(sanitizedBaseName).png"
        let filePath = tempDir.appendingPathComponent(fileName)
        try? pngData.write(to: filePath)

        attachedFiles.append(AttachedFile(
            name: fileName,
            path: filePath.path,
            content: "[Pasted image saved at: \(filePath.path)]",
            kind: .image
        ))
        return true
    }

    private func openAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.title = "Attach files to chat"
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else { return }
        attachPickedFiles(panel.urls)
    }

    private func attachPickedFiles(_ urls: [URL]) {
        var skippedNames: [String] = []

        for url in urls {
            guard url.isFileURL else {
                skippedNames.append(url.lastPathComponent)
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                skippedNames.append(url.lastPathComponent)
                continue
            }

            if isSupportedPastedImageURL(url) {
                attachedFiles.append(AttachedFile(
                    name: url.lastPathComponent,
                    path: url.path,
                    content: "[Attached image at: \(url.path)]",
                    kind: .image
                ))
                continue
            }

            if let content = tryReadTextAttachment(at: url) {
                attachedFiles.append(AttachedFile(
                    name: url.lastPathComponent,
                    path: url.path,
                    content: content,
                    kind: .textFile
                ))
            } else {
                skippedNames.append(url.lastPathComponent)
            }
        }

        if !skippedNames.isEmpty {
            let suffix = skippedNames.count == 1 ? skippedNames[0] : skippedNames.joined(separator: ", ")
            provider.messages.append(
                ChatMessage(
                    role: .system,
                    content: "Skipped attachments: \(suffix). Only images and text files are supported for now.",
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
            )
        }
    }

    private func tryReadTextAttachment(at url: URL) -> String? {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .unicode) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            return content
        }
        return nil
    }

    // MARK: - Helpers

    @State private var listResetID = UUID()

    private var chatInputPlaceholder: String {
        "\(provider.chatInteractionMode.inputPlaceholderSuffix) to \(provider.providerName)…"
    }

    private var sendButtonHelp: String {
        provider.chatInteractionMode == .plan ? "Send planning request" : "Send"
    }

    private var modelPromptMenu: some View {
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
            promptFooterChip(
                title: provider.chatSelectedModel.uppercased(),
                iconName: "cpu",
                tint: .orange,
                useMonospacedText: true
            )
        }
        .menuStyle(.borderlessButton)
        .help("\(AppStrings.modelLabel) Codex")
    }

    private var effortPromptMenu: some View {
        Menu {
            ForEach(provider.chatAvailableEfforts, id: \.self) { effort in
                Button {
                    provider.chatSelectedEffort = effort
                } label: {
                    HStack {
                        Text(effortDisplayLabel(effort))
                        if provider.chatSelectedEffort == effort {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            promptFooterChip(
                title: effortDisplayLabel(provider.chatSelectedEffort),
                iconName: "brain",
                tint: .secondary
            )
        }
        .menuStyle(.borderlessButton)
        .help(AppStrings.codexReasoningHelp)
    }

    private func promptFooterChip(
        title: String,
        iconName: String,
        tint: Color,
        useMonospacedText: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 12, height: 12)

            Text(title)
                .font(.system(size: 10, weight: .semibold, design: useMonospacedText ? .monospaced : .default))
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 8, height: 8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: usesCodexVisualStyle ? AppChromeMetrics.codexFooterChipHeight : 22)
        .background(usesCodexVisualStyle ? AppChromePalette.codexPromptInner : AppChromePalette.surfaceSubbar)
        .clipShape(Capsule())
    }

    private func environmentPromptMenu(_ title: String) -> some View {
        Menu {
            Button {} label: {
                HStack {
                    Text(title)
                    Image(systemName: "checkmark")
                }
            }
            .disabled(true)

            Divider()

            Button {} label: {
                Text(environmentExecutionLabel)
            }
            .disabled(true)

            Button {} label: {
                Text(AppStrings.networkActive)
            }
            .disabled(true)

            Button {} label: {
                Text(provider.chatWorkingDirectory.path)
                    .lineLimit(1)
            }
            .disabled(true)
        } label: {
            promptFooterChip(
                title: title,
                iconName: "laptopcomputer",
                tint: .secondary
            )
        }
        .menuStyle(.borderlessButton)
        .help(AppStrings.codexExecutionContextHelp)
    }

    private func configurationPromptMenu(_ title: String) -> some View {
        Menu {
            Button {} label: {
                HStack {
                    Text(title)
                    Image(systemName: "checkmark")
                }
            }
            .disabled(true)

            Divider()

            Button {} label: {
                Text("\(AppStrings.modelLabel): \(provider.chatSelectedModel.uppercased())")
            }
            .disabled(true)

            Button {} label: {
                Text("\(AppStrings.reasoningLabel): \(effortDisplayLabel(provider.chatSelectedEffort))")
            }
            .disabled(true)

            Button {} label: {
                Text("\(AppStrings.modeLabel): \(provider.chatInteractionMode.badgeLabel)")
            }
            .disabled(true)
        } label: {
            promptFooterChip(
                title: title,
                iconName: "gearshape",
                tint: .secondary
            )
        }
        .menuStyle(.borderlessButton)
        .help(AppStrings.presetHelp)
    }

    private var customInstructionsEditorSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppStrings.instructions)
                                .font(.system(size: 15, weight: .semibold))
                            Text(AppStrings.codexPromptOnly)
                                .font(.system(size: 11))
                                .foregroundStyle(AppChromePalette.codexMutedText)
                        }

                        Spacer(minLength: 0)

                        Text(provider.chatCustomInstructions.summaryLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(provider.chatCustomInstructions.hasAny ? AppChromePalette.codexIDEContext : AppChromePalette.codexMutedText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(AppChromePalette.codexPromptInner)
                            )
                    }

                    customInstructionsEditorSection(
                        title: AppStrings.globalInstructions,
                        subtitle: AppStrings.globalInstructionsSubtitle,
                        text: $globalCustomInstructionsDraft,
                        placeholder: "E.g. Respond in simple, direct English."
                    )

                    customInstructionsEditorSection(
                        title: AppStrings.sessionInstructions,
                        subtitle: AppStrings.sessionInstructionsSubtitle,
                        text: $sessionCustomInstructionsDraft,
                        placeholder: "E.g. In this conversation, be concise and always cite files."
                    )

                    HStack(spacing: 10) {
                        Button("Reset global") {
                            globalCustomInstructionsDraft = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button("Reset session") {
                            sessionCustomInstructionsDraft = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()
                .overlay(AppChromePalette.codexPromptDivider.opacity(0.65))

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(AppStrings.cancel) {
                    showCustomInstructionsEditor = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(AppStrings.save) {
                    provider.updateChatCustomInstructions(
                        global: globalCustomInstructionsDraft,
                        session: sessionCustomInstructionsDraft
                    )
                    showCustomInstructionsEditor = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(AppChromePalette.codexCanvas)
        }
        .frame(width: 620)
        .frame(minHeight: 430, idealHeight: 500, maxHeight: 620, alignment: .topLeading)
        .background(AppChromePalette.codexCanvas)
    }

    private func customInstructionsEditorSection(
        title: String,
        subtitle: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppChromePalette.codexMutedText)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)

                if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(AppChromePalette.codexMutedText.opacity(0.7))
                        .padding(.top, 8)
                        .padding(.leading, 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 112, maxHeight: 140)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppChromePalette.codexPromptShell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppChromePalette.codexPromptStroke, lineWidth: 1)
            )
        }
    }

    private func openCustomInstructionsEditor() {
        globalCustomInstructionsDraft = provider.chatCustomInstructions.globalText
        sessionCustomInstructionsDraft = provider.chatCustomInstructions.sessionText
        showCustomInstructionsEditor = true
    }

    private var environmentExecutionLabel: String {
        switch provider.chatInteractionMode {
        case .plan:
            return "Lecture seule"
        case .agent, .acceptEdits:
            return "Écriture locale"
        }
    }

    private func effortDisplayLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "low":
            return "Bas"
        case "medium":
            return "Moyen"
        case "high":
            return "Eleve"
        case "xhigh":
            return "Tres approfondi"
        default:
            return effort
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return }
        inputText = ""
        refreshSelectionCache()

        if text == "/plan" {
            provider.chatInteractionMode = .plan
            flashModeChange()
            return
        }

        if text == "/agent" {
            provider.chatInteractionMode = .agent
            flashModeChange()
            return
        }

        if text.hasPrefix("/review"), provider.chatSupportsReview {
            let command = String(text.dropFirst("/review".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            provider.startChatReview(command: command.isEmpty ? nil : command)
            return
        }

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
            let displayText = AttachedFile.chatDisplayText(userText: text, attachedFiles: attachedFiles)
            let items = attachedFiles.map(\.chatInputItem) + (text.isEmpty ? [] : [.text(text)])
            attachedFiles.removeAll()

            provider.sendMessageWithDisplay(displayText: displayText, items: items)
        } else {
            provider.sendMessage(text)
        }
    }

    private func flashModeChange() {
        modeStatusFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            modeStatusFlash = false
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

    private func imagePreviewPath(for message: ChatMessage) -> String? {
        guard message.toolName == "ImageView",
              let toolInput = message.toolInput,
              let data = toolInput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String,
              !path.isEmpty
        else {
            return nil
        }
        return path
    }

    @ViewBuilder
    private func statusBadgeView(_ badge: ChatStatusBadge) -> some View {
        let actions = provider.chatStatusActions(for: badge)
        if actions.isEmpty {
            statusBadgeChip(badge)
        } else {
            Menu {
                ForEach(actions) { action in
                    Button {
                        provider.performChatStatusAction(action)
                    } label: {
                        if let systemImage = action.systemImage {
                            Label(action.label, systemImage: systemImage)
                        } else {
                            Text(action.label)
                        }
                    }
                }
            } label: {
                statusBadgeChip(badge, isActionable: true)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func statusBadgeChip(_ badge: ChatStatusBadge, isActionable: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: statusBadgeIconName(badge.kind))
                .font(.system(size: 9, weight: .semibold))
            Text(badge.text)
                .lineLimit(1)
            if isActionable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.8)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(statusBadgeColor(badge.kind))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(
                    usesCodexVisualStyle
                        ? AppChromePalette.codexPromptInner.opacity(0.9)
                        : statusBadgeColor(badge.kind).opacity(0.12)
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    usesCodexVisualStyle
                        ? AppChromePalette.codexPromptStroke.opacity(0.8)
                        : Color.clear,
                    lineWidth: usesCodexVisualStyle ? 0.8 : 0
                )
        )
    }

    @ViewBuilder
    private func reviewFindingCard(_ message: ChatMessage) -> some View {
        let finding = message.reviewFinding
        HStack(alignment: .top, spacing: usesCodexVisualStyle ? 10 : 8) {
            if usesCodexVisualStyle {
                codexTimelineGlyph("exclamationmark.bubble", tint: reviewFindingColor(finding?.priority))
            } else {
                Circle()
                    .fill(reviewFindingColor(finding?.priority).opacity(0.18))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(reviewFindingColor(finding?.priority))
                    }
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    if let priorityLabel = finding?.priorityLabel {
                        Text(priorityLabel)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(reviewFindingColor(finding?.priority))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(reviewFindingColor(finding?.priority).opacity(0.12))
                            )
                    }

                    Text(finding?.title ?? message.content)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if let location = finding?.locationLabel {
                        Text(location)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Text(finding?.body ?? message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let filePath = finding?.filePath, !filePath.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Ouvrir") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(usesCodexVisualStyle ? AppChromePalette.codexMutedText : .secondary)
                    }
                }
            }
            .padding(usesCodexVisualStyle ? 10 : 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(usesCodexVisualStyle ? AppChromePalette.codexEventFill : Color.orange.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        usesCodexVisualStyle ? AppChromePalette.codexPromptStroke.opacity(0.8) : reviewFindingColor(finding?.priority).opacity(0.18),
                        lineWidth: 0.8
                    )
            )

            Spacer(minLength: 20)
        }
        .padding(.vertical, usesCodexVisualStyle ? 3 : 4)
    }

    private func statusBadgeIconName(_ kind: ChatStatusBadgeKind) -> String {
        switch kind {
        case .connecting: return "bolt.horizontal.circle"
        case .connected: return "bolt.horizontal.circle.fill"
        case .reviewActive: return "checklist"
        case .reviewDone: return "checkmark.seal"
        case .reviewAttention: return "exclamationmark.triangle"
        case .authRequired: return "person.crop.circle.badge.exclamationmark"
        case .mcpOkay: return "server.rack"
        case .mcpWarning: return "server.rack"
        }
    }

    private func statusBadgeColor(_ kind: ChatStatusBadgeKind) -> Color {
        switch kind {
        case .connecting: return .secondary
        case .connected: return .green.opacity(0.9)
        case .reviewActive: return .pink.opacity(0.95)
        case .reviewDone: return .blue.opacity(0.9)
        case .reviewAttention: return .orange.opacity(0.95)
        case .authRequired: return .orange.opacity(0.95)
        case .mcpOkay: return .teal.opacity(0.95)
        case .mcpWarning: return .orange.opacity(0.95)
        }
    }

    private func reviewFindingColor(_ priority: Int?) -> Color {
        switch priority {
        case 0: return .red
        case 1: return .orange
        case 2: return .yellow
        case 3: return .blue
        default: return .orange
        }
    }

    private func toolAccentColor(_ name: String) -> Color {
        switch name {
        case "Read", "Glob", "Grep": return .blue
        case "Edit", "Write": return .orange
        case "Bash": return .green
        case "WebSearch", "WebFetch": return .purple
        case "ImageView": return .blue.opacity(0.9)
        case "Agent": return .mint.opacity(0.9)
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

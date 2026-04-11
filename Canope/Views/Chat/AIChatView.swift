import Combine
import AppKit
import SwiftUI

// MARK: - AI Chat View (Native headless chat panel)

struct AIChatView<Provider: HeadlessChatProviding>: View {
    @ObservedObject var provider: Provider
    let fileRootURL: URL?
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var selectedSlashIndex: Int?
    @State private var showSessionPicker = false
    @StateObject private var selectionContextStore = ChatSelectionContextStore()
    @State private var attachedFiles: [AttachedFile] = []
    @State private var imageCounter = 0
    @State private var pasteMonitor: Any?
    @State private var fileListItems: [String] = []
    @State private var editingMessageID: UUID?
    @State private var editingText = ""
    @State private var fileListTask: Task<Void, Never>?
    @State private var isRenamingCurrentSession = false
    @State private var currentSessionNameDraft = ""
    @State private var modeStatusFlash = false
    @StateObject private var approvalFormModel = ChatApprovalFormModel()
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

    private var composerState: ChatComposerState {
        ChatComposerState(
            inputText: inputText,
            attachedFiles: attachedFiles,
            interactionMode: provider.chatInteractionMode,
            providerName: provider.providerName,
            usesCodexVisualStyle: usesCodexVisualStyle
        )
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
            selectionContextStore.startMonitoring(selectionStatePath: CanopeContextFiles.ideSelectionStatePaths[0])
            selectionContextStore.refreshSelectionCache(force: true, statePath: CanopeContextFiles.ideSelectionStatePaths[0])
            approvalFormModel.sync(with: provider.pendingApprovalRequest)
        }
        .onDisappear {
            fileListTask?.cancel()
            fileListTask = nil
            selectionContextStore.stopMonitoring()
            hoveredUserMessageHideTask?.cancel()
            hoveredUserMessageHideTask = nil
        }
        .onChange(of: provider.pendingApprovalRequest?.id) { _, _ in
            approvalFormModel.sync(with: provider.pendingApprovalRequest)
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

    private var chatFileRootURL: URL {
        fileRootURL ?? provider.chatWorkingDirectory
    }

    private var currentSelection: ChatSelectionInfo? { selectionContextStore.cachedSelection }

    private var visibleSelection: ChatSelectionInfo? {
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
        ChatSessionHeader(
            provider: provider,
            usesCodexVisualStyle: usesCodexVisualStyle,
            effortDisplayLabel: effortDisplayLabel,
            onRename: {
                currentSessionNameDraft = provider.chatSessionDisplayName
                isRenamingCurrentSession = true
            },
            onStop: {
                provider.stop()
            },
            statusBadgeView: { badge in
                statusBadgeView(badge)
            }
        )
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
                                ChatMessageActions.beginEditing(
                                    message: message,
                                    editingMessageID: &editingMessageID,
                                    editingText: &editingText
                                )
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
                ChatMessageActions.beginEditing(
                    message: message,
                    editingMessageID: &editingMessageID,
                    editingText: &editingText
                )
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
        editingMessageID = nil
        ChatMessageActions.commitEditedMessage(
            message: message,
            editingText: editingText,
            provider: provider,
            isLatestEditableUserMessage: isLatestEditableUserMessage(message)
        )
    }

    private func copyUserMessage(_ message: ChatMessage) {
        ChatMessageActions.copy(message)
    }

    private func forkUserMessage(_ message: ChatMessage) {
        ChatMessageActions.fork(message: message, provider: provider)
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
                            .font(.system(size: usesCodexVisualStyle ? 14 : 13))
                            .foregroundStyle(.primary)
                            .lineSpacing(usesCodexVisualStyle ? 6 : 2)
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
                                .font(.system(size: usesCodexVisualStyle ? 14 : 13))
                                .foregroundStyle(.primary.opacity(usesCodexVisualStyle ? 0.9 : 0.7))
                                .lineSpacing(usesCodexVisualStyle ? 6 : 2)
                                .textSelection(.enabled)
                        }
                    } else if let preRenderedMarkdown = message.preRenderedMarkdown,
                              !needsBlockMarkdown {
                        Text(preRenderedMarkdown)
                            .font(.system(size: usesCodexVisualStyle ? 14 : 13))
                            .lineSpacing(usesCodexVisualStyle ? 6 : 2)
                            .textSelection(.enabled)
                    } else {
                        assistantMarkdownStable(message, needsBlockMarkdown: needsBlockMarkdown)
                    }
                }
                .padding(.horizontal, usesCodexVisualStyle ? 16 : 0)
                .padding(.vertical, usesCodexVisualStyle ? 14 : 0)
                .frame(maxWidth: usesCodexVisualStyle ? 720 : .infinity, alignment: .leading)
                .background {
                    if usesCodexVisualStyle {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppChromePalette.codexEventFill.opacity(0.96))
                    }
                }
                .overlay {
                    if usesCodexVisualStyle {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(AppChromePalette.codexPromptStroke.opacity(0.65), lineWidth: 1)
                    }
                }

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
                .font(.system(size: usesCodexVisualStyle ? 14 : 13))
                .lineSpacing(usesCodexVisualStyle ? 6 : 2)
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
        ChatComposerBar(
            provider: provider,
            usesCodexVisualStyle: usesCodexVisualStyle,
            selection: visibleSelection,
            showsSuggestions: !fileListItems.isEmpty || (showSlashSuggestions && !filteredSlashCommands.isEmpty),
            showsAttachments: !attachedFiles.isEmpty,
            onInstallPasteMonitor: installPasteMonitor,
            onRemovePasteMonitor: removePasteMonitor,
            onExitStop: {
                provider.stop()
            },
            approvalContent: { approval in
                approvalRequestCard(approval)
            },
            suggestionsContent: {
                VStack(spacing: 0) {
                    if !fileListItems.isEmpty {
                        promptFileSuggestionsList
                    }
                    if showSlashSuggestions, !filteredSlashCommands.isEmpty {
                        promptSlashSuggestionsList
                    }
                }
            },
            attachmentsContent: {
                attachedFilesStrip
            },
            promptFieldContent: {
                Group {
                    if usesCodexVisualStyle {
                        promptTextField
                            .padding(.horizontal, 18)
                            .padding(.top, (visibleSelection == nil && attachedFiles.isEmpty) ? 10 : 7)
                            .padding(.bottom, 8)
                    } else {
                        HStack(spacing: 8) {
                            attachButton(isCodexPrompt: false)
                            promptTextField
                            sendButton(isCodexPrompt: false)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            },
            standardFooterContent: {
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
            },
            codexFooterContent: {
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
            },
            codexSecondaryContent: {
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
            }
        )
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
                CodexPromptEditor(
                    text: $inputText,
                    isFocused: Binding(
                        get: { isInputFocused },
                        set: { isInputFocused = $0 }
                    )
                ) {
                    send()
                } onTextChange: {
                        updateSlashSuggestions()
                        updateFileList()
                    }

                if inputText.isEmpty {
                    Text(composerState.placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(AppChromePalette.codexMutedText.opacity(0.72))
                        .padding(.top, CodexPromptEditor.placeholderTopInset)
                        .padding(.leading, CodexPromptEditor.placeholderLeadingInset)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: composerState.promptEditorHeight, alignment: .topLeading)
        } else {
            TextField(composerState.placeholder, text: $inputText, axis: .vertical)
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
        ChatApprovalCard(
            approval: approval,
            usesCodexVisualStyle: usesCodexVisualStyle,
            formModel: approvalFormModel,
            onDismiss: {
                provider.dismissPendingApprovalRequest()
            },
            onApprove: {
                provider.approvePendingApprovalRequest()
            },
            onSubmit: { fieldValues in
                provider.submitPendingApprovalRequest(fieldValues: fieldValues)
            }
        )
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
            let items = ChatAttachmentSupport.listFiles(at: workDir, query: query)
            guard !Task.isCancelled else { return }
            fileListItems = items
        }
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
        if let attachment = ChatAttachmentSupport.makeAttachment(from: filePath) {
            attachedFiles.append(attachment)
        } else {
            provider.messages.append(
                ChatMessage(
                    role: .system,
                    content: ChatAttachmentSupport.skippedAttachmentMessage(for: [filePath.lastPathComponent]),
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
            )
        }

        // Remove @query from input
        if let atIdx = inputText.lastIndex(of: "@") {
            inputText = String(inputText[..<atIdx])
        }
        fileListItems = []
    }

    // MARK: - Selection State

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
           let imageURL = urls.first(where: ChatAttachmentSupport.isSupportedImageURL) {
            return imageURL
        }

        if let rawString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           rawString.isEmpty == false {
            if rawString.hasPrefix("file://"),
               let url = URL(string: rawString),
               ChatAttachmentSupport.isSupportedImageURL(url) {
                return url
            }

            let fileURL = URL(fileURLWithPath: rawString)
            if ChatAttachmentSupport.isSupportedImageURL(fileURL) {
                return fileURL
            }
        }

        return nil
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

            if let attachment = ChatAttachmentSupport.makeAttachment(from: url) {
                attachedFiles.append(attachment)
            } else {
                skippedNames.append(url.lastPathComponent)
            }
        }

        if !skippedNames.isEmpty {
            provider.messages.append(
                ChatMessage(
                    role: .system,
                    content: ChatAttachmentSupport.skippedAttachmentMessage(for: skippedNames),
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
            )
        }
    }

    // MARK: - Helpers

    @State private var listResetID = UUID()

    private var chatInputPlaceholder: String { composerState.placeholder }

    private var sendButtonHelp: String { composerState.sendButtonHelp }

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
        ChatCustomInstructionsSheet(
            summaryLabel: provider.chatCustomInstructions.summaryLabel,
            hasAnyInstructions: provider.chatCustomInstructions.hasAny,
            globalText: $globalCustomInstructionsDraft,
            sessionText: $sessionCustomInstructionsDraft,
            onResetGlobal: {
                globalCustomInstructionsDraft = ""
            },
            onResetSession: {
                sessionCustomInstructionsDraft = ""
            },
            onCancel: {
                showCustomInstructionsEditor = false
            },
            onSave: {
                provider.updateChatCustomInstructions(
                    global: globalCustomInstructionsDraft,
                    session: sessionCustomInstructionsDraft
                )
                showCustomInstructionsEditor = false
            }
        )
    }

    private func openCustomInstructionsEditor() {
        globalCustomInstructionsDraft = provider.chatCustomInstructions.globalText
        sessionCustomInstructionsDraft = provider.chatCustomInstructions.sessionText
        showCustomInstructionsEditor = true
    }

    private var environmentExecutionLabel: String {
        composerState.environmentExecutionLabel
    }

    private func effortDisplayLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh":
            return "Very deep"
        default:
            return effort
        }
    }

    private var canSend: Bool { composerState.canSend }

    private func send() {
        let originalText = inputText
        guard ChatCommandRouter.route(
            inputText: originalText,
            attachedFiles: attachedFiles,
            supportsReview: provider.chatSupportsReview,
            chatFileRootURL: chatFileRootURL
        ) != nil else {
            return
        }
        inputText = ""
        selectionContextStore.refreshSelectionCache(statePath: CanopeContextFiles.ideSelectionStatePaths[0])

        guard let action = ChatCommandRouter.route(
            inputText: originalText,
            attachedFiles: attachedFiles,
            supportsReview: provider.chatSupportsReview,
            chatFileRootURL: chatFileRootURL
        ) else {
            return
        }

        switch action {
        case .setMode(let mode):
            provider.chatInteractionMode = mode
            flashModeChange()

        case .startReview(let command):
            provider.startChatReview(command: command)

        case .newSession:
            provider.newChatSession()

        case .resumeLastChatSession(let matchingDirectory):
            provider.resumeLastChatSession(matchingDirectory: matchingDirectory)

        case .showSessionPicker:
            showSessionPicker = true

        case .sendItems(let displayText, let items):
            attachedFiles.removeAll()
            provider.sendMessageWithDisplay(displayText: displayText, items: items)

        case .sendText(let text):
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
            if !usesCodexVisualStyle {
                Image(systemName: statusBadgeIconName(badge.kind))
                    .font(.system(size: 9, weight: .semibold))
            }
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

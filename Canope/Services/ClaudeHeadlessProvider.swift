import Foundation
import Combine
import SwiftUI

// MARK: - Claude Headless Provider

@MainActor
final class ClaudeHeadlessProvider: ObservableObject, AIHeadlessProvider {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var isConnected = false
    @Published var session = SessionInfo()
    @Published var selectedModel: String = "opus"
    @Published var selectedEffort: String = "high"
    @Published var includesIDEContext = true
    @Published var chatInteractionMode: ChatInteractionMode = .agent
    @Published var pendingApprovalRequest: ChatApprovalRequest?

    let providerName = "Claude"
    let providerIcon = "brain.head.profile"

    static let availableModels = ["opus", "sonnet", "haiku"]
    static let availableEfforts = ["low", "medium", "high", "max"]

    private var currentProcess: Process?
    private var readTask: Task<Void, Never>?
    private let streamReducer = ClaudeStreamReducer()
    private(set) var workingDirectory: URL
    var workingDirectoryURL: URL { resumeWorkingDirectory ?? workingDirectory }
    private var currentAssistantIndex: Int?
    private var useContinueForNextMessage = false
    private var resumeWorkingDirectory: URL?  // override cwd when resuming a session from another project
    private var messageQueue: [QueuedMessage] = []
    private var pendingMarkdownPreRenders: [(UUID, String)] = []
    private var markdownPreRenderTask: Task<Void, Never>?
    private var currentRunInteractionMode: ChatInteractionMode = .agent
    private var currentRunIncludesIDEContext = true
    private var currentRunPrompt = ""
    private var currentRunDisplayText = ""

    private struct QueuedMessage {
        let messageID: UUID
        let prompt: String
        let interactionMode: ChatInteractionMode
        let includeIDEContext: Bool
    }

    private enum ClaudeLaunchMode {
        case send
        case forkEdit(sessionId: String)

        var pipelineMode: ClaudeSendPipeline.LaunchMode {
            switch self {
            case .send:
                return .send(useContinue: false, resumeSessionID: nil)
            case .forkEdit(let sessionId):
                return .forkEdit(sessionID: sessionId)
            }
        }
    }

    init(workingDirectory: URL? = nil) {
        if let wd = workingDirectory {
            self.workingDirectory = wd
        } else {
            // Try to find the project root from the active terminal's cwd
            let cwd = FileManager.default.currentDirectoryPath
            self.workingDirectory = cwd == "/"
                ? FileManager.default.homeDirectoryForCurrentUser
                : URL(fileURLWithPath: cwd)
        }
    }

    /// Update working directory (e.g. when project changes)
    func updateWorkingDirectory(_ url: URL) {
        workingDirectory = url
    }

    var chatSupportsPlanMode: Bool { true }

    // MARK: - Lifecycle

    func start() {
        isConnected = true
    }

    func stop() {
        cancelInFlightWork()
        isProcessing = false
        // Stay connected — stop only cancels the current request
        if let idx = currentAssistantIndex, idx < messages.count {
            messages[idx].isStreaming = false
        }
        currentAssistantIndex = nil
    }

    /// Cancels stdout reader, throttle, pending parse lines, and terminates the CLI process.
    private func cancelInFlightWork() {
        streamReducer.reset()
        readTask?.cancel()
        readTask = nil
        if let proc = currentProcess, proc.isRunning { proc.terminate() }
        currentProcess = nil
    }

    /// Resume a specific session by ID. Shows last few messages as plain text preview.
    func resumeSession(id: String) {
        cancelInFlightWork()
        clearMarkdownPreRenderWork()
        isProcessing = false
        currentAssistantIndex = nil

        session.id = id
        session.name = Self.sessionEntry(id: id, defaultDirectory: workingDirectory)?.name
        messages.removeAll()

        // Load cwd + last few messages in background
        Task.detached { [weak self] in
            let cwd = Self.findSessionCwd(id: id)
            let history = Self.parseSessionHistory(id: id)
            // Only keep the last 5 user/assistant messages as plain text preview
            // Load messages from the end until we hit a character budget
            let charBudget = 3000
            var preview: [ChatMessage] = []
            var totalChars = 0
            for msg in history.reversed() {
                if totalChars + msg.content.count > charBudget && !preview.isEmpty { break }
                var m = msg
                m.isFromHistory = true
                preview.insert(m, at: 0)
                totalChars += msg.content.count
            }
            // Last assistant message gets full markdown rendering
            if let lastIdx = preview.lastIndex(where: { $0.role == .assistant }) {
                preview[lastIdx].isFromHistory = false
            }
            await MainActor.run { [weak self] in
                self?.resumeWorkingDirectory = cwd
                self?.messages = Array(preview)
                self?.appendSystem("Session resumed: \(id.prefix(12))…")
                self?.enqueueMarkdownPreRenderForLastAssistantIfNeeded()
            }
        }
    }

    private nonisolated static func findSessionCwd(id: String) -> URL? {
        ClaudeSessionStore.findSessionCwd(id: id)
    }

    /// Load conversation history from the JSONL file for a session.
    private nonisolated static func parseSessionHistory(id: String) -> [ChatMessage] {
        ClaudeTranscriptLoader.parseSessionHistory(id: id)
    }

    nonisolated static func cleanedResumedUserMessage(_ text: String) -> String {
        let pattern = #"^\[Canope IDE Context[^\n]*\]\n.*?\n\[/Canope IDE Context\]\n*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges >= 2
        else {
            return text
        }

        let contentRange = match.range(at: 1)
        guard contentRange.location != NSNotFound else { return text }
        return nsText.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Edit the last user message and resend with --fork-session.
    func editAndResend(newText: String) {
        guard let sid = session.id else {
            // No session to fork — just send as new message
            sendMessage(newText)
            return
        }

        // Remove messages after the last user message
        if let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) {
            messages.removeSubrange(lastUserIdx...)
        }

        // Fork the session with the new message
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(
            role: .user, content: trimmed, timestamp: Date(),
            isStreaming: false, isCollapsed: false
        ))

        pendingApprovalRequest = nil
        beginClaudeRun(
            userPrompt: trimmed,
            displayText: trimmed,
            mode: .forkEdit(sessionId: sid),
            interactionMode: chatInteractionMode,
            includeIDEContext: includesIDEContext
        )
    }

    /// Start a fresh conversation, clearing all state.
    func newSession() {
        cancelInFlightWork()
        clearMarkdownPreRenderWork()
        isProcessing = false
        currentAssistantIndex = nil
        session = SessionInfo()
        resumeWorkingDirectory = nil
        useContinueForNextMessage = false
        messages.removeAll()
        appendSystem(AppStrings.newConversation)
    }

    func renameCurrentSession(to name: String) {
        guard let id = session.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.renameSession(id: id, name: trimmed, fallbackCwd: workingDirectory)
        session.name = trimmed.isEmpty ? nil : trimmed
    }

    /// Resume the most recent session for the provided project root only.
    func resumeLastSession(matchingDirectory: URL? = nil) {
        cancelInFlightWork()
        clearMarkdownPreRenderWork()
        isProcessing = false
        currentAssistantIndex = nil

        let directory = matchingDirectory ?? workingDirectory
        guard let latest = Self.listSessions(limit: 1, matchingDirectory: directory).first else {
            appendSystem("No session found for this folder")
            return
        }
        resumeSession(id: latest.id)
    }

    /// List available sessions from `~/.claude/projects`, enriched by `~/.claude/sessions` when available.
    static func listSessions(limit: Int = 15, matchingDirectory: URL? = nil) -> [SessionEntry] {
        ClaudeSessionStore.listSessions(limit: limit, matchingDirectory: matchingDirectory)
    }

    private nonisolated static func sessionEntry(id: String, defaultDirectory: URL? = nil) -> SessionEntry? {
        ClaudeSessionStore.sessionEntry(id: id, defaultDirectory: defaultDirectory)
    }

    struct SessionEntry: Identifiable {
        let id: String
        let name: String
        let project: String
        let date: Date?
        let cwd: URL?

        var displayName: String {
            if !name.isEmpty { return name }
            return project
        }

        var dateString: String {
            guard let date else { return "" }
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            return fmt.string(from: date)
        }
    }

    /// Rename a session by updating or creating metadata in ~/.claude/sessions/
    nonisolated static func renameSession(id: String, name: String, fallbackCwd: URL? = nil) {
        ClaudeSessionStore.renameSession(id: id, name: name, fallbackCwd: fallbackCwd)
    }

    /// Send with a different display text than what's sent to Claude
    func sendMessageWithDisplay(displayText: String, items: [ChatInputItem]) {
        let prompt = ChatInputItem.legacyPrompt(from: items)
        sendMessageWithDisplay(displayText: displayText, prompt: prompt)
    }

    /// Send with a different display text than what's sent to Claude
    func sendMessageWithDisplay(displayText: String, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isProcessing {
            enqueueUserMessage(displayText: displayText, prompt: trimmed, interactionMode: chatInteractionMode)
            return
        }

        if !isConnected { start() }

        pendingApprovalRequest = nil
        appendUserMessage(displayText)

        beginClaudeRun(
            userPrompt: trimmed,
            displayText: displayText,
            mode: .send,
            interactionMode: chatInteractionMode,
            includeIDEContext: includesIDEContext
        )
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Queue if already processing
        if isProcessing {
            enqueueUserMessage(displayText: trimmed, prompt: trimmed, interactionMode: chatInteractionMode)
            return
        }

        if !isConnected { start() }

        pendingApprovalRequest = nil
        appendUserMessage(trimmed)

        beginClaudeRun(
            userPrompt: trimmed,
            displayText: trimmed,
            mode: .send,
            interactionMode: chatInteractionMode,
            includeIDEContext: includesIDEContext
        )
    }

    private func appendUserMessage(_ text: String, queuePosition: Int? = nil) {
        messages.append(ChatMessage(
            role: .user,
            content: text,
            timestamp: Date(),
            isStreaming: false,
            isCollapsed: false,
            queuePosition: queuePosition
        ))
    }

    private func enqueueUserMessage(displayText: String, prompt: String, interactionMode: ChatInteractionMode) {
        let message = ChatMessage(
            role: .user,
            content: displayText,
            timestamp: Date(),
            isStreaming: false,
            isCollapsed: false,
            queuePosition: messageQueue.count + 1
        )
        messages.append(message)
        messageQueue.append(
            QueuedMessage(
                messageID: message.id,
                prompt: prompt,
                interactionMode: interactionMode,
                includeIDEContext: includesIDEContext
            )
        )
        refreshQueuedMessagePositions()
    }

    private func refreshQueuedMessagePositions() {
        for (offset, queued) in messageQueue.enumerated() {
            guard let idx = messages.firstIndex(where: { $0.id == queued.messageID }) else { continue }
            messages[idx].queuePosition = offset + 1
        }
    }

    /// Single entry point for `claude` CLI runs (normal send and fork-edit).
    private func beginClaudeRun(
        userPrompt trimmed: String,
        displayText: String,
        mode: ClaudeLaunchMode,
        interactionMode: ChatInteractionMode,
        includeIDEContext: Bool
    ) {
        cancelInFlightWork()

        isProcessing = true
        currentAssistantIndex = nil
        currentRunInteractionMode = interactionMode
        currentRunIncludesIDEContext = includeIDEContext
        currentRunPrompt = trimmed
        currentRunDisplayText = displayText

        let model = selectedModel
        let effort = selectedEffort
        let cwd = resumeWorkingDirectory ?? workingDirectory
        let skipMcp = resumeWorkingDirectory != nil
        let resumeIdAtLaunch = session.id

        let useContinue: Bool
        switch mode {
        case .send:
            useContinue = useContinueForNextMessage
            useContinueForNextMessage = false
        case .forkEdit:
            useContinue = false
        }

        let launchMode: ClaudeSendPipeline.LaunchMode
        switch mode {
        case .send:
            launchMode = .send(useContinue: useContinue, resumeSessionID: resumeIdAtLaunch)
        case .forkEdit(let sid):
            launchMode = .forkEdit(sessionID: sid)
        }

        readTask = Task.detached { [weak self] in
            let proc = Process()
            let cliPath = Self.findCLI("claude")
            proc.executableURL = URL(fileURLWithPath: cliPath)
            let launchConfig = ClaudeSendPipeline.makeLaunchConfiguration(
                prompt: trimmed,
                displayPrompt: displayText,
                launchMode: launchMode,
                interactionMode: interactionMode,
                includeIDEContext: includeIDEContext,
                model: model,
                effort: effort,
                currentDirectoryURL: cwd,
                skipMcp: skipMcp
            )
            proc.currentDirectoryURL = launchConfig.currentDirectoryURL
            proc.arguments = launchConfig.arguments

            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            await MainActor.run {
                ClaudeIDEBridgeService.shared.startIfNeeded()
                CanopeContextFiles.writeClaudeIDEMcpConfig()
            }
            launchConfig.environment.forEach { key, value in
                env[key] = value
            }
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            await MainActor.run { [weak self] in
                self?.currentProcess = proc
            }

            do {
                try proc.run()
            } catch {
                await MainActor.run { [weak self] in
                    self?.appendSystem("\(AppStrings.errorPrefix) \(error.localizedDescription)")
                    self?.isProcessing = false
                }
                return
            }

            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading

            stderrHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty && (t.contains("Error") || t.contains("error")) else { return }
                DispatchQueue.main.async {
                    self?.appendSystem(t)
                }
            }

            while true {
                let data = stdoutHandle.availableData
                if data.isEmpty { break }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                await MainActor.run { [weak self] in
                    self?.handleOutput(text)
                }
            }

            stderrHandle.readabilityHandler = nil
            await MainActor.run { [weak self] in
                self?.finalizeAfterProcessExit()
            }
        }
    }

    private func finalizeAfterProcessExit() {
        streamReducer.flushPendingLines { [weak self] event in
            self?.handleStreamEvent(event)
        }
        finalizeStreamingAssistant()
        if isProcessing {
            isProcessing = false
        }
        processQueue()
    }

    private func processQueue() {
        guard !messageQueue.isEmpty, !isProcessing else { return }
        let next = messageQueue.removeFirst()
        if let idx = messages.firstIndex(where: { $0.id == next.messageID }) {
            messages[idx].queuePosition = nil
        }
        refreshQueuedMessagePositions()
        beginClaudeRun(
            userPrompt: next.prompt,
            displayText: queuedDisplayText(for: next.messageID, fallback: next.prompt),
            mode: .send,
            interactionMode: next.interactionMode,
            includeIDEContext: next.includeIDEContext
        )
    }

    // MARK: - Output Parsing

    private func handleOutput(_ text: String) {
        streamReducer.appendOutput(text) { [weak self] event in
            self?.handleStreamEvent(event)
        }
    }

    private func handleStreamEvent(_ event: ClaudeStreamEvent) {
        switch event {
        case .system(let json):
            handleSystemEvent(json)
        case .assistant(let json):
            handleAssistantEvent(json)
        case .result(let json):
            handleResultEvent(json)
        }
    }

    private func handleSystemEvent(_ json: [String: Any]) {
        guard let subtype = json["subtype"] as? String else { return }
        if subtype == "init" {
            session.id = json["session_id"] as? String
            if let id = session.id {
                session.name = Self.sessionEntry(id: id, defaultDirectory: workingDirectory)?.name
            }
            session.model = json["model"] as? String
            let shortModel = session.model?
                .replacingOccurrences(of: "claude-", with: "")
                .components(separatedBy: "[").first ?? "claude"
            appendSystem("Session · \(shortModel)")
        }
    }

    private func handleAssistantEvent(_ json: [String: Any]) {
        guard let msgObj = json["message"] as? [String: Any],
              let content = msgObj["content"] as? [[String: Any]]
        else { return }

        for block in content {
            guard let blockType = block["type"] as? String else { continue }

            switch blockType {
            case "text":
                guard let text = block["text"] as? String else { continue }
                if let idx = currentAssistantIndex, idx < messages.count,
                   messages[idx].role == .assistant
                {
                    messages[idx].content = text
                    messages[idx].isStreaming = true
                } else {
                    let newIdx = messages.count
                    messages.append(ChatMessage(
                        role: .assistant, content: text, timestamp: Date(),
                        isStreaming: true, isCollapsed: false,
                        presentationKind: currentRunInteractionMode == .plan ? .plan : .standard
                    ))
                    currentAssistantIndex = newIdx
                }

            case "tool_use":
                // Finalize any streaming assistant text before tool use
                finalizeStreamingAssistant()

                let toolName = block["name"] as? String ?? "tool"
                if Self.shouldBlockTool(
                    name: toolName,
                    input: block["input"] as? [String: Any],
                    mode: currentRunInteractionMode
                ) {
                    abortBlockedToolAttempt(toolName: toolName, mode: currentRunInteractionMode)
                    return
                }
                var inputStr = ""
                if let input = block["input"] as? [String: Any],
                   let inputData = try? JSONSerialization.data(
                       withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: inputData, encoding: .utf8)
                {
                    inputStr = str
                }

                let summary = Self.toolSummary(name: toolName, input: block["input"] as? [String: Any])

                // Group consecutive tool calls of the same type into one card
                if let lastIdx = messages.indices.last,
                   messages[lastIdx].role == .toolUse,
                   messages[lastIdx].toolName == toolName
                {
                    // Increment counter in existing card
                    let count = (messages[lastIdx].toolCount ?? 1) + 1
                    messages[lastIdx].toolCount = count
                    messages[lastIdx].content = "\(summary) (\(count))"
                } else {
                    messages.append(ChatMessage(
                        role: .toolUse, content: summary, timestamp: Date(),
                        toolName: toolName, toolInput: inputStr,
                        isStreaming: false, isCollapsed: true
                    ))
                }

            case "tool_result":
                var resultText = ""
                if let text = block["content"] as? String {
                    resultText = text
                } else if let arr = block["content"] as? [[String: Any]] {
                    resultText = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                let display = resultText.count > 800
                    ? String(resultText.prefix(800)) + "…"
                    : resultText

                // Attach result to the last tool_use message
                if let lastToolIdx = messages.lastIndex(where: { $0.role == .toolUse }) {
                    messages[lastToolIdx].toolOutput = display
                } else {
                    messages.append(ChatMessage(
                        role: .toolResult, content: display, timestamp: Date(),
                        isStreaming: false, isCollapsed: true
                    ))
                }

            default:
                break
            }
        }
    }

    private func handleResultEvent(_ json: [String: Any]) {
        finalizeStreamingAssistant()
        isProcessing = false

        // Show errors
        if json["is_error"] as? Bool == true {
            if let errors = json["errors"] as? [String], !errors.isEmpty {
                appendSystem("\(AppStrings.errorPrefix) \(errors.joined(separator: ", "))")
            } else {
                appendSystem(AppStrings.unknownError)
            }
            return
        }

        session.turns += 1
        session.costUSD += json["total_cost_usd"] as? Double ?? 0
        session.durationMs += json["duration_ms"] as? Int ?? 0
    }

    // MARK: - Helpers

    private func finalizeStreamingAssistant() {
        let capturedIdx = currentAssistantIndex
        if let idx = capturedIdx, idx < messages.count {
            messages[idx].isStreaming = false
            let id = messages[idx].id
            let content = messages[idx].content
            enqueueMarkdownPreRender(messageId: id, content: content)
        }
        currentAssistantIndex = nil
    }

    private func abortBlockedToolAttempt(toolName: String, mode: ChatInteractionMode) {
        finalizeStreamingAssistant()
        if mode == .acceptEdits {
            pendingApprovalRequest = ChatApprovalRequest(
                toolName: toolName,
                prompt: currentRunPrompt,
                displayText: currentRunDisplayText
            )
        } else {
            appendSystem(Self.blockedToolMessage(toolName: toolName, mode: mode))
        }
        cancelInFlightWork()
        isProcessing = false
    }

    private func queuedDisplayText(for messageID: UUID, fallback: String) -> String {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return fallback }
        return messages[idx].content
    }

    func approvePendingApprovalRequest() {
        guard let request = pendingApprovalRequest else { return }
        pendingApprovalRequest = nil
        beginClaudeRun(
            userPrompt: request.prompt,
            displayText: request.displayText,
            mode: .send,
            interactionMode: .agent,
            includeIDEContext: currentRunIncludesIDEContext
        )
    }

    func dismissPendingApprovalRequest() {
        pendingApprovalRequest = nil
    }

    private func clearMarkdownPreRenderWork() {
        pendingMarkdownPreRenders.removeAll()
        markdownPreRenderTask?.cancel()
        markdownPreRenderTask = nil
    }

    private func enqueueMarkdownPreRender(messageId: UUID, content: String) {
        guard !content.isEmpty else { return }
        guard !ChatMarkdownPolicy.shouldSkipFullMarkdown(for: content) else { return }
        pendingMarkdownPreRenders.append((messageId, content))
        processMarkdownPreRenderQueueIfNeeded()
    }

    private func processMarkdownPreRenderQueueIfNeeded() {
        guard markdownPreRenderTask == nil, !pendingMarkdownPreRenders.isEmpty else { return }
        let (messageId, content) = pendingMarkdownPreRenders.removeFirst()
        markdownPreRenderTask = Task.detached(priority: .utility) { [weak self] in
            let attr = MarkdownBlockView.renderAttributedPreviewForBackground(content)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.markdownPreRenderTask = nil
                if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                    self.messages[idx].preRenderedMarkdown = attr
                    ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &self.messages)
                }
                self.processMarkdownPreRenderQueueIfNeeded()
            }
        }
    }

    private func enqueueMarkdownPreRenderForLastAssistantIfNeeded() {
        guard let lastIdx = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let m = messages[lastIdx]
        guard !m.isFromHistory else { return }
        enqueueMarkdownPreRender(messageId: m.id, content: m.content)
    }

    private func appendSystem(_ text: String) {
        messages.append(ChatMessage(
            role: .system, content: text, timestamp: Date(),
            isStreaming: false, isCollapsed: false
        ))
    }

    // MARK: - Tool Display Info

    static func toolIcon(for name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Edit": return "pencil.line"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Glob": return "folder.badge.magnifyingglass"  // custom fallback below
        case "Grep": return "magnifyingglass"
        case "WebSearch": return "globe"
        case "WebFetch": return "globe"
        case "ImageView": return "photo"
        case "Review": return "checklist"
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }
}

#if DEBUG
extension ClaudeHeadlessProvider {
    func testSetProcessing(_ isProcessing: Bool) {
        self.isProcessing = isProcessing
    }

    func testSetCurrentRunState(
        interactionMode: ChatInteractionMode = .agent,
        includeIDEContext: Bool = true,
        prompt: String = "",
        displayText: String = ""
    ) {
        currentRunInteractionMode = interactionMode
        currentRunIncludesIDEContext = includeIDEContext
        currentRunPrompt = prompt
        currentRunDisplayText = displayText
    }

    func testHandleAssistantEvent(_ json: [String: Any]) {
        handleAssistantEvent(json)
    }

    func testHandleResultEvent(_ json: [String: Any]) {
        handleResultEvent(json)
    }

    var testQueuedMessageCount: Int {
        messageQueue.count
    }
}
#endif

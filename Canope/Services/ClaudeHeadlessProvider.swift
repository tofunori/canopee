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
    private var outputBuffer = ""
    private var pendingLines: [String] = []
    private var throttleTask: Task<Void, Never>?
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
        throttleTask?.cancel()
        throttleTask = nil
        pendingLines.removeAll()
        outputBuffer = ""
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
        if let metadata = sessionMetadataIndex()[id], let cwd = metadata.cwd {
            return cwd
        }
        guard let jsonlURL = findSessionJSONLURL(id: id) else { return nil }
        return jsonlHeader(at: jsonlURL)?.cwd
    }

    /// Load conversation history from the JSONL file for a session.
    private nonisolated static func parseSessionHistory(id: String) -> [ChatMessage] {
        var result: [ChatMessage] = []
        loadSessionHistoryInto(id: id, messages: &result)
        return result
    }

    private nonisolated static func loadSessionHistoryInto(id: String, messages: inout [ChatMessage]) {
        // Search all project dirs for the session JSONL
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeDir, includingPropertiesForKeys: nil
        ) else { return }

        var jsonlURL: URL?
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                jsonlURL = candidate
                break
            }
        }
        guard let url = jsonlURL,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        // Only parse the tail of the file to avoid freezing on large sessions
        let allLines = content.components(separatedBy: "\n")
        let lines = allLines.suffix(20) // last ~20 JSONL entries
        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            guard type == "user" || type == "assistant" else { continue }
            guard let msg = json["message"] as? [String: Any] else { continue }
            let role = msg["role"] as? String ?? type
            let contentVal = msg["content"]

            if role == "user" {
                if let text = contentVal as? String, !text.isEmpty {
                    messages.append(ChatMessage(
                        role: .user, content: cleanedResumedUserMessage(text), timestamp: Date(),
                        isStreaming: false, isCollapsed: false, isFromHistory: true
                    ))
                } else if let blocks = contentVal as? [[String: Any]] {
                    let text = blocks.compactMap { b -> String? in
                        if b["type"] as? String == "text" { return b["text"] as? String }
                        return nil
                    }.joined(separator: "\n")
                    if !text.isEmpty {
                        messages.append(ChatMessage(
                            role: .user, content: cleanedResumedUserMessage(text), timestamp: Date(),
                            isStreaming: false, isCollapsed: false, isFromHistory: true
                        ))
                    }
                }
            } else if role == "assistant" {
                guard let blocks = contentVal as? [[String: Any]] else { continue }
                for block in blocks {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                        messages.append(ChatMessage(
                            role: .assistant, content: text, timestamp: Date(),
                            isStreaming: false, isCollapsed: false, isFromHistory: true
                        ))
                    } else if blockType == "tool_use" {
                        let toolName = block["name"] as? String ?? "tool"
                        let summary = Self.toolSummary(name: toolName, input: block["input"] as? [String: Any])
                        messages.append(ChatMessage(
                            role: .toolUse, content: summary, timestamp: Date(),
                            toolName: toolName,
                            isStreaming: false, isCollapsed: true
                        ))
                    }
                }
            }
        }
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
        appendSystem("Nouvelle conversation")
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
        let expectedPath = normalizedSessionPath(for: matchingDirectory)
        let metadataIndex = sessionMetadataIndex()

        let entries = sessionJSONLFiles().compactMap { url -> SessionEntry? in
            let sid = url.deletingPathExtension().lastPathComponent
            let metadata = metadataIndex[sid]
            let header = jsonlHeader(at: url)
            let cwdURL = metadata?.cwd ?? header?.cwd
            if let expectedPath, normalizedSessionPath(for: cwdURL) != expectedPath {
                return nil
            }

            let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let date = metadata?.date ?? fileDate
            let name = metadata?.name.isEmpty == false ? (metadata?.name ?? "") : (header?.title ?? "")
            let project = cwdURL?.lastPathComponent ?? ""
            return SessionEntry(id: sid, name: name, project: project, date: date, cwd: cwdURL)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        return Array(entries.prefix(limit))
    }

    private nonisolated static func normalizedSessionPath(for url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private struct SessionMetadata {
        let name: String
        let cwd: URL?
        let date: Date?
    }

    private struct JSONLHeader {
        let cwd: URL?
        let title: String
    }

    private nonisolated static func sessionMetadataIndex() -> [String: SessionMetadata] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }

        var result: [String: SessionMetadata] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String
            else { continue }

            let name = json["name"] as? String ?? ""
            let cwdString = json["cwd"] as? String ?? ""
            let cwd = cwdString.isEmpty ? nil : URL(fileURLWithPath: cwdString)
            let ts = json["startedAt"] as? Double ?? 0
            let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : nil
            result[sid] = SessionMetadata(name: name, cwd: cwd, date: date)
        }
        return result
    }

    private nonisolated static func sessionJSONLFiles() -> [URL] {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return projectDirs.flatMap { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ))?
            .filter { $0.pathExtension == "jsonl" } ?? []
        }
    }

    private nonisolated static func findSessionJSONLURL(id: String) -> URL? {
        sessionJSONLFiles().first { $0.deletingPathExtension().lastPathComponent == id }
    }

    private nonisolated static func jsonlHeader(at url: URL) -> JSONLHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 64 * 1024)
        guard let data, !data.isEmpty else { return nil }

        let content = String(decoding: data, as: UTF8.self)
        var cwd: URL?
        var title = ""

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = rawLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if cwd == nil, let cwdString = json["cwd"] as? String, !cwdString.isEmpty {
                cwd = URL(fileURLWithPath: cwdString)
            }

            if title.isEmpty, let lastPrompt = json["lastPrompt"] as? String, !lastPrompt.isEmpty {
                title = compactSessionTitle(lastPrompt)
            }

            if title.isEmpty,
               json["type"] as? String == "user",
               let message = json["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    title = compactSessionTitle(text)
                } else if let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { block -> String? in
                        guard block["type"] as? String == "text" else { return nil }
                        return block["text"] as? String
                    }.joined(separator: "\n")
                    if !text.isEmpty { title = compactSessionTitle(text) }
                }
            }

            if cwd != nil, !title.isEmpty { break }
        }

        return JSONLHeader(cwd: cwd, title: title)
    }

    private nonisolated static func compactSessionTitle(_ text: String, maxLength: Int = 90) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxLength else { return singleLine }
        return String(singleLine.prefix(maxLength - 1)) + "…"
    }

    private nonisolated static func sessionEntry(id: String, defaultDirectory: URL? = nil) -> SessionEntry? {
        let metadata = sessionMetadataIndex()[id]
        let header = findSessionJSONLURL(id: id).flatMap { jsonlHeader(at: $0) }
        let cwdURL = metadata?.cwd ?? header?.cwd ?? defaultDirectory
        let name = metadata?.name.isEmpty == false ? (metadata?.name ?? "") : (header?.title ?? "")
        let project = cwdURL?.lastPathComponent ?? ""
        return SessionEntry(id: id, name: name, project: project, date: metadata?.date, cwd: cwdURL)
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
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = sessionEntry(id: id, defaultDirectory: fallbackCwd)
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String, sid == id
            else { continue }

            json["name"] = trimmedName
            if json["cwd"] == nil, let cwd = existing?.cwd?.path {
                json["cwd"] = cwd
            }
            if json["startedAt"] == nil, let startedAt = existing?.date?.timeIntervalSince1970 {
                json["startedAt"] = startedAt * 1000
            }
            guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? updated.write(to: file, options: .atomic)
            return
        }

        var json: [String: Any] = ["sessionId": id]
        if !trimmedName.isEmpty { json["name"] = trimmedName }
        if let cwd = existing?.cwd?.path ?? fallbackCwd?.path {
            json["cwd"] = cwd
        }
        if let startedAt = existing?.date?.timeIntervalSince1970 {
            json["startedAt"] = startedAt * 1000
        }
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? updated.write(to: sessionsDir.appendingPathComponent("\(id).json"), options: .atomic)
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
        outputBuffer = ""
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

        readTask = Task.detached { [weak self] in
            let proc = Process()
            let cliPath = Self.findCLI("claude")
            proc.executableURL = URL(fileURLWithPath: cliPath)

            let prompt = Self.buildPromptForInteractionMode(
                trimmed,
                mode: interactionMode,
                includeIDEContext: includeIDEContext
            )
            var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                        "--model", model, "--effort", effort]
            switch mode {
            case .send:
                if useContinue {
                    args += ["--continue"]
                } else if let sid = resumeIdAtLaunch {
                    args += ["--resume", sid]
                }
            case .forkEdit(let sid):
                args += ["--resume", sid, "--fork-session"]
            }
            proc.currentDirectoryURL = cwd

            if !skipMcp {
                let mcpConfigPath = CanopeContextFiles.claudeIDEMcpConfigPaths[0]
                if FileManager.default.fileExists(atPath: mcpConfigPath) {
                    args += ["--mcp-config", mcpConfigPath]
                }
            }
            proc.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            await MainActor.run {
                ClaudeIDEBridgeService.shared.startIfNeeded()
                CanopeContextFiles.writeClaudeIDEMcpConfig()
            }
            for entry in CanopeContextFiles.terminalEnvironment {
                let parts = entry.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    env[String(parts[0])] = String(parts[1])
                }
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
        outputBuffer += text
        while let range = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<range.lowerBound])
            outputBuffer = String(outputBuffer[range.upperBound...])
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            pendingLines.append(line)
        }
        // Throttle: process pending lines at most every 150ms
        if throttleTask == nil {
            throttleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                let lines = self.pendingLines
                self.pendingLines.removeAll()
                self.throttleTask = nil
                for line in lines {
                    self.parseLine(line)
                }
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "system":
            handleSystemEvent(json)
        case "assistant":
            handleAssistantEvent(json)
        case "result":
            handleResultEvent(json)
        default:
            break
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

    nonisolated static func toolSummary(name: String, input: [String: Any]?) -> String {
        guard let input = input else { return name }
        switch name {
        case "Read":
            let path = (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
            return path
        case "Edit":
            let path = (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
            return path
        case "Write":
            let path = (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
            return path
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            return String(cmd.prefix(60))
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        case "WebSearch":
            return input["query"] as? String ?? ""
        default:
            return name
        }
    }

    nonisolated static func isMutatingTool(name: String, input: [String: Any]?) -> Bool {
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return true
        case "Bash":
            return true
        default:
            if let command = input?["command"] as? String {
                let lowered = command.lowercased()
                let mutatingHints = [
                    "rm ", "mv ", "cp ", "mkdir ", "touch ", "tee ",
                    "cat >", "sed -i", "python ", "python3 ",
                    "git commit", "git push", "apply_patch"
                ]
                return mutatingHints.contains(where: lowered.contains)
            }
            return false
        }
    }

    nonisolated static func isShellExecutionTool(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "bash"
            || lowered == "shell"
            || lowered.contains("exec_command")
            || lowered.contains("write_stdin")
            || lowered.contains("run_command")
            || lowered.contains("terminal")
    }

    nonisolated static func shouldBlockTool(name: String, input: [String: Any]?, mode: ChatInteractionMode) -> Bool {
        switch mode {
        case .agent:
            return false
        case .acceptEdits:
            return isMutatingTool(name: name, input: input) || isShellExecutionTool(name: name)
        case .plan:
            return isMutatingTool(name: name, input: input) || isShellExecutionTool(name: name)
        }
    }

    nonisolated static func blockedToolMessage(toolName: String, mode: ChatInteractionMode) -> String {
        switch mode {
        case .agent:
            return "L’action \(toolName) a ete bloquee."
        case .acceptEdits:
            return "Mode accept edits: l’action \(toolName) a ete bloquee en attendant ton approbation. L’approbation interactive n’est pas encore branchee."
        case .plan:
            return "\(AppStrings.mutatingActionBlockedPrefix) \(toolName) \(AppStrings.mutatingActionBlockedSuffix)"
        }
    }

    /// Reads the current IDE selection state and injects it as context before the user's message.
    nonisolated static func buildPromptWithIDEContext(
        _ userMessage: String,
        includeIDEContext: Bool = true
    ) -> String {
        guard includeIDEContext else {
            return userMessage
        }
        let selectionPath = CanopeContextFiles.ideSelectionStatePaths[0]
        guard let data = FileManager.default.contents(atPath: selectionPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return userMessage
        }

        let filePath = json["filePath"] as? String ?? ""
        let fileName = (filePath as NSString).lastPathComponent
        let trimmedLineText = (json["lineText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lineText = trimmedLineText.isEmpty ? nil : trimmedLineText
        let trimmedSelectionLineContext = (json["selectionLineContext"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectionLineContext = trimmedSelectionLineContext.isEmpty ? nil : trimmedSelectionLineContext
        let contextSuffix: String
        if let selectionLineContext {
            contextSuffix = """

            [Selected line context]
            \(selectionLineContext)
            [/Selected line context]
            """
        } else if let lineText {
            contextSuffix = """

            [Current line]
            \(lineText)
            [/Current line]
            """
        } else {
            contextSuffix = ""
        }

        let context = """
        [Canope IDE Context — current selection in "\(fileName)"]
        \(text)
        \(contextSuffix)
        [/Canope IDE Context]

        \(userMessage)
        """
        return context
    }

    nonisolated static func buildPromptForInteractionMode(
        _ userMessage: String,
        mode: ChatInteractionMode,
        includeIDEContext: Bool = true
    ) -> String {
        let promptWithContext = buildPromptWithIDEContext(
            userMessage,
            includeIDEContext: includeIDEContext
        )
        switch mode {
        case .agent:
            return promptWithContext
        case .acceptEdits:
            return """
            [Canope Accept Edits Mode]
            Tu es en mode accept edits.
            - N'applique aucune edition de fichier sans approbation explicite.
            - N'utilise pas Bash ni aucune commande shell.
            - N'utilise aucune action de terminal, d'execution ou avec effets de bord.
            - Propose les changements de facon concrete et ciblee.
            - Si une edition est appropriee et que la demande est claire, tente directement l'outil d'edition: le client demandera l'approbation inline.
            - N'ecris pas de message du type "j'attends ton approbation" ou "si tu veux, j'applique"; laisse l'UI d'approbation faire ce travail.
            - Une fois l'approbation accordee, applique seulement le changement valide, sans redemander la permission dans le chat.
            [/Canope Accept Edits Mode]

            \(promptWithContext)
            """
        case .plan:
            return """
            [Canope Plan Mode]
            Tu es en mode plan strict.
            - N'execute aucune edition de fichier.
            - N'utilise aucune commande mutante.
            - Ne lance aucune action avec effets de bord.
            - Produis seulement un plan structure avec: Objectif, Changements proposes, Validation, Risques.
            - Si une information manque, formule des hypotheses explicites au lieu d'agir.
            [/Canope Plan Mode]

            \(promptWithContext)
            """
        }
    }

    nonisolated static func findCLI(_ name: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/\(NSUserName())"
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/bin/env"
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

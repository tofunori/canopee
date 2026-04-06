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

    private struct QueuedMessage {
        let messageID: UUID
        let prompt: String
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
                self?.appendSystem("Session reprise : \(id.prefix(12))…")
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
                        role: .user, content: text, timestamp: Date(),
                        isStreaming: false, isCollapsed: false, isFromHistory: true
                    ))
                } else if let blocks = contentVal as? [[String: Any]] {
                    let text = blocks.compactMap { b -> String? in
                        if b["type"] as? String == "text" { return b["text"] as? String }
                        return nil
                    }.joined(separator: "\n")
                    if !text.isEmpty {
                        messages.append(ChatMessage(
                            role: .user, content: text, timestamp: Date(),
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

        beginClaudeRun(userPrompt: trimmed, mode: .forkEdit(sessionId: sid))
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

    /// Resume the most recent session for the provided project root only.
    func resumeLastSession(matchingDirectory: URL? = nil) {
        cancelInFlightWork()
        clearMarkdownPreRenderWork()
        isProcessing = false
        currentAssistantIndex = nil

        let directory = matchingDirectory ?? workingDirectory
        guard let latest = Self.listSessions(limit: 1, matchingDirectory: directory).first else {
            appendSystem("Aucune session trouvée pour ce dossier")
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

    /// Rename a session by updating the JSON file in ~/.claude/sessions/
    nonisolated static func renameSession(id: String, name: String) {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String, sid == id
            else { continue }

            json["name"] = name
            guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? updated.write(to: file, options: .atomic)
            return
        }
    }

    /// Send with a different display text than what's sent to Claude
    func sendMessageWithDisplay(displayText: String, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isProcessing {
            enqueueUserMessage(displayText: displayText, prompt: trimmed)
            return
        }

        if !isConnected { start() }

        appendUserMessage(displayText)

        beginClaudeRun(userPrompt: trimmed, mode: .send)
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Queue if already processing
        if isProcessing {
            enqueueUserMessage(displayText: trimmed, prompt: trimmed)
            return
        }

        if !isConnected { start() }

        appendUserMessage(trimmed)

        beginClaudeRun(userPrompt: trimmed, mode: .send)
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

    private func enqueueUserMessage(displayText: String, prompt: String) {
        let message = ChatMessage(
            role: .user,
            content: displayText,
            timestamp: Date(),
            isStreaming: false,
            isCollapsed: false,
            queuePosition: messageQueue.count + 1
        )
        messages.append(message)
        messageQueue.append(QueuedMessage(messageID: message.id, prompt: prompt))
        refreshQueuedMessagePositions()
    }

    private func refreshQueuedMessagePositions() {
        for (offset, queued) in messageQueue.enumerated() {
            guard let idx = messages.firstIndex(where: { $0.id == queued.messageID }) else { continue }
            messages[idx].queuePosition = offset + 1
        }
    }

    /// Single entry point for `claude` CLI runs (normal send and fork-edit).
    private func beginClaudeRun(userPrompt trimmed: String, mode: ClaudeLaunchMode) {
        cancelInFlightWork()

        isProcessing = true
        currentAssistantIndex = nil
        outputBuffer = ""

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

            let prompt = Self.buildPromptWithIDEContext(trimmed)
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
                    self?.appendSystem("Erreur : \(error.localizedDescription)")
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
        beginClaudeRun(userPrompt: next.prompt, mode: .send)
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
                        isStreaming: true, isCollapsed: false
                    ))
                    currentAssistantIndex = newIdx
                }

            case "tool_use":
                // Finalize any streaming assistant text before tool use
                finalizeStreamingAssistant()

                let toolName = block["name"] as? String ?? "tool"
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
                appendSystem("Erreur : \(errors.joined(separator: ", "))")
            } else {
                appendSystem("Erreur inconnue")
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

    /// Reads the current IDE selection state and injects it as context before the user's message.
    nonisolated static func buildPromptWithIDEContext(_ userMessage: String) -> String {
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

        let context = """
        [Canope IDE Context — current selection in "\(fileName)"]
        \(text)
        [/Canope IDE Context]

        \(userMessage)
        """
        return context
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
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }
}

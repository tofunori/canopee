import Foundation
import Combine

// MARK: - Common Chat Models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var toolName: String?
    var toolInput: String?
    var toolOutput: String?
    var isStreaming: Bool
    var isCollapsed: Bool

    enum Role: Equatable {
        case user
        case assistant
        case toolUse
        case toolResult
        case system
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming
            && lhs.isCollapsed == rhs.isCollapsed
    }
}

struct SessionInfo: Equatable {
    var id: String?
    var model: String?
    var costUSD: Double = 0
    var turns: Int = 0
    var durationMs: Int = 0
}

// MARK: - Provider Protocol

/// Abstracts the headless CLI process (Claude, Codex, etc.)
@MainActor
protocol AIHeadlessProvider: ObservableObject {
    var messages: [ChatMessage] { get set }
    var isProcessing: Bool { get set }
    var isConnected: Bool { get }
    var session: SessionInfo { get }
    var providerName: String { get }
    var providerIcon: String { get } // SF Symbol name

    func start()
    func stop()
    func sendMessage(_ text: String)
}

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
    private let workingDirectory: URL
    private var currentAssistantIndex: Int?
    private var useContinueForNextMessage = false
    private var resumeWorkingDirectory: URL?  // override cwd when resuming a session from another project

    init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: - Lifecycle

    func start() {
        isConnected = true
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        if let proc = currentProcess, proc.isRunning { proc.terminate() }
        currentProcess = nil
        isConnected = false
        isProcessing = false
    }

    /// Resume a specific session by ID. Loads message history and sets --resume for next message.
    func resumeSession(id: String) {
        // Clean up any running process
        readTask?.cancel()
        readTask = nil
        if let old = currentProcess, old.isRunning { old.terminate() }
        currentProcess = nil
        isProcessing = false
        currentAssistantIndex = nil
        outputBuffer = ""

        session.id = id
        messages.removeAll()

        // Find the session's original cwd so --resume works
        resumeWorkingDirectory = Self.findSessionCwd(id: id)

        loadSessionHistory(id: id)
        appendSystem("Session reprise : \(id.prefix(12))…")
    }

    private static func findSessionCwd(id: String) -> URL? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return nil }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String, sid == id,
                  let cwd = json["cwd"] as? String
            else { continue }
            let url = URL(fileURLWithPath: cwd)
            if FileManager.default.fileExists(atPath: cwd) { return url }
        }
        return nil
    }

    /// Load conversation history from the JSONL file for a session.
    private func loadSessionHistory(id: String) {
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

        let lines = content.components(separatedBy: "\n")
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
                        isStreaming: false, isCollapsed: false
                    ))
                } else if let blocks = contentVal as? [[String: Any]] {
                    let text = blocks.compactMap { b -> String? in
                        if b["type"] as? String == "text" { return b["text"] as? String }
                        return nil
                    }.joined(separator: "\n")
                    if !text.isEmpty {
                        messages.append(ChatMessage(
                            role: .user, content: text, timestamp: Date(),
                            isStreaming: false, isCollapsed: false
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
                            isStreaming: false, isCollapsed: false
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

    /// Resume the most recent session.
    func resumeLastSession() {
        readTask?.cancel()
        readTask = nil
        if let old = currentProcess, old.isRunning { old.terminate() }
        currentProcess = nil
        isProcessing = false

        useContinueForNextMessage = true
        session.id = nil
        appendSystem("Mode reprise activé — ton prochain message reprendra la dernière session")
    }

    /// List available sessions from ~/.claude/sessions/
    static func listSessions(limit: Int = 15) -> [SessionEntry] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
            .prefix(limit)

        return jsonFiles.compactMap { url -> SessionEntry? in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String
            else { return nil }

            let name = json["name"] as? String ?? ""
            let cwd = (json["cwd"] as? String ?? "")
            let project = (cwd as NSString).lastPathComponent
            let ts = json["startedAt"] as? Double ?? 0
            let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : nil

            return SessionEntry(id: sid, name: name, project: project, date: date)
        }
    }

    struct SessionEntry: Identifiable {
        let id: String
        let name: String
        let project: String
        let date: Date?

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

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Debug: show state
        if !isConnected {
            appendSystem("⚠ isConnected=false, calling start()")
            start()
        }
        if isProcessing {
            appendSystem("⚠ Process en cours, annulation du précédent")
        }

        messages.append(ChatMessage(
            role: .user, content: trimmed, timestamp: Date(),
            isStreaming: false, isCollapsed: false
        ))

        // Kill any previous process still running
        readTask?.cancel()
        readTask = nil
        if let old = currentProcess, old.isRunning { old.terminate() }
        currentProcess = nil

        isProcessing = true
        currentAssistantIndex = nil
        outputBuffer = ""

        // Launch a new claude process for this message
        let proc = Process()
        let cliPath = Self.findCLI("claude")
        proc.executableURL = URL(fileURLWithPath: cliPath)

        // Build the prompt with IDE context injected
        let prompt = Self.buildPromptWithIDEContext(trimmed)

        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--model", selectedModel, "--effort", selectedEffort]
        // Resume: --continue for last session, --resume for current session
        if useContinueForNextMessage {
            args += ["--continue"]
            useContinueForNextMessage = false
        } else if let sid = session.id {
            args += ["--resume", sid]
        }
        // Connect to Canope's IDE bridge MCP server
        let mcpConfigPath = CanopeContextFiles.claudeIDEMcpConfigPaths[0]
        if FileManager.default.fileExists(atPath: mcpConfigPath) {
            args += ["--mcp-config", mcpConfigPath]
        }
        proc.arguments = args
        // Use the session's original cwd for resume, otherwise use the default
        proc.currentDirectoryURL = resumeWorkingDirectory ?? workingDirectory
        if resumeWorkingDirectory != nil {
            resumeWorkingDirectory = nil // only use once, subsequent messages stay in this session
        }

        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        // Ensure IDE bridge is running and MCP config is written
        ClaudeIDEBridgeService.shared.startIfNeeded()
        CanopeContextFiles.writeClaudeIDEMcpConfig()
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
        currentProcess = proc

        do {
            try proc.run()
        } catch {
            appendSystem("Erreur launch : \(error.localizedDescription)")
            isProcessing = false
            return
        }

        // Read stdout and stderr using FileHandle callbacks (more reliable than Task.detached loops)
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { self?.appendSystem("stderr: \(t)") }
            }
        }

        readTask = Task.detached { [weak self] in
            // Read stdout line by line
            while true {
                let data = stdoutHandle.availableData
                if data.isEmpty { break }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                await MainActor.run { [weak self] in
                    self?.handleOutput(text)
                }
            }

            // Process finished — clean up
            stderrHandle.readabilityHandler = nil
            await MainActor.run { [weak self] in
                self?.isProcessing = false
                // Finalize streaming
                if let idx = self?.currentAssistantIndex, let count = self?.messages.count,
                   idx < count
                {
                    self?.messages[idx].isStreaming = false
                }
            }
        }
    }

    // MARK: - Output Parsing

    private func handleOutput(_ text: String) {
        outputBuffer += text
        while let range = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<range.lowerBound])
            outputBuffer = String(outputBuffer[range.upperBound...])
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            parseLine(line)
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

                // Extract a short summary for the tool card
                let summary = Self.toolSummary(name: toolName, input: block["input"] as? [String: Any])

                messages.append(ChatMessage(
                    role: .toolUse, content: summary, timestamp: Date(),
                    toolName: toolName, toolInput: inputStr,
                    isStreaming: false, isCollapsed: true
                ))

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
        if let idx = currentAssistantIndex, idx < messages.count {
            messages[idx].isStreaming = false
        }
        currentAssistantIndex = nil
    }

    private func appendSystem(_ text: String) {
        messages.append(ChatMessage(
            role: .system, content: text, timestamp: Date(),
            isStreaming: false, isCollapsed: false
        ))
    }

    static func toolSummary(name: String, input: [String: Any]?) -> String {
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
    static func buildPromptWithIDEContext(_ userMessage: String) -> String {
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

    static func findCLI(_ name: String) -> String {
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

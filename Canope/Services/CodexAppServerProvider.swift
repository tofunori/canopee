import Combine
import Foundation
import SwiftUI

// MARK: - Codex app-server JSON-RPC (stdio JSONL)

/// Single-session JSON-RPC client for `codex app-server --listen stdio://`.
private final class CodexAppServerRPCSession: @unchecked Sendable {
    private let lock = NSLock()
    private var nextRequestID = 1
    /// Success payloads are JSON-encoded `result` (Sendable `Data`).
    private var pending: [Int: (Result<Data?, NSError>) -> Void] = [:]
    private var buffer = Data()
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stdinHandle: FileHandle?

    /// Params are JSON-encoded dictionary (`Data`) for Swift 6 cross-isolation safety.
    var onNotification: (@Sendable (String, Data) -> Void)?

    func startProcess(arguments: [String], environment: [String: String]) throws {
        guard process == nil else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: arguments[0])
        proc.arguments = Array(arguments.dropFirst())
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        proc.environment = env

        let out = Pipe()
        let input = Pipe()
        proc.standardOutput = out
        proc.standardInput = input
        proc.standardError = Pipe()

        try proc.run()
        process = proc
        stdoutHandle = out.fileHandleForReading
        stdinHandle = input.fileHandleForWriting

        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { return }
            self.appendAndDispatch(chunk)
        }
    }

    func terminate() {
        stdoutHandle?.readabilityHandler = nil
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
        stdoutHandle = nil
        stdinHandle = nil
        lock.lock()
        let waiters = pending
        pending.removeAll()
        lock.unlock()
        for (_, w) in waiters {
            w(.failure(NSError(domain: "CodexAppServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "cancelled"])))
        }
    }

    private func appendAndDispatch(_ chunk: Data) {
        buffer.append(chunk)
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { continue }
            dispatchLine(line)
        }
    }

    private func dispatchLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let idNum = jsonInt(obj["id"]) {
            lock.lock()
            let waiter = pending.removeValue(forKey: idNum)
            lock.unlock()
            if let waiter {
                if let err = obj["error"] as? [String: Any] {
                    let msg = (err["message"] as? String) ?? String(describing: err)
                    waiter(.failure(NSError(domain: "CodexAppServer", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])))
                } else {
                    waiter(.success(encodeJSONRPCResult(obj["result"])))
                }
            }
            return
        }

        if let method = obj["method"] as? String {
            let params = obj["params"] as? [String: Any] ?? [:]
            let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            onNotification?(method, paramsData)
        }
    }

    func call(method: String, params: [String: Any], requestId: Int? = nil) async throws -> Any? {
        let id: Int = lock.withLock {
            if let requestId { return requestId }
            let i = nextRequestID
            nextRequestID += 1
            return i
        }
        let payload: [String: Any] = ["method": method, "id": id, "params": params]
        guard let payloadBytes = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: payloadBytes, encoding: .utf8)
        else {
            throw NSError(domain: "CodexAppServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encode failed"])
        }
        line.append("\n")
        guard let stdin = stdinHandle else {
            throw NSError(domain: "CodexAppServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "No stdin"])
        }

        let resultData: Data? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            lock.lock()
            pending[id] = { (result: Result<Data?, NSError>) in
                switch result {
                case .success(let payload):
                    cont.resume(returning: payload)
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
            lock.unlock()
            stdin.write(Data(line.utf8))
        }
        return try decodeJSONRPCResult(resultData)
    }

    func notify(method: String, params: [String: Any]) throws {
        let payload: [String: Any] = ["method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        stdinHandle?.write(Data(line.utf8))
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let i as Int: return i
    case let d as Double: return Int(d)
    case let n as NSNumber: return n.intValue
    default: return nil
    }
}

/// JSON-RPC `result` field encoded as UTF-8 data (nullable JSON values use `null`).
private func encodeJSONRPCResult(_ value: Any?) -> Data? {
    guard let value else {
        return Data("null".utf8)
    }
    if value is NSNull {
        return Data("null".utf8)
    }
    if JSONSerialization.isValidJSONObject(value) {
        return try? JSONSerialization.data(withJSONObject: value)
    }
    return try? JSONSerialization.data(withJSONObject: [value])
}

private func decodeJSONRPCResult(_ data: Data?) throws -> Any? {
    guard let data, !data.isEmpty else { return nil }
    let obj = try JSONSerialization.jsonObject(with: data)
    if obj is NSNull { return nil }
    return obj
}

// MARK: - Codex headless provider (app-server)

@MainActor
final class CodexAppServerProvider: ObservableObject, AIHeadlessProvider {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var isConnected = false
    @Published var session = SessionInfo()
    @Published var selectedModel: String = "gpt-5.4"
    @Published var selectedEffort: String = "medium"

    let providerName = "Codex"
    let providerIcon = "chevron.left.forwardslash.chevron.right"

    static let defaultModels = ["gpt-5.4", "gpt-5.3-codex", "gpt-5.2"]
    static let defaultEfforts = ["low", "medium", "high"]

    private var workingDirectory: URL
    private var resumeWorkingDirectory: URL?
    private var rpc: CodexAppServerRPCSession?
    private var initialized = false
    private var currentThreadId: String?
    private var currentTurnId: String?
    private var currentAssistantMessageIndex: Int?
    private var currentAgentItemId: String?
    private var lastRetryStatusMessage: String?
    private var pendingMarkdown: [(UUID, String)] = []
    private var markdownTask: Task<Void, Never>?

    init(workingDirectory: URL? = nil) {
        if let wd = workingDirectory {
            self.workingDirectory = wd
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            self.workingDirectory = cwd == "/"
                ? FileManager.default.homeDirectoryForCurrentUser
                : URL(fileURLWithPath: cwd)
        }
    }

    func updateWorkingDirectory(_ url: URL) {
        workingDirectory = url
    }

    var workingDirectoryURL: URL { resumeWorkingDirectory ?? workingDirectory }

    func start() {
        isConnected = true
        Task { await ensureSession() }
    }

    func stop() {
        Task { await interruptIfNeeded() }
        isProcessing = false
        if let idx = currentAssistantMessageIndex, idx < messages.count {
            messages[idx].isStreaming = false
        }
        currentAssistantMessageIndex = nil
        currentAgentItemId = nil
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !isConnected { start() }
        Task { await sendUserMessage(trimmed, display: trimmed) }
    }

    func sendMessageWithDisplay(displayText: String, prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if !isConnected { start() }
        Task { await sendUserMessage(p, display: displayText) }
    }

    // MARK: - Connection

    private func ensureSession() async {
        if !initialized {
            await connectAndHandshake()
        }
    }

    private func ensureConnected() async {
        if !initialized {
            await connectAndHandshake()
        }
    }

    private func connectAndHandshake() async {
        ClaudeIDEBridgeService.shared.startIfNeeded()
        CanopeContextFiles.writeClaudeIDEMcpConfig()

        let rpcSession = CodexAppServerRPCSession()
        rpcSession.onNotification = { [weak self] method, paramsData in
            Task { @MainActor in
                let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
                self?.handleNotification(method: method, params: params)
            }
        }
        self.rpc = rpcSession

        let args = Self.buildAppServerArguments(bridgeURL: Self.resolvedBridgeURL())

        do {
            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            for entry in CanopeContextFiles.terminalEnvironment {
                let parts = entry.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    env[String(parts[0])] = String(parts[1])
                }
            }
            try rpcSession.startProcess(arguments: Self.codexLaunchArguments() + args, environment: env)

            _ = try await rpcSession.call(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "canope_native",
                        "title": "Canope",
                        "version": "1.0.0",
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                    ] as [String: Any],
                ],
                requestId: 0
            )
            try rpcSession.notify(method: "initialized", params: [:])
            initialized = true

            await refreshModels(rpc: rpcSession)
        } catch {
            rpcSession.terminate()
            rpc = nil
            appendSystem("Codex: \(error.localizedDescription)")
            isConnected = false
        }
    }

    private func refreshModels(rpc: CodexAppServerRPCSession) async {
        do {
            if let result = try await rpc.call(method: "model/list", params: ["includeHidden": false]) as? [String: Any],
               let data = result["data"] as? [[String: Any]] {
                let ids = data.compactMap { $0["id"] as? String }
                if !ids.isEmpty {
                    selectedModel = ids.contains(selectedModel) ? selectedModel : ids[0]
                    // published via @Published — store in a local cache for chatAvailableModels
                    Self.cachedModelList = ids
                }
            }
        } catch {
            Self.cachedModelList = nil
        }
    }

    private static var cachedModelList: [String]?

    private func interruptIfNeeded() async {
        guard let rpc, let tid = currentThreadId, let turn = currentTurnId else { return }
        _ = try? await rpc.call(
            method: "turn/interrupt",
            params: ["threadId": tid, "turnId": turn]
        )
    }

    // MARK: - Send flow

    private func sendUserMessage(_ prompt: String, display: String) async {
        await ensureConnected()
        guard let rpc else { return }

        let fullPrompt = Self.buildPromptWithIDEContext(prompt)
        messages.append(
            ChatMessage(
                role: .user,
                content: display,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
        )

        isProcessing = true
        currentAssistantMessageIndex = nil
        currentAgentItemId = nil
        lastRetryStatusMessage = nil

        do {
            if currentThreadId == nil {
                let cwd = workingDirectoryURL.path
                let result = try await rpc.call(
                    method: "thread/start",
                    params: [
                        "model": selectedModel,
                        "cwd": cwd,
                        "approvalPolicy": "never",
                        "sandbox": "workspace-write",
                        "serviceName": "canope",
                    ]
                ) as? [String: Any]
                if let thread = result?["thread"] as? [String: Any],
                   let id = thread["id"] as? String {
                    currentThreadId = id
                    session.id = id
                    session.name = thread["name"] as? String
                    session.turns = 0
                }
            }

            guard let threadId = currentThreadId else {
                throw NSError(domain: "CodexAppServer", code: 10, userInfo: [NSLocalizedDescriptionKey: "No thread"])
            }

            let turnParams: [String: Any] = [
                "threadId": threadId,
                "input": [["type": "text", "text": fullPrompt]],
                "cwd": workingDirectoryURL.path,
                "model": selectedModel,
                "effort": selectedEffort,
                "approvalPolicy": "never",
                "sandboxPolicy": [
                    "type": "workspaceWrite",
                    "writableRoots": [workingDirectoryURL.path],
                    "networkAccess": true,
                ],
            ]
            _ = try await rpc.call(method: "turn/start", params: turnParams)
            session.turns += 1
        } catch {
            appendSystem("Codex: \(error.localizedDescription)")
            isProcessing = false
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let tid = turn["id"] as? String {
                currentTurnId = tid
            }
        case "item/started":
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String {
                if type == "agentMessage" {
                    let iid = (item["id"] as? String) ?? UUID().uuidString
                    currentAgentItemId = iid
                    let msg = ChatMessage(
                        role: .assistant,
                        content: "",
                        timestamp: Date(),
                        isStreaming: true,
                        isCollapsed: false
                    )
                    messages.append(msg)
                    currentAssistantMessageIndex = messages.count - 1
                } else if type == "mcpToolCall" {
                    let name = (item["tool"] as? String) ?? "mcp"
                    let summary = (item["server"] as? String).map { "\($0) · \(name)" } ?? name
                    messages.append(
                        ChatMessage(
                            role: .toolUse,
                            content: summary,
                            timestamp: Date(),
                            toolName: name,
                            toolInput: Self.jsonString(item["arguments"]),
                            isStreaming: false,
                            isCollapsed: true
                        )
                    )
                }
            }
        case "item/agentMessage/delta":
            let delta = extractDeltaText(params) ?? ""
            guard !delta.isEmpty, let idx = currentAssistantMessageIndex, idx < messages.count else { return }
            messages[idx].content += delta
            messages[idx].isStreaming = true
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               (item["type"] as? String) == "agentMessage",
               let idx = currentAssistantMessageIndex, idx < messages.count {
                messages[idx].isStreaming = false
                enqueueMarkdownPreRender(for: messages[idx].id, text: messages[idx].content)
                currentAssistantMessageIndex = nil
                currentAgentItemId = nil
            }
        case "turn/completed":
            if let idx = currentAssistantMessageIndex, idx < messages.count {
                messages[idx].isStreaming = false
                enqueueMarkdownPreRender(for: messages[idx].id, text: messages[idx].content)
                currentAssistantMessageIndex = nil
            }
            isProcessing = false
            currentTurnId = nil
            lastRetryStatusMessage = nil
        case "error":
            let errorPayload = params["error"] as? [String: Any]
            let message = (errorPayload?["message"] as? String)
                ?? (params["message"] as? String)
                ?? "Erreur Codex"
            let details = errorPayload?["additionalDetails"] as? String
            let rendered = [message, details]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n")
            let willRetry = params["willRetry"] as? Bool ?? false

            if !willRetry || lastRetryStatusMessage != rendered {
                appendSystem(rendered)
            }

            if willRetry {
                lastRetryStatusMessage = rendered
            } else {
                lastRetryStatusMessage = nil
                isProcessing = false
                currentTurnId = nil
            }
        default:
            break
        }
    }

    private func extractDeltaText(_ params: [String: Any]) -> String? {
        if let s = params["delta"] as? String { return s }
        if let s = params["text"] as? String { return s }
        if let s = params["textDelta"] as? String { return s }
        return nil
    }

    private func appendSystem(_ text: String) {
        messages.append(
            ChatMessage(
                role: .system,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
        )
    }

    private func enqueueMarkdownPreRender(for id: UUID, text: String) {
        pendingMarkdown.append((id, text))
        scheduleMarkdownPreRender()
    }

    private func scheduleMarkdownPreRender() {
        markdownTask?.cancel()
        markdownTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run { [weak self] in
                self?.flushMarkdownPreRender()
            }
        }
    }

    private func flushMarkdownPreRender() {
        guard !pendingMarkdown.isEmpty else { return }
        let batch = pendingMarkdown
        pendingMarkdown.removeAll()
        Task.detached { [weak self] in
            var results: [(UUID, AttributedString)] = []
            for (id, text) in batch {
                let attr = await ChatMessage.attributedPreview(for: text)
                results.append((id, attr))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, attr) in results {
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        self.messages[idx].preRenderedMarkdown = attr
                    }
                }
            }
        }
    }

    private static func jsonString(_ obj: Any?) -> String? {
        guard let obj else { return nil }
        if let s = obj as? String { return s }
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: d, encoding: .utf8)
        else { return String(describing: obj) }
        return str
    }

    // MARK: - CLI

    nonisolated static func findCodexCLI() -> String {
        let preferred = [
            "~/.local/bin/codex",
            "/Users/\(NSUserName())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let p = ExecutableLocator.find("codex", preferredPaths: preferred) {
            return p
        }
        return "/usr/bin/env"
    }

    /// Executable + optional `codex` arg when using `/usr/bin/env`.
    nonisolated static func codexLaunchArguments() -> [String] {
        let path = findCodexCLI()
        if path == "/usr/bin/env" {
            return ["/usr/bin/env", "codex"]
        }
        return [path]
    }

    private static func resolvedBridgeURL() -> String {
        if let v = ProcessInfo.processInfo.environment["CANOPE_IDE_BRIDGE_URL"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["CANOPE_CLAUDE_IDE_BRIDGE_URL"], !v.isEmpty { return v }
        return CanopeContextFiles.claudeIDEBridgeURL
    }

    /// Arguments after executable for `codex app-server` with Canope MCP bridge.
    nonisolated static func buildAppServerArguments(bridgeURL: String) -> [String] {
        let dev = ClaudeCLIWrapperService.canopeCodexDeveloperInstructions()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let argsArr = ["-y", "mcp-remote", bridgeURL, "--transport", "sse-only"]
        let argsToml = (try? JSONSerialization.data(withJSONObject: argsArr))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return [
            "app-server",
            "--listen", "stdio://",
            "-c", "instructions=\"\(dev)\"",
            "-c", "developer_instructions=\"\(dev)\"",
            "-c", "mcp_servers.canope.type=\"stdio\"",
            "-c", "mcp_servers.canope.command=\"npx\"",
            "-c", "mcp_servers.canope.args=\(argsToml)",
        ]
    }

    nonisolated static func buildPromptWithIDEContext(_ userMessage: String) -> String {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return userMessage
        }
        let filePath = json["filePath"] as? String ?? ""
        let fileName = (filePath as NSString).lastPathComponent
        return """
        [Canope IDE Context — current selection in "\(fileName)")]
        \(text)
        [/Canope IDE Context]

        \(userMessage)
        """
    }
}

// MARK: - HeadlessChatProviding

extension CodexAppServerProvider: HeadlessChatProviding {
    var chatWorkingDirectory: URL { workingDirectoryURL }

    var chatSessionDisplayName: String {
        let trimmed = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return session.id == nil ? "Nouvelle conversation" : "Conversation"
    }

    var chatCanRenameCurrentSession: Bool { session.id != nil }

    var chatAvailableModels: [String] {
        if let list = Self.cachedModelList, !list.isEmpty { return list }
        return Self.defaultModels
    }

    var chatAvailableEfforts: [String] { Self.defaultEfforts }

    var chatSelectedModel: String {
        get { selectedModel }
        set { selectedModel = newValue }
    }

    var chatSelectedEffort: String {
        get { selectedEffort }
        set { selectedEffort = newValue }
    }

    func newChatSession() {
        Task {
            await disconnectAndReset()
            appendSystem("Nouvelle conversation")
        }
    }

    func resumeLastChatSession(matchingDirectory: URL?) {
        Task { await resumeFromList(matchingDirectory: matchingDirectory ?? workingDirectory) }
    }

    func resumeChatSession(id: String) {
        Task { await resumeThread(id: id) }
    }

    func renameCurrentChatSession(to name: String) {
        guard let tid = session.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.name = trimmed.isEmpty ? nil : trimmed
        Task {
            _ = try? await rpc?.call(
                method: "thread/name/set",
                params: ["threadId": tid, "name": trimmed]
            )
        }
    }

    func editAndResendLastUser(newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tid = currentThreadId else {
            sendMessage(trimmed)
            return
        }
        Task {
            _ = try? await rpc?.call(method: "thread/rollback", params: ["threadId": tid, "numTurns": 1])
            if let lastUser = messages.lastIndex(where: { $0.role == .user }) {
                messages.removeSubrange(lastUser...)
            }
            await sendUserMessage(trimmed, display: trimmed)
        }
    }

    func listChatSessions(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] {
        Self.ephemeralThreadList(limit: limit, matchingDirectory: matchingDirectory)
    }

    static func renameChatSession(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            try? await Self.ephemeralRename(threadId: id, name: trimmed)
        }
    }

    static func toolIconName(for toolName: String) -> String {
        ClaudeHeadlessProvider.toolIcon(for: toolName)
    }

    // MARK: - Private session helpers

    private func disconnectAndReset() async {
        rpc?.terminate()
        rpc = nil
        initialized = false
        currentThreadId = nil
        currentTurnId = nil
        currentAssistantMessageIndex = nil
        lastRetryStatusMessage = nil
        session = SessionInfo()
        messages.removeAll()
    }

    private func resumeThread(id: String) async {
        await disconnectAndReset()
        await connectAndHandshake()
        guard let rpc else { return }
        do {
            _ = try await rpc.call(method: "thread/resume", params: ["threadId": id])
            currentThreadId = id
            session.id = id
            appendSystem("Session reprise : \(id.prefix(12))…")
        } catch {
            appendSystem("Reprise impossible : \(error.localizedDescription)")
        }
    }

    private func resumeFromList(matchingDirectory: URL) async {
        await disconnectAndReset()
        await connectAndHandshake()
        guard let rpc else { return }
        do {
            let params: [String: Any] = [
                "limit": 1,
                "sortKey": "updated_at",
                "cwd": matchingDirectory.path,
                "sourceKinds": ["appServer", "cli", "vscode", "exec"],
            ]
            if let res = try await rpc.call(method: "thread/list", params: params) as? [String: Any],
               let data = res["data"] as? [[String: Any]],
               let first = data.first,
               let id = first["id"] as? String {
                _ = try await rpc.call(method: "thread/resume", params: ["threadId": id])
                currentThreadId = id
                session.id = id
                session.name = first["name"] as? String
                appendSystem("Session reprise")
            } else {
                appendSystem("Aucune session trouvée pour ce dossier")
            }
        } catch {
            appendSystem("Erreur : \(error.localizedDescription)")
        }
    }

    private static func ephemeralRename(threadId: String, name: String) async throws {
        await MainActor.run {
            ClaudeIDEBridgeService.shared.startIfNeeded()
            CanopeContextFiles.writeClaudeIDEMcpConfig()
        }
        let args = buildAppServerArguments(bridgeURL: resolvedBridgeStatic())
        let session = CodexAppServerRPCSession()
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        for entry in CanopeContextFiles.terminalEnvironment {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        try session.startProcess(arguments: codexLaunchArguments() + args, environment: env)
        _ = try await session.call(
            method: "initialize",
            params: [
                "clientInfo": ["name": "canope_rename", "title": "Canope", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true] as [String: Any],
            ],
            requestId: 0
        )
        try session.notify(method: "initialized", params: [:])
        _ = try await session.call(
            method: "thread/name/set",
            params: ["threadId": threadId, "name": name]
        )
        session.terminate()
    }

    nonisolated static func ephemeralThreadList(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] {
        final class Box: @unchecked Sendable {
            var rows: [ChatSessionListItem] = []
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task {
            box.rows = await ephemeralThreadListAsync(limit: limit, matchingDirectory: matchingDirectory)
            sem.signal()
        }
        sem.wait()
        return box.rows
    }

    private static func ephemeralThreadListAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem] {
        await MainActor.run {
            ClaudeIDEBridgeService.shared.startIfNeeded()
            CanopeContextFiles.writeClaudeIDEMcpConfig()
        }
        let args = buildAppServerArguments(bridgeURL: resolvedBridgeStatic())
        let rpcSession = CodexAppServerRPCSession()
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        for entry in CanopeContextFiles.terminalEnvironment {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        do {
            try rpcSession.startProcess(arguments: codexLaunchArguments() + args, environment: env)
            _ = try await rpcSession.call(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "canope_list", "title": "Canope", "version": "1.0.0"],
                    "capabilities": ["experimentalApi": true] as [String: Any],
                ],
                requestId: 0
            )
            try rpcSession.notify(method: "initialized", params: [:])
            var params: [String: Any] = [
                "limit": limit,
                "sortKey": "updated_at",
                "sourceKinds": ["appServer", "cli", "vscode", "exec"],
            ]
            if let d = matchingDirectory {
                params["cwd"] = d.path
            }
            guard let res = try await rpcSession.call(method: "thread/list", params: params) as? [String: Any],
                  let data = res["data"] as? [[String: Any]]
            else {
                rpcSession.terminate()
                return []
            }
            let cwdPath = matchingDirectory?.path ?? ""
            let proj = (cwdPath as NSString).lastPathComponent
            var out: [ChatSessionListItem] = []
            for t in data {
                let id = (t["id"] as? String) ?? ""
                let name = (t["name"] as? String) ?? (t["preview"] as? String) ?? ""
                let date = parseCodexThreadDate(t["updatedAt"] ?? t["createdAt"])
                out.append(ChatSessionListItem(id: id, name: name, project: proj, date: date))
            }
            rpcSession.terminate()
            return out
        } catch {
            rpcSession.terminate()
            return []
        }
    }

    private static func parseCodexThreadDate(_ value: Any?) -> Date? {
        guard let d = value as? Double else { return nil }
        if d > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: d / 1000)
        }
        return Date(timeIntervalSince1970: d)
    }

    private static func resolvedBridgeStatic() -> String {
        if let v = ProcessInfo.processInfo.environment["CANOPE_IDE_BRIDGE_URL"], !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["CANOPE_CLAUDE_IDE_BRIDGE_URL"], !v.isEmpty { return v }
        return CanopeContextFiles.claudeIDEBridgeURL
    }
}

import Combine
import Foundation
import SwiftUI

struct CodexThreadHistorySnapshot {
    let name: String?
    let turns: Int
    let messages: [ChatMessage]
    let reviewStateDescription: String?
    let reviewStatusBadge: ChatStatusBadge?
}

// MARK: - Codex app-server JSON-RPC (stdio JSONL)

private enum CodexTraceLog {
    private static let fileURL = URL(fileURLWithPath: "/tmp/canope_codex_trace.log")
    private static let queue = DispatchQueue(label: "Canope.CodexTraceLog")

    static func write(_ message: String) {
        queue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}

/// Single-session JSON-RPC client for `codex app-server --listen stdio://`.
final class CodexAppServerRPCSession: @unchecked Sendable {
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "CodexAppServerRPCSession.io")
    private var nextRequestID = 1
    /// Success payloads are JSON-encoded `result` (Sendable `Data`).
    private var pending: [Int: (Result<Data?, NSError>) -> Void] = [:]
    private var buffer = Data()
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdinHandle: FileHandle?

    /// Params are JSON-encoded dictionary (`Data`) for Swift 6 cross-isolation safety.
    var onNotification: (@Sendable (String, Data) -> Void)?
    var onRequest: (@Sendable (Int, String, Data) -> Void)?

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
        let err = Pipe()
        proc.standardOutput = out
        proc.standardInput = input
        proc.standardError = err

        let pathValue = environment["PATH"] ?? ""
        let shellValue = environment["SHELL"] ?? ""
        let homeValue = environment["HOME"] ?? ""
        CodexTraceLog.write("startProcess executable=\(arguments[0]) args=\(Array(arguments.dropFirst())) PATH=\(pathValue) SHELL=\(shellValue) HOME=\(homeValue)")

        try proc.run()
        process = proc
        stdoutHandle = out.fileHandleForReading
        stderrHandle = err.fileHandleForReading
        stdinHandle = input.fileHandleForWriting

        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { return }
            self.ioQueue.async {
                self.appendAndDispatch(chunk)
            }
        }

        stderrHandle?.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            CodexTraceLog.write("stderr \(text)")
        }
    }

    func terminate() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
        stdoutHandle = nil
        stderrHandle = nil
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
        CodexTraceLog.write("recv \(line)")
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let method = obj["method"] as? String,
           let idNum = jsonInt(obj["id"]) {
            let params = obj["params"] as? [String: Any] ?? [:]
            let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            onRequest?(idNum, method, paramsData)
            return
        }

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

    private func writeJSONLine(_ payload: [String: Any]) throws {
        try ioQueue.sync {
            guard let payloadBytes = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: payloadBytes, encoding: .utf8)
            else {
                throw NSError(domain: "CodexAppServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encode failed"])
            }
            line.append("\n")
            guard let stdin = stdinHandle else {
                throw NSError(domain: "CodexAppServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "No stdin"])
            }
            CodexTraceLog.write("send \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            stdin.write(Data(line.utf8))
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
            do {
                try self.writeJSONLine(payload)
            } catch {
                self.lock.lock()
                let waiter = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                waiter?(.failure(error as NSError))
            }
        }
        return try decodeJSONRPCResult(resultData)
    }

    func notify(method: String, params: [String: Any]) throws {
        try writeJSONLine(["method": method, "params": params])
    }

    func respond(id: Int, result: Any?) throws {
        try writeJSONLine([
            "id": id,
            "result": result ?? NSNull(),
        ])
    }

    func respondError(id: Int, code: Int = -32000, message: String) throws {
        try writeJSONLine([
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
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

func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let i as Int: return i
    case let d as Double: return Int(d)
    case let n as NSNumber: return n.intValue
    default: return nil
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
    @Published var includesIDEContext = true
    @Published var chatInteractionMode: ChatInteractionMode = .agent
    @Published var chatReviewStateDescription: String?
    @Published private var reviewStatusBadge: ChatStatusBadge?
    @Published private var authStatusBadge: ChatStatusBadge?
    @Published private var mcpStatusBadge: ChatStatusBadge?
    @Published var pendingApprovalRequest: ChatApprovalRequest?
    @Published private var globalCustomInstructionsText: String
    @Published private var sessionCustomInstructionsText: String = ""

    let providerName = "Codex"
    let providerIcon = "chevron.left.forwardslash.chevron.right"

    static let defaultModels = ["gpt-5.4", "gpt-5.3-codex", "gpt-5.2"]
    static let defaultEfforts = ["low", "medium", "high", "xhigh"]
    static let globalCustomInstructionsDefaultsKey = CodexCustomInstructionsStore.globalDefaultsKey
    static let sessionCustomInstructionsDefaultsKey = CodexCustomInstructionsStore.sessionDefaultsKey

    private var workingDirectory: URL
    private var rpc: CodexAppServerRPCSession?
    private var initialized = false
    private var connectTask: Task<Void, Never>?
    private let threadCoordinator = CodexThreadCoordinator()
    private let approvalCoordinator = CodexApprovalCoordinator()
    private let toolEventReducer = CodexToolEventReducer()
    private var currentRun = CodexCurrentRunState()

    init(workingDirectory: URL? = nil) {
        self.globalCustomInstructionsText = CodexCustomInstructionsStore.loadGlobalText()
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

    var workingDirectoryURL: URL { threadCoordinator.workingDirectoryURL(base: workingDirectory) }

    deinit {
        connectTask?.cancel()
        rpc?.terminate()
    }

    func start() {
        isConnected = true
        _ = beginConnectionIfNeeded()
    }

    func stop() {
        Task { await interruptIfNeeded() }
        approvalCoordinator.reset()
        toolEventReducer.stop(messages: &messages)
        isProcessing = false
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !isConnected { start() }
        pendingApprovalRequest = nil
        Task {
            await sendUserMessage(
                [.text(trimmed)],
                display: trimmed,
                interactionMode: chatInteractionMode,
                includeIDEContext: includesIDEContext
            )
        }
    }

    func sendMessageWithDisplay(displayText: String, items: [ChatInputItem]) {
        let prompt = ChatInputItem.legacyPrompt(from: items)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !isConnected { start() }
        pendingApprovalRequest = nil
        Task {
            await sendUserMessage(
                items,
                display: displayText,
                interactionMode: chatInteractionMode,
                includeIDEContext: includesIDEContext
            )
        }
    }

    func sendMessageWithDisplay(displayText: String, prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if !isConnected { start() }
        pendingApprovalRequest = nil
        Task {
            await sendUserMessage(
                [.text(p)],
                display: displayText,
                interactionMode: chatInteractionMode,
                includeIDEContext: includesIDEContext
            )
        }
    }

    // MARK: - Connection

    private func ensureSession() async {
        if let task = beginConnectionIfNeeded() {
            await task.value
        }
    }

    private func ensureConnected() async {
        if let task = beginConnectionIfNeeded() {
            await task.value
        }
    }

    @discardableResult
    private func beginConnectionIfNeeded() -> Task<Void, Never>? {
        if initialized { return nil }
        if let connectTask { return connectTask }

        let task = Task { [weak self] in
            await self?.connectAndHandshake()
            await MainActor.run { [weak self] in
                self?.connectTask = nil
            }
        }
        connectTask = task
        return task
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
        rpcSession.onRequest = { [weak self] id, method, paramsData in
            Task { @MainActor in
                let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
                self?.handleServerRequest(id: id, method: method, params: params)
            }
        }
        self.rpc = rpcSession

        let args = CodexAppServerLaunchSupport.buildAppServerArguments(
            bridgeURL: CodexAppServerLaunchSupport.resolvedBridgeURL()
        )

        do {
            let env = CodexAppServerLaunchSupport.buildProcessEnvironment()
            try rpcSession.startProcess(
                arguments: CodexAppServerLaunchSupport.codexLaunchArguments() + args,
                environment: env
            )

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
            authStatusBadge = nil
            mcpStatusBadge = ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")

            await refreshModels(rpc: rpcSession)
        } catch {
            rpcSession.terminate()
            rpc = nil
            appendSystem("Codex: \(error.localizedDescription)")
            updateStatusForErrorMessage(error.localizedDescription)
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
        await threadCoordinator.interruptIfNeeded(rpc: rpc)
    }

    // MARK: - Send flow

    private func sendUserMessage(
        _ items: [ChatInputItem],
        display: String,
        interactionMode: ChatInteractionMode,
        includeIDEContext: Bool,
        appendUserMessage: Bool = true
    ) async {
        let prompt = ChatInputItem.legacyPrompt(from: items)
        if appendUserMessage {
            messages.append(
                ChatMessage(
                    role: .user,
                    content: display,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
            )
        }

        isProcessing = true
        currentRun.configure(
            interactionMode: interactionMode,
            includesIDEContext: includeIDEContext,
            inputItems: items,
            prompt: prompt,
            displayText: display
        )
        toolEventReducer.configureNewRun()
        CodexTraceLog.write("sendUserMessage mode=\(interactionMode.rawValue) display=\(display.replacingOccurrences(of: "\n", with: "\\n"))")

        await ensureConnected()
        guard let rpc else {
            CodexTraceLog.write("sendUserMessage aborted: rpc unavailable")
            isProcessing = false
            return
        }

        do {
            if threadCoordinator.currentThreadId == nil {
                let cwd = workingDirectoryURL.path
                CodexTraceLog.write("thread/start cwd=\(cwd) model=\(self.selectedModel) approval=\(CodexApprovalCoordinator.approvalPolicy(for: interactionMode)) sandbox=\(CodexApprovalCoordinator.threadSandboxMode(for: interactionMode))")
                if let thread = try await threadCoordinator.startThreadIfNeeded(
                    rpc: rpc,
                    model: selectedModel,
                    interactionMode: interactionMode,
                    workingDirectory: workingDirectoryURL
                ) {
                    session.id = thread.id
                    session.name = thread.name
                    session.turns = 0
                    CodexCustomInstructionsStore.saveSessionText(sessionCustomInstructionsText, threadId: thread.id)
                    CodexTraceLog.write("thread/start result threadId=\(thread.id)")
                }
            }

            guard let threadId = threadCoordinator.currentThreadId else {
                throw NSError(domain: "CodexAppServer", code: 10, userInfo: [NSLocalizedDescriptionKey: "No thread"])
            }

            CodexTraceLog.write("turn/start threadId=\(threadId) effort=\(self.selectedEffort) model=\(self.selectedModel)")
            try await threadCoordinator.startTurn(
                rpc: rpc,
                items: items,
                interactionMode: interactionMode,
                includeIDEContext: includeIDEContext,
                globalCustomInstructions: globalCustomInstructionsText,
                sessionCustomInstructions: sessionCustomInstructionsText,
                workingDirectory: workingDirectoryURL,
                model: selectedModel,
                effort: selectedEffort
            )
            CodexTraceLog.write("turn/start returned")
            session.turns += 1
        } catch {
            CodexTraceLog.write("sendUserMessage error \(error.localizedDescription)")
            appendSystem("Codex: \(error.localizedDescription)")
            updateStatusForErrorMessage(error.localizedDescription)
            isProcessing = false
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        guard shouldHandleThreadScopedPayload(params) else {
            let foreignThreadID = params["threadId"] as? String ?? "<none>"
            let activeThreadID = threadCoordinator.currentThreadId ?? "<none>"
            CodexTraceLog.write("ignored notification \(method) foreignThread=\(foreignThreadID) activeThread=\(activeThreadID)")
            return
        }
        let paramsSummary = Self.jsonString(params) ?? "{}"
        CodexTraceLog.write("notification \(method) params=\(paramsSummary)")
        switch CodexNotificationRouter.route(method: method, params: params) {
        case .turnStarted(let turnID):
            threadCoordinator.setCurrentTurnId(turnID)

        case .itemStarted(let item):
            handleItemStarted(item)

        case .assistantDelta(let itemID, let delta):
            toolEventReducer.bufferAssistantDelta(delta, itemID: itemID, messages: &messages)
            if toolEventReducer.needsAssistantDeltaFlushScheduling {
                toolEventReducer.scheduleAssistantDeltaFlush { [weak self] in
                    guard let self else { return }
                    self.toolEventReducer.flushPendingAssistantDelta(messages: &self.messages)
                }
            }

        case .toolOutputDelta(let itemID, let delta):
            toolEventReducer.appendToolOutputDelta(itemID: itemID, delta: delta)

        case .itemCompleted(let item):
            toolEventReducer.flushPendingAssistantDelta(messages: &messages)
            toolEventReducer.clearAssistantDeltaWork()
            handleItemCompleted(item)

        case .turnCompleted:
            toolEventReducer.flushPendingAssistantDelta(messages: &messages)
            toolEventReducer.clearAssistantDeltaWork()
            if let idx = toolEventReducer.currentAssistantMessageIndex, idx < messages.count {
                messages[idx].isStreaming = false
                toolEventReducer.scheduleMarkdownPreRender { [weak self] in
                    guard let self else { return }
                    self.toolEventReducer.flushMarkdownPreRender(into: &self.messages)
                }
            }
            isProcessing = false
            threadCoordinator.setCurrentTurnId(nil)
            toolEventReducer.markRetryStatusMessage(nil)
            approvalCoordinator.reset()

        case .turnPlanUpdated(let explanation, let plan):
            guard toolEventReducer.currentAssistantMessageIndex == nil else { break }
            toolEventReducer.enqueuePlanUpdate(
                explanation: explanation,
                plan: plan,
                messages: &messages
            )
            if toolEventReducer.needsMarkdownScheduling {
                toolEventReducer.scheduleMarkdownPreRender { [weak self] in
                    guard let self else { return }
                    self.toolEventReducer.flushMarkdownPreRender(into: &self.messages)
                }
            }

        case .serverRequestResolved(let requestID):
            approvalCoordinator.removeRequest(id: requestID)
            if pendingApprovalRequest?.rpcRequestID == requestID {
                pendingApprovalRequest = nil
            }

        case .approvalResolved(let itemID):
            clearResolvedApproval(for: itemID)

        case .error(let rendered, let willRetry):
            toolEventReducer.flushPendingAssistantDelta(messages: &messages)
            toolEventReducer.clearAssistantDeltaWork()
            if !willRetry || toolEventReducer.lastRetryStatusMessage != rendered {
                appendSystem(rendered)
            }
            updateStatusForErrorMessage(rendered)

            if willRetry {
                toolEventReducer.markRetryStatusMessage(rendered)
            } else {
                toolEventReducer.markRetryStatusMessage(nil)
                isProcessing = false
                threadCoordinator.setCurrentTurnId(nil)
            }

        case .ignored:
            break
        }
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
        guard shouldHandleThreadScopedPayload(params) else {
            let foreignThreadID = params["threadId"] as? String ?? "<none>"
            let activeThreadID = threadCoordinator.currentThreadId ?? "<none>"
            CodexTraceLog.write("ignored serverRequest id=\(id) method=\(method) foreignThread=\(foreignThreadID) activeThread=\(activeThreadID)")
            return
        }
        let paramsSummary = Self.jsonString(params) ?? "{}"
        CodexTraceLog.write("serverRequest id=\(id) method=\(method) params=\(paramsSummary)")
        let request = approvalCoordinator.registerRequest(id: id, method: method, params: params)
        let disposition = CodexApprovalCoordinator.serverRequestDisposition(
            for: method,
            mode: currentRun.interactionMode,
            params: params
        )
        updateStatusForServerRequest(method: method, disposition: disposition)
        switch disposition {
        case .autoApprove:
            isProcessing = true
            Task { [weak self] in
                await self?.replyToServerRequest(id: id, method: method, approved: true)
            }
        case .inlineApproval:
            pendingApprovalRequest = approvalCoordinator.makeApprovalRequest(
                from: request,
                prompt: currentRun.prompt,
                displayText: currentRun.displayText
            )
            isProcessing = false
        case .reject:
            appendSystem(CodexApprovalCoordinator.blockedServerRequestMessage(
                method: method,
                mode: currentRun.interactionMode,
                params: params
            ))
            Task { [weak self] in
                await self?.replyToServerRequest(id: id, method: method, approved: false)
            }
            isProcessing = false
        case .denyPermissions:
            appendSystem(CodexApprovalCoordinator.blockedServerRequestMessage(
                method: method,
                mode: currentRun.interactionMode,
                params: params
            ))
            Task { [weak self] in
                await self?.replyToPermissionsRequest(id: id, grant: false)
            }
            isProcessing = false
        case .unsupported:
            let message = CodexApprovalCoordinator.unsupportedServerRequestMessage(for: method)
            appendSystem(message)
            Task { [weak self] in
                await self?.replyUnsupportedServerRequest(id: id, method: method, message: message)
            }
            isProcessing = false
        }
    }

    private func handleItemStarted(_ item: [String: Any]) {
        guard let type = item["type"] as? String else { return }
        switch type {
        case "agentMessage", "plan":
            beginStreamingAssistantItem(item, type: type)
        case "mcpToolCall":
            handleMCPToolCallStarted(item)
        case "commandExecution":
            appendToolUseItem(
                itemID: item["id"] as? String,
                toolName: "Bash",
                content: Self.commandExecutionSummary(item),
                toolInput: Self.jsonString(item["command"] ?? item["commandActions"] ?? item)
            )
        case "fileChange":
            appendToolUseItem(
                itemID: item["id"] as? String,
                toolName: "Edit",
                content: Self.fileChangeSummary(item),
                toolInput: Self.jsonString(item["changes"] ?? item)
            )
        case "dynamicToolCall":
            appendToolUseItem(
                itemID: item["id"] as? String,
                toolName: (item["tool"] as? String) ?? "dynamicTool",
                content: Self.dynamicToolCallSummary(item),
                toolInput: Self.dynamicToolCallInputPreview(item) ?? Self.jsonString(item["arguments"] ?? item)
            )
        case "webSearch":
            appendToolUseItem(
                itemID: item["id"] as? String,
                toolName: "WebSearch",
                content: Self.webSearchSummary(item),
                toolInput: Self.webSearchInputPreview(item) ?? Self.jsonString(["query": item["query"] as? String ?? "", "action": item["action"] as Any])
            )
        case "imageView":
            appendToolUseItem(
                itemID: item["id"] as? String,
                toolName: "ImageView",
                content: Self.imageViewSummary(item),
                toolInput: Self.jsonString(["path": item["path"] as? String ?? ""])
            )
        case "collabAgentToolCall":
            appendToolUseItem(
                itemID: item["id"] as? String,
                toolName: "Agent",
                content: Self.collabAgentToolCallSummary(item),
                toolInput: Self.collabAgentToolCallInputPreview(item) ?? Self.jsonString(item)
            )
        case "enteredReviewMode":
            chatReviewStateDescription = Self.reviewStateDescription(item)
            reviewStatusBadge = ChatStatusBadge(kind: .reviewActive, text: chatReviewStateDescription ?? "Review active")
        case "exitedReviewMode":
            chatReviewStateDescription = nil
        default:
            break
        }
    }

    private func beginStreamingAssistantItem(_ item: [String: Any], type: String) {
        let traceItemID = (item["id"] as? String) ?? ""
        CodexTraceLog.write("beginStreamingAssistantItem type=\(type) itemId=\(traceItemID)")
        toolEventReducer.clearAssistantDeltaWork()
        toolEventReducer.beginStreamingAssistantItem(
            item: item,
            type: type,
            interactionMode: currentRun.interactionMode,
            messages: &messages
        )
        if toolEventReducer.needsMarkdownScheduling {
            toolEventReducer.scheduleMarkdownPreRender { [weak self] in
                guard let self else { return }
                self.toolEventReducer.flushMarkdownPreRender(into: &self.messages)
            }
        }
    }

    private func handleMCPToolCallStarted(_ item: [String: Any]) {
        let toolName = (item["tool"] as? String) ?? ""
        let itemID = (item["id"] as? String) ?? ""
        CodexTraceLog.write("handleMCPToolCallStarted tool=\(toolName) itemId=\(itemID)")
        toolEventReducer.flushPendingAssistantDelta(messages: &messages)
        toolEventReducer.clearAssistantDeltaWork()
        let name = (item["tool"] as? String) ?? "mcp"
        let summary = (item["server"] as? String).map { "\($0) · \(name)" } ?? name
        mcpStatusBadge = ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")
        if ClaudeHeadlessProvider.shouldBlockTool(
            name: name,
            input: item["arguments"] as? [String: Any],
            mode: currentRun.interactionMode
        ) {
            if currentRun.interactionMode == .acceptEdits {
                pendingApprovalRequest = ChatApprovalRequest(
                    toolName: name,
                    actionLabel: "MCP",
                    prompt: currentRun.prompt,
                    displayText: currentRun.displayText,
                    details: [summary],
                    itemID: item["id"] as? String,
                    threadID: threadCoordinator.currentThreadId,
                    turnID: threadCoordinator.currentTurnId
                )
            } else {
                appendSystem(ClaudeHeadlessProvider.blockedToolMessage(
                    toolName: name,
                    mode: currentRun.interactionMode
                ))
            }
            Task { await interruptIfNeeded() }
            isProcessing = false
            threadCoordinator.setCurrentTurnId(nil)
            return
        }
        appendToolUseItem(
            itemID: item["id"] as? String,
            toolName: name,
            content: summary,
            toolInput: Self.jsonString(item["arguments"])
        )
    }

    private func handleItemCompleted(_ item: [String: Any]) {
        guard let type = item["type"] as? String else { return }
        switch type {
        case "agentMessage", "plan":
            completeAssistantItem(item)
        case "commandExecution":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: "Bash",
                summary: Self.completedCommandExecutionSummary(
                    item,
                    bufferedOutput: toolEventReducer.bufferedOutput(for: item["id"] as? String)
                )
            )
        case "fileChange":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: "Edit",
                summary: Self.completedFileChangeSummary(
                    item,
                    bufferedOutput: toolEventReducer.bufferedOutput(for: item["id"] as? String)
                )
            )
        case "dynamicToolCall":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: (item["tool"] as? String) ?? "dynamicTool",
                summary: Self.completedDynamicToolCallSummary(item)
            )
        case "webSearch":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: "WebSearch",
                summary: Self.completedWebSearchSummary(item)
            )
        case "imageView":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: "ImageView",
                summary: Self.completedImageViewSummary(item)
            )
        case "collabAgentToolCall":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: "Agent",
                summary: Self.completedCollabAgentToolCallSummary(item)
            )
        case "enteredReviewMode":
            chatReviewStateDescription = Self.reviewStateDescription(item)
            reviewStatusBadge = ChatStatusBadge(kind: .reviewActive, text: chatReviewStateDescription ?? "Review active")
        case "exitedReviewMode":
            appendExitedReviewModeMessages(item)
            chatReviewStateDescription = nil
            reviewStatusBadge = ChatStatusBadge(kind: .reviewDone, text: "Review terminee")
        case "mcpToolCall":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: (item["tool"] as? String) ?? "mcp",
                summary: Self.completedDynamicToolCallSummary(item)
            )
        default:
            break
        }
    }

    private func completeAssistantItem(_ item: [String: Any]) {
        let itemID = (item["id"] as? String) ?? ""
        CodexTraceLog.write("completeAssistantItem itemId=\(itemID)")
        toolEventReducer.completeAssistantItem(item: item, messages: &messages)
        if toolEventReducer.needsMarkdownScheduling {
            toolEventReducer.scheduleMarkdownPreRender { [weak self] in
                guard let self else { return }
                self.toolEventReducer.flushMarkdownPreRender(into: &self.messages)
            }
        }
    }

    private func appendToolUseItem(itemID: String?, toolName: String, content: String, toolInput: String?) {
        toolEventReducer.appendToolUseItem(
            itemID: itemID,
            toolName: toolName,
            content: content,
            toolInput: toolInput,
            messages: &messages
        )
    }

    private func completeToolItem(itemID: String?, toolName: String, summary: String?) {
        toolEventReducer.completeToolItem(
            itemID: itemID,
            toolName: toolName,
            summary: summary,
            messages: &messages
        )
    }

    private func updateStatusForServerRequest(method: String, disposition: CodexServerRequestDisposition) {
        let badges = Self.derivedStatusBadges(forServerRequestMethod: method, disposition: disposition)
        if let auth = badges.auth {
            authStatusBadge = auth
        }
        if let mcp = badges.mcp {
            mcpStatusBadge = mcp
        }
        if let review = badges.review {
            reviewStatusBadge = review
        }
    }

    private func updateStatusForErrorMessage(_ text: String) {
        let badges = Self.derivedStatusBadges(forErrorText: text)
        if let auth = badges.auth {
            authStatusBadge = auth
        }
        if let mcp = badges.mcp {
            mcpStatusBadge = mcp
        }
        if let review = badges.review {
            reviewStatusBadge = review
        }
    }

    private func handleTurnPlanUpdated(_ params: [String: Any]) {
        guard toolEventReducer.currentAssistantMessageIndex == nil,
              let plan = params["plan"] as? [[String: Any]],
              !plan.isEmpty
        else { return }
        toolEventReducer.enqueuePlanUpdate(
            explanation: params["explanation"] as? String,
            plan: plan,
            messages: &messages
        )
        if toolEventReducer.needsMarkdownScheduling {
            toolEventReducer.scheduleMarkdownPreRender { [weak self] in
                guard let self else { return }
                self.toolEventReducer.flushMarkdownPreRender(into: &self.messages)
            }
        }
    }

    private func clearResolvedApproval(for itemID: String?) {
        approvalCoordinator.clearResolvedApproval(for: itemID, pendingApprovalRequest: &pendingApprovalRequest)
        toolEventReducer.clearResolvedApproval(for: itemID)
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

    private func replyToServerRequest(
        id: Int,
        method: String,
        approved: Bool,
        fieldValues: [String: String] = [:]
    ) async {
        guard let rpc else { return }
        do {
            CodexTraceLog.write("replyToServerRequest id=\(id) method=\(method) approved=\(approved)")
            switch method {
            case "item/commandExecution/requestApproval",
                 "item/fileChange/requestApproval":
                try rpc.respond(
                    id: id,
                    result: [
                        "decision": approved ? "accept" : "decline",
                    ]
                )
            case "item/permissions/requestApproval":
                try rpc.respond(
                    id: id,
                    result: [
                        "permissions": Self.grantedPermissions(
                            from: approvalCoordinator.request(for: id)?.params ?? [:],
                            grant: approved,
                            workingDirectory: workingDirectoryURL
                        ),
                        "scope": "turn",
                    ]
                )
            case "mcpServer/elicitation/request":
                try rpc.respond(
                    id: id,
                    result: Self.elicitationResponseResult(
                        from: approvalCoordinator.request(for: id)?.params ?? [:],
                        approved: approved,
                        fieldValues: fieldValues
                    )
                )
            case "item/tool/requestUserInput":
                guard approved else {
                    try rpc.respondError(id: id, message: "User declined interactive input")
                    break
                }
                try rpc.respond(
                    id: id,
                    result: Self.toolRequestUserInputResponseResult(
                        from: approvalCoordinator.request(for: id)?.params ?? [:],
                        fieldValues: fieldValues
                    )
                )
            default:
                try rpc.respondError(id: id, message: Self.unsupportedServerRequestMessage(for: method))
            }
            approvalCoordinator.removeRequest(id: id)
        } catch {
            appendSystem("Codex: \(error.localizedDescription)")
            isProcessing = false
        }
    }

    private func replyToPermissionsRequest(id: Int, grant: Bool) async {
        guard let rpc else { return }
        do {
            CodexTraceLog.write("replyToPermissionsRequest id=\(id) grant=\(grant)")
            try rpc.respond(
                id: id,
                result: [
                    "permissions": Self.grantedPermissions(
                        from: approvalCoordinator.request(for: id)?.params ?? [:],
                        grant: grant,
                        workingDirectory: workingDirectoryURL
                    ),
                    "scope": "turn",
                ]
            )
            approvalCoordinator.removeRequest(id: id)
        } catch {
            appendSystem("Codex: \(error.localizedDescription)")
        }
    }

    private func replyUnsupportedServerRequest(id: Int, method: String, message: String) async {
        guard let rpc else { return }
        do {
            CodexTraceLog.write("replyUnsupportedServerRequest id=\(id) method=\(method) message=\(message)")
            switch method {
            case "item/tool/call":
                try rpc.respond(
                    id: id,
                    result: [
                        "success": false,
                        "contentItems": [[
                            "type": "inputText",
                            "text": message,
                        ]],
                    ]
                )
            default:
                try rpc.respondError(id: id, message: message)
            }
            approvalCoordinator.removeRequest(id: id)
        } catch {
            appendSystem("Codex: \(error.localizedDescription)")
        }
    }

    nonisolated static func jsonString(_ obj: Any?) -> String? {
        guard let obj else { return nil }
        if let s = obj as? String { return s }
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: d, encoding: .utf8)
        else { return String(describing: obj) }
        return str
    }

    private static func grantedPermissions(from params: [String: Any], grant: Bool, workingDirectory: URL) -> [String: Any] {
        guard grant else { return [:] }
        if let additionalPermissions = params["additionalPermissions"] as? [String: Any] {
            return additionalPermissions
        }
        if let permissions = params["permissions"] as? [String: Any] {
            return permissions
        }
        return [
            "fileSystem": [
                "write": [workingDirectory.path],
            ],
        ]
    }

    nonisolated private static func elicitationResponseResult(
        from params: [String: Any],
        approved: Bool,
        fieldValues: [String: String] = [:]
    ) -> [String: Any] {
        if approved {
            let content = mcpElicitationContent(from: params, fieldValues: fieldValues)
            return [
                "action": "accept",
                "content": content,
            ]
        }
        return [
            "action": "decline",
        ]
    }

    nonisolated private static func supportsSimpleMCPApprovalElicitation(_ params: [String: Any]) -> Bool {
        guard let requestedSchema = params["requestedSchema"] as? [String: Any],
              (requestedSchema["type"] as? String) == "object"
        else {
            return false
        }
        let properties = requestedSchema["properties"] as? [String: Any] ?? [:]
        let required = requestedSchema["required"] as? [Any] ?? []
        return properties.isEmpty && required.isEmpty
    }

    nonisolated private static func toolRequestUserInputFields(from params: [String: Any]) -> [ChatInteractiveField] {
        guard let questions = params["questions"] as? [[String: Any]], !questions.isEmpty else {
            return []
        }

        return questions.compactMap { question in
            guard let id = (question["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let header = (question["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let prompt = (question["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty
            else {
                return nil
            }

            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> ChatInteractiveOption? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String
                else {
                    return nil
                }
                return ChatInteractiveOption(label: label, description: description)
            }

            let isSecret = question["isSecret"] as? Bool ?? false
            let allowsOther = question["isOther"] as? Bool ?? false
            let kind: ChatInteractiveFieldKind = options.isEmpty ? (isSecret ? .secureText : .text) : .singleChoice
            let defaultValue = options.first?.label ?? (kind == .boolean ? "false" : "")

            return ChatInteractiveField(
                id: id,
                title: header.isEmpty ? id : header,
                prompt: prompt,
                kind: kind,
                options: options,
                isRequired: true,
                allowsCustomValue: allowsOther,
                placeholder: isSecret ? "Saisir la valeur" : nil,
                defaultValue: defaultValue
            )
        }
    }

    nonisolated private static func mcpElicitationFields(from params: [String: Any]) -> [ChatInteractiveField] {
        guard (params["mode"] as? String) != "url",
              let requestedSchema = params["requestedSchema"] as? [String: Any],
              (requestedSchema["type"] as? String) == "object",
              let properties = requestedSchema["properties"] as? [String: Any]
        else {
            return []
        }

        let requiredSet = Set((requestedSchema["required"] as? [String]) ?? [])

        return properties.keys.sorted().compactMap { key in
            guard let schema = properties[key] as? [String: Any] else { return nil }

            let enumValues = (schema["enum"] as? [Any])?.compactMap { $0 as? String } ?? []
            let type = (schema["type"] as? String) ?? "string"
            let title = (schema["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (schema["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: ChatInteractiveFieldKind
            let options: [ChatInteractiveOption]

            if !enumValues.isEmpty {
                kind = .singleChoice
                options = enumValues.map { ChatInteractiveOption(label: $0, description: $0) }
            } else {
                options = []
                switch type {
                case "boolean":
                    kind = .boolean
                case "integer":
                    kind = .integer
                case "number":
                    kind = .number
                default:
                    kind = .text
                }
            }

            let defaultValue: String
            switch kind {
            case .boolean:
                defaultValue = "false"
            case .singleChoice:
                defaultValue = options.first?.label ?? ""
            default:
                defaultValue = ""
            }

            return ChatInteractiveField(
                id: key,
                title: (title?.isEmpty == false ? title! : key),
                prompt: description?.nilIfEmpty,
                kind: kind,
                options: options,
                isRequired: requiredSet.contains(key),
                allowsCustomValue: false,
                placeholder: nil,
                defaultValue: defaultValue
            )
        }
    }

    nonisolated private static func serverRequestFields(method: String, params: [String: Any]) -> [ChatInteractiveField] {
        switch method {
        case "item/tool/requestUserInput":
            return toolRequestUserInputFields(from: params)
        case "mcpServer/elicitation/request":
            return mcpElicitationFields(from: params)
        default:
            return []
        }
    }

    nonisolated private static func supportsInlineMCPFormElicitation(_ params: [String: Any]) -> Bool {
        !mcpElicitationFields(from: params).isEmpty
    }

    nonisolated private static func supportsToolRequestUserInput(_ params: [String: Any]) -> Bool {
        !toolRequestUserInputFields(from: params).isEmpty
    }

    nonisolated private static func interactiveAnswerStrings(
        for fieldID: String,
        fieldValues: [String: String]
    ) -> [String] {
        let key = fieldID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let selected = (fieldValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if selected == "__other__" {
            let custom = (fieldValues["\(key)__other"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? [] : [custom]
        }
        return selected.isEmpty ? [] : [selected]
    }

    nonisolated private static func toolRequestUserInputResponseResult(
        from params: [String: Any],
        fieldValues: [String: String]
    ) -> [String: Any] {
        let questions = params["questions"] as? [[String: Any]] ?? []
        var answers: [String: Any] = [:]
        for question in questions {
            guard let id = question["id"] as? String, !id.isEmpty else { continue }
            answers[id] = [
                "answers": interactiveAnswerStrings(for: id, fieldValues: fieldValues),
            ]
        }
        return ["answers": answers]
    }

    nonisolated private static func mcpElicitationContent(
        from params: [String: Any],
        fieldValues: [String: String]
    ) -> [String: Any] {
        guard let requestedSchema = params["requestedSchema"] as? [String: Any],
              let properties = requestedSchema["properties"] as? [String: Any]
        else {
            return [:]
        }

        var content: [String: Any] = [:]
        for key in properties.keys.sorted() {
            guard let schema = properties[key] as? [String: Any] else { continue }
            let raw = (fieldValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let type = (schema["type"] as? String) ?? "string"

            switch type {
            case "boolean":
                if !raw.isEmpty {
                    content[key] = (raw as NSString).boolValue
                }
            case "integer":
                if let value = Int(raw) {
                    content[key] = value
                }
            case "number":
                if let value = Double(raw) {
                    content[key] = value
                }
            default:
                if !raw.isEmpty {
                    content[key] = raw
                }
            }
        }
        return content
    }

    nonisolated private static func mcpElicitationToolName(from params: [String: Any]) -> String {
        if let message = params["message"] as? String,
           let toolStart = message.range(of: "\""),
           let toolEnd = message[toolStart.upperBound...].range(of: "\"") {
            return String(message[toolStart.upperBound..<toolEnd.lowerBound])
        }
        if let meta = params["_meta"] as? [String: Any],
           let toolDescription = (meta["tool_description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !toolDescription.isEmpty {
            return toolDescription
        }
        if let serverName = (params["serverName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !serverName.isEmpty {
            return "\(serverName) MCP"
        }
        return "Appel MCP"
    }

    nonisolated static func serverRequestDisposition(
        for method: String,
        mode: ChatInteractionMode,
        params: [String: Any] = [:]
    ) -> ServerRequestDisposition {
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval":
            switch mode {
            case .agent: return .autoApprove
            case .acceptEdits: return .inlineApproval
            case .plan: return .reject
            }
        case "item/permissions/requestApproval":
            switch mode {
            case .agent: return .autoApprove
            case .acceptEdits, .plan: return .denyPermissions
            }
        case "mcpServer/elicitation/request":
            if supportsSimpleMCPApprovalElicitation(params) {
                switch mode {
                case .agent: return .autoApprove
                case .acceptEdits: return .inlineApproval
                case .plan: return .reject
                }
            }
            guard supportsInlineMCPFormElicitation(params) else { return .unsupported }
            switch mode {
            case .agent, .acceptEdits: return .inlineApproval
            case .plan: return .reject
            }
        case "item/tool/requestUserInput":
            guard supportsToolRequestUserInput(params) else { return .unsupported }
            switch mode {
            case .agent, .acceptEdits: return .inlineApproval
            case .plan: return .reject
            }
        case "item/tool/call",
             "account/chatgptAuthTokens/refresh":
            return .unsupported
        default:
            return .unsupported
        }
    }

    nonisolated static func serverRequestToolName(method: String, params: [String: Any]) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            if let command = params["command"] as? String, !command.isEmpty {
                return command
            }
            return "Commande"
        case "item/fileChange/requestApproval":
            if let files = params["paths"] as? [String], let first = files.first {
                return (first as NSString).lastPathComponent
            }
            return "Edition"
        case "item/permissions/requestApproval":
            return "Permissions"
        case "mcpServer/elicitation/request":
            return mcpElicitationToolName(from: params)
        case "item/tool/requestUserInput":
            if let questions = params["questions"] as? [[String: Any]],
               let first = questions.first,
               let header = first["header"] as? String,
               !header.isEmpty {
                return header
            }
            return "Reponse requise"
        default:
            return method
        }
    }

    nonisolated static func serverRequestActionLabel(method: String) -> String? {
        switch method {
        case "item/fileChange/requestApproval":
            return "Edit"
        case "item/commandExecution/requestApproval":
            return "Bash"
        case "mcpServer/elicitation/request":
            return "MCP"
        case "item/tool/requestUserInput":
            return "Input"
        default:
            return nil
        }
    }

    nonisolated static func serverRequestMessage(method: String, params: [String: Any]) -> String? {
        switch method {
        case "mcpServer/elicitation/request":
            return (params["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case "item/tool/requestUserInput":
            if let questions = params["questions"] as? [[String: Any]],
               let first = questions.first,
               let prompt = first["question"] as? String {
                return prompt.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            return "Saisie requise"
        case "item/fileChange/requestApproval":
            return "Autoriser cette modification ?"
        case "item/commandExecution/requestApproval":
            return "Autoriser cette commande ?"
        default:
            return nil
        }
    }

    nonisolated static func serverRequestDetails(method: String, params: [String: Any]) -> [String] {
        switch method {
        case "item/fileChange/requestApproval":
            var details: [String] = []
            if let paths = params["paths"] as? [String], !paths.isEmpty {
                details.append(contentsOf: paths.map { path in
                    let last = (path as NSString).lastPathComponent
                    return last.isEmpty ? path : last
                })
                if paths.count > 1 {
                    details.append("\(paths.count) fichiers")
                }
                return details
            }
            if let changes = params["changes"] as? [[String: Any]], !changes.isEmpty {
                details.append(contentsOf: changes.compactMap { change in
                    let path = (change["path"] as? String) ?? (change["newPath"] as? String) ?? ""
                    guard !path.isEmpty else { return nil }
                    let last = (path as NSString).lastPathComponent
                    return last.isEmpty ? path : last
                })
                if changes.count > 1 {
                    details.append("\(changes.count) modifications")
                }
                return details
            }
            return []
        case "item/commandExecution/requestApproval":
            var details: [String] = []
            if let command = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !command.isEmpty {
                details.append(command)
            }
            if let cwd = (params["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                details.append(cwd)
            }
            return details
        case "mcpServer/elicitation/request":
            if let serverName = (params["serverName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !serverName.isEmpty {
                return [serverName]
            }
            return []
        default:
            return []
        }
    }

    nonisolated static func serverRequestPreview(method: String, params: [String: Any]) -> ChatApprovalPreview? {
        switch method {
        case "item/fileChange/requestApproval":
            return fileChangeApprovalPreview(params: params)
        default:
            return nil
        }
    }

    nonisolated private static func fileChangeApprovalPreview(params: [String: Any]) -> ChatApprovalPreview? {
        guard let changes = params["changes"] as? [[String: Any]], !changes.isEmpty else { return nil }
        guard let primary = changes.first else { return nil }

        let path = (primary["path"] as? String) ?? (primary["newPath"] as? String) ?? ""
        let fileName: String
        if path.isEmpty {
            fileName = changes.count > 1 ? "\(changes.count) modifications" : "Modification"
        } else {
            let last = (path as NSString).lastPathComponent
            fileName = last.isEmpty ? path : last
        }

        let kind = ((primary["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) ?? "update"
        let title = path.isEmpty ? kind.capitalized : "\(fileName) · \(kind)"

        guard let diff = (primary["diff"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !diff.isEmpty else {
            return nil
        }

        let lines = diff
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                if trimmed.hasPrefix("---") || trimmed.hasPrefix("+++") || trimmed == "\\ No newline at end of file" {
                    return false
                }
                return true
            }

        var kept: [String] = []
        for line in lines {
            if line.hasPrefix("@@") {
                kept.append(line)
                continue
            }
            if line.hasPrefix("+") || line.hasPrefix("-") {
                kept.append(line)
            }
            if kept.count >= 6 { break }
        }

        if kept.isEmpty {
            kept = Array(lines.prefix(4))
        }

        guard !kept.isEmpty else { return nil }

        let maxLineLength = 92
        let body = kept.map { line in
            if line.count > maxLineLength {
                return String(line.prefix(maxLineLength - 1)) + "…"
            }
            return line
        }.joined(separator: "\n")

        return ChatApprovalPreview(title: title, body: body)
    }

    nonisolated static func blockedServerRequestMessage(
        method: String,
        mode: ChatInteractionMode,
        params: [String: Any] = [:]
    ) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            return ClaudeHeadlessProvider.blockedToolMessage(toolName: "Bash", mode: mode)
        case "item/fileChange/requestApproval":
            return ClaudeHeadlessProvider.blockedToolMessage(toolName: "Edit", mode: mode)
        case "mcpServer/elicitation/request":
            return ClaudeHeadlessProvider.blockedToolMessage(
                toolName: mcpElicitationToolName(from: params),
                mode: mode
            )
        case "item/permissions/requestApproval":
            switch mode {
            case .plan:
                return AppStrings.permissionRequestBlocked
            case .acceptEdits:
                return "Mode accept edits: la demande de permission additionnelle a ete bloquee en attendant ton approbation."
            case .agent:
                return "Demande de permission additionnelle."
            }
        default:
            return unsupportedServerRequestMessage(for: method)
        }
    }

    nonisolated static func unsupportedServerRequestMessage(for method: String) -> String {
        switch method {
        case "item/tool/call":
            return "Codex: les appels d’outils dynamiques ne sont pas encore pris en charge dans Canope."
        case "item/tool/requestUserInput":
            return "Codex: cette demande d’entrée utilisateur interactive n’est pas encore prise en charge dans Canope."
        case "mcpServer/elicitation/request":
            return "Codex: cette demande MCP exige un formulaire interactif qui n’est pas encore pris en charge dans Canope."
        case "account/chatgptAuthTokens/refresh":
            return "Codex: le rafraichissement des jetons ChatGPT n’est pas encore pris en charge dans Canope."
        default:
            return "Codex: requete app-server non prise en charge (\(method))."
        }
    }

    nonisolated static func approvalPolicy(for mode: ChatInteractionMode) -> String {
        switch mode {
        case .agent, .acceptEdits:
            return "on-request"
        case .plan:
            return "never"
        }
    }

    nonisolated static func threadSandboxMode(for mode: ChatInteractionMode) -> String {
        switch mode {
        case .plan:
            return "read-only"
        case .agent, .acceptEdits:
            return "workspace-write"
        }
    }

    nonisolated static func sandboxPolicy(
        for mode: ChatInteractionMode,
        workingDirectory: URL
    ) -> [String: Any] {
        switch mode {
        case .plan:
            return [
                "type": "readOnly",
                "networkAccess": true,
            ]
        case .agent, .acceptEdits:
            return [
                "type": "workspaceWrite",
                "writableRoots": [workingDirectory.path],
                "networkAccess": true,
            ]
        }
    }

    nonisolated static func buildPromptWithIDEContext(
        _ userMessage: String,
        includeIDEContext: Bool = true
    ) -> String {
        CodexPromptComposer.buildPromptWithIDEContext(
            userMessage,
            includeIDEContext: includeIDEContext
        )
    }

    nonisolated static func buildPromptForInteractionMode(
        _ userMessage: String,
        mode: ChatInteractionMode,
        includeIDEContext: Bool = true
    ) -> String {
        buildPromptForInteractionMode(
            userMessage,
            mode: mode,
            includeIDEContext: includeIDEContext,
            globalCustomInstructions: "",
            sessionCustomInstructions: ""
        )
    }

    nonisolated static func buildPromptForInteractionMode(
        _ userMessage: String,
        mode: ChatInteractionMode,
        includeIDEContext: Bool = true,
        globalCustomInstructions: String,
        sessionCustomInstructions: String
    ) -> String {
        CodexPromptComposer.buildPromptForInteractionMode(
            userMessage,
            mode: mode,
            includeIDEContext: includeIDEContext,
            globalCustomInstructions: globalCustomInstructions,
            sessionCustomInstructions: sessionCustomInstructions
        )
    }

    nonisolated static func buildTurnInputPayload(
        from items: [ChatInputItem],
        interactionMode: ChatInteractionMode,
        includeIDEContext: Bool = true,
        globalCustomInstructions: String = "",
        sessionCustomInstructions: String = ""
    ) -> [[String: Any]] {
        CodexPromptComposer.buildTurnInputPayload(
            from: items,
            interactionMode: interactionMode,
            includeIDEContext: includeIDEContext,
            globalCustomInstructions: globalCustomInstructions,
            sessionCustomInstructions: sessionCustomInstructions
        )
    }

    private nonisolated static func buildCustomInstructionsBlock(
        global: String,
        session: String
    ) -> String {
        let normalizedGlobal = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSession = session.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSession = normalizedSession == normalizedGlobal ? "" : normalizedSession
        var sections: [String] = []

        if !normalizedGlobal.isEmpty {
            sections.append("""
            [Canope Custom Instructions — Global]
            \(normalizedGlobal)
            [/Canope Custom Instructions — Global]
            """)
        }

        if !effectiveSession.isEmpty {
            sections.append("""
            [Canope Custom Instructions — Session]
            \(effectiveSession)
            [/Canope Custom Instructions — Session]
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func loadGlobalCustomInstructions() -> String {
        CodexCustomInstructionsStore.loadGlobalText()
    }

    private static func saveGlobalCustomInstructions(_ text: String) {
        CodexCustomInstructionsStore.saveGlobalText(text)
    }

    private static func loadSessionCustomInstructions(threadId: String) -> String {
        CodexCustomInstructionsStore.loadSessionText(threadId: threadId)
    }

    private static func saveSessionCustomInstructions(_ text: String, threadId: String) {
        CodexCustomInstructionsStore.saveSessionText(text, threadId: threadId)
    }
}

// MARK: - HeadlessChatProviding

extension CodexAppServerProvider: HeadlessChatProviding {
    var chatWorkingDirectory: URL { workingDirectoryURL }
    var chatVisualStyle: ChatVisualStyle { .codex }
    var chatUsesBottomPromptControls: Bool { true }
    var chatPromptEnvironmentLabel: String? { "Local" }
    var chatPromptConfigurationLabel: String? { AppStrings.customize }
    var chatSupportsCustomInstructions: Bool { true }
    var chatCustomInstructions: ChatCustomInstructions {
        ChatCustomInstructions(
            globalText: globalCustomInstructionsText,
            sessionText: sessionCustomInstructionsText
        )
    }
    var chatSupportsIDEContextToggle: Bool { true }
    var chatIncludesIDEContext: Bool {
        get { includesIDEContext }
        set { includesIDEContext = newValue }
    }
    var chatSupportsPlanMode: Bool { true }
    var chatSupportsReview: Bool { true }
    var chatStatusBadges: [ChatStatusBadge] {
        var badges: [ChatStatusBadge] = []
        if isConnected {
            badges.append(
                ChatStatusBadge(
                    kind: initialized ? .connected : .connecting,
                    text: initialized ? AppStrings.connected : AppStrings.connecting
                )
            )
        }
        if let mcpStatusBadge {
            badges.append(mcpStatusBadge)
        }
        if let authStatusBadge {
            badges.append(authStatusBadge)
        }
        if let reviewStatusBadge {
            badges.append(reviewStatusBadge)
        }
        return badges
    }

    func chatStatusActions(for badge: ChatStatusBadge) -> [ChatStatusAction] {
        Self.statusActions(for: badge)
    }

    func performChatStatusAction(_ action: ChatStatusAction) {
        Task { [weak self] in
            await self?.runStatusAction(action)
        }
    }

    var chatSessionDisplayName: String {
        let trimmed = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return session.id == nil ? AppStrings.newConversation : AppStrings.conversation
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

    func updateChatCustomInstructions(global: String, session: String) {
        let normalizedGlobal = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSession = session.trimmingCharacters(in: .whitespacesAndNewlines)
        globalCustomInstructionsText = normalizedGlobal
        sessionCustomInstructionsText = normalizedSession
        CodexCustomInstructionsStore.saveGlobalText(normalizedGlobal)
        if let threadId = threadCoordinator.currentThreadId {
            CodexCustomInstructionsStore.saveSessionText(normalizedSession, threadId: threadId)
        }
    }

    func resetSessionCustomInstructions() {
        updateChatCustomInstructions(global: globalCustomInstructionsText, session: "")
    }

    func newChatSession() {
        Task {
            await disconnectAndReset()
            appendSystem(AppStrings.newConversation)
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
            if threadCoordinator.currentThreadId == nil {
                threadCoordinator.setCurrentThreadId(tid)
            }
            await threadCoordinator.renameCurrentThread(rpc: rpc, name: trimmed)
        }
    }

    func editAndResendLastUser(newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, threadCoordinator.currentThreadId != nil else {
            sendMessage(trimmed)
            return
        }
        Task {
            try? await threadCoordinator.rollbackLastTurn(rpc: rpc)
            if let lastUser = messages.lastIndex(where: { $0.role == .user }) {
                messages.removeSubrange(lastUser...)
            }
            await sendUserMessage(
                [.text(trimmed)],
                display: trimmed,
                interactionMode: chatInteractionMode,
                includeIDEContext: includesIDEContext
            )
        }
    }

    func forkChatFromUserMessage(newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await disconnectAndReset()
            appendSystem(AppStrings.newConversation)
            await sendUserMessage(
                [.text(trimmed)],
                display: trimmed,
                interactionMode: chatInteractionMode,
                includeIDEContext: includesIDEContext
            )
        }
    }

    func startChatReview(command: String?) {
        guard let tid = threadCoordinator.currentThreadId else {
            appendSystem(AppStrings.startConversationBeforeReview)
            return
        }

        let target = Self.reviewTarget(from: command)
        isProcessing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.rpc?.call(
                    method: "review/start",
                    params: [
                        "threadId": tid,
                        "delivery": "inline",
                        "target": target,
                    ]
                )
            } catch {
                self.appendSystem("Codex: impossible de lancer la review (\(error.localizedDescription))")
                self.isProcessing = false
            }
        }
    }

    func approvePendingApprovalRequest() {
        guard let request = pendingApprovalRequest else { return }
        pendingApprovalRequest = nil
        if let rpcRequestID = request.rpcRequestID, let rpcMethod = request.rpcMethod {
            isProcessing = true
            Task { [weak self] in
                await self?.replyToServerRequest(id: rpcRequestID, method: rpcMethod, approved: true)
            }
            return
        }
        Task {
            await sendUserMessage(
                currentRun.inputItems.isEmpty ? [.text(request.prompt)] : currentRun.inputItems,
                display: request.displayText,
                interactionMode: .agent,
                includeIDEContext: currentRun.includesIDEContext,
                appendUserMessage: false
            )
        }
    }

    func dismissPendingApprovalRequest() {
        if let request = pendingApprovalRequest,
           let rpcRequestID = request.rpcRequestID,
           let rpcMethod = request.rpcMethod {
            pendingApprovalRequest = nil
            Task { [weak self] in
                if rpcMethod == "mcpServer/elicitation/request" {
                    await self?.replyToServerRequest(id: rpcRequestID, method: rpcMethod, approved: false)
                } else if rpcMethod == "item/tool/requestUserInput" {
                    await self?.replyUnsupportedServerRequest(
                        id: rpcRequestID,
                        method: rpcMethod,
                        message: "Codex: saisie utilisateur annulee."
                    )
                } else {
                    await self?.replyToServerRequest(id: rpcRequestID, method: rpcMethod, approved: false)
                }
            }
            return
        }
        pendingApprovalRequest = nil
    }

    func submitPendingApprovalRequest(fieldValues: [String: String]) {
        guard let request = pendingApprovalRequest else { return }
        pendingApprovalRequest = nil
        if let rpcRequestID = request.rpcRequestID, let rpcMethod = request.rpcMethod {
            isProcessing = true
            Task { [weak self] in
                await self?.replyToServerRequest(
                    id: rpcRequestID,
                    method: rpcMethod,
                    approved: true,
                    fieldValues: fieldValues
                )
            }
            return
        }
        approvePendingApprovalRequest()
    }

    func listChatSessions(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] {
        Self.ephemeralThreadList(limit: limit, matchingDirectory: matchingDirectory)
    }

    func listChatSessionsAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem] {
        await CodexThreadCoordinator.ephemeralThreadListAsync(limit: limit, matchingDirectory: matchingDirectory)
    }

    static func renameChatSession(id: String, name: String) {
        CodexSessionPersistence.renameChatSession(id: id, name: name)
    }

    static func toolIconName(for toolName: String) -> String {
        ClaudeHeadlessProvider.toolIcon(for: toolName)
    }

    // MARK: - Private session helpers

    private func runStatusAction(_ action: ChatStatusAction) async {
        await ensureConnected()
        guard initialized, let rpc else {
            appendSystem("Codex n'est pas connecte.")
            return
        }

        switch action.id {
        case "mcpReload":
            mcpStatusBadge = ChatStatusBadge(kind: .connecting, text: "MCP recharge…")
            do {
                _ = try await rpc.call(method: "config/mcpServer/reload", params: [:])
                mcpStatusBadge = ChatStatusBadge(kind: .mcpOkay, text: "MCP recharge")
            } catch {
                updateStatusForErrorMessage(error.localizedDescription)
                appendSystem("Reload MCP impossible : \(error.localizedDescription)")
            }
        case "mcpStatusList":
            mcpStatusBadge = ChatStatusBadge(kind: .connecting, text: "MCP status…")
            do {
                let result = try await rpc.call(method: "mcpServerStatus/list", params: [:])
                mcpStatusBadge = Self.badgeFromMCPStatusResult(result)
            } catch {
                updateStatusForErrorMessage(error.localizedDescription)
                appendSystem("Verification MCP impossible : \(error.localizedDescription)")
            }
        case "chatgptAuthRefresh":
            authStatusBadge = ChatStatusBadge(kind: .connecting, text: "Auth ChatGPT…")
            do {
                _ = try await rpc.call(method: "account/chatgptAuthTokens/refresh", params: [:])
                authStatusBadge = nil
            } catch {
                updateStatusForErrorMessage(error.localizedDescription)
                appendSystem("Rafraichissement ChatGPT impossible : \(error.localizedDescription)")
            }
        case "mcpOAuthLogin":
            authStatusBadge = ChatStatusBadge(kind: .connecting, text: "Login MCP…")
            do {
                _ = try await rpc.call(
                    method: "mcpServer/oauth/login",
                    params: ["serverName": "canope"]
                )
                authStatusBadge = nil
                mcpStatusBadge = ChatStatusBadge(kind: .mcpOkay, text: "MCP login")
            } catch {
                updateStatusForErrorMessage(error.localizedDescription)
                appendSystem("Login MCP impossible : \(error.localizedDescription)")
            }
        default:
            break
        }
    }

    private func disconnectAndReset() async {
        connectTask?.cancel()
        connectTask = nil
        toolEventReducer.reset(messages: &messages)
        rpc?.terminate()
        rpc = nil
        initialized = false
        threadCoordinator.clearRuntimeState()
        session = SessionInfo()
        sessionCustomInstructionsText = ""
        chatReviewStateDescription = nil
        reviewStatusBadge = nil
        authStatusBadge = nil
        mcpStatusBadge = nil
        messages.removeAll()
        pendingApprovalRequest = nil
        approvalCoordinator.reset()
        currentRun.reset()
    }

    private func shouldHandleThreadScopedPayload(_ params: [String: Any]) -> Bool {
        guard let payloadThreadID = params["threadId"] as? String,
              !payloadThreadID.isEmpty,
              let currentThreadID = threadCoordinator.currentThreadId,
              !currentThreadID.isEmpty
        else {
            return true
        }

        return payloadThreadID == currentThreadID
    }

    private func resumeThread(id: String) async {
        await disconnectAndReset()
        await connectAndHandshake()
        guard let rpc else { return }
        do {
            if let snapshot = try await threadCoordinator.resumeThread(
                id: id,
                rpc: rpc,
                historyReader: Self.historySnapshot(fromThreadReadResult:)
            ) {
                messages = snapshot.messages
                session.name = snapshot.name
                session.turns = snapshot.turns
                chatReviewStateDescription = snapshot.reviewStateDescription
                reviewStatusBadge = snapshot.reviewStatusBadge
            }
            session.id = id
            sessionCustomInstructionsText = CodexCustomInstructionsStore.loadSessionText(threadId: id)
            appendSystem("Session resumed: \(id.prefix(12))…")
        } catch {
            appendSystem("Could not resume session: \(error.localizedDescription)")
        }
    }

    private func resumeFromList(matchingDirectory: URL) async {
        await disconnectAndReset()
        await connectAndHandshake()
        guard let rpc else { return }
        do {
            if let result = try await threadCoordinator.resumeLatestThread(
                matchingDirectory: matchingDirectory,
                rpc: rpc,
                historyReader: Self.historySnapshot(fromThreadReadResult:)
            ) {
                if let snapshot = result.snapshot {
                    messages = snapshot.messages
                    session.name = snapshot.name ?? result.name
                    session.turns = snapshot.turns
                    chatReviewStateDescription = snapshot.reviewStateDescription
                    reviewStatusBadge = snapshot.reviewStatusBadge
                }
                session.id = result.id
                sessionCustomInstructionsText = CodexCustomInstructionsStore.loadSessionText(threadId: result.id)
                if session.name == nil {
                    session.name = result.name
                }
                appendSystem("Session resumed")
            } else {
                appendSystem("No session found for this folder")
            }
        } catch {
            appendSystem("\(AppStrings.errorPrefix) \(error.localizedDescription)")
        }
    }

    nonisolated static func ephemeralThreadList(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] {
        CodexSessionPersistence.ephemeralThreadList(limit: limit, matchingDirectory: matchingDirectory)
    }

    static func historySnapshot(fromThreadReadResult result: [String: Any]) -> CodexThreadHistorySnapshot? {
        CodexSessionPersistence.historySnapshot(fromThreadReadResult: result)
    }

    nonisolated static func reviewTarget(from command: String?) -> [String: Any] {
        CodexSessionPersistence.reviewTarget(from: command)
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
}

#if DEBUG
extension CodexAppServerProvider {
    func testHandleNotification(method: String, params: [String: Any]) {
        handleNotification(method: method, params: params)
    }

    func testReceiveAssistantDelta(_ delta: String) {
        handleNotification(method: "item/agentMessage/delta", params: ["delta": delta])
    }

    func testBeginAssistantMessage() {
        handleNotification(method: "item/started", params: ["item": ["type": "agentMessage", "id": UUID().uuidString]])
    }

    func testCompleteAssistantMessage() {
        handleNotification(method: "item/completed", params: ["item": ["type": "agentMessage"]])
    }

    func testFlushPendingAssistantDelta() {
        toolEventReducer.flushPendingAssistantDelta(messages: &messages)
        toolEventReducer.clearAssistantDeltaWork()
    }

    func testFlushMarkdownPreRender() {
        toolEventReducer.flushMarkdownPreRender(into: &messages)
    }

    func testHandleServerRequest(id: Int, method: String, params: [String: Any]) {
        handleServerRequest(id: id, method: method, params: params)
    }

    func testSetCurrentRunState(
        interactionMode: ChatInteractionMode,
        prompt: String = "",
        displayText: String = ""
    ) {
        currentRun.configure(
            interactionMode: interactionMode,
            includesIDEContext: currentRun.includesIDEContext,
            inputItems: prompt.isEmpty ? [] : [.text(prompt)],
            prompt: prompt,
            displayText: displayText
        )
    }

    func testResolvePendingMarkdownSynchronously() {
        toolEventReducer.flushMarkdownPreRender(into: &messages)
    }

    var testPendingMarkdownCount: Int {
        toolEventReducer.pendingMarkdownCount
    }

    static func testServerRequestFields(method: String, params: [String: Any]) -> [ChatInteractiveField] {
        serverRequestFields(method: method, params: params)
    }

    static func testToolRequestUserInputResponseResult(
        params: [String: Any],
        fieldValues: [String: String]
    ) -> [String: Any] {
        toolRequestUserInputResponseResult(from: params, fieldValues: fieldValues)
    }

    static func testMcpElicitationResponseResult(
        params: [String: Any],
        approved: Bool,
        fieldValues: [String: String] = [:]
    ) -> [String: Any] {
        elicitationResponseResult(from: params, approved: approved, fieldValues: fieldValues)
    }

    static func testReviewTarget(command: String?) -> [String: Any] {
        reviewTarget(from: command)
    }

    static func testServerRequestDetails(method: String, params: [String: Any]) -> [String] {
        serverRequestDetails(method: method, params: params)
    }

    static func testServerRequestPreview(method: String, params: [String: Any]) -> ChatApprovalPreview? {
        serverRequestPreview(method: method, params: params)
    }

    static func testParseReviewOutput(_ text: String) -> (summary: String?, findings: [ChatReviewFinding]) {
        parseReviewOutput(text)
    }

    static func testDynamicToolCallInputPreview(_ item: [String: Any]) -> String? {
        dynamicToolCallInputPreview(item)
    }

    static func testCollabAgentToolCallInputPreview(_ item: [String: Any]) -> String? {
        collabAgentToolCallInputPreview(item)
    }

    static func testWebSearchInputPreview(_ item: [String: Any]) -> String? {
        webSearchInputPreview(item)
    }

    static func testDerivedStatusBadgesForServerRequest(
        method: String,
        disposition: ServerRequestDisposition
    ) -> (auth: ChatStatusBadge?, mcp: ChatStatusBadge?, review: ChatStatusBadge?) {
        derivedStatusBadges(forServerRequestMethod: method, disposition: disposition)
    }

    static func testDerivedStatusBadgesForErrorText(
        _ text: String
    ) -> (auth: ChatStatusBadge?, mcp: ChatStatusBadge?, review: ChatStatusBadge?) {
        derivedStatusBadges(forErrorText: text)
    }

    static func testStatusActions(for badge: ChatStatusBadge) -> [ChatStatusAction] {
        statusActions(for: badge)
    }

    static func testBadgeFromMCPStatusResult(_ result: Any?) -> ChatStatusBadge {
        badgeFromMCPStatusResult(result)
    }

    func testSetStatusBadges(review: ChatStatusBadge? = nil, auth: ChatStatusBadge? = nil, mcp: ChatStatusBadge? = nil) {
        reviewStatusBadge = review
        authStatusBadge = auth
        mcpStatusBadge = mcp
    }

    func testSetConnectionState(isConnected: Bool, initialized: Bool) {
        self.isConnected = isConnected
        self.initialized = initialized
    }

    func testSetProcessing(_ isProcessing: Bool) {
        self.isProcessing = isProcessing
    }

    func testSetCurrentThreadId(_ id: String?) {
        threadCoordinator.setCurrentThreadId(id)
        session.id = id
    }

    func testSetCurrentTurnId(_ id: String?) {
        threadCoordinator.setCurrentTurnId(id)
    }

    var testCurrentTurnId: String? {
        threadCoordinator.currentTurnId
    }

    static func testStoredSessionCustomInstructions(threadId: String) -> String {
        CodexCustomInstructionsStore.loadSessionText(threadId: threadId)
    }

    static func testClearStoredCustomInstructions() {
        CodexCustomInstructionsStore.clearAll()
    }
}
#endif

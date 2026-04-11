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

private func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let i as Int: return i
    case let d as Double: return Int(d)
    case let n as NSNumber: return n.intValue
    default: return nil
    }
}

private extension String {
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
    private var currentRun = CodexCurrentRunState()
    private var currentAssistantMessageIndex: Int?
    private var currentAgentItemId: String?
    private var lastRetryStatusMessage: String?
    private var pendingAssistantDelta = ""
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var pendingMarkdown: [(UUID, String)] = []
    private var markdownTask: Task<Void, Never>?
    private var itemToolUseMessageIndex: [String: Int] = [:]
    private var itemOutputBuffers: [String: String] = [:]

    private static let assistantDeltaThrottleNanoseconds: UInt64 = 60_000_000
    private static let markdownPreRenderDelayNanoseconds: UInt64 = 80_000_000

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
        assistantDeltaFlushTask?.cancel()
        markdownTask?.cancel()
        rpc?.terminate()
    }

    func start() {
        isConnected = true
        _ = beginConnectionIfNeeded()
    }

    func stop() {
        Task { await interruptIfNeeded() }
        flushPendingAssistantDelta()
        clearAssistantDeltaWork()
        clearMarkdownPreRenderWork()
        approvalCoordinator.reset()
        itemToolUseMessageIndex.removeAll()
        itemOutputBuffers.removeAll()
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

        let args = Self.buildAppServerArguments(bridgeURL: Self.resolvedBridgeURL())

        do {
            let env = Self.buildProcessEnvironment()
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
        currentAssistantMessageIndex = nil
        currentAgentItemId = nil
        lastRetryStatusMessage = nil
        itemToolUseMessageIndex.removeAll()
        itemOutputBuffers.removeAll()
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
        let paramsSummary = Self.jsonString(params) ?? "{}"
        CodexTraceLog.write("notification \(method) params=\(paramsSummary)")
        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let tid = turn["id"] as? String {
                threadCoordinator.setCurrentTurnId(tid)
            }
        case "item/started":
            if let item = params["item"] as? [String: Any] {
                handleItemStarted(item)
            }
        case "item/agentMessage/delta":
            let delta = extractDeltaText(params) ?? ""
            bufferAssistantDelta(delta, itemID: params["itemId"] as? String)
        case "item/plan/delta":
            let delta = extractDeltaText(params) ?? ""
            bufferAssistantDelta(delta, itemID: params["itemId"] as? String)
        case "item/commandExecution/outputDelta",
             "item/fileChange/outputDelta":
            if let itemID = params["itemId"] as? String {
                let delta = extractDeltaText(params)
                    ?? (params["output"] as? String)
                    ?? (params["aggregatedOutput"] as? String)
                    ?? ""
                if !delta.isEmpty {
                    itemOutputBuffers[itemID, default: ""].append(delta)
                }
            }
        case "item/completed":
            flushPendingAssistantDelta()
            clearAssistantDeltaWork()
            if let item = params["item"] as? [String: Any] {
                handleItemCompleted(item)
            }
        case "turn/completed":
            flushPendingAssistantDelta()
            clearAssistantDeltaWork()
            if let idx = currentAssistantMessageIndex, idx < messages.count {
                messages[idx].isStreaming = false
                enqueueMarkdownPreRender(for: messages[idx].id, text: messages[idx].content)
                currentAssistantMessageIndex = nil
            }
            isProcessing = false
            threadCoordinator.setCurrentTurnId(nil)
            lastRetryStatusMessage = nil
            approvalCoordinator.reset()
        case "turn/plan/updated":
            handleTurnPlanUpdated(params)
        case "serverRequest/resolved":
            if let requestId = jsonInt(params["requestId"]) {
                approvalCoordinator.removeRequest(id: requestId)
                if pendingApprovalRequest?.rpcRequestID == requestId {
                    pendingApprovalRequest = nil
                }
            }
        case "item/commandExecution/approvalResolved",
             "item/fileChange/approvalResolved",
             "item/tool/requestUserInputResolved":
            clearResolvedApproval(for: params["itemId"] as? String)
        case "error":
            let errorPayload = params["error"] as? [String: Any]
            let message = (errorPayload?["message"] as? String)
                ?? (params["message"] as? String)
                ?? AppStrings.codexError
            let details = errorPayload?["additionalDetails"] as? String
            let rendered = [message, details]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n")
            let willRetry = params["willRetry"] as? Bool ?? false

            flushPendingAssistantDelta()
            clearAssistantDeltaWork()
            if !willRetry || lastRetryStatusMessage != rendered {
                appendSystem(rendered)
            }
            updateStatusForErrorMessage(rendered)

            if willRetry {
                lastRetryStatusMessage = rendered
            } else {
                lastRetryStatusMessage = nil
                isProcessing = false
                threadCoordinator.setCurrentTurnId(nil)
            }
        default:
            break
        }
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
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
        clearAssistantDeltaWork()
        let itemID = (item["id"] as? String) ?? UUID().uuidString
        currentAgentItemId = itemID
        let text = (item["text"] as? String) ?? ""
        let presentationKind: ChatMessage.PresentationKind = type == "plan" ? .plan : (currentRun.interactionMode == .plan ? .plan : .standard)
        let message = ChatMessage(
            role: .assistant,
            content: text,
            timestamp: Date(),
            isStreaming: true,
            isCollapsed: false,
            presentationKind: presentationKind
        )
        messages.append(message)
        currentAssistantMessageIndex = messages.count - 1
        if !text.isEmpty {
            enqueueMarkdownPreRender(for: message.id, text: text)
        }
    }

    private func handleMCPToolCallStarted(_ item: [String: Any]) {
        let toolName = (item["tool"] as? String) ?? ""
        let itemID = (item["id"] as? String) ?? ""
        CodexTraceLog.write("handleMCPToolCallStarted tool=\(toolName) itemId=\(itemID)")
        flushPendingAssistantDelta()
        clearAssistantDeltaWork()
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
                summary: Self.completedCommandExecutionSummary(item, bufferedOutput: itemOutputBuffers[item["id"] as? String ?? ""])
            )
        case "fileChange":
            completeToolItem(
                itemID: item["id"] as? String,
                toolName: "Edit",
                summary: Self.completedFileChangeSummary(item, bufferedOutput: itemOutputBuffers[item["id"] as? String ?? ""])
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
        if let text = item["text"] as? String,
           let idx = currentAssistantMessageIndex,
           idx < messages.count,
           messages[idx].content.isEmpty {
            messages[idx].content = text
        }

        if let idx = currentAssistantMessageIndex, idx < messages.count {
            messages[idx].isStreaming = false
            enqueueMarkdownPreRender(for: messages[idx].id, text: messages[idx].content)
        }
        currentAssistantMessageIndex = nil
        currentAgentItemId = nil
    }

    private func appendToolUseItem(itemID: String?, toolName: String, content: String, toolInput: String?) {
        messages.append(
            ChatMessage(
                role: .toolUse,
                content: content,
                timestamp: Date(),
                toolName: toolName,
                toolInput: toolInput,
                isStreaming: false,
                isCollapsed: true
            )
        )
        if let itemID {
            itemToolUseMessageIndex[itemID] = messages.count - 1
        }
    }

    private func completeToolItem(itemID: String?, toolName: String, summary: String?) {
        guard let summary, !summary.isEmpty else { return }
        if let itemID,
           let idx = itemToolUseMessageIndex[itemID],
           idx < messages.count {
            messages[idx].toolOutput = summary
            messages[idx].isCollapsed = true
            itemToolUseMessageIndex.removeValue(forKey: itemID)
            itemOutputBuffers.removeValue(forKey: itemID)
            return
        }
        messages.append(
            ChatMessage(
                role: .toolResult,
                content: summary,
                timestamp: Date(),
                toolName: toolName,
                isStreaming: false,
                isCollapsed: false
            )
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
        guard currentAssistantMessageIndex == nil,
              let plan = params["plan"] as? [[String: Any]],
              !plan.isEmpty
        else { return }
        let text = Self.renderPlanText(plan: plan, explanation: params["explanation"] as? String)
        messages.append(
            ChatMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false,
                presentationKind: .plan
            )
        )
        if let id = messages.last?.id {
            enqueueMarkdownPreRender(for: id, text: text)
        }
    }

    private func clearResolvedApproval(for itemID: String?) {
        approvalCoordinator.clearResolvedApproval(for: itemID, pendingApprovalRequest: &pendingApprovalRequest)
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

    private func bufferAssistantDelta(_ delta: String, itemID: String?) {
        guard !delta.isEmpty,
              let idx = assistantMessageIndex(for: itemID),
              idx < messages.count
        else { return }
        let itemIDSummary = itemID ?? ""
        CodexTraceLog.write("assistantDelta itemId=\(itemIDSummary) chars=\(delta.count)")
        if let itemID, currentAgentItemId == nil {
            currentAgentItemId = itemID
        }
        pendingAssistantDelta += delta
        messages[idx].isStreaming = true
        scheduleAssistantDeltaFlushIfNeeded()
    }

    private func assistantMessageIndex(for itemID: String?) -> Int? {
        if let itemID,
           let currentAgentItemId,
           currentAgentItemId == itemID,
           let currentAssistantMessageIndex,
           currentAssistantMessageIndex < messages.count {
            return currentAssistantMessageIndex
        }
        if itemID == nil,
           let currentAssistantMessageIndex,
           currentAssistantMessageIndex < messages.count {
            return currentAssistantMessageIndex
        }
        return currentAssistantMessageIndex
    }

    private func scheduleAssistantDeltaFlushIfNeeded() {
        guard assistantDeltaFlushTask == nil else { return }
        assistantDeltaFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.assistantDeltaThrottleNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.assistantDeltaFlushTask = nil
            self.flushPendingAssistantDelta()
        }
    }

    private func flushPendingAssistantDelta() {
        guard !pendingAssistantDelta.isEmpty else { return }
        guard let idx = currentAssistantMessageIndex, idx < messages.count else {
            pendingAssistantDelta.removeAll()
            return
        }
        let merged = messages[idx].content + pendingAssistantDelta
        messages[idx].content = Self.sanitizeAssistantDisplayText(merged)
        messages[idx].isStreaming = true
        pendingAssistantDelta.removeAll()
    }

    private func clearAssistantDeltaWork() {
        assistantDeltaFlushTask?.cancel()
        assistantDeltaFlushTask = nil
        pendingAssistantDelta.removeAll()
    }

    private static func sanitizeAssistantDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let paragraphs = trimmed.components(separatedBy: "\n\n")
        let filtered = paragraphs.filter { paragraph in
            let normalized = paragraph.folding(
                options: [String.CompareOptions.diacriticInsensitive, String.CompareOptions.caseInsensitive],
                locale: Locale.current
            )
            if normalized.contains("l'edition directe a echoue") { return false }
            if normalized.contains("the direct edit failed") { return false }
            if normalized.contains("direct edit failed") { return false }
            if normalized.contains("i couldn't find the exact text") { return false }
            if normalized.contains("je n'ai pas trouve le texte exact") { return false }
            if normalized.contains("le texte exact") && normalized.contains("pas ete retrouve") { return false }
            if normalized.contains("exact text") && normalized.contains("not found") { return false }
            return true
        }

        guard !filtered.isEmpty else { return "" }
        return filtered.joined(separator: "\n\n")
    }

    private func enqueueMarkdownPreRender(for id: UUID, text: String) {
        guard !text.isEmpty else { return }
        guard !ChatMarkdownPolicy.shouldSkipFullMarkdown(for: text) else { return }
        pendingMarkdown.append((id, text))
        scheduleMarkdownPreRender()
    }

    private func scheduleMarkdownPreRender() {
        markdownTask?.cancel()
        markdownTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: Self.markdownPreRenderDelayNanoseconds)
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
                let attr = MarkdownBlockView.renderAttributedPreviewForBackground(text)
                results.append((id, attr))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, attr) in results {
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        self.messages[idx].preRenderedMarkdown = attr
                        ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &self.messages)
                    }
                }
                self.markdownTask = nil
            }
        }
    }

    private func clearMarkdownPreRenderWork() {
        pendingMarkdown.removeAll()
        markdownTask?.cancel()
        markdownTask = nil
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

    private static func jsonString(_ obj: Any?) -> String? {
        guard let obj else { return nil }
        if let s = obj as? String { return s }
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: d, encoding: .utf8)
        else { return String(describing: obj) }
        return str
    }

    private static func commandExecutionSummary(_ item: [String: Any]) -> String {
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = (item["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command, !command.isEmpty, let cwd, !cwd.isEmpty {
            return "\(command) · \(cwd)"
        }
        if let command, !command.isEmpty {
            return command
        }
        return "Command in progress"
    }

    private static func fileChangeSummary(_ item: [String: Any]) -> String {
        if let changes = item["changes"] as? [[String: Any]], !changes.isEmpty {
            let firstPath = (changes.first?["path"] as? String) ?? (changes.first?["newPath"] as? String)
            if let firstPath, !firstPath.isEmpty {
                return "Modification proposee · \((firstPath as NSString).lastPathComponent)"
            }
            return "Modification proposee · \(changes.count) fichier(s)"
        }
        return "Modification proposee"
    }

    private static func completedCommandExecutionSummary(_ item: [String: Any], bufferedOutput: String?) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command"
        let exitCode = jsonInt(item["exitCode"])
        let output = ((item["aggregatedOutput"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            ?? (bufferedOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        let statusLabel: String
        switch status {
        case "declined":
            statusLabel = AppStrings.commandDeclined
        case "failed":
            statusLabel = AppStrings.commandFailed
        default:
            statusLabel = AppStrings.commandCompleted
        }
        let suffix = exitCode.map { " (code \($0))" } ?? ""
        if let output {
            return "\(statusLabel)\(suffix) · \(command)\n\(output)"
        }
        return "\(statusLabel)\(suffix) · \(command)"
    }

    private static func completedFileChangeSummary(_ item: [String: Any], bufferedOutput: String?) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let base = fileChangeSummary(item)
        let output = (bufferedOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        switch status {
        case "declined":
            return "\(base) \(AppStrings.changeDeclined)"
        case "failed":
            if let output, !output.isEmpty {
                return "\(base) \(AppStrings.changeNotApplied)"
            }
            return "\(base) \(AppStrings.changeNotApplied)"
        default:
            if let output {
                return "\(base) \(AppStrings.changeApplied)\n\(output)"
            }
            return "\(base) \(AppStrings.changeApplied)"
        }
    }

    private static func completedDynamicToolCallSummary(_ item: [String: Any]) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let text = extractText(fromContentItems: item["contentItems"] as? [[String: Any]])
        switch status {
        case "failed":
            return text ?? AppStrings.toolCallFailed
        default:
            return text ?? AppStrings.toolCallCompleted
        }
    }

    private static func dynamicToolCallSummary(_ item: [String: Any]) -> String {
        if let tool = (item["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
            if let argsPreview = compactKeyValuePreview(
                from: item["arguments"] as? [String: Any],
                preferredKeys: ["path", "filePath", "query", "url", "cwd", "pattern"],
                maxLines: 1
            ) {
                return "Dynamic call · \(tool) · \(argsPreview.replacingOccurrences(of: "\n", with: " · "))"
            }
            return "Dynamic call · \(tool)"
        }
        return "Dynamic tool call"
    }

    private static func dynamicToolCallInputPreview(_ item: [String: Any]) -> String? {
        compactKeyValuePreview(
            from: item["arguments"] as? [String: Any],
            preferredKeys: ["path", "filePath", "query", "url", "cwd", "pattern", "command", "text"],
            maxLines: 5
        )
    }

    private static func webSearchSummary(_ item: [String: Any]) -> String {
        let query = (item["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = (item["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let query, !query.isEmpty, let action {
            return "Recherche web · \(query) · \(action)"
        }
        if let query, !query.isEmpty {
            return "Recherche web · \(query)"
        }
        return "Recherche web"
    }

    private static func webSearchInputPreview(_ item: [String: Any]) -> String? {
        var lines: [String] = []
        if let query = (item["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            lines.append("query: \(query)")
        }
        if let action = (item["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            lines.append("action: \(action)")
        }
        if let domains = item["allowedDomains"] as? [String], !domains.isEmpty {
            lines.append("domains: \(domains.prefix(3).joined(separator: ", "))")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func completedWebSearchSummary(_ item: [String: Any]) -> String? {
        let base = webSearchSummary(item)
        if let action = (item["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return "\(base)\nAction: \(action)"
        }
        return base
    }

    private static func imageViewSummary(_ item: [String: Any]) -> String {
        if let path = (item["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return "Image ouverte · \((path as NSString).lastPathComponent)"
        }
        return "Image ouverte"
    }

    private static func completedImageViewSummary(_ item: [String: Any]) -> String? {
        imageViewSummary(item)
    }

    private static func collabAgentToolCallSummary(_ item: [String: Any]) -> String {
        let tool = (item["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = (item["senderThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (item["targetThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tool, !tool.isEmpty, let sender, !sender.isEmpty, let target, !target.isEmpty {
            return "Collab agent · \(tool) · \(sender.prefix(6)) → \(target.prefix(6))"
        }
        if let tool, !tool.isEmpty, let sender, !sender.isEmpty {
            return "Collab agent · \(tool) · \(sender.prefix(8))"
        }
        if let tool, !tool.isEmpty {
            return "Collab agent · \(tool)"
        }
        return "Collab agent"
    }

    private static func collabAgentToolCallInputPreview(_ item: [String: Any]) -> String? {
        var lines: [String] = []
        if let sender = (item["senderThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            lines.append("sender: \(sender)")
        }
        if let target = (item["targetThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            lines.append("target: \(target)")
        }
        if let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            lines.append("status: \(status)")
        }
        if let argumentsPreview = compactKeyValuePreview(
            from: item["arguments"] as? [String: Any],
            preferredKeys: ["path", "query", "url", "cwd"],
            maxLines: 2
        ), !argumentsPreview.isEmpty {
            lines.append(argumentsPreview)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func completedCollabAgentToolCallSummary(_ item: [String: Any]) -> String? {
        let base = collabAgentToolCallSummary(item)
        if let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return "\(base)\nStatut: \(status)"
        }
        return base
    }

    private static func compactKeyValuePreview(
        from dictionary: [String: Any]?,
        preferredKeys: [String],
        maxLines: Int
    ) -> String? {
        guard let dictionary, !dictionary.isEmpty else { return nil }

        var orderedKeys: [String] = []
        for key in preferredKeys where dictionary[key] != nil {
            orderedKeys.append(key)
        }
        for key in dictionary.keys.sorted() where !orderedKeys.contains(key) {
            orderedKeys.append(key)
        }

        var lines: [String] = []
        for key in orderedKeys {
            guard let value = dictionary[key],
                  let previewValue = compactPreviewValue(value),
                  !previewValue.isEmpty
            else { continue }
            lines.append("\(key): \(previewValue)")
            if lines.count >= maxLines { break }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func compactPreviewValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case let number as NSNumber:
            return number.stringValue
        case let array as [String]:
            let trimmed = array
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !trimmed.isEmpty else { return nil }
            let prefix = trimmed.prefix(3).joined(separator: ", ")
            return trimmed.count > 3 ? "\(prefix), …" : prefix
        case let array as [Any]:
            let values = array.compactMap { compactPreviewValue($0) }
            guard !values.isEmpty else { return nil }
            let prefix = values.prefix(3).joined(separator: ", ")
            return values.count > 3 ? "\(prefix), …" : prefix
        case let nested as [String: Any]:
            return compactKeyValuePreview(from: nested, preferredKeys: Array(nested.keys.sorted()), maxLines: 1)?
                .replacingOccurrences(of: "\n", with: " · ")
        default:
            return nil
        }
    }

    private static func derivedStatusBadges(
        forServerRequestMethod method: String,
        disposition: ServerRequestDisposition
    ) -> (auth: ChatStatusBadge?, mcp: ChatStatusBadge?, review: ChatStatusBadge?) {
        switch method {
        case "account/chatgptAuthTokens/refresh":
            return (ChatStatusBadge(kind: .authRequired, text: "ChatGPT login"), nil, nil)
        case "mcpServer/oauth/login":
            return (ChatStatusBadge(kind: .authRequired, text: "Login MCP"), ChatStatusBadge(kind: .mcpWarning, text: "MCP login"), nil)
        case "config/mcpServer/reload":
            let kind: ChatStatusBadgeKind = disposition == .unsupported || disposition == .reject ? .mcpWarning : .mcpOkay
            let text = disposition == .unsupported || disposition == .reject ? "MCP reload" : "MCP recharge"
            return (nil, ChatStatusBadge(kind: kind, text: text), nil)
        case "mcpServerStatus/list":
            let kind: ChatStatusBadgeKind = disposition == .unsupported || disposition == .reject ? .mcpWarning : .mcpOkay
            return (nil, ChatStatusBadge(kind: kind, text: kind == .mcpOkay ? "MCP status" : "MCP attention"), nil)
        case let value where value.hasPrefix("mcpServer/"):
            let kind: ChatStatusBadgeKind = disposition == .unsupported || disposition == .reject ? .mcpWarning : .mcpOkay
            return (nil, ChatStatusBadge(kind: kind, text: kind == .mcpOkay ? "MCP OK" : "MCP attention"), nil)
        default:
            return (nil, nil, nil)
        }
    }

    private static func derivedStatusBadges(
        forErrorText text: String
    ) -> (auth: ChatStatusBadge?, mcp: ChatStatusBadge?, review: ChatStatusBadge?) {
        let lower = text.lowercased()
        let auth: ChatStatusBadge?
        if lower.contains("chatgpt") && (lower.contains("auth") || lower.contains("token") || lower.contains("login")) {
            auth = ChatStatusBadge(kind: .authRequired, text: "ChatGPT login")
        } else if lower.contains("oauth") || lower.contains("login") || lower.contains("auth") || lower.contains("token") {
            auth = ChatStatusBadge(kind: .authRequired, text: "Auth requise")
        } else {
            auth = nil
        }

        let mcp: ChatStatusBadge?
        if lower.contains("mcp") && lower.contains("reload") {
            mcp = ChatStatusBadge(kind: .mcpWarning, text: "MCP reload")
        } else if lower.contains("mcp") && (lower.contains("transport") || lower.contains("broken pipe") || lower.contains("connection reset")) {
            mcp = ChatStatusBadge(kind: .mcpWarning, text: "MCP transport")
        } else if lower.contains("mcp") {
            mcp = ChatStatusBadge(kind: .mcpWarning, text: "MCP attention")
        } else {
            mcp = nil
        }

        let review: ChatStatusBadge?
        if lower.contains("review") {
            review = ChatStatusBadge(kind: .reviewAttention, text: "Review attention")
        } else {
            review = nil
        }

        return (auth, mcp, review)
    }

    private static func statusActions(for badge: ChatStatusBadge) -> [ChatStatusAction] {
        switch badge.kind {
        case .authRequired:
            if badge.text == "ChatGPT login" {
                return [
                    ChatStatusAction(
                        id: "chatgptAuthRefresh",
                        label: "Rafraichir l'auth ChatGPT",
                        systemImage: "arrow.clockwise"
                    ),
                ]
            }
            return [
                ChatStatusAction(
                    id: "mcpOAuthLogin",
                    label: "Relancer le login MCP",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                ),
                ChatStatusAction(
                    id: "mcpStatusList",
                    label: "Verifier l'etat MCP",
                    systemImage: "server.rack"
                ),
            ]
        case .mcpOkay:
            return [
                ChatStatusAction(
                    id: "mcpStatusList",
                    label: "Verifier l'etat MCP",
                    systemImage: "server.rack"
                ),
                ChatStatusAction(
                    id: "mcpReload",
                    label: "Recharger la config MCP",
                    systemImage: "arrow.triangle.2.circlepath"
                ),
            ]
        case .mcpWarning:
            return [
                ChatStatusAction(
                    id: "mcpReload",
                    label: "Recharger la config MCP",
                    systemImage: "arrow.triangle.2.circlepath"
                ),
                ChatStatusAction(
                    id: "mcpStatusList",
                    label: "Verifier l'etat MCP",
                    systemImage: "server.rack"
                ),
            ]
        default:
            return []
        }
    }

    private static func reviewStateDescription(_ item: [String: Any]) -> String {
        let review = (item["review"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let review, !review.isEmpty {
            return "Review actif · \(review)"
        }
        return "Review actif"
    }

    private func appendExitedReviewModeMessages(_ item: [String: Any]) {
        guard let rendered = (item["review"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rendered.isEmpty
        else {
            return
        }

        let parsed = Self.parseReviewOutput(rendered)
        if let summary = parsed.summary, !summary.isEmpty {
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: summary,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
            )
        }

        for finding in parsed.findings {
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: finding.body,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false,
                    presentationKind: .reviewFinding,
                    reviewFinding: finding
                )
            )
        }
    }

    private static func parseReviewOutput(_ rendered: String) -> (summary: String?, findings: [ChatReviewFinding]) {
        let normalized = rendered
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return (nil, []) }

        let lines = normalized.components(separatedBy: "\n")
        let findingStarts = lines.indices.filter { index in
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("[P") && line.contains("]")
        }

        guard let firstStart = findingStarts.first else {
            return (normalized, [])
        }

        let prefix = lines[..<firstStart]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = prefix
            .replacingOccurrences(of: "Review Findings:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var findings: [ChatReviewFinding] = []
        for (offset, start) in findingStarts.enumerated() {
            let end = offset + 1 < findingStarts.count ? findingStarts[offset + 1] : lines.count
            let block = Array(lines[start..<end])
            guard let finding = parseRenderedReviewFinding(block) else { continue }
            findings.append(finding)
        }
        return (summary, findings)
    }

    private static func parseRenderedReviewFinding(_ blockLines: [String]) -> ChatReviewFinding? {
        guard let firstLineRaw = blockLines.first else { return nil }
        let firstLine = firstLineRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty else { return nil }

        let titleRegex = try? NSRegularExpression(pattern: #"^\[P([0-3])\]\s*(.+)$"#)
        let nsTitle = firstLine as NSString
        let titleRange = NSRange(location: 0, length: nsTitle.length)
        let titleMatch = titleRegex?.firstMatch(in: firstLine, range: titleRange)

        let priority = titleMatch.flatMap { match -> Int? in
            guard match.numberOfRanges > 1 else { return nil }
            return Int(nsTitle.substring(with: match.range(at: 1)))
        }
        let title = titleMatch.map { match -> String in
            guard match.numberOfRanges > 2 else { return firstLine }
            return nsTitle.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? firstLine

        var bodyLines: [String] = []
        var filePath: String?
        var lineStart: Int?
        var lineEnd: Int?
        var confidenceScore: Double?

        for rawLine in blockLines.dropFirst() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Location:") {
                let location = String(trimmed.dropFirst("Location:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = parseReviewLocation(location)
                filePath = parsed.path
                lineStart = parsed.start
                lineEnd = parsed.end
                continue
            }
            if trimmed.lowercased().hasPrefix("confidence:") {
                let raw = String(trimmed.dropFirst("Confidence:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                confidenceScore = Double(raw)
                continue
            }
            bodyLines.append(rawLine)
        }

        let body = bodyLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ChatReviewFinding(
            title: title,
            body: body.isEmpty ? title : body,
            filePath: filePath,
            lineStart: lineStart,
            lineEnd: lineEnd,
            priority: priority,
            confidenceScore: confidenceScore
        )
    }

    private static func parseReviewLocation(_ location: String) -> (path: String?, start: Int?, end: Int?) {
        let regex = try? NSRegularExpression(pattern: #"^(.*?):(\d+)(?:-(\d+))?$"#)
        let nsLocation = location as NSString
        let range = NSRange(location: 0, length: nsLocation.length)
        guard let match = regex?.firstMatch(in: location, range: range), match.numberOfRanges >= 3 else {
            return (location.nilIfEmpty, nil, nil)
        }

        let path = nsLocation.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Int(nsLocation.substring(with: match.range(at: 2)))
        let end: Int? = {
            guard match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound else { return nil }
            return Int(nsLocation.substring(with: match.range(at: 3)))
        }()
        return (path.nilIfEmpty, start, end)
    }

    private static func extractText(fromContentItems items: [[String: Any]]?) -> String? {
        items?
            .compactMap { item in
                if let text = item["text"] as? String { return text }
                if let text = item["content"] as? String { return text }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func renderPlanText(plan: [[String: Any]], explanation: String?) -> String {
        var lines: [String] = []
        if let explanation, !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Objectif")
            lines.append(explanation)
            lines.append("")
        }
        lines.append("Plan")
        for (index, step) in plan.enumerated() {
            let status = (step["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (step["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Etape \(index + 1)"
            if let status, !status.isEmpty {
                lines.append("\(index + 1). [\(status)] \(text)")
            } else {
                lines.append("\(index + 1). \(text)")
            }
        }
        return lines.joined(separator: "\n")
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
        let bridgeURLToml = bridgeURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let argsToml = "[\"-y\", \"mcp-remote\", \"\(bridgeURLToml)\", \"--transport\", \"sse-only\"]"
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

    nonisolated static func buildProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        for entry in CanopeContextFiles.terminalEnvironment {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }

        let shell = env["SHELL"] ?? "/bin/zsh"
        let applied = ClaudeCLIWrapperService.shared.apply(
            to: env.map { "\($0.key)=\($0.value)" },
            shellPath: shell
        )

        var normalized: [String: String] = [:]
        for entry in applied {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                normalized[String(parts[0])] = String(parts[1])
            }
        }

        if normalized["PATH"]?.isEmpty != false {
            normalized["PATH"] = [
                "/Users/\(NSUserName())/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                "/Library/TeX/texbin",
            ].joined(separator: ":")
        }

        return normalized
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
        await Self.ephemeralThreadListAsync(limit: limit, matchingDirectory: matchingDirectory)
    }

    static func renameChatSession(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            try? await CodexThreadCoordinator.ephemeralRename(threadId: id, name: trimmed)
        }
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

    private static func badgeFromMCPStatusResult(_ result: Any?) -> ChatStatusBadge {
        guard let result else {
            return ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")
        }

        let statusStrings = collectLowercasedStatusStrings(from: result)
        if statusStrings.contains(where: { $0.contains("error") || $0.contains("failed") || $0.contains("disconnected") }) {
            return ChatStatusBadge(kind: .mcpWarning, text: "MCP attention")
        }
        if statusStrings.contains(where: { $0.contains("auth") || $0.contains("login") || $0.contains("oauth") }) {
            return ChatStatusBadge(kind: .mcpWarning, text: "MCP login")
        }
        return ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")
    }

    private static func collectLowercasedStatusStrings(from value: Any) -> [String] {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed.lowercased()]
        case let dict as [String: Any]:
            return dict.values.flatMap { collectLowercasedStatusStrings(from: $0) }
        case let array as [Any]:
            return array.flatMap { collectLowercasedStatusStrings(from: $0) }
        default:
            return []
        }
    }

    private func disconnectAndReset() async {
        connectTask?.cancel()
        connectTask = nil
        clearAssistantDeltaWork()
        clearMarkdownPreRenderWork()
        rpc?.terminate()
        rpc = nil
        initialized = false
        threadCoordinator.clearRuntimeState()
        currentAssistantMessageIndex = nil
        lastRetryStatusMessage = nil
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
        itemToolUseMessageIndex.removeAll()
        itemOutputBuffers.removeAll()
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

    private static func ephemeralRename(threadId: String, name: String) async throws {
        await MainActor.run {
            ClaudeIDEBridgeService.shared.startIfNeeded()
            CanopeContextFiles.writeClaudeIDEMcpConfig()
        }
        let args = buildAppServerArguments(bridgeURL: resolvedBridgeStatic())
        let session = CodexAppServerRPCSession()
        let env = buildProcessEnvironment()
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
        let env = buildProcessEnvironment()
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

    nonisolated private static func reviewTarget(from command: String?) -> [String: Any] {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return ["type": "uncommittedChanges"]
        }

        if trimmed.hasPrefix("branch ") {
            let branch = String(trimmed.dropFirst("branch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return ["type": "uncommittedChanges"] }
            return [
                "type": "baseBranch",
                "branch": branch,
            ]
        }

        if trimmed.hasPrefix("commit ") {
            let sha = String(trimmed.dropFirst("commit ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { return ["type": "uncommittedChanges"] }
            return [
                "type": "commit",
                "sha": sha,
            ]
        }

        return [
            "type": "custom",
            "instructions": trimmed,
        ]
    }

    static func historySnapshot(fromThreadReadResult result: [String: Any]) -> CodexThreadHistorySnapshot? {
        guard let thread = result["thread"] as? [String: Any] else { return nil }
        let turns = thread["turns"] as? [[String: Any]] ?? []
        var messages: [ChatMessage] = []
        var reviewStateDescription: String?
        var reviewStatusBadge: ChatStatusBadge?

        for turn in turns {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                messages.append(contentsOf: historyMessages(
                    for: item,
                    reviewStateDescription: &reviewStateDescription,
                    reviewStatusBadge: &reviewStatusBadge
                ))
            }
        }

        return CodexThreadHistorySnapshot(
            name: thread["name"] as? String,
            turns: turns.count,
            messages: messages,
            reviewStateDescription: reviewStateDescription,
            reviewStatusBadge: reviewStatusBadge
        )
    }

    private static func historyMessages(
        for item: [String: Any],
        reviewStateDescription currentReviewStateDescription: inout String?,
        reviewStatusBadge currentReviewStatusBadge: inout ChatStatusBadge?
    ) -> [ChatMessage] {
        guard let type = item["type"] as? String else { return [] }

        switch type {
        case "userMessage":
            guard let text = historyUserMessageText(from: item) else { return [] }
            var message = ChatMessage(
                role: .user,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
            message.isFromHistory = true
            return [message]

        case "agentMessage":
            let text = sanitizeAssistantDisplayText((item["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            var message = ChatMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
            message.isFromHistory = true
            return [message]

        case "plan":
            let text = ((item["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            var message = ChatMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false,
                presentationKind: .plan
            )
            message.isFromHistory = true
            return [message]

        case "commandExecution":
            return [historyToolMessage(
                toolName: "Bash",
                content: commandExecutionSummary(item),
                toolInput: jsonString(item["command"] ?? item["commandActions"] ?? item),
                toolOutput: completedCommandExecutionSummary(item, bufferedOutput: item["aggregatedOutput"] as? String)
            )]

        case "fileChange":
            return [historyToolMessage(
                toolName: "Edit",
                content: fileChangeSummary(item),
                toolInput: jsonString(item["changes"] ?? item),
                toolOutput: completedFileChangeSummary(item, bufferedOutput: item["aggregatedOutput"] as? String)
            )]

        case "mcpToolCall":
            let name = (item["tool"] as? String) ?? "mcp"
            let summary = (item["server"] as? String).map { "\($0) · \(name)" } ?? name
            return [historyToolMessage(
                toolName: name,
                content: summary,
                toolInput: jsonString(item["arguments"]),
                toolOutput: completedDynamicToolCallSummary(item)
            )]

        case "dynamicToolCall":
            return [historyToolMessage(
                toolName: (item["tool"] as? String) ?? "dynamicTool",
                content: dynamicToolCallSummary(item),
                toolInput: dynamicToolCallInputPreview(item) ?? jsonString(item["arguments"] ?? item),
                toolOutput: completedDynamicToolCallSummary(item)
            )]

        case "webSearch":
            return [historyToolMessage(
                toolName: "WebSearch",
                content: webSearchSummary(item),
                toolInput: webSearchInputPreview(item) ?? jsonString(["query": item["query"] as? String ?? "", "action": item["action"] as Any]),
                toolOutput: completedWebSearchSummary(item)
            )]

        case "imageView":
            return [historyToolMessage(
                toolName: "ImageView",
                content: imageViewSummary(item),
                toolInput: jsonString(["path": item["path"] as? String ?? ""]),
                toolOutput: completedImageViewSummary(item)
            )]

        case "collabAgentToolCall":
            return [historyToolMessage(
                toolName: "Agent",
                content: collabAgentToolCallSummary(item),
                toolInput: collabAgentToolCallInputPreview(item) ?? jsonString(item),
                toolOutput: completedCollabAgentToolCallSummary(item)
            )]

        case "enteredReviewMode":
            currentReviewStateDescription = reviewStateDescription(item)
            currentReviewStatusBadge = ChatStatusBadge(kind: .reviewActive, text: currentReviewStateDescription ?? "Review active")
            return []

        case "exitedReviewMode":
            currentReviewStateDescription = nil
            currentReviewStatusBadge = ChatStatusBadge(kind: .reviewDone, text: "Review terminee")
            guard let rendered = (item["review"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rendered.isEmpty
            else {
                return []
            }
            let parsed = parseReviewOutput(rendered)
            var renderedMessages: [ChatMessage] = []
            if let summary = parsed.summary, !summary.isEmpty {
                var summaryMessage = ChatMessage(
                    role: .assistant,
                    content: summary,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false
                )
                summaryMessage.isFromHistory = true
                renderedMessages.append(summaryMessage)
            }
            for finding in parsed.findings {
                var findingMessage = ChatMessage(
                    role: .assistant,
                    content: finding.body,
                    timestamp: Date(),
                    isStreaming: false,
                    isCollapsed: false,
                    presentationKind: .reviewFinding,
                    reviewFinding: finding
                )
                findingMessage.isFromHistory = true
                renderedMessages.append(findingMessage)
            }
            return renderedMessages

        default:
            return []
        }
    }

    private static func historyToolMessage(
        toolName: String,
        content: String,
        toolInput: String?,
        toolOutput: String?
    ) -> ChatMessage {
        var message = ChatMessage(
            role: .toolUse,
            content: content,
            timestamp: Date(),
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            isStreaming: false,
            isCollapsed: true
        )
        message.isFromHistory = true
        return message
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

    private static func historyUserMessageText(from item: [String: Any]) -> String? {
        let content = item["content"] as? [[String: Any]] ?? []
        let fragments = content.compactMap { fragment -> String? in
            let type = (fragment["type"] as? String) ?? ""
            switch type {
            case "text":
                return (fragment["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            case "localImage":
                if let path = (fragment["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    return "[Image jointe: \((path as NSString).lastPathComponent)]"
                }
                return "[Image jointe]"
            case "image":
                if let url = (fragment["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                    return "[Image jointe: \(url)]"
                }
                return "[Image jointe]"
            case "mention", "skill":
                let name = (fragment["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return name?.nilIfEmpty.map { "[\($0)]" } ?? "[Contexte joint]"
            default:
                if let text = (fragment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
                return nil
            }
        }

        let text = fragments.joined(separator: "\n\n").nilIfEmpty
        let cleaned = text.map(cleanedResumedUserMessage(_:))
        return cleaned?.nilIfEmpty
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
        flushPendingAssistantDelta()
        clearAssistantDeltaWork()
    }

    func testFlushMarkdownPreRender() {
        flushMarkdownPreRender()
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
        guard !pendingMarkdown.isEmpty else { return }
        let batch = pendingMarkdown
        pendingMarkdown.removeAll()
        for (id, text) in batch {
            let attr = MarkdownBlockView.renderAttributedPreviewForBackground(text)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].preRenderedMarkdown = attr
                ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &messages)
            }
        }
        markdownTask = nil
    }

    var testPendingMarkdownCount: Int {
        pendingMarkdown.count
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
        fieldValues: [String: String]
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

    func testSetCurrentThreadId(_ id: String?) {
        threadCoordinator.setCurrentThreadId(id)
        session.id = id
    }

    static func testStoredSessionCustomInstructions(threadId: String) -> String {
        CodexCustomInstructionsStore.loadSessionText(threadId: threadId)
    }

    static func testClearStoredCustomInstructions() {
        CodexCustomInstructionsStore.clearAll()
    }
}
#endif

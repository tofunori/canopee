import Combine
import Foundation
import SwiftUI

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
private final class CodexAppServerRPCSession: @unchecked Sendable {
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
    enum ServerRequestDisposition: Equatable {
        case autoApprove
        case inlineApproval
        case reject
        case denyPermissions
        case unsupported
    }

    private struct PendingServerRequest {
        let id: Int
        let method: String
        let itemID: String?
        let threadID: String?
        let turnID: String?
        let params: [String: Any]
    }

    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var isConnected = false
    @Published var session = SessionInfo()
    @Published var selectedModel: String = "gpt-5.4"
    @Published var selectedEffort: String = "medium"
    @Published var chatInteractionMode: ChatInteractionMode = .agent
    @Published var pendingApprovalRequest: ChatApprovalRequest?

    let providerName = "Codex"
    let providerIcon = "chevron.left.forwardslash.chevron.right"

    static let defaultModels = ["gpt-5.4", "gpt-5.3-codex", "gpt-5.2"]
    static let defaultEfforts = ["low", "medium", "high", "xhigh"]

    private var workingDirectory: URL
    private var resumeWorkingDirectory: URL?
    private var rpc: CodexAppServerRPCSession?
    private var initialized = false
    private var connectTask: Task<Void, Never>?
    private var currentThreadId: String?
    private var currentTurnId: String?
    private var currentAssistantMessageIndex: Int?
    private var currentAgentItemId: String?
    private var lastRetryStatusMessage: String?
    private var pendingAssistantDelta = ""
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var pendingMarkdown: [(UUID, String)] = []
    private var markdownTask: Task<Void, Never>?
    private var currentRunInteractionMode: ChatInteractionMode = .agent
    private var currentRunInputItems: [ChatInputItem] = []
    private var currentRunPrompt = ""
    private var currentRunDisplayText = ""
    private var pendingServerRequests: [Int: PendingServerRequest] = [:]
    private var itemToolUseMessageIndex: [String: Int] = [:]
    private var itemOutputBuffers: [String: String] = [:]

    private static let assistantDeltaThrottleNanoseconds: UInt64 = 60_000_000
    private static let markdownPreRenderDelayNanoseconds: UInt64 = 80_000_000

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
        pendingServerRequests.removeAll()
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
        Task { await sendUserMessage([.text(trimmed)], display: trimmed, interactionMode: chatInteractionMode) }
    }

    func sendMessageWithDisplay(displayText: String, items: [ChatInputItem]) {
        let prompt = ChatInputItem.legacyPrompt(from: items)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !isConnected { start() }
        pendingApprovalRequest = nil
        Task { await sendUserMessage(items, display: displayText, interactionMode: chatInteractionMode) }
    }

    func sendMessageWithDisplay(displayText: String, prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if !isConnected { start() }
        pendingApprovalRequest = nil
        Task { await sendUserMessage([.text(p)], display: displayText, interactionMode: chatInteractionMode) }
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

    private func sendUserMessage(
        _ items: [ChatInputItem],
        display: String,
        interactionMode: ChatInteractionMode,
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
        currentRunInteractionMode = interactionMode
        currentRunInputItems = items
        currentRunPrompt = prompt
        currentRunDisplayText = display
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
            if currentThreadId == nil {
                let cwd = workingDirectoryURL.path
                CodexTraceLog.write("thread/start cwd=\(cwd) model=\(self.selectedModel) approval=\(Self.approvalPolicy(for: interactionMode)) sandbox=\(Self.threadSandboxMode(for: interactionMode))")
                let result = try await rpc.call(
                    method: "thread/start",
                    params: [
                        "model": selectedModel,
                        "cwd": cwd,
                        "approvalPolicy": Self.approvalPolicy(for: interactionMode),
                        "sandbox": Self.threadSandboxMode(for: interactionMode),
                        "serviceName": "canope",
                    ]
                ) as? [String: Any]
                if let thread = result?["thread"] as? [String: Any],
                   let id = thread["id"] as? String {
                    currentThreadId = id
                    session.id = id
                    session.name = thread["name"] as? String
                    session.turns = 0
                    CodexTraceLog.write("thread/start result threadId=\(id)")
                }
            }

            guard let threadId = currentThreadId else {
                throw NSError(domain: "CodexAppServer", code: 10, userInfo: [NSLocalizedDescriptionKey: "No thread"])
            }

            let turnParams: [String: Any] = [
                "threadId": threadId,
                "input": Self.buildTurnInputPayload(from: items, interactionMode: interactionMode),
                "cwd": workingDirectoryURL.path,
                "model": selectedModel,
                "effort": selectedEffort,
                "approvalPolicy": Self.approvalPolicy(for: interactionMode),
                "sandboxPolicy": Self.sandboxPolicy(for: interactionMode, workingDirectory: workingDirectoryURL),
            ]
            CodexTraceLog.write("turn/start threadId=\(threadId) effort=\(self.selectedEffort) model=\(self.selectedModel)")
            _ = try await rpc.call(method: "turn/start", params: turnParams)
            CodexTraceLog.write("turn/start returned")
            session.turns += 1
        } catch {
            CodexTraceLog.write("sendUserMessage error \(error.localizedDescription)")
            appendSystem("Codex: \(error.localizedDescription)")
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
                currentTurnId = tid
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
            currentTurnId = nil
            lastRetryStatusMessage = nil
            pendingServerRequests.removeAll()
        case "turn/plan/updated":
            handleTurnPlanUpdated(params)
        case "serverRequest/resolved":
            if let requestId = jsonInt(params["requestId"]) {
                pendingServerRequests.removeValue(forKey: requestId)
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
                ?? "Erreur Codex"
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

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) {
        let paramsSummary = Self.jsonString(params) ?? "{}"
        CodexTraceLog.write("serverRequest id=\(id) method=\(method) params=\(paramsSummary)")
        let request = PendingServerRequest(
            id: id,
            method: method,
            itemID: params["itemId"] as? String,
            threadID: params["threadId"] as? String,
            turnID: params["turnId"] as? String,
            params: params
        )
        pendingServerRequests[id] = request
        switch Self.serverRequestDisposition(for: method, mode: currentRunInteractionMode, params: params) {
        case .autoApprove:
            isProcessing = true
            Task { [weak self] in
                await self?.replyToServerRequest(id: id, method: method, approved: true)
            }
        case .inlineApproval:
            pendingApprovalRequest = ChatApprovalRequest(
                toolName: Self.serverRequestToolName(method: method, params: params),
                prompt: currentRunPrompt,
                displayText: currentRunDisplayText,
                message: Self.serverRequestMessage(method: method, params: params),
                fields: Self.serverRequestFields(method: method, params: params),
                rpcRequestID: id,
                rpcMethod: method,
                itemID: request.itemID,
                threadID: request.threadID,
                turnID: request.turnID
            )
            isProcessing = false
        case .reject:
            appendSystem(Self.blockedServerRequestMessage(method: method, mode: currentRunInteractionMode, params: params))
            Task { [weak self] in
                await self?.replyToServerRequest(id: id, method: method, approved: false)
            }
            isProcessing = false
        case .denyPermissions:
            appendSystem(Self.blockedServerRequestMessage(method: method, mode: currentRunInteractionMode, params: params))
            Task { [weak self] in
                await self?.replyToPermissionsRequest(id: id, grant: false)
            }
            isProcessing = false
        case .unsupported:
            let message = Self.unsupportedServerRequestMessage(for: method)
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
                content: "Appel d’outil dynamique",
                toolInput: Self.jsonString(item["arguments"] ?? item)
            )
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
        let presentationKind: ChatMessage.PresentationKind = type == "plan" ? .plan : (currentRunInteractionMode == .plan ? .plan : .standard)
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
        if ClaudeHeadlessProvider.shouldBlockTool(
            name: name,
            input: item["arguments"] as? [String: Any],
            mode: currentRunInteractionMode
        ) {
            if currentRunInteractionMode == .acceptEdits {
                pendingApprovalRequest = ChatApprovalRequest(
                    toolName: name,
                    prompt: currentRunPrompt,
                    displayText: currentRunDisplayText,
                    itemID: item["id"] as? String,
                    threadID: currentThreadId,
                    turnID: currentTurnId
                )
            } else {
                appendSystem(ClaudeHeadlessProvider.blockedToolMessage(
                    toolName: name,
                    mode: currentRunInteractionMode
                ))
            }
            Task { await interruptIfNeeded() }
            isProcessing = false
            currentTurnId = nil
            return
        }
        let summary = (item["server"] as? String).map { "\($0) · \(name)" } ?? name
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
        guard let itemID else { return }
        if pendingApprovalRequest?.itemID == itemID {
            pendingApprovalRequest = nil
        }
        pendingServerRequests = pendingServerRequests.filter { _, value in
            value.itemID != itemID
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
                            from: pendingServerRequests[id]?.params ?? [:],
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
                        from: pendingServerRequests[id]?.params ?? [:],
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
                        from: pendingServerRequests[id]?.params ?? [:],
                        fieldValues: fieldValues
                    )
                )
            default:
                try rpc.respondError(id: id, message: Self.unsupportedServerRequestMessage(for: method))
            }
            pendingServerRequests.removeValue(forKey: id)
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
                        from: pendingServerRequests[id]?.params ?? [:],
                        grant: grant,
                        workingDirectory: workingDirectoryURL
                    ),
                    "scope": "turn",
                ]
            )
            pendingServerRequests.removeValue(forKey: id)
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
            pendingServerRequests.removeValue(forKey: id)
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
        return "Commande en cours"
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
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Commande"
        let exitCode = jsonInt(item["exitCode"])
        let output = ((item["aggregatedOutput"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            ?? (bufferedOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        let statusLabel: String
        switch status {
        case "declined":
            statusLabel = "Commande refusee"
        case "failed":
            statusLabel = "Commande echouee"
        default:
            statusLabel = "Commande terminee"
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
            return "\(base) refusee"
        case "failed":
            if let output, !output.isEmpty {
                return "\(base) non appliquee"
            }
            return "\(base) non appliquee"
        default:
            if let output {
                return "\(base) appliquee\n\(output)"
            }
            return "\(base) appliquee"
        }
    }

    private static func completedDynamicToolCallSummary(_ item: [String: Any]) -> String? {
        let status = (item["status"] as? String) ?? "completed"
        let text = extractText(fromContentItems: item["contentItems"] as? [[String: Any]])
        switch status {
        case "failed":
            return text ?? "Appel d’outil echoue"
        default:
            return text ?? "Appel d’outil termine"
        }
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
                return "Mode plan: la demande de permissions supplementaires a ete bloquee."
            case .acceptEdits:
                return "Mode accept edits: la demande de permissions supplementaires a ete bloquee en attendant ton approbation."
            case .agent:
                return "Demande de permissions supplementaires."
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

    nonisolated static func buildPromptForInteractionMode(_ userMessage: String, mode: ChatInteractionMode) -> String {
        let promptWithContext = buildPromptWithIDEContext(userMessage)
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
            - Si un outil d'edition serait necessaire, attends l'approbation au lieu d'agir.
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

    nonisolated static func buildTurnInputPayload(
        from items: [ChatInputItem],
        interactionMode: ChatInteractionMode
    ) -> [[String: Any]] {
        items.flatMap { item in
            switch item {
            case .text(let text):
                return ChatInputItem.text(buildPromptForInteractionMode(text, mode: interactionMode)).codexPayloads
            default:
                return item.codexPayloads
            }
        }
    }
}

// MARK: - HeadlessChatProviding

extension CodexAppServerProvider: HeadlessChatProviding {
    var chatWorkingDirectory: URL { workingDirectoryURL }
    var chatSupportsPlanMode: Bool { true }

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
            await sendUserMessage([.text(trimmed)], display: trimmed, interactionMode: chatInteractionMode)
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
                currentRunInputItems.isEmpty ? [.text(request.prompt)] : currentRunInputItems,
                display: request.displayText,
                interactionMode: .agent,
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
        connectTask?.cancel()
        connectTask = nil
        clearAssistantDeltaWork()
        clearMarkdownPreRenderWork()
        rpc?.terminate()
        rpc = nil
        initialized = false
        currentThreadId = nil
        currentTurnId = nil
        currentAssistantMessageIndex = nil
        lastRetryStatusMessage = nil
        session = SessionInfo()
        messages.removeAll()
        pendingApprovalRequest = nil
        pendingServerRequests.removeAll()
        itemToolUseMessageIndex.removeAll()
        itemOutputBuffers.removeAll()
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
        currentRunInteractionMode = interactionMode
        currentRunInputItems = prompt.isEmpty ? [] : [.text(prompt)]
        currentRunPrompt = prompt
        currentRunDisplayText = displayText
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
}
#endif

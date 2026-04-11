import Foundation

@MainActor
final class CodexThreadCoordinator {
    private(set) var currentThreadId: String?
    private(set) var currentTurnId: String?
    private(set) var resumeWorkingDirectory: URL?

    func workingDirectoryURL(base: URL) -> URL {
        resumeWorkingDirectory ?? base
    }

    func setCurrentThreadId(_ id: String?) {
        currentThreadId = id
    }

    func setCurrentTurnId(_ id: String?) {
        currentTurnId = id
    }

    func clearRuntimeState() {
        currentThreadId = nil
        currentTurnId = nil
        resumeWorkingDirectory = nil
    }

    func startThreadIfNeeded(
        rpc: CodexAppServerRPCSession,
        model: String,
        interactionMode: ChatInteractionMode,
        workingDirectory: URL
    ) async throws -> (id: String, name: String?)? {
        guard currentThreadId == nil else { return nil }

        let result = try await rpc.call(
            method: "thread/start",
            params: [
                "model": model,
                "cwd": workingDirectory.path,
                "approvalPolicy": CodexApprovalCoordinator.approvalPolicy(for: interactionMode),
                "sandbox": CodexApprovalCoordinator.threadSandboxMode(for: interactionMode),
                "serviceName": "canope",
            ]
        ) as? [String: Any]

        guard let thread = result?["thread"] as? [String: Any],
              let id = thread["id"] as? String
        else {
            return nil
        }

        currentThreadId = id
        return (id, thread["name"] as? String)
    }

    func startTurn(
        rpc: CodexAppServerRPCSession,
        items: [ChatInputItem],
        interactionMode: ChatInteractionMode,
        includeIDEContext: Bool,
        globalCustomInstructions: String,
        sessionCustomInstructions: String,
        workingDirectory: URL,
        model: String,
        effort: String
    ) async throws {
        guard let threadId = currentThreadId else {
            throw NSError(domain: "CodexAppServer", code: 10, userInfo: [NSLocalizedDescriptionKey: "No thread"])
        }

        let turnParams: [String: Any] = [
            "threadId": threadId,
            "input": CodexPromptComposer.buildTurnInputPayload(
                from: items,
                interactionMode: interactionMode,
                includeIDEContext: includeIDEContext,
                globalCustomInstructions: globalCustomInstructions,
                sessionCustomInstructions: sessionCustomInstructions
            ),
            "cwd": workingDirectory.path,
            "model": model,
            "effort": effort,
            "approvalPolicy": CodexApprovalCoordinator.approvalPolicy(for: interactionMode),
            "sandboxPolicy": CodexApprovalCoordinator.sandboxPolicy(
                for: interactionMode,
                workingDirectory: workingDirectory
            ),
        ]
        _ = try await rpc.call(method: "turn/start", params: turnParams)
    }

    func interruptIfNeeded(rpc: CodexAppServerRPCSession?) async {
        guard let rpc, let threadId = currentThreadId, let turnId = currentTurnId else { return }
        _ = try? await rpc.call(
            method: "turn/interrupt",
            params: ["threadId": threadId, "turnId": turnId]
        )
    }

    func rollbackLastTurn(rpc: CodexAppServerRPCSession?) async throws {
        guard let rpc, let threadId = currentThreadId else {
            throw NSError(domain: "CodexAppServer", code: 10, userInfo: [NSLocalizedDescriptionKey: "No thread"])
        }
        _ = try await rpc.call(method: "thread/rollback", params: ["threadId": threadId, "numTurns": 1])
    }

    func renameCurrentThread(rpc: CodexAppServerRPCSession?, name: String) async {
        guard let rpc, let threadId = currentThreadId else { return }
        _ = try? await rpc.call(
            method: "thread/name/set",
            params: ["threadId": threadId, "name": name]
        )
    }

    func resumeThread(
        id: String,
        rpc: CodexAppServerRPCSession,
        historyReader: @MainActor ([String: Any]) -> CodexThreadHistorySnapshot?
    ) async throws -> CodexThreadHistorySnapshot? {
        let snapshot: CodexThreadHistorySnapshot?
        if let threadRead = try await rpc.call(
            method: "thread/read",
            params: ["threadId": id, "includeTurns": true]
        ) as? [String: Any] {
            snapshot = await historyReader(threadRead)
        } else {
            snapshot = nil
        }

        _ = try await rpc.call(method: "thread/resume", params: ["threadId": id])
        currentThreadId = id
        currentTurnId = nil
        return snapshot
    }

    func resumeLatestThread(
        matchingDirectory: URL,
        rpc: CodexAppServerRPCSession,
        historyReader: @MainActor ([String: Any]) -> CodexThreadHistorySnapshot?
    ) async throws -> (id: String, name: String?, snapshot: CodexThreadHistorySnapshot?)? {
        let params: [String: Any] = [
            "limit": 1,
            "sortKey": "updated_at",
            "cwd": matchingDirectory.path,
            "sourceKinds": ["appServer", "cli", "vscode", "exec"],
        ]
        guard let result = try await rpc.call(method: "thread/list", params: params) as? [String: Any],
              let data = result["data"] as? [[String: Any]],
              let first = data.first,
              let id = first["id"] as? String
        else {
            return nil
        }

        let snapshot = try await resumeThread(id: id, rpc: rpc, historyReader: historyReader)
        return (id, first["name"] as? String, snapshot)
    }

    static func ephemeralRename(threadId: String, name: String) async throws {
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

    static func ephemeralThreadListAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem] {
        await MainActor.run {
            ClaudeIDEBridgeService.shared.startIfNeeded()
            CanopeContextFiles.writeClaudeIDEMcpConfig()
        }
        let args = buildAppServerArguments(bridgeURL: resolvedBridgeStatic())
        let rpcSession = CodexAppServerRPCSession()
        do {
            let env = buildProcessEnvironment()
            try rpcSession.startProcess(arguments: codexLaunchArguments() + args, environment: env)
            _ = try await rpcSession.call(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "canope_threads", "title": "Canope", "version": "1.0.0"],
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
            if let matchingDirectory {
                params["cwd"] = matchingDirectory.path
            }
            guard let res = try await rpcSession.call(method: "thread/list", params: params) as? [String: Any],
                  let data = res["data"] as? [[String: Any]]
            else {
                rpcSession.terminate()
                return []
            }

            let cwdPath = matchingDirectory?.path ?? ""
            let project = (cwdPath as NSString).lastPathComponent
            let items = data.map { thread in
                ChatSessionListItem(
                    id: (thread["id"] as? String) ?? "",
                    name: (thread["name"] as? String) ?? (thread["preview"] as? String) ?? "",
                    project: project,
                    date: parseCodexThreadDate(thread["updatedAt"] ?? thread["createdAt"])
                )
            }
            rpcSession.terminate()
            return items
        } catch {
            rpcSession.terminate()
            return []
        }
    }

    private static func parseCodexThreadDate(_ value: Any?) -> Date? {
        guard let dateValue = value as? Double else { return nil }
        if dateValue > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: dateValue / 1000)
        }
        return Date(timeIntervalSince1970: dateValue)
    }

    private static func resolvedBridgeStatic() -> String {
        if let value = ProcessInfo.processInfo.environment["CANOPE_IDE_BRIDGE_URL"], !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment["CANOPE_CLAUDE_IDE_BRIDGE_URL"], !value.isEmpty { return value }
        return CanopeContextFiles.claudeIDEBridgeURL
    }

    private static func findCodexCLI() -> String {
        let preferred = [
            "~/.local/bin/codex",
            "/Users/\(NSUserName())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = ExecutableLocator.find("codex", preferredPaths: preferred) {
            return path
        }
        return "/usr/bin/env"
    }

    private static func codexLaunchArguments() -> [String] {
        let path = findCodexCLI()
        if path == "/usr/bin/env" {
            return ["/usr/bin/env", "codex"]
        }
        return [path]
    }

    private static func buildAppServerArguments(bridgeURL: String) -> [String] {
        let developerInstructions = ClaudeCLIWrapperService.canopeCodexDeveloperInstructions()
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
            "-c", "instructions=\"\(developerInstructions)\"",
            "-c", "developer_instructions=\"\(developerInstructions)\"",
            "-c", "mcp_servers.canope.type=\"stdio\"",
            "-c", "mcp_servers.canope.command=\"npx\"",
            "-c", "mcp_servers.canope.args=\(argsToml)",
        ]
    }

    private static func buildProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        for entry in CanopeContextFiles.terminalEnvironment {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                environment[String(parts[0])] = String(parts[1])
            }
        }

        let shell = environment["SHELL"] ?? "/bin/zsh"
        let applied = ClaudeCLIWrapperService.shared.apply(
            to: environment.map { "\($0.key)=\($0.value)" },
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
}

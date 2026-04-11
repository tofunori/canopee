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
            snapshot = historyReader(threadRead)
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
        let args = CodexAppServerLaunchSupport.buildAppServerArguments(
            bridgeURL: CodexAppServerLaunchSupport.resolvedBridgeURL()
        )
        let session = CodexAppServerRPCSession()
        let env = CodexAppServerLaunchSupport.buildProcessEnvironment()
        try session.startProcess(
            arguments: CodexAppServerLaunchSupport.codexLaunchArguments() + args,
            environment: env
        )
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
        let args = CodexAppServerLaunchSupport.buildAppServerArguments(
            bridgeURL: CodexAppServerLaunchSupport.resolvedBridgeURL()
        )
        let rpcSession = CodexAppServerRPCSession()
        do {
            let env = CodexAppServerLaunchSupport.buildProcessEnvironment()
            try rpcSession.startProcess(
                arguments: CodexAppServerLaunchSupport.codexLaunchArguments() + args,
                environment: env
            )
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

}

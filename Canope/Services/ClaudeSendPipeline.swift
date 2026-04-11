import Foundation

enum ClaudeSendPipeline {
    enum LaunchMode: Equatable {
        case send(useContinue: Bool, resumeSessionID: String?)
        case forkEdit(sessionID: String)
    }

    struct LaunchConfiguration: Equatable {
        let prompt: String
        let arguments: [String]
        let currentDirectoryURL: URL
        let environment: [String: String]
    }

    static func makeLaunchConfiguration(
        prompt: String,
        displayPrompt: String,
        launchMode: LaunchMode,
        interactionMode: ChatInteractionMode,
        includeIDEContext: Bool,
        model: String,
        effort: String,
        currentDirectoryURL: URL,
        skipMcp: Bool
    ) -> LaunchConfiguration {
        let builtPrompt = ClaudeHeadlessProvider.buildPromptForInteractionMode(
            prompt,
            mode: interactionMode,
            includeIDEContext: includeIDEContext
        )
        var arguments = [
            "-p", builtPrompt,
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--effort", effort,
        ]
        switch launchMode {
        case .send(let useContinue, let resumeSessionID):
            if useContinue {
                arguments += ["--continue"]
            } else if let resumeSessionID {
                arguments += ["--resume", resumeSessionID]
            }
        case .forkEdit(let sessionID):
            arguments += ["--resume", sessionID, "--fork-session"]
        }

        if !skipMcp {
            let mcpConfigPath = CanopeContextFiles.claudeIDEMcpConfigPaths[0]
            if FileManager.default.fileExists(atPath: mcpConfigPath) {
                arguments += ["--mcp-config", mcpConfigPath]
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        for entry in CanopeContextFiles.terminalEnvironment {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }

        return LaunchConfiguration(
            prompt: displayPrompt,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: env
        )
    }
}

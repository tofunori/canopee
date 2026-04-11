import Foundation

enum CodexAppServerLaunchSupport {
    static func resolvedBridgeURL() -> String {
        if let value = ProcessInfo.processInfo.environment["CANOPE_IDE_BRIDGE_URL"], !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment["CANOPE_CLAUDE_IDE_BRIDGE_URL"], !value.isEmpty { return value }
        return CanopeContextFiles.claudeIDEBridgeURL
    }

    static func codexLaunchArguments() -> [String] {
        let path = findCodexCLI()
        if path == "/usr/bin/env" {
            return ["/usr/bin/env", "codex"]
        }
        return [path]
    }

    static func buildAppServerArguments(bridgeURL: String) -> [String] {
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

    static func buildProcessEnvironment() -> [String: String] {
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
}

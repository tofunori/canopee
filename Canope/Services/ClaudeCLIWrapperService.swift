import Foundation

final class ClaudeCLIWrapperService: @unchecked Sendable {
    static let shared = ClaudeCLIWrapperService()

    private let fileManager = FileManager.default
    private let wrapperDirectoryURL: URL
    private let claudeWrapperURL: URL
    private let codexWrapperURL: URL
    private let opencodeWrapperURL: URL
    private let opencodeInstructionsURL: URL
    private let zshBootstrapDirectoryURL: URL

    private init() {
        wrapperDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("canope-cli-bin", isDirectory: true)
        claudeWrapperURL = wrapperDirectoryURL.appendingPathComponent("claude")
        codexWrapperURL = wrapperDirectoryURL.appendingPathComponent("codex")
        opencodeWrapperURL = wrapperDirectoryURL.appendingPathComponent("opencode")
        opencodeInstructionsURL = wrapperDirectoryURL.appendingPathComponent("opencode-canope-instructions.md")
        zshBootstrapDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("canope-zdotdir", isDirectory: true)
    }

    func apply(to environment: [String], shellPath: String? = nil) -> [String] {
        var updatedEnvironment = Self.prependingToPATH(wrapperDirectoryURL.path, in: environment)
        let claudeWrapperPath = prepareClaudeWrapperIfNeeded()?.path
        let codexWrapperPath = prepareCodexWrapperIfNeeded()?.path
        let opencodeWrapperPath = prepareOpenCodeWrapperIfNeeded()?.path

        if Self.isZshShell(shellPath),
           let bootstrapURL = prepareZshBootstrapIfNeeded(
               sourceDirectory: Self.sourceZDOTDIR(from: environment),
               claudeWrapperPath: claudeWrapperPath,
               codexWrapperPath: codexWrapperPath,
               opencodeWrapperPath: opencodeWrapperPath
           ) {
            updatedEnvironment = Self.settingEnvironmentVariable(
                "ZDOTDIR",
                to: bootstrapURL.path,
                in: updatedEnvironment
            )
        }

        return updatedEnvironment
    }

    @discardableResult
    func prepareWrapperIfNeeded() -> URL? {
        prepareClaudeWrapperIfNeeded()
    }

    @discardableResult
    func prepareClaudeWrapperIfNeeded() -> URL? {
        guard let realClaudePath = resolveRealClaudePath() else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: wrapperDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let script = Self.wrapperScript(realClaudePath: realClaudePath)
            let existing = try? String(contentsOf: claudeWrapperURL, encoding: .utf8)
            if existing != script {
                try script.write(to: claudeWrapperURL, atomically: true, encoding: .utf8)
            }

            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeWrapperURL.path)
            return claudeWrapperURL
        } catch {
            print("[Canope] Claude wrapper not prepared: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func prepareCodexWrapperIfNeeded() -> URL? {
        guard let realCodexPath = resolveRealCodexPath() else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: wrapperDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let script = Self.codexWrapperScript(realCodexPath: realCodexPath)
            let existing = try? String(contentsOf: codexWrapperURL, encoding: .utf8)
            if existing != script {
                try script.write(to: codexWrapperURL, atomically: true, encoding: .utf8)
            }

            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexWrapperURL.path)
            return codexWrapperURL
        } catch {
            print("[Canope] Codex wrapper not prepared: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func prepareOpenCodeWrapperIfNeeded() -> URL? {
        guard let realOpenCodePath = resolveRealOpenCodePath() else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: wrapperDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let instructions = Self.canopeOpenCodeInstructions()
            let existingInstructions = try? String(contentsOf: opencodeInstructionsURL, encoding: .utf8)
            if existingInstructions != instructions {
                try instructions.write(to: opencodeInstructionsURL, atomically: true, encoding: .utf8)
            }

            let script = Self.opencodeWrapperScript(
                realOpenCodePath: realOpenCodePath,
                bridgeURL: CanopeContextFiles.claudeIDEBridgeURL,
                instructionsPath: opencodeInstructionsURL.path
            )
            let existing = try? String(contentsOf: opencodeWrapperURL, encoding: .utf8)
            if existing != script {
                try script.write(to: opencodeWrapperURL, atomically: true, encoding: .utf8)
            }

            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opencodeWrapperURL.path)
            return opencodeWrapperURL
        } catch {
            print("[Canope] OpenCode wrapper not prepared: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveRealClaudePath() -> String? {
        let preferredPaths = [
            "~/.local/bin/claude",
            "/Users/tofunori/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]

        guard let path = ExecutableLocator.find("claude", preferredPaths: preferredPaths) else {
            print("[Canope] Claude wrapper not prepared: claude executable not found")
            return nil
        }

        guard path != claudeWrapperURL.path else {
            print("[Canope] Claude wrapper not prepared: resolved claude path points to wrapper")
            return nil
        }

        return path
    }

    private func resolveRealCodexPath() -> String? {
        let preferredPaths = [
            "~/.local/bin/codex",
            "/Users/tofunori/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]

        guard let path = ExecutableLocator.find("codex", preferredPaths: preferredPaths) else {
            print("[Canope] Codex wrapper not prepared: codex executable not found")
            return nil
        }

        guard path != codexWrapperURL.path else {
            print("[Canope] Codex wrapper not prepared: resolved codex path points to wrapper")
            return nil
        }

        return path
    }

    private func resolveRealOpenCodePath() -> String? {
        let preferredPaths = [
            "~/.opencode/bin/opencode",
            "/Users/tofunori/.opencode/bin/opencode",
            "~/.local/bin/opencode",
            "/Users/tofunori/.local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]

        guard let path = ExecutableLocator.find("opencode", preferredPaths: preferredPaths) else {
            print("[Canope] OpenCode wrapper not prepared: opencode executable not found")
            return nil
        }

        guard path != opencodeWrapperURL.path else {
            print("[Canope] OpenCode wrapper not prepared: resolved opencode path points to wrapper")
            return nil
        }

        return path
    }

    static func prependingToPATH(_ directory: String, in environment: [String]) -> [String] {
        var updatedEnvironment = environment.filter { !$0.hasPrefix("PATH=") }
        let currentPATH = environment.first(where: { $0.hasPrefix("PATH=") })?.dropFirst(5) ?? ""

        let pathComponents = ([directory] + currentPATH.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty }
        let deduplicatedComponents = Array(NSOrderedSet(array: pathComponents)) as? [String] ?? pathComponents
        updatedEnvironment.append("PATH=\(deduplicatedComponents.joined(separator: ":"))")
        return updatedEnvironment
    }

    static func zshBootstrapRC(
        sourceDirectory: String,
        wrapperDirectory: String,
        claudeWrapperPath: String?,
        codexWrapperPath: String?,
        opencodeWrapperPath: String?,
        mcpConfigPath: String,
        alternateMcpConfigPath: String,
        bridgeURL: String
    ) -> String {
        let sourcePath = (sourceDirectory as NSString).appendingPathComponent(".zshrc")
        let claudeAlias = claudeWrapperPath.map { "alias claude=\(shellSingleQuoted($0))" } ?? ""
        let codexAlias = codexWrapperPath.map { "alias codex=\(shellSingleQuoted($0))" } ?? ""
        let opencodeAlias = opencodeWrapperPath.map { "alias opencode=\(shellSingleQuoted($0))" } ?? ""

        return """
        # Generated by Canope for terminal-local Claude IDE integration.
        if [ -f \(shellSingleQuoted(sourcePath)) ]; then
          source \(shellSingleQuoted(sourcePath))
        fi

        export PATH=\(shellSingleQuoted(wrapperDirectory)):$PATH
        export CANOPE_CLAUDE_IDE_MCP_CONFIG=\(shellSingleQuoted(mcpConfigPath))
        export CANOPEE_CLAUDE_IDE_MCP_CONFIG=\(shellSingleQuoted(alternateMcpConfigPath))
        export CANOPE_IDE_BRIDGE_URL=\(shellSingleQuoted(bridgeURL))
        export CANOPEE_IDE_BRIDGE_URL=\(shellSingleQuoted(bridgeURL))
        export CANOPE_CLAUDE_IDE_BRIDGE_URL=\(shellSingleQuoted(bridgeURL))
        export CANOPEE_CLAUDE_IDE_BRIDGE_URL=\(shellSingleQuoted(bridgeURL))
        \(claudeAlias)
        \(codexAlias)
        \(opencodeAlias)
        hash -r 2>/dev/null || rehash 2>/dev/null || true
        """
    }

    static func canopeSessionSystemPrompt() -> String {
        """
        Dans Canopée, quand l'utilisateur demande sa sélection courante, son texte sélectionné ou "ce passage", utiliser d'abord la sélection IDE déjà fournie au contexte.
        Quand l'utilisateur demande quel article, paper ou texte est actuellement ouvert dans Canopée, lire /tmp/canopee_paper.txt pour identifier le document courant.
        Ne pas utiliser pdf-selection pour lire une sélection provenant de Canopée.
        """
    }

    static func canopeCodexDeveloperInstructions() -> String {
        """
        When the user asks about the current selection in Canope, first use the Canope MCP tools getCurrentSelection or getLatestSelection before asking the user to paste text.
        When the user asks which PDF, paper, article, or document is currently open in Canope, first use the Canope MCP tool getCurrentPaper before answering.
        If getCurrentPaper reports success, do not say that no PDF is attached or open.
        Only fall back to reading /tmp/canopee_paper.txt directly if the getCurrentPaper tool is unavailable.
        When the user asks to summarize, explain, or analyze an attached file or the current PDF/article in Canope, use the attached file content or getCurrentPaper as the primary source.
        For attached-document or PDF-summary requests, do not inspect workspace memory files, repo context, or unrelated IDE selections unless the user explicitly asks for project context.
        """
    }

    static func canopeOpenCodeInstructions() -> String {
        """
        In Canope, when the user asks about the current selection, first use the Canope MCP tools `getCurrentSelection` or `getLatestSelection` before asking the user to paste text.
        When the user asks which PDF, paper, article, or document is currently open in Canope, first use the Canope MCP tool `getCurrentPaper`.
        If `getCurrentPaper` reports success, do not say that no PDF is open or attached.
        Only fall back to reading `/tmp/canopee_paper.txt` directly if the Canope MCP tools are unavailable.
        """
    }

    static func wrapperScript(realClaudePath: String) -> String {
        let escapedRealClaudePath = shellSingleQuoted(realClaudePath)
        let escapedSystemPrompt = shellSingleQuoted(canopeSessionSystemPrompt())

        return """
        #!/bin/sh
        REAL_CLAUDE=\(escapedRealClaudePath)
        MCP_CONFIG="${CANOPE_CLAUDE_IDE_MCP_CONFIG:-/tmp/canope_claude_ide_mcp.json}"
        APPEND_SYSTEM_PROMPT=\(escapedSystemPrompt)

        if [ -z "$MCP_CONFIG" ] || [ ! -f "$MCP_CONFIG" ]; then
          exec "$REAL_CLAUDE" "$@"
        fi

        for arg in "$@"; do
          case "$arg" in
            --mcp-config|--mcp-config=*|--strict-mcp-config|--strict-mcp-config=*|--help|-h|--version|-v|--print|-p|--system-prompt|--system-prompt=*|--append-system-prompt|--append-system-prompt=*|--system-prompt-file|--system-prompt-file=*|--append-system-prompt-file|--append-system-prompt-file=*)
              exec "$REAL_CLAUDE" "$@"
              ;;
          esac
        done

        case "${1:-}" in
          auth|doctor|install|mcp|plugin|plugins|setup-token|update|upgrade|agents|auto-mode)
            exec "$REAL_CLAUDE" "$@"
            ;;
        esac

        for arg in "$@"; do
          if [ "$arg" = "--ide" ]; then
            exec "$REAL_CLAUDE" --append-system-prompt "$APPEND_SYSTEM_PROMPT" --mcp-config "$MCP_CONFIG" "$@"
          fi
        done

        exec "$REAL_CLAUDE" --append-system-prompt "$APPEND_SYSTEM_PROMPT" --mcp-config "$MCP_CONFIG" --ide "$@"
        """
    }

    static func codexWrapperScript(realCodexPath: String) -> String {
        let escapedRealCodexPath = shellSingleQuoted(realCodexPath)
        let escapedBridgeURL = shellSingleQuoted(CanopeContextFiles.claudeIDEBridgeURL)
        let escapedDeveloperInstructions = shellSingleQuoted(canopeCodexDeveloperInstructions())

        return """
        #!/bin/sh
        REAL_CODEX=\(escapedRealCodexPath)
        BRIDGE_URL="${CANOPE_IDE_BRIDGE_URL:-${CANOPE_CLAUDE_IDE_BRIDGE_URL:-\(escapedBridgeURL)}}"
        DEVELOPER_INSTRUCTIONS=\(escapedDeveloperInstructions)

        if [ -z "$BRIDGE_URL" ]; then
          exec "$REAL_CODEX" "$@"
        fi

        for arg in "$@"; do
          case "$arg" in
            -c|--config|--help|-h|--version|-V)
              exec "$REAL_CODEX" "$@"
              ;;
          esac
        done

        case "${1:-}" in
          login|logout|mcp|completion|debug|app|app-server|help|features)
            exec "$REAL_CODEX" "$@"
            ;;
        esac

        exec "$REAL_CODEX" \
          -c "instructions=\\"$DEVELOPER_INSTRUCTIONS\\"" \
          -c "developer_instructions=\\"$DEVELOPER_INSTRUCTIONS\\"" \
          -c "mcp_servers.canope.type=\\"stdio\\"" \
          -c "mcp_servers.canope.command=\\"npx\\"" \
          -c "mcp_servers.canope.args=[\\"-y\\",\\"mcp-remote\\",\\"$BRIDGE_URL\\",\\"--transport\\",\\"sse-only\\"]" \
          "$@"
        """
    }

    static func opencodeWrapperScript(realOpenCodePath: String, bridgeURL: String, instructionsPath: String) -> String {
        let escapedRealOpenCodePath = shellSingleQuoted(realOpenCodePath)
        let escapedBridgeURL = shellSingleQuoted(bridgeURL)

        let configObject: [String: Any] = [
            "mcp": [
                "canope": [
                    "type": "remote",
                    "url": bridgeURL,
                    "enabled": true,
                    "timeout": 10_000,
                ],
            ],
            "instructions": [instructionsPath],
        ]
        let configJSON = (try? JSONSerialization.data(withJSONObject: configObject, options: []))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"mcp\":{\"canope\":{\"type\":\"remote\",\"url\":\(shellSingleQuoted(bridgeURL)),\"enabled\":true}}}"
        let escapedConfigJSON = shellSingleQuoted(configJSON)
        let escapedInstructionsPath = shellSingleQuoted(instructionsPath)

        return """
        #!/bin/sh
        REAL_OPENCODE=\(escapedRealOpenCodePath)
        BRIDGE_URL="${CANOPE_IDE_BRIDGE_URL:-${CANOPE_CLAUDE_IDE_BRIDGE_URL:-\(escapedBridgeURL)}}"
        INSTRUCTIONS_PATH=\(escapedInstructionsPath)
        CONFIG_JSON=\(escapedConfigJSON)

        if [ ! -f "$INSTRUCTIONS_PATH" ]; then
          exec "$REAL_OPENCODE" "$@"
        fi

        for arg in "$@"; do
          case "$arg" in
            --help|-h|--version|-v|completion|mcp|debug|providers|agent|upgrade|uninstall|serve|web|models|stats|export|import|github|pr|session|plugin|db|acp|attach)
              exec "$REAL_OPENCODE" "$@"
              ;;
          esac
        done

        if [ -z "${OPENCODE_CONFIG_CONTENT:-}" ]; then
          export OPENCODE_CONFIG_CONTENT="$CONFIG_JSON"
        fi

        exec "$REAL_OPENCODE" "$@"
        """
    }

    private static func shellSingleQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func prepareZshBootstrapIfNeeded(
        sourceDirectory: String,
        claudeWrapperPath: String?,
        codexWrapperPath: String?,
        opencodeWrapperPath: String?
    ) -> URL? {
        let files = [
            ".zshenv": Self.zshForwarderScript(
                fileName: ".zshenv",
                sourceDirectory: sourceDirectory
            ),
            ".zprofile": Self.zshForwarderScript(
                fileName: ".zprofile",
                sourceDirectory: sourceDirectory
            ),
            ".zshrc": Self.zshBootstrapRC(
                sourceDirectory: sourceDirectory,
                wrapperDirectory: wrapperDirectoryURL.path,
                claudeWrapperPath: claudeWrapperPath,
                codexWrapperPath: codexWrapperPath,
                opencodeWrapperPath: opencodeWrapperPath,
                mcpConfigPath: CanopeContextFiles.claudeIDEMcpConfigPaths[0],
                alternateMcpConfigPath: CanopeContextFiles.claudeIDEMcpConfigPaths[1],
                bridgeURL: CanopeContextFiles.claudeIDEBridgeURL
            ),
            ".zlogin": Self.zshForwarderScript(
                fileName: ".zlogin",
                sourceDirectory: sourceDirectory
            ),
        ]

        do {
            try fileManager.createDirectory(
                at: zshBootstrapDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            for (fileName, contents) in files {
                let fileURL = zshBootstrapDirectoryURL.appendingPathComponent(fileName)
                let existing = try? String(contentsOf: fileURL, encoding: .utf8)
                if existing != contents {
                    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
                }
            }

            return zshBootstrapDirectoryURL
        } catch {
            print("[Canope] Claude zsh bootstrap not prepared: \(error.localizedDescription)")
            return nil
        }
    }

    private static func sourceZDOTDIR(from environment: [String]) -> String {
        environment
            .first(where: { $0.hasPrefix("ZDOTDIR=") })
            .map { String($0.dropFirst("ZDOTDIR=".count)) }
            ?? NSHomeDirectory()
    }

    private static func settingEnvironmentVariable(
        _ key: String,
        to value: String,
        in environment: [String]
    ) -> [String] {
        var updatedEnvironment = environment.filter { !$0.hasPrefix("\(key)=") }
        updatedEnvironment.append("\(key)=\(value)")
        return updatedEnvironment
    }

    private static func isZshShell(_ shellPath: String?) -> Bool {
        guard let shellPath, !shellPath.isEmpty else { return false }
        return URL(fileURLWithPath: shellPath).lastPathComponent.contains("zsh")
    }

    private static func zshForwarderScript(fileName: String, sourceDirectory: String) -> String {
        let sourcePath = (sourceDirectory as NSString).appendingPathComponent(fileName)
        return """
        # Generated by Canope to preserve the user's zsh startup files.
        if [ -f \(shellSingleQuoted(sourcePath)) ]; then
          source \(shellSingleQuoted(sourcePath))
        fi
        """
    }
}

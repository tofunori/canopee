import Foundation

extension ClaudeHeadlessProvider {
    nonisolated static func toolSummary(name: String, input: [String: Any]?) -> String {
        guard let input else { return name }
        switch name {
        case "Read", "Edit", "Write":
            let path = (input["file_path"] as? String ?? "").components(separatedBy: "/").last ?? ""
            return path
        case "Bash":
            let command = input["command"] as? String ?? ""
            return String(command.prefix(60))
        case "Glob", "Grep":
            return input["pattern"] as? String ?? ""
        case "WebSearch":
            return input["query"] as? String ?? ""
        default:
            return name
        }
    }

    nonisolated static func isMutatingTool(name: String, input: [String: Any]?) -> Bool {
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return true
        case "Bash":
            return true
        default:
            if let command = input?["command"] as? String {
                let lowered = command.lowercased()
                let mutatingHints = [
                    "rm ", "mv ", "cp ", "mkdir ", "touch ", "tee ",
                    "cat >", "sed -i", "python ", "python3 ",
                    "git commit", "git push", "apply_patch",
                ]
                return mutatingHints.contains(where: lowered.contains)
            }
            return false
        }
    }

    nonisolated static func isShellExecutionTool(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "bash"
            || lowered == "shell"
            || lowered.contains("exec_command")
            || lowered.contains("write_stdin")
            || lowered.contains("run_command")
            || lowered.contains("terminal")
    }

    nonisolated static func shouldBlockTool(name: String, input: [String: Any]?, mode: ChatInteractionMode) -> Bool {
        switch mode {
        case .agent:
            return false
        case .acceptEdits, .plan:
            return isMutatingTool(name: name, input: input) || isShellExecutionTool(name: name)
        }
    }

    nonisolated static func blockedToolMessage(toolName: String, mode: ChatInteractionMode) -> String {
        switch mode {
        case .agent:
            return "L’action \(toolName) a ete bloquee."
        case .acceptEdits:
            return "Mode accept edits: l’action \(toolName) a ete bloquee en attendant ton approbation. L’approbation interactive n’est pas encore branchee."
        case .plan:
            return "\(AppStrings.mutatingActionBlockedPrefix) \(toolName) \(AppStrings.mutatingActionBlockedSuffix)"
        }
    }

    nonisolated static func buildPromptWithIDEContext(
        _ userMessage: String,
        includeIDEContext: Bool = true
    ) -> String {
        guard includeIDEContext else {
            return userMessage
        }
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
        let trimmedLineText = (json["lineText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lineText = trimmedLineText.isEmpty ? nil : trimmedLineText
        let trimmedSelectionLineContext = (json["selectionLineContext"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectionLineContext = trimmedSelectionLineContext.isEmpty ? nil : trimmedSelectionLineContext
        let contextSuffix: String
        if let selectionLineContext {
            contextSuffix = """

            [Selected line context]
            \(selectionLineContext)
            [/Selected line context]
            """
        } else if let lineText {
            contextSuffix = """

            [Current line]
            \(lineText)
            [/Current line]
            """
        } else {
            contextSuffix = ""
        }

        let context = """
        [Canope IDE Context — current selection in "\(fileName)"]
        \(text)
        \(contextSuffix)
        [/Canope IDE Context]

        \(userMessage)
        """
        return context
    }

    nonisolated static func buildPromptForInteractionMode(
        _ userMessage: String,
        mode: ChatInteractionMode,
        includeIDEContext: Bool = true
    ) -> String {
        let promptWithContext = buildPromptWithIDEContext(
            userMessage,
            includeIDEContext: includeIDEContext
        )
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
            - Si une edition est appropriee et que la demande est claire, tente directement l'outil d'edition: le client demandera l'approbation inline.
            - N'ecris pas de message du type "j'attends ton approbation" ou "si tu veux, j'applique"; laisse l'UI d'approbation faire ce travail.
            - Une fois l'approbation accordee, applique seulement le changement valide, sans redemander la permission dans le chat.
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

    nonisolated static func findCLI(_ name: String) -> String {
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
}

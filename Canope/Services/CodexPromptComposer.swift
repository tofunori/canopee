import Foundation

enum CodexPromptComposer {
    static func buildPromptWithIDEContext(
        _ userMessage: String,
        includeIDEContext: Bool = true
    ) -> String {
        guard includeIDEContext else {
            return userMessage
        }

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
        let lineText = trimmedOrNil(json["lineText"] as? String)
        let selectionLineContext = trimmedOrNil(json["selectionLineContext"] as? String)
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

        return """
        [Canope IDE Context — current selection in "\(fileName)")]
        \(text)
        \(contextSuffix)
        [/Canope IDE Context]

        \(userMessage)
        """
    }

    static func buildPromptForInteractionMode(
        _ userMessage: String,
        mode: ChatInteractionMode,
        includeIDEContext: Bool = true,
        globalCustomInstructions: String = "",
        sessionCustomInstructions: String = ""
    ) -> String {
        let promptWithContext = buildPromptWithIDEContext(
            userMessage,
            includeIDEContext: includeIDEContext
        )
        let customInstructionsBlock = buildCustomInstructionsBlock(
            global: globalCustomInstructions,
            session: sessionCustomInstructions
        )

        func joinSections(_ sections: [String]) -> String {
            sections
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        switch mode {
        case .agent:
            return joinSections([customInstructionsBlock, promptWithContext])
        case .acceptEdits:
            return joinSections([
                """
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
                """,
                customInstructionsBlock,
                promptWithContext,
            ])
        case .plan:
            return joinSections([
                """
                [Canope Plan Mode]
                Tu es en mode plan strict.
                - N'execute aucune edition de fichier.
                - N'utilise aucune commande mutante.
                - Ne lance aucune action avec effets de bord.
                - Produis seulement un plan structure avec: Objectif, Changements proposes, Validation, Risques.
                - Si une information manque, formule des hypotheses explicites au lieu d'agir.
                [/Canope Plan Mode]
                """,
                customInstructionsBlock,
                promptWithContext,
            ])
        }
    }

    static func buildTurnInputPayload(
        from items: [ChatInputItem],
        interactionMode: ChatInteractionMode,
        includeIDEContext: Bool = true,
        globalCustomInstructions: String = "",
        sessionCustomInstructions: String = ""
    ) -> [[String: Any]] {
        items.flatMap { item in
            switch item {
            case .text(let text):
                return ChatInputItem.text(
                    buildPromptForInteractionMode(
                        text,
                        mode: interactionMode,
                        includeIDEContext: includeIDEContext,
                        globalCustomInstructions: globalCustomInstructions,
                        sessionCustomInstructions: sessionCustomInstructions
                    )
                ).codexPayloads
            default:
                return item.codexPayloads
            }
        }
    }

    private static func buildCustomInstructionsBlock(
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

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import XCTest
@testable import Canope

final class ChatSolidificationTests: XCTestCase {
    func testAttachedFileMapsToStructuredChatInputItems() {
        let textFile = AttachedFile(
            name: "notes.md",
            path: "/tmp/notes.md",
            content: "# Notes"
        )
        let imageFile = AttachedFile(
            name: "capture.png",
            path: "/tmp/capture.png",
            content: "[Pasted image saved at: /tmp/capture.png]",
            kind: .image
        )

        XCTAssertEqual(
            textFile.chatInputItem,
            .textFile(name: "notes.md", path: "/tmp/notes.md", content: "# Notes")
        )
        XCTAssertEqual(
            imageFile.chatInputItem,
            .localImage(path: "/tmp/capture.png")
        )
    }

    func testChatInputItemLegacyPromptKeepsFilesAndImagesReadable() {
        let prompt = ChatInputItem.legacyPrompt(from: [
            .textFile(name: "notes.md", path: "/tmp/notes.md", content: "# Notes"),
            .localImage(path: "/tmp/capture.png"),
            .text("Explique ce contenu"),
        ])

        XCTAssertTrue(prompt.contains("[Attached file: notes.md]"))
        XCTAssertTrue(prompt.contains("Path: /tmp/notes.md"))
        XCTAssertTrue(prompt.contains("[Attached image: capture.png]"))
        XCTAssertTrue(prompt.contains("Explique ce contenu"))
    }

    func testChatInteractionModeCyclesInExpectedOrder() {
        XCTAssertEqual(ChatInteractionMode.agent.next, .acceptEdits)
        XCTAssertEqual(ChatInteractionMode.acceptEdits.next, .plan)
        XCTAssertEqual(ChatInteractionMode.plan.next, .agent)
    }

    func testBuildPromptWithIDEContext_appendsSelection() throws {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        let payload: [String: Any] = [
            "text": "selected line",
            "filePath": "/tmp/paper.tex",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let out = ClaudeHeadlessProvider.buildPromptWithIDEContext("Hello")
        XCTAssertTrue(out.contains("[Canope IDE Context"))
        XCTAssertTrue(out.contains("selected line"))
        XCTAssertTrue(out.contains("Hello"))
    }

    func testClaudePlanPromptWrapsUserMessageAndAddsGuardrails() {
        let out = ClaudeHeadlessProvider.buildPromptForInteractionMode("Fais le plan", mode: .plan)
        XCTAssertTrue(out.contains("[Canope Plan Mode]"))
        XCTAssertTrue(out.contains("Produis seulement un plan structure"))
        XCTAssertTrue(out.contains("Fais le plan"))
    }

    func testClaudeAcceptEditsPromptAddsEditOnlyGuardrails() {
        let out = ClaudeHeadlessProvider.buildPromptForInteractionMode("Modifie ce fichier", mode: .acceptEdits)
        XCTAssertTrue(out.contains("[Canope Accept Edits Mode]"))
        XCTAssertTrue(out.contains("N'applique aucune edition de fichier sans approbation explicite"))
        XCTAssertTrue(out.contains("N'utilise pas Bash"))
        XCTAssertTrue(out.contains("Modifie ce fichier"))
    }

    func testClaudeMutatingToolDetectionFlagsEditsAndBash() {
        XCTAssertTrue(ClaudeHeadlessProvider.isMutatingTool(name: "Edit", input: nil))
        XCTAssertTrue(ClaudeHeadlessProvider.isMutatingTool(name: "Bash", input: ["command": "ls -la"]))
        XCTAssertFalse(ClaudeHeadlessProvider.isMutatingTool(name: "Read", input: nil))
    }

    func testAcceptEditsBlocksMutationsPendingApproval() {
        XCTAssertTrue(ClaudeHeadlessProvider.shouldBlockTool(name: "Bash", input: nil, mode: .acceptEdits))
        XCTAssertTrue(ClaudeHeadlessProvider.shouldBlockTool(name: "functions.exec_command", input: nil, mode: .acceptEdits))
        XCTAssertTrue(ClaudeHeadlessProvider.shouldBlockTool(name: "Edit", input: nil, mode: .acceptEdits))
        XCTAssertTrue(ClaudeHeadlessProvider.shouldBlockTool(name: "Write", input: nil, mode: .acceptEdits))
        XCTAssertFalse(ClaudeHeadlessProvider.shouldBlockTool(name: "Read", input: nil, mode: .acceptEdits))
    }

    func testBlockedToolMessageReflectsInteractionMode() {
        XCTAssertEqual(
            ClaudeHeadlessProvider.blockedToolMessage(toolName: "Bash", mode: .acceptEdits),
            "Mode accept edits: l’action Bash a ete bloquee en attendant ton approbation. L’approbation interactive n’est pas encore branchee."
        )
        XCTAssertEqual(
            ClaudeHeadlessProvider.blockedToolMessage(toolName: "Edit", mode: .plan),
            "Mode plan: l’action mutante Edit a ete bloquee."
        )
    }

    @MainActor
    func testMarkdownAttributedPreview_includesHeading() {
        let raw = "## Title\n\nBody **bold**"
        let attr = MarkdownBlockView.attributedPreview(for: raw)
        XCTAssertFalse(attr.characters.isEmpty)
    }

    @MainActor
    func testChatMessage_attributedPreview() {
        let attr = ChatMessage.attributedPreview(for: "# Hi\n\nTest")
        XCTAssertFalse(attr.characters.isEmpty)
    }

    func testChatMarkdownPolicy_skipsVeryLargeMessages() {
        let s = String(repeating: "a", count: ChatMarkdownPolicy.maxFullRenderCharacters + 1)
        XCTAssertTrue(ChatMarkdownPolicy.shouldSkipFullMarkdown(for: s))
        XCTAssertFalse(ChatMarkdownPolicy.shouldSkipFullMarkdown(for: "short"))
    }

    func testChatMarkdownPolicy_preRenderedRetention_evictsOldestWhenMessageCountExceeded() {
        var messages: [ChatMessage] = []
        for _ in 0..<(ChatMarkdownPolicy.maxRetainedPreRenderedMessages + 1) {
            var m = ChatMessage(
                role: .assistant,
                content: String(repeating: "a", count: 100),
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
            m.preRenderedMarkdown = AttributedString("x")
            messages.append(m)
        }
        ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &messages)

        let withPrerender = messages.filter { $0.preRenderedMarkdown != nil }
        XCTAssertEqual(withPrerender.count, ChatMarkdownPolicy.maxRetainedPreRenderedMessages)
        XCTAssertNil(messages.first?.preRenderedMarkdown, "oldest assistant should lose pre-render first")
        XCTAssertNotNil(messages.last?.preRenderedMarkdown)
    }

    func testChatMarkdownPolicy_preRenderedRetention_evictsWhenCharacterBudgetExceeded() {
        // Two newest exactly fill the char budget; the third (oldest) must be evicted.
        let chunk = ChatMarkdownPolicy.maxRetainedPreRenderedCharacters / 2
        var messages: [ChatMessage] = []
        for _ in 0..<3 {
            var m = ChatMessage(
                role: .assistant,
                content: String(repeating: "b", count: chunk),
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false
            )
            m.preRenderedMarkdown = AttributedString("y")
            messages.append(m)
        }
        ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &messages)

        let withPrerender = messages.filter { $0.preRenderedMarkdown != nil }
        XCTAssertEqual(withPrerender.count, 2, "only two newest fit under char budget")
        XCTAssertNil(messages.first?.preRenderedMarkdown)
    }

    func testChatMarkdownPolicy_preRenderedRetention_skipsHistoryMessages() {
        var old = ChatMessage(
            role: .assistant,
            content: "hist",
            timestamp: Date(),
            isStreaming: false,
            isCollapsed: false
        )
        old.isFromHistory = true
        old.preRenderedMarkdown = AttributedString("h")

        var fresh = ChatMessage(
            role: .assistant,
            content: String(repeating: "c", count: 50_000),
            timestamp: Date(),
            isStreaming: false,
            isCollapsed: false
        )
        fresh.preRenderedMarkdown = AttributedString("f")

        var messages = [old, fresh]
        ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &messages)

        XCTAssertNotNil(messages[0].preRenderedMarkdown)
        XCTAssertNotNil(messages[1].preRenderedMarkdown)
    }

    func testMarkdownBlockView_renderAttributedPreviewForBackground_matchesPipeline() {
        let raw = "## Title\n\nPara **bold**"
        let bg = MarkdownBlockView.renderAttributedPreviewForBackground(raw)
        XCTAssertFalse(bg.characters.isEmpty)
    }

    func testChatMessageEquality_includesToolOutput() {
        let a = ChatMessage(
            role: .toolUse, content: "x", timestamp: Date(),
            toolName: "Read",
            isStreaming: false, isCollapsed: true
        )
        var b = a
        b.toolOutput = "out"
        XCTAssertNotEqual(a, b)
    }

    func testChatMessageEquality_includesPresentationKind() {
        let a = ChatMessage(
            role: .assistant,
            content: "Plan",
            timestamp: Date(),
            isStreaming: false,
            isCollapsed: false
        )
        var b = a
        b.presentationKind = .plan
        XCTAssertNotEqual(a, b)
    }

    func testCodexServerRequestDispositionRespectsInteractionMode() {
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "item/fileChange/requestApproval",
                mode: .agent
            ),
            .autoApprove
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "item/fileChange/requestApproval",
                mode: .acceptEdits
            ),
            .inlineApproval
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "item/fileChange/requestApproval",
                mode: .plan
            ),
            .reject
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "item/tool/call",
                mode: .agent
            ),
            .unsupported
        )
        let simpleElicitation: [String: Any] = [
            "requestedSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
            ],
        ]
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "mcpServer/elicitation/request",
                mode: .agent,
                params: simpleElicitation
            ),
            .autoApprove
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "mcpServer/elicitation/request",
                mode: .acceptEdits,
                params: simpleElicitation
            ),
            .inlineApproval
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "mcpServer/elicitation/request",
                mode: .plan,
                params: simpleElicitation
            ),
            .reject
        )
        let toolRequestInput: [String: Any] = [
            "questions": [[
                "header": "Nom",
                "id": "name",
                "question": "Quel nom veux-tu utiliser ?",
            ]],
        ]
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "item/tool/requestUserInput",
                mode: .agent,
                params: toolRequestInput
            ),
            .inlineApproval
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "item/tool/requestUserInput",
                mode: .plan,
                params: toolRequestInput
            ),
            .reject
        )
        XCTAssertEqual(
            CodexAppServerProvider.serverRequestDisposition(
                for: "mcpServer/elicitation/request",
                mode: .agent,
                params: [
                    "requestedSchema": [
                        "type": "object",
                        "properties": [
                            "confirmed": ["type": "boolean"],
                        ],
                        "required": ["confirmed"],
                    ],
                ]
            ),
            .inlineApproval
        )
    }

    @MainActor
    func testCodexApprovalPolicyMatchesInteractionMode() {
        XCTAssertEqual(CodexAppServerProvider.approvalPolicy(for: .agent), "on-request")
        XCTAssertEqual(CodexAppServerProvider.approvalPolicy(for: .acceptEdits), "on-request")
        XCTAssertEqual(CodexAppServerProvider.approvalPolicy(for: .plan), "never")
        XCTAssertEqual(CodexAppServerProvider.threadSandboxMode(for: .plan), "read-only")
        XCTAssertEqual(CodexAppServerProvider.threadSandboxMode(for: .agent), "workspace-write")
        XCTAssertTrue(CodexAppServerProvider.defaultEfforts.contains("xhigh"))
    }

    func testCodexTurnInputPayloadPreservesStructuredInputs() {
        let payload = CodexAppServerProvider.buildTurnInputPayload(
            from: [
                .textFile(name: "notes.md", path: "/tmp/notes.md", content: "# Notes"),
                .localImage(path: "/tmp/capture.png"),
                .text("Explique ce contenu"),
            ],
            interactionMode: .agent
        )

        XCTAssertEqual(payload.count, 3)
        XCTAssertEqual(payload[0]["type"] as? String, "text")
        XCTAssertEqual(payload[1]["type"] as? String, "localImage")
        XCTAssertEqual(payload[1]["path"] as? String, "/tmp/capture.png")
        XCTAssertEqual(payload[2]["type"] as? String, "text")
        XCTAssertTrue((payload[0]["text"] as? String)?.contains("[Attached file: notes.md]") == true)
        XCTAssertTrue((payload[2]["text"] as? String)?.contains("Explique ce contenu") == true)
    }

    @MainActor
    func testCodexAcceptEditsServerApprovalCreatesPendingApproval() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentRunState(interactionMode: .acceptEdits, prompt: "Modifie ce fichier", displayText: "Modifie ce fichier")
        provider.testHandleServerRequest(
            id: 41,
            method: "item/fileChange/requestApproval",
            params: ["paths": ["/tmp/example.md"]]
        )

        XCTAssertEqual(provider.pendingApprovalRequest?.rpcRequestID, 41)
        XCTAssertEqual(provider.pendingApprovalRequest?.rpcMethod, "item/fileChange/requestApproval")
        XCTAssertEqual(provider.pendingApprovalRequest?.toolName, "example.md")
        XCTAssertEqual(provider.pendingApprovalRequest?.itemID, nil)
        XCTAssertFalse(provider.isProcessing)
    }

    @MainActor
    func testCodexAcceptEditsSimpleMCPElicitationCreatesPendingApproval() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentRunState(interactionMode: .acceptEdits, prompt: "Vois-tu ma selection?", displayText: "Vois-tu ma selection?")
        provider.testHandleServerRequest(
            id: 42,
            method: "mcpServer/elicitation/request",
            params: [
                "serverName": "canope",
                "message": "Allow the canope MCP server to run tool \"getCurrentSelection\"?",
                "requestedSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ],
            ]
        )

        XCTAssertEqual(provider.pendingApprovalRequest?.rpcRequestID, 42)
        XCTAssertEqual(provider.pendingApprovalRequest?.rpcMethod, "mcpServer/elicitation/request")
        XCTAssertEqual(provider.pendingApprovalRequest?.toolName, "getCurrentSelection")
        XCTAssertFalse(provider.isProcessing)
    }

    @MainActor
    func testCodexAgentToolRequestUserInputCreatesInteractiveApproval() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentRunState(interactionMode: .agent, prompt: "Configure ça", displayText: "Configure ça")
        provider.testHandleServerRequest(
            id: 43,
            method: "item/tool/requestUserInput",
            params: [
                "itemId": "tool_1",
                "threadId": "thread_1",
                "turnId": "turn_1",
                "questions": [[
                    "header": "Nom",
                    "id": "name",
                    "question": "Quel nom veux-tu utiliser ?",
                ]],
            ]
        )

        XCTAssertEqual(provider.pendingApprovalRequest?.rpcRequestID, 43)
        XCTAssertEqual(provider.pendingApprovalRequest?.fields.count, 1)
        XCTAssertEqual(provider.pendingApprovalRequest?.fields.first?.id, "name")
        XCTAssertEqual(provider.pendingApprovalRequest?.message, "Quel nom veux-tu utiliser ?")
    }

    @MainActor
    func testCodexMcpFormFieldExtractionSupportsBooleanAndText() {
        let fields = CodexAppServerProvider.testServerRequestFields(
            method: "mcpServer/elicitation/request",
            params: [
                "mode": "form",
                "message": "Confirme la publication",
                "requestedSchema": [
                    "type": "object",
                    "properties": [
                        "confirmed": [
                            "type": "boolean",
                            "title": "Confirmation",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Titre affiche",
                        ],
                    ],
                    "required": ["confirmed", "title"],
                ],
            ]
        )

        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first(where: { $0.id == "confirmed" })?.kind, .boolean)
        XCTAssertEqual(fields.first(where: { $0.id == "title" })?.kind, .text)
    }

    @MainActor
    func testCodexToolRequestUserInputResponseResultMapsAnswersByQuestionId() {
        let result = CodexAppServerProvider.testToolRequestUserInputResponseResult(
            params: [
                "questions": [[
                    "header": "Nom",
                    "id": "name",
                    "question": "Quel nom ?",
                ]],
            ],
            fieldValues: ["name": "Canope"]
        )

        let answers = result["answers"] as? [String: Any]
        let name = answers?["name"] as? [String: Any]
        XCTAssertEqual(name?["answers"] as? [String], ["Canope"])
    }

    @MainActor
    func testCodexMcpElicitationResponseResultBuildsTypedContent() {
        let result = CodexAppServerProvider.testMcpElicitationResponseResult(
            params: [
                "requestedSchema": [
                    "type": "object",
                    "properties": [
                        "confirmed": ["type": "boolean"],
                        "count": ["type": "integer"],
                        "label": ["type": "string"],
                    ],
                ],
            ],
            approved: true,
            fieldValues: [
                "confirmed": "true",
                "count": "3",
                "label": "Hydrology",
            ]
        )

        XCTAssertEqual(result["action"] as? String, "accept")
        let content = result["content"] as? [String: Any]
        XCTAssertEqual(content?["confirmed"] as? Bool, true)
        XCTAssertEqual(content?["count"] as? Int, 3)
        XCTAssertEqual(content?["label"] as? String, "Hydrology")
    }

    @MainActor
    func testCodexUnsupportedServerRequestAppendsSystemMessage() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testHandleServerRequest(id: 7, method: "item/tool/call", params: [:])

        XCTAssertEqual(
            provider.messages.last?.content,
            "Codex: les appels d’outils dynamiques ne sont pas encore pris en charge dans Canope."
        )
    }

    @MainActor
    func testCodexPlanItemStreamsIntoPlanPresentation() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentRunState(interactionMode: .plan, prompt: "Fais un plan", displayText: "Fais un plan")
        provider.testHandleNotification(
            method: "item/started",
            params: ["item": ["type": "plan", "id": "plan_1"]]
        )
        provider.testHandleNotification(
            method: "item/plan/delta",
            params: ["itemId": "plan_1", "delta": "Objectif\nPlan"]
        )
        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": ["type": "plan", "id": "plan_1"]]
        )

        XCTAssertEqual(provider.messages.last?.role, .assistant)
        XCTAssertEqual(provider.messages.last?.presentationKind, .plan)
        XCTAssertEqual(provider.messages.last?.content, "Objectif\nPlan")
    }

    @MainActor
    func testCodexReviewNotificationsUpdateReviewState() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testHandleNotification(
            method: "item/started",
            params: ["item": ["type": "enteredReviewMode", "id": "review_1", "review": "working-tree"]]
        )
        XCTAssertEqual(provider.chatReviewStateDescription, "Review actif · working-tree")

        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": ["type": "exitedReviewMode", "id": "review_1", "review": "working-tree"]]
        )
        XCTAssertNil(provider.chatReviewStateDescription)
    }

    @MainActor
    func testCodexReviewCommandWithoutActiveThreadShowsHelpfulMessage() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.startChatReview()

        XCTAssertEqual(provider.messages.last?.role, .system)
        XCTAssertEqual(provider.messages.last?.content, "Codex: lance d’abord une conversation avant /review.")
    }

    @MainActor
    func testCodexCompletedCommandExecutionKeepsCompactToolCard() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testHandleNotification(
            method: "item/started",
            params: ["item": ["type": "commandExecution", "id": "cmd_1", "command": "ls -la", "cwd": "/tmp", "status": "inProgress"]]
        )
        provider.testHandleNotification(
            method: "item/commandExecution/outputDelta",
            params: ["itemId": "cmd_1", "delta": "file.txt"]
        )
        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": ["type": "commandExecution", "id": "cmd_1", "command": "ls -la", "status": "completed", "exitCode": 0]]
        )

        XCTAssertEqual(provider.messages.count, 1)
        XCTAssertEqual(provider.messages.last?.role, .toolUse)
        XCTAssertTrue(provider.messages.last?.toolOutput?.contains("Commande terminee") == true)
        XCTAssertTrue(provider.messages.last?.toolOutput?.contains("file.txt") == true)
        XCTAssertEqual(provider.messages.last?.isCollapsed, true)
    }

    @MainActor
    func testCodexWebSearchCreatesCompactToolCard() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testHandleNotification(
            method: "item/started",
            params: ["item": [
                "type": "webSearch",
                "id": "web_1",
                "query": "hydrology paper",
            ]]
        )
        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": [
                "type": "webSearch",
                "id": "web_1",
                "query": "hydrology paper",
            ]]
        )

        XCTAssertEqual(provider.messages.count, 1)
        XCTAssertEqual(provider.messages.last?.role, .toolUse)
        XCTAssertEqual(provider.messages.last?.toolName, "WebSearch")
        XCTAssertEqual(provider.messages.last?.content, "Recherche web · hydrology paper")
        XCTAssertEqual(provider.messages.last?.toolOutput, "Recherche web · hydrology paper")
    }

    @MainActor
    func testCodexFailedFileChangeUsesNeutralSummary() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testHandleNotification(
            method: "item/started",
            params: ["item": [
                "type": "fileChange",
                "id": "edit_1",
                "changes": [["path": "/tmp/demo.tex"]],
            ]]
        )
        provider.testHandleNotification(
            method: "item/fileChange/outputDelta",
            params: ["itemId": "edit_1", "delta": "Exact text not found"]
        )
        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": [
                "type": "fileChange",
                "id": "edit_1",
                "status": "failed",
                "changes": [["path": "/tmp/demo.tex"]],
            ]]
        )

        XCTAssertEqual(provider.messages.count, 1)
        XCTAssertEqual(provider.messages.last?.role, .toolUse)
        XCTAssertEqual(provider.messages.last?.toolOutput, "Modification proposee · demo.tex non appliquee")
    }

    @MainActor
    func testCodexSuppressesDirectEditFailureBoilerplateFromAssistantDisplay() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testBeginAssistantMessage()
        provider.testReceiveAssistantDelta("Je vais appliquer seulement le changement approuve.\n\n")
        provider.testReceiveAssistantDelta("L’edition directe a echoue parce que le texte exact left=8pt n’a pas ete retrouve tel quel dans le fichier.\n\n")
        provider.testReceiveAssistantDelta("Je verifie maintenant la selection active.")
        provider.testFlushPendingAssistantDelta()

        XCTAssertEqual(
            provider.messages.last?.content,
            "Je vais appliquer seulement le changement approuve.\n\nJe verifie maintenant la selection active."
        )
    }
}

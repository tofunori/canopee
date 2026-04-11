import AppKit
import CoreText
import PDFKit
import XCTest
@testable import Canope

final class ChatSolidificationTests: XCTestCase {
    @MainActor
    final class MockHeadlessProvider: ObservableObject, HeadlessChatProviding {
        @Published var messages: [ChatMessage] = []
        @Published var isProcessing = false
        @Published var isConnected = true
        @Published var session = SessionInfo()
        @Published var pendingApprovalRequest: ChatApprovalRequest?

        let providerName = "Mock"
        let providerIcon = "brain"
        var chatWorkingDirectory = URL(fileURLWithPath: "/tmp")
        var chatSessionDisplayName = "Mock session"
        var chatCanRenameCurrentSession = false
        var chatVisualStyle: ChatVisualStyle = .standard
        var chatUsesBottomPromptControls = false
        var chatPromptEnvironmentLabel: String?
        var chatPromptConfigurationLabel: String?
        var chatSupportsCustomInstructions = false
        var chatCustomInstructions = ChatCustomInstructions()
        var chatSupportsIDEContextToggle = true
        var chatIncludesIDEContext = true
        var chatInteractionMode: ChatInteractionMode = .agent
        var chatSupportsPlanMode = true
        var chatSupportsReview = false
        var chatReviewStateDescription: String?
        var chatStatusBadges: [ChatStatusBadge] = []
        var chatAvailableModels: [String] = ["mock"]
        var chatSelectedModel = "mock"
        var chatAvailableEfforts: [String] = ["low"]
        var chatSelectedEffort = "low"

        func start() {}
        func stop() {}
        func sendMessage(_ text: String) { _ = text }
        func chatStatusActions(for badge: ChatStatusBadge) -> [ChatStatusAction] { _ = badge; return [] }
        func performChatStatusAction(_ action: ChatStatusAction) { _ = action }
        func newChatSession() {}
        func resumeLastChatSession(matchingDirectory: URL?) { _ = matchingDirectory }
        func resumeChatSession(id: String) { _ = id }
        func renameCurrentChatSession(to name: String) { _ = name }
        func updateChatCustomInstructions(global: String, session: String) {
            chatCustomInstructions = ChatCustomInstructions(globalText: global, sessionText: session)
        }
        func resetSessionCustomInstructions() {
            chatCustomInstructions = ChatCustomInstructions(globalText: chatCustomInstructions.globalText, sessionText: "")
        }
        func editAndResendLastUser(newText: String) { _ = newText }
        func forkChatFromUserMessage(newText: String) { _ = newText }
        func sendMessageWithDisplay(displayText: String, items: [ChatInputItem]) { _ = displayText; _ = items }
        func sendMessageWithDisplay(displayText: String, prompt: String) { _ = displayText; _ = prompt }
        func startChatReview(command: String?) { _ = command }
        func approvePendingApprovalRequest() {}
        func submitPendingApprovalRequest(fieldValues: [String: String]) { _ = fieldValues }
        func dismissPendingApprovalRequest() { pendingApprovalRequest = nil }
        func listChatSessions(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] { _ = limit; _ = matchingDirectory; return [] }
        func listChatSessionsAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem] { _ = limit; _ = matchingDirectory; return [] }
        static func renameChatSession(id: String, name: String) { _ = id; _ = name }
        static func toolIconName(for toolName: String) -> String { toolName }
    }

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

    func testAttachedFileDisplaySummaryUsesCompactImageLabel() {
        let imageFile = AttachedFile(
            name: "image_001.png",
            path: "/tmp/image_001.png",
            content: "",
            kind: .image
        )

        XCTAssertEqual(AttachedFile.chatDisplaySummary(for: [imageFile]), "🖼 1 image attached")
    }

    func testAttachedFileDisplayTextKeepsPromptReadableWithImageAttachment() {
        let imageFile = AttachedFile(
            name: "image_001.png",
            path: "/tmp/image_001.png",
            content: "",
            kind: .image
        )

        let displayText = AttachedFile.chatDisplayText(
            userText: "non regarde comment la premiere etait belle",
            attachedFiles: [imageFile]
        )

        XCTAssertEqual(
            displayText,
            "non regarde comment la premiere etait belle\n🖼 1 image attached"
        )
    }

    func testAttachedFileDisplayTextKeepsLongDocumentAttachmentCompact() {
        let pdfFile = AttachedFile(
            name: "dossier_determinisme_diamond_seminaire_doctoral.pdf",
            path: "/tmp/dossier_determinisme_diamond_seminaire_doctoral.pdf",
            content: "PDF",
            kind: .textFile
        )

        let displayText = AttachedFile.chatDisplayText(
            userText: "fit toi a ce document",
            attachedFiles: [pdfFile]
        )

        XCTAssertEqual(
            displayText,
            "fit toi a ce document\n📎 1 file attached"
        )
    }

    func testChatAttachmentSupportReadsUnicodeFallbackForAutocompleteAndPickerParity() throws {
        let url = makeTemporaryTextFile(
            named: "selection-unicode.txt",
            content: "Bonjour de l’encoding Unicode",
            encoding: .unicode
        )

        XCTAssertEqual(
            ChatAttachmentSupport.readTextAttachment(at: url),
            "Bonjour de l’encoding Unicode"
        )
        XCTAssertEqual(
            ChatAttachmentSupport.readTextFileWithFallbacks(at: url),
            "Bonjour de l’encoding Unicode"
        )
    }

    func testChatAttachmentSupportReadsPDFWithSharedPageMarkersForAttachments() throws {
        let url = try makeTemporaryTextPDF(
            named: "attached-pages.pdf",
            pages: ["Page un", "Page deux"]
        )

        XCTAssertEqual(
            ChatAttachmentSupport.readTextAttachment(at: url),
            """
            [Attached PDF: attached-pages.pdf]

            --- Page 1 ---
            Page un

            --- Page 2 ---
            Page deux
            """
        )
    }

    func testChatAttachmentSupportMakeAttachmentKeepsImageAttachmentsStructured() throws {
        let url = try makeTemporaryFile(
            named: "capture.png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        let attachment = ChatAttachmentSupport.makeAttachment(from: url)

        XCTAssertEqual(attachment?.name, "capture.png")
        XCTAssertEqual(attachment?.path, url.path)
        XCTAssertEqual(attachment?.content, "[Attached image at: \(url.path)]")
        XCTAssertEqual(attachment?.kind, .image)
    }

    func testChatAttachmentSupportMakeAttachmentKeepsTextFallbacksStructured() throws {
        let url = makeTemporaryTextFile(
            named: "notes-unicode.txt",
            content: "Bonjour Unicode",
            encoding: .unicode
        )

        let attachment = ChatAttachmentSupport.makeAttachment(from: url)

        XCTAssertEqual(attachment?.name, "notes-unicode.txt")
        XCTAssertEqual(attachment?.path, url.path)
        XCTAssertEqual(attachment?.content, "Bonjour Unicode")
        XCTAssertEqual(attachment?.kind, .textFile)
    }

    func testChatAttachmentSupportSkippedAttachmentMessageRemainsStable() {
        XCTAssertEqual(
            ChatAttachmentSupport.skippedAttachmentMessage(for: ["notes.bin", "archive.zip"]),
            "Skipped attachments: notes.bin, archive.zip. Only images and text files are supported for now."
        )
    }

    func testChatInteractionModeCyclesInExpectedOrder() {
        XCTAssertEqual(ChatInteractionMode.agent.next, .acceptEdits)
        XCTAssertEqual(ChatInteractionMode.acceptEdits.next, .plan)
        XCTAssertEqual(ChatInteractionMode.plan.next, .agent)
    }

    @MainActor
    func testProvidersExposeExpectedChatVisualStyles() {
        let claude = ClaudeHeadlessProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let codex = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(claude.chatVisualStyle, .standard)
        XCTAssertEqual(codex.chatVisualStyle, .codex)
    }

    func testChatCustomInstructionsSummaryLabelReflectsState() {
        XCTAssertEqual(ChatCustomInstructions().summaryLabel, "No instructions")
        XCTAssertEqual(ChatCustomInstructions(globalText: "Toujours concis").summaryLabel, "Global active")
        XCTAssertEqual(ChatCustomInstructions(sessionText: "Cite les fichiers").summaryLabel, "Session active")
        XCTAssertEqual(
            ChatCustomInstructions(globalText: "Toujours concis", sessionText: "Cite les fichiers").summaryLabel,
            "Global + session"
        )
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

    func testCodexBuildPromptWithIDEContextIncludesSelectedLineContext() throws {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        let payload: [String: Any] = [
            "text": "right=2.0cm]{",
            "filePath": "/tmp/paper.tex",
            "selectionLineContext": "\\begin{adjustwidth}{0cm}{[[right=2.0cm]{",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let out = CodexAppServerProvider.buildPromptWithIDEContext("met ca a 1cm")
        XCTAssertTrue(out.contains("[Selected line context]"))
        XCTAssertTrue(out.contains("\\begin{adjustwidth}{0cm}{[[right=2.0cm]{"))
        XCTAssertTrue(out.contains("met ca a 1cm"))
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
        XCTAssertTrue(out.contains("le client demandera l'approbation inline"))
        XCTAssertTrue(out.contains("N'ecris pas de message du type"))
        XCTAssertTrue(out.contains("Modifie ce fichier"))
    }

    func testCodexAcceptEditsPromptPrefersInlineApprovalOverChatNegotiation() {
        let out = CodexAppServerProvider.buildPromptForInteractionMode("Modifie ce fichier", mode: .acceptEdits)
        XCTAssertTrue(out.contains("[Canope Accept Edits Mode]"))
        XCTAssertTrue(out.contains("le client demandera l'approbation inline"))
        XCTAssertTrue(out.contains("N'ecris pas de message du type"))
        XCTAssertFalse(out.contains("attends l'approbation au lieu d'agir"))
        XCTAssertTrue(out.contains("Modifie ce fichier"))
    }

    func testCodexPromptIncludesGlobalAndSessionCustomInstructionsInOrder() {
        let out = CodexAppServerProvider.buildPromptForInteractionMode(
            "Explique ce fichier",
            mode: .agent,
            globalCustomInstructions: "Toujours repondre en francais quebecois.",
            sessionCustomInstructions: "Dans cette session, sois tres concis."
        )

        XCTAssertTrue(out.contains("[Canope Custom Instructions — Global]"))
        XCTAssertTrue(out.contains("[Canope Custom Instructions — Session]"))
        XCTAssertLessThan(
            out.range(of: "[Canope Custom Instructions — Global]")!.lowerBound,
            out.range(of: "[Canope Custom Instructions — Session]")!.lowerBound
        )
        XCTAssertLessThan(
            out.range(of: "[Canope Custom Instructions — Session]")!.lowerBound,
            out.range(of: "Explique ce fichier")!.lowerBound
        )
    }

    func testCodexPromptSkipsDuplicateSessionInstructions() {
        let out = CodexAppServerProvider.buildPromptForInteractionMode(
            "Explique ce fichier",
            mode: .agent,
            globalCustomInstructions: "Toujours etre concis.",
            sessionCustomInstructions: "Toujours etre concis."
        )

        XCTAssertTrue(out.contains("[Canope Custom Instructions — Global]"))
        XCTAssertFalse(out.contains("[Canope Custom Instructions — Session]"))
    }

    func testCodexPromptPrefersCurrentPaperContextForPDFRequests() throws {
        let selectionPath = CanopeContextFiles.ideSelectionStatePaths[0]
        let paperPath = CanopeContextFiles.paperPaths[0]

        let selectionPayload: [String: Any] = [
            "text": "memory_summary rollout details",
            "filePath": "/Users/tofunori/.codex/memories/MEMORY.md",
        ]
        let selectionData = try JSONSerialization.data(withJSONObject: selectionPayload)
        try selectionData.write(to: URL(fileURLWithPath: selectionPath), options: .atomic)
        try """
        ========================================
        CURRENTLY OPEN PAPER IN CANOPÉE
        ========================================
        Title: Test Paper
        Authors: Jane Doe

        Main result from the PDF.
        """.write(toFile: paperPath, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(atPath: selectionPath)
            try? FileManager.default.removeItem(atPath: paperPath)
        }

        let out = CodexAppServerProvider.buildPromptForInteractionMode(
            "Résume le PDF ouvert",
            mode: .agent
        )

        XCTAssertTrue(out.contains("[Canope Paper Context"))
        XCTAssertTrue(out.contains("Title: Test Paper"))
        XCTAssertTrue(out.contains("Main result from the PDF."))
        XCTAssertFalse(out.contains("[Canope IDE Context"))
        XCTAssertFalse(out.contains("memory_summary rollout details"))
    }

    @MainActor
    func testChatHeaderStateHidesConnectedAndMCPOkayInCodexStyle() {
        let provider = MockHeadlessProvider()
        provider.session.turns = 3
        provider.chatStatusBadges = [
            ChatStatusBadge(kind: .connected, text: "Connected"),
            ChatStatusBadge(kind: .mcpOkay, text: "MCP OK"),
            ChatStatusBadge(kind: .authRequired, text: "Auth required"),
        ]

        let state = ChatHeaderState(provider: provider, usesCodexVisualStyle: true)

        XCTAssertFalse(state.showsProviderIcon)
        XCTAssertEqual(state.visibleStatusBadges, [ChatStatusBadge(kind: .authRequired, text: "Auth required")])
        XCTAssertEqual(state.turnCountLabel, "3 turns")
    }

    func testChatComposerStateReflectsPromptAndAttachmentAvailability() {
        let emptyState = ChatComposerState(
            inputText: "   ",
            attachedFiles: [],
            interactionMode: .plan,
            providerName: "Codex",
            usesCodexVisualStyle: true
        )
        XCTAssertFalse(emptyState.canSend)
        XCTAssertEqual(emptyState.placeholder, "Plan to Codex…")
        XCTAssertEqual(emptyState.sendButtonHelp, "Send planning request")
        XCTAssertEqual(emptyState.environmentExecutionLabel, "Read-only")

        let attachmentState = ChatComposerState(
            inputText: "",
            attachedFiles: [AttachedFile(name: "note.txt", path: "/tmp/note.txt", content: "x")],
            interactionMode: .agent,
            providerName: "Codex",
            usesCodexVisualStyle: true
        )
        XCTAssertTrue(attachmentState.canSend)
        XCTAssertEqual(attachmentState.environmentExecutionLabel, "Local write")
    }

    func testCodexNotificationRouterRoutesToolOutputAndErrors() {
        let toolEvent = CodexNotificationRouter.route(
            method: "item/commandExecution/outputDelta",
            params: ["itemId": "item-1", "output": "hello"]
        )
        switch toolEvent {
        case .toolOutputDelta(let itemID, let delta):
            XCTAssertEqual(itemID, "item-1")
            XCTAssertEqual(delta, "hello")
        default:
            XCTFail("Expected tool output delta event")
        }

        let errorEvent = CodexNotificationRouter.route(
            method: "error",
            params: [
                "message": "Boom",
                "willRetry": true,
            ]
        )
        switch errorEvent {
        case .error(let rendered, let willRetry):
            XCTAssertEqual(rendered, "Boom")
            XCTAssertTrue(willRetry)
        default:
            XCTFail("Expected error event")
        }
    }

    @MainActor
    func testClaudeStreamReducerFlushesBufferedEventsIncludingTrailingLineWithoutNewline() {
        let reducer = ClaudeStreamReducer()
        var events: [ClaudeStreamEvent] = []

        reducer.appendOutput("""
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"result","duration_ms":12}
        """) { event in
            events.append(event)
        }
        reducer.flushPendingLines { event in
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        if case .system(let json) = events[0] {
            XCTAssertEqual(json["session_id"] as? String, "abc")
        } else {
            XCTFail("Expected system event first")
        }
        if case .result(let json) = events[1] {
            XCTAssertEqual(json["duration_ms"] as? Int, 12)
        } else {
            XCTFail("Expected result event second")
        }
    }

    @MainActor
    func testCodexCustomInstructionsPersistGloballyAndPerThread() {
        CodexAppServerProvider.testClearStoredCustomInstructions()
        defer { CodexAppServerProvider.testClearStoredCustomInstructions() }

        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentThreadId("thread-123")
        provider.updateChatCustomInstructions(
            global: "Toujours repondre en francais quebecois.",
            session: "Dans cette session, sois tres concis."
        )

        XCTAssertEqual(provider.chatCustomInstructions.globalText, "Toujours repondre en francais quebecois.")
        XCTAssertEqual(provider.chatCustomInstructions.sessionText, "Dans cette session, sois tres concis.")
        XCTAssertEqual(
            CodexAppServerProvider.testStoredSessionCustomInstructions(threadId: "thread-123"),
            "Dans cette session, sois tres concis."
        )

        let reloaded = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(reloaded.chatCustomInstructions.globalText, "Toujours repondre en francais quebecois.")
    }

    @MainActor
    func testCodexThreadReadHistorySnapshotBuildsVisibleMessages() {
        let result: [String: Any] = [
            "thread": [
                "name": "Session test",
                "turns": [
                    [
                        "id": "turn-1",
                        "items": [
                            [
                                "type": "userMessage",
                                "id": "item-user",
                                "content": [[
                                    "type": "text",
                                    "text": "Bonjour Codex"
                                ]]
                            ],
                            [
                                "type": "agentMessage",
                                "id": "item-assistant",
                                "text": "Salut"
                            ],
                            [
                                "type": "commandExecution",
                                "id": "item-bash",
                                "command": "/bin/echo hi",
                                "cwd": "/tmp",
                                "status": "completed",
                                "exitCode": 0,
                                "aggregatedOutput": "hi"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let snapshot = CodexAppServerProvider.historySnapshot(fromThreadReadResult: result)

        XCTAssertEqual(snapshot?.name, "Session test")
        XCTAssertEqual(snapshot?.turns, 1)
        XCTAssertEqual(snapshot?.messages.count, 3)
        XCTAssertEqual(snapshot?.messages.first?.role, .user)
        XCTAssertEqual(snapshot?.messages.first?.content, "Bonjour Codex")
        XCTAssertEqual(snapshot?.messages[1].role, .assistant)
        XCTAssertEqual(snapshot?.messages[1].content, "Salut")
        XCTAssertEqual(snapshot?.messages[2].role, .toolUse)
        XCTAssertEqual(snapshot?.messages[2].toolName, "Bash")
        XCTAssertEqual(snapshot?.messages[2].toolOutput, "Command completed (code 0) · /bin/echo hi\nhi")
        XCTAssertTrue(snapshot?.messages.allSatisfy(\.isFromHistory) ?? false)
    }

    @MainActor
    func testCodexThreadReadHistorySnapshotStripsInjectedIDEContextFromUserMessage() {
        let result: [String: Any] = [
            "thread": [
                "name": "Session test",
                "turns": [
                    [
                        "id": "turn-1",
                        "items": [
                            [
                                "type": "userMessage",
                                "id": "item-user",
                                "content": [[
                                    "type": "text",
                                    "text": """
                                    [Canope IDE Context — current selection in "Proposed Research Initiative v6.tex")]
                                    \\vfill

                                    [Selected line context]
                                    foo[[bar]]
                                    [/Selected line context]
                                    [/Canope IDE Context]

                                    ui, globalement je le trouve bon pour approcher des partenaires.
                                    """
                                ]]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let snapshot = CodexAppServerProvider.historySnapshot(fromThreadReadResult: result)

        XCTAssertEqual(snapshot?.messages.count, 1)
        XCTAssertEqual(snapshot?.messages.first?.role, .user)
        XCTAssertEqual(
            snapshot?.messages.first?.content,
            "ui, globalement je le trouve bon pour approcher des partenaires."
        )
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

    func testChatCommandRouterRoutesLocalCommands() {
        XCTAssertEqual(
            ChatCommandRouter.route(
                inputText: "/plan",
                attachedFiles: [],
                supportsReview: true,
                chatFileRootURL: URL(fileURLWithPath: "/tmp/chat")
            ),
            .setMode(.plan)
        )

        XCTAssertEqual(
            ChatCommandRouter.route(
                inputText: "/resume",
                attachedFiles: [],
                supportsReview: true,
                chatFileRootURL: URL(fileURLWithPath: "/tmp/chat")
            ),
            .showSessionPicker
        )

        XCTAssertEqual(
            ChatCommandRouter.route(
                inputText: "/continue",
                attachedFiles: [],
                supportsReview: true,
                chatFileRootURL: URL(fileURLWithPath: "/tmp/chat")
            ),
            .resumeLastChatSession(matchingDirectory: URL(fileURLWithPath: "/tmp/chat"))
        )
    }

    func testChatCommandRouterRoutesReviewOnlyWhenSupported() {
        XCTAssertEqual(
            ChatCommandRouter.route(
                inputText: "/review HEAD~1",
                attachedFiles: [],
                supportsReview: true,
                chatFileRootURL: URL(fileURLWithPath: "/tmp/chat")
            ),
            .startReview(command: "HEAD~1")
        )

        XCTAssertEqual(
            ChatCommandRouter.route(
                inputText: "/review HEAD~1",
                attachedFiles: [],
                supportsReview: false,
                chatFileRootURL: URL(fileURLWithPath: "/tmp/chat")
            ),
            .sendText("/review HEAD~1")
        )
    }

    func testChatCommandRouterBuildsStructuredInputItemsForAttachments() {
        let attachment = AttachedFile(
            name: "notes.txt",
            path: "/tmp/notes.txt",
            content: "Hydrology notes",
            kind: .textFile
        )

        XCTAssertEqual(
            ChatCommandRouter.route(
                inputText: "Regarde ca",
                attachedFiles: [attachment],
                supportsReview: true,
                chatFileRootURL: URL(fileURLWithPath: "/tmp/chat")
            ),
            .sendItems(
                displayText: "Regarde ca\n📎 1 file attached",
                items: [
                    .textFile(name: "notes.txt", path: "/tmp/notes.txt", content: "Hydrology notes"),
                    .text("Regarde ca"),
                ]
            )
        )
    }

    @MainActor
    func testChatApprovalFormModelValidatesRequiredIntegerAndNumberFields() {
        let model = ChatApprovalFormModel()
        let approval = ChatApprovalRequest(
            toolName: "request_user_input",
            prompt: "Prompt",
            displayText: "Prompt",
            fields: [
                ChatInteractiveField(
                    id: "count",
                    title: "Count",
                    prompt: nil,
                    kind: .integer,
                    options: [],
                    isRequired: true,
                    allowsCustomValue: false,
                    placeholder: nil,
                    defaultValue: ""
                ),
                ChatInteractiveField(
                    id: "ratio",
                    title: "Ratio",
                    prompt: nil,
                    kind: .number,
                    options: [],
                    isRequired: false,
                    allowsCustomValue: false,
                    placeholder: nil,
                    defaultValue: ""
                ),
            ]
        )

        model.sync(with: approval)
        XCTAssertFalse(model.canSubmit(approval))

        model.setValue("abc", for: "count")
        XCTAssertFalse(model.canSubmit(approval))

        model.setValue("3", for: "count")
        model.setValue("oops", for: "ratio")
        XCTAssertFalse(model.canSubmit(approval))

        model.setValue("0.75", for: "ratio")
        XCTAssertTrue(model.canSubmit(approval))
    }

    @MainActor
    func testChatApprovalFormModelResolvesOtherChoiceValue() {
        let model = ChatApprovalFormModel()
        let field = ChatInteractiveField(
            id: "format",
            title: "Format",
            prompt: nil,
            kind: .singleChoice,
            options: [
                ChatInteractiveOption(label: "PDF", description: ""),
                ChatInteractiveOption(label: "DOCX", description: ""),
            ],
            isRequired: true,
            allowsCustomValue: true,
            placeholder: nil,
            defaultValue: "PDF"
        )
        let approval = ChatApprovalRequest(
            toolName: "request_user_input",
            prompt: "Prompt",
            displayText: "Prompt",
            fields: [field]
        )

        model.sync(with: approval)
        model.setValue("__other__", for: "format")
        model.setOtherValue("Markdown", for: "format")

        XCTAssertEqual(model.resolvedValue(for: field), "Markdown")
        XCTAssertTrue(model.canSubmit(approval))
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
        XCTAssertEqual(provider.chatStatusBadges.last?.kind, .reviewActive)

        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": ["type": "exitedReviewMode", "id": "review_1", "review": "Aucun finding."]]
        )
        XCTAssertNil(provider.chatReviewStateDescription)
        XCTAssertEqual(provider.chatStatusBadges.last?.kind, .reviewDone)
    }

    @MainActor
    func testCodexReviewCommandWithoutActiveThreadShowsHelpfulMessage() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.startChatReview(command: nil)

        XCTAssertEqual(provider.messages.last?.role, .system)
        XCTAssertEqual(provider.messages.last?.content, "Codex: start a conversation before /review.")
    }

    @MainActor
    func testCodexReviewTargetParsingSupportsBranchCommitAndCustomInstructions() {
        XCTAssertEqual(
            CodexAppServerProvider.testReviewTarget(command: nil)["type"] as? String,
            "uncommittedChanges"
        )
        XCTAssertEqual(
            CodexAppServerProvider.testReviewTarget(command: "branch main")["branch"] as? String,
            "main"
        )
        XCTAssertEqual(
            CodexAppServerProvider.testReviewTarget(command: "commit abc123")["sha"] as? String,
            "abc123"
        )
        XCTAssertEqual(
            CodexAppServerProvider.testReviewTarget(command: "cherche les regressions UI")["instructions"] as? String,
            "cherche les regressions UI"
        )
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
        XCTAssertTrue(provider.messages.last?.toolOutput?.contains("Command completed") == true)
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
                "action": "search",
            ]]
        )
        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": [
                "type": "webSearch",
                "id": "web_1",
                "query": "hydrology paper",
                "action": "search",
            ]]
        )

        XCTAssertEqual(provider.messages.count, 1)
        XCTAssertEqual(provider.messages.last?.role, .toolUse)
        XCTAssertEqual(provider.messages.last?.toolName, "WebSearch")
        XCTAssertEqual(provider.messages.last?.content, "Recherche web · hydrology paper · search")
        XCTAssertEqual(provider.messages.last?.toolInput, "query: hydrology paper\naction: search")
        XCTAssertEqual(provider.messages.last?.toolOutput, "Recherche web · hydrology paper · search\nAction: search")
    }

    @MainActor
    func testCodexDynamicToolCallUsesCompactArgumentPreview() {
        let preview = CodexAppServerProvider.testDynamicToolCallInputPreview([
            "tool": "read_file",
            "arguments": [
                "path": "/tmp/demo.tex",
                "query": "snow albedo",
                "limit": 25,
            ],
        ])

        XCTAssertEqual(
            preview,
            """
            path: /tmp/demo.tex
            query: snow albedo
            limit: 25
            """
        )
    }

    @MainActor
    func testCodexCollabAgentToolCallUsesCompactPreview() {
        let preview = CodexAppServerProvider.testCollabAgentToolCallInputPreview([
            "tool": "delegate",
            "senderThreadId": "thread_source_123",
            "targetThreadId": "thread_target_456",
            "status": "running",
            "arguments": [
                "path": "/tmp/demo.tex",
            ],
        ])

        XCTAssertEqual(
            preview,
            """
            sender: thread_source_123
            target: thread_target_456
            status: running
            path: /tmp/demo.tex
            """
        )
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
        XCTAssertEqual(provider.messages.last?.toolOutput, "Modification proposee · demo.tex not applied")
    }

    @MainActor
    func testCodexServerRequestDetailsSummarizeFileEditsAndCommands() {
        XCTAssertEqual(
            CodexAppServerProvider.testServerRequestDetails(
                method: "item/fileChange/requestApproval",
                params: ["paths": ["/tmp/demo.tex", "/tmp/notes.md"]]
            ),
            ["demo.tex", "notes.md", "2 fichiers"]
        )
        XCTAssertEqual(
            CodexAppServerProvider.testServerRequestDetails(
                method: "item/commandExecution/requestApproval",
                params: ["command": "latexmk main.tex", "cwd": "/tmp/project"]
            ),
            ["latexmk main.tex", "/tmp/project"]
        )
    }

    @MainActor
    func testCodexServerRequestPreviewExtractsCompactDiffForFileChanges() {
        let preview = CodexAppServerProvider.testServerRequestPreview(
            method: "item/fileChange/requestApproval",
            params: [
                "changes": [[
                    "path": "/tmp/demo.tex",
                    "kind": "update",
                    "diff": """
                    --- a/demo.tex
                    +++ b/demo.tex
                    @@ -10,3 +10,3 @@
                    -\\setlength{\\tabcolsep}{8pt}
                    +\\setlength{\\tabcolsep}{6pt}
                    """,
                ]],
            ]
        )

        XCTAssertEqual(preview?.title, "demo.tex · update")
        XCTAssertEqual(
            preview?.body,
            """
            @@ -10,3 +10,3 @@
            -\\setlength{\\tabcolsep}{8pt}
            +\\setlength{\\tabcolsep}{6pt}
            """
        )
    }

    @MainActor
    func testCodexAcceptEditsApprovalCarriesContextDetails() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentRunState(interactionMode: .acceptEdits, prompt: "Fais le changement", displayText: "Fais le changement")
        provider.testHandleServerRequest(
            id: 99,
            method: "item/fileChange/requestApproval",
            params: [
                "itemId": "edit_1",
                "threadId": "thread_1",
                "turnId": "turn_1",
                "paths": ["/tmp/demo.tex"],
                "changes": [[
                    "path": "/tmp/demo.tex",
                    "kind": "update",
                    "diff": """
                    @@ -1,1 +1,1 @@
                    -left=8pt
                    +left=6pt
                    """,
                ]],
            ]
        )

        XCTAssertEqual(provider.pendingApprovalRequest?.details, ["demo.tex"])
        XCTAssertEqual(provider.pendingApprovalRequest?.actionLabel, "Edit")
        XCTAssertEqual(provider.pendingApprovalRequest?.preview?.title, "demo.tex · update")
        XCTAssertEqual(
            provider.pendingApprovalRequest?.preview?.body,
            """
            @@ -1,1 +1,1 @@
            -left=8pt
            +left=6pt
            """
        )
    }

    @MainActor
    func testCodexParseRenderedReviewOutputCreatesSummaryAndFindings() {
        let rendered = """
        Patch incorrect: deux regressions doivent etre corrigees.

        Review Findings:

        [P1] Valider l’entree utilisateur
        Cette branche ecrit des donnees non verifiees dans le cache.
        Location: /tmp/demo.swift:10-12

        [P2] Reutiliser le formatter partage
        Le formatter local recree dans la boucle est inutilement couteux.
        Location: /tmp/format.swift:30-31
        """

        let parsed = CodexAppServerProvider.testParseReviewOutput(rendered)
        XCTAssertEqual(parsed.summary, "Patch incorrect: deux regressions doivent etre corrigees.")
        XCTAssertEqual(parsed.findings.count, 2)
        XCTAssertEqual(parsed.findings[0].title, "Valider l’entree utilisateur")
        XCTAssertEqual(parsed.findings[0].priority, 1)
        XCTAssertEqual(parsed.findings[0].filePath, "/tmp/demo.swift")
        XCTAssertEqual(parsed.findings[0].lineStart, 10)
        XCTAssertEqual(parsed.findings[0].lineEnd, 12)
    }

    @MainActor
    func testCodexExitedReviewModeAppendsReviewFindingCards() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testHandleNotification(
            method: "item/started",
            params: ["item": ["type": "enteredReviewMode", "id": "review_1", "review": "working-tree"]]
        )
        provider.testHandleNotification(
            method: "item/completed",
            params: ["item": ["type": "exitedReviewMode", "id": "review_1", "review": """
            Patch incorrect.

            [P1] Stabiliser le calcul
            Le resultat diverge selon l’ordre des entrees.
            Location: /tmp/demo.swift:42-44
            """]]
        )

        XCTAssertEqual(provider.messages.count, 2)
        XCTAssertEqual(provider.messages[0].presentationKind, .standard)
        XCTAssertEqual(provider.messages[1].presentationKind, .reviewFinding)
        XCTAssertEqual(provider.messages[1].reviewFinding?.title, "Stabiliser le calcul")
        XCTAssertEqual(provider.messages[1].reviewFinding?.locationLabel, "demo.swift:42-44")
    }

    @MainActor
    func testCodexStatusBadgesCombineConnectionAndSubsystemState() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetConnectionState(isConnected: true, initialized: true)
        provider.testSetStatusBadges(
            review: ChatStatusBadge(kind: .reviewDone, text: "Review terminee"),
            auth: ChatStatusBadge(kind: .authRequired, text: "Auth requise"),
            mcp: ChatStatusBadge(kind: .mcpOkay, text: "MCP OK")
        )

        XCTAssertEqual(
            provider.chatStatusBadges.map(\.text),
            ["Connected", "MCP OK", "Auth requise", "Review terminee"]
        )
    }

    @MainActor
    func testCodexServerRequestStatusBadgesAreSpecificForAuthAndMcp() {
        let authBadges = CodexAppServerProvider.testDerivedStatusBadgesForServerRequest(
            method: "account/chatgptAuthTokens/refresh",
            disposition: .unsupported
        )
        XCTAssertEqual(authBadges.auth?.text, "ChatGPT login")

        let reloadBadges = CodexAppServerProvider.testDerivedStatusBadgesForServerRequest(
            method: "config/mcpServer/reload",
            disposition: .unsupported
        )
        XCTAssertEqual(reloadBadges.mcp?.text, "MCP reload")

        let loginBadges = CodexAppServerProvider.testDerivedStatusBadgesForServerRequest(
            method: "mcpServer/oauth/login",
            disposition: .inlineApproval
        )
        XCTAssertEqual(loginBadges.auth?.text, "Login MCP")
        XCTAssertEqual(loginBadges.mcp?.text, "MCP login")
    }

    @MainActor
    func testCodexErrorStatusBadgesDetectMcpTransportAndChatgptAuth() {
        let transportBadges = CodexAppServerProvider.testDerivedStatusBadgesForErrorText(
            "MCP transport closed: broken pipe"
        )
        XCTAssertEqual(transportBadges.mcp?.text, "MCP transport")

        let authBadges = CodexAppServerProvider.testDerivedStatusBadgesForErrorText(
            "ChatGPT auth token refresh required"
        )
        XCTAssertEqual(authBadges.auth?.text, "ChatGPT login")
    }

    @MainActor
    func testCodexStatusBadgeActionsExposeUsefulMcpAndAuthOperations() {
        let mcpActions = CodexAppServerProvider.testStatusActions(
            for: ChatStatusBadge(kind: .mcpWarning, text: "MCP reload")
        )
        XCTAssertEqual(mcpActions.map(\.id), ["mcpReload", "mcpStatusList"])

        let authActions = CodexAppServerProvider.testStatusActions(
            for: ChatStatusBadge(kind: .authRequired, text: "ChatGPT login")
        )
        XCTAssertEqual(authActions.map(\.id), ["chatgptAuthRefresh"])
    }

    @MainActor
    func testCodexMCPStatusResultBadgeHighlightsAttentionAndHealthyStates() {
        let warningBadge = CodexAppServerProvider.testBadgeFromMCPStatusResult([
            "servers": [
                ["name": "canope", "status": "error"],
            ],
        ])
        XCTAssertEqual(warningBadge.kind, .mcpWarning)
        XCTAssertEqual(warningBadge.text, "MCP attention")

        let okayBadge = CodexAppServerProvider.testBadgeFromMCPStatusResult([
            "servers": [
                ["name": "canope", "status": "connected"],
            ],
        ])
        XCTAssertEqual(okayBadge.kind, .mcpOkay)
        XCTAssertEqual(okayBadge.text, "MCP OK")
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

    @MainActor
    func testClaudeQueuesMessagesWhileProcessing() {
        let provider = ClaudeHeadlessProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetProcessing(true)

        provider.sendMessage("Deuxieme message")

        XCTAssertEqual(provider.messages.count, 1)
        XCTAssertEqual(provider.messages.first?.role, .user)
        XCTAssertEqual(provider.messages.first?.content, "Deuxieme message")
        XCTAssertEqual(provider.messages.first?.queuePosition, 1)
        XCTAssertEqual(provider.testQueuedMessageCount, 1)
    }

    @MainActor
    func testClaudeToolUseAndToolResultStayAssociatedOnSameCard() {
        let provider = ClaudeHeadlessProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetCurrentRunState(interactionMode: .agent)

        provider.testHandleAssistantEvent([
            "message": [
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Read",
                        "input": ["file_path": "/tmp/note.txt"],
                    ],
                    [
                        "type": "tool_result",
                        "content": "Contenu lu",
                    ],
                ]
            ]
        ])

        XCTAssertEqual(provider.messages.count, 1)
        XCTAssertEqual(provider.messages.first?.role, .toolUse)
        XCTAssertEqual(provider.messages.first?.toolName, "Read")
        XCTAssertEqual(provider.messages.first?.content, "note.txt")
        XCTAssertEqual(provider.messages.first?.toolOutput, "Contenu lu")
    }

    @MainActor
    func testClaudeResultEventStopsProcessingAndAccumulatesSessionMetrics() {
        let provider = ClaudeHeadlessProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetProcessing(true)

        provider.testHandleResultEvent([
            "duration_ms": 42,
            "total_cost_usd": 0.125,
        ])

        XCTAssertFalse(provider.isProcessing)
        XCTAssertEqual(provider.session.turns, 1)
        XCTAssertEqual(provider.session.durationMs, 42)
        XCTAssertEqual(provider.session.costUSD, 0.125, accuracy: 0.0001)
    }

    @MainActor
    func testCodexRetryingErrorKeepsProcessingAndTurnStateUntilRetryCompletes() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetProcessing(true)
        provider.testSetCurrentTurnId("turn-123")

        provider.testHandleNotification(method: "error", params: [
            "message": "Boom",
            "willRetry": true,
        ])

        XCTAssertTrue(provider.isProcessing)
        XCTAssertEqual(provider.testCurrentTurnId, "turn-123")
        XCTAssertEqual(provider.messages.last?.role, .system)
        XCTAssertEqual(provider.messages.last?.content, "Boom")
    }

    @MainActor
    func testCodexNonRetryingErrorStopsProcessingAndClearsTurnState() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetProcessing(true)
        provider.testSetCurrentTurnId("turn-123")

        provider.testHandleNotification(method: "error", params: [
            "message": "Boom",
            "willRetry": false,
        ])

        XCTAssertFalse(provider.isProcessing)
        XCTAssertNil(provider.testCurrentTurnId)
        XCTAssertEqual(provider.messages.last?.role, .system)
        XCTAssertEqual(provider.messages.last?.content, "Boom")
    }

    @MainActor
    func testCodexTurnCompletedClearsStreamingAssistantAndTurnState() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp"))
        provider.testSetProcessing(true)
        provider.testSetCurrentTurnId("turn-123")
        provider.testBeginAssistantMessage()
        provider.testReceiveAssistantDelta("Plan en cours")
        provider.testFlushPendingAssistantDelta()

        provider.testHandleNotification(method: "turn/completed", params: [:])

        XCTAssertFalse(provider.isProcessing)
        XCTAssertNil(provider.testCurrentTurnId)
        XCTAssertEqual(provider.messages.last?.role, .assistant)
        XCTAssertFalse(provider.messages.last?.isStreaming ?? true)
    }

    private func makeTemporaryTextFile(
        named name: String,
        content: String,
        encoding: String.Encoding
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? content.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func makeTemporaryFile(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private func makeTemporaryTextPDF(named name: String, pages: [String]) throws -> URL {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            XCTFail("Expected a PDF data consumer")
            throw NSError(domain: "ChatSolidificationTests", code: 1)
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 400)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Expected a PDF graphics context")
            throw NSError(domain: "ChatSolidificationTests", code: 2)
        }

        for pageText in pages {
            context.beginPDFPage(nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
            let attributedString = NSAttributedString(string: pageText, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributedString)
            context.textPosition = CGPoint(x: 36, y: 220)
            CTLineDraw(line, context)
            context.endPDFPage()
        }

        context.closePDF()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }
}

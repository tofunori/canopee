import XCTest
@testable import Canope

final class ChatSolidificationTests: XCTestCase {
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

    @MainActor
    func testTerminalWorkspaceState_reusesChatProvidersForSameTab() {
        let state = TerminalWorkspaceState()
        let tabID = UUID()
        let workingDirectory = URL(fileURLWithPath: "/tmp/canope-tests")

        let claudeA = state.claudeChatProvider(for: tabID, workingDirectory: workingDirectory)
        let claudeB = state.claudeChatProvider(for: tabID, workingDirectory: workingDirectory)
        XCTAssertTrue(claudeA === claudeB)

        let codexA = state.codexChatProvider(for: tabID, workingDirectory: workingDirectory)
        let codexB = state.codexChatProvider(for: tabID, workingDirectory: workingDirectory)
        XCTAssertTrue(codexA === codexB)
    }

    @MainActor
    func testCodexProvider_batchesAssistantDeltasUntilFlushed() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp/canope-tests"))

        provider.testBeginAssistantMessage()
        provider.testReceiveAssistantDelta("Bon")
        provider.testReceiveAssistantDelta("jour")

        XCTAssertEqual(provider.messages.last?.content, "")
        XCTAssertEqual(provider.messages.last?.role, .assistant)

        provider.testFlushPendingAssistantDelta()

        XCTAssertEqual(provider.messages.last?.content, "Bonjour")
        XCTAssertEqual(provider.messages.last?.isStreaming, true)
    }

    @MainActor
    func testCodexProvider_prerenderRetentionIsBounded() {
        let provider = CodexAppServerProvider(workingDirectory: URL(fileURLWithPath: "/tmp/canope-tests"))

        for idx in 0..<(ChatMarkdownPolicy.maxRetainedPreRenderedMessages + 2) {
            let text = "message-\(idx)\n\n" + String(repeating: "x", count: 100)
            provider.testBeginAssistantMessage()
            provider.testReceiveAssistantDelta(text)
            provider.testFlushPendingAssistantDelta()
            provider.testCompleteAssistantMessage()
            XCTAssertEqual(provider.testPendingMarkdownCount, 1)
            provider.testResolvePendingMarkdownSynchronously()
        }

        let retained = provider.messages.filter { $0.role == .assistant && $0.preRenderedMarkdown != nil }
        XCTAssertEqual(retained.count, ChatMarkdownPolicy.maxRetainedPreRenderedMessages)
        XCTAssertNil(provider.messages.first(where: { $0.role == .assistant })?.preRenderedMarkdown)
        XCTAssertNotNil(provider.messages.last(where: { $0.role == .assistant })?.preRenderedMarkdown)
    }
}

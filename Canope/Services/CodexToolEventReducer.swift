import Foundation

@MainActor
final class CodexToolEventReducer {
    private(set) var currentAssistantMessageIndex: Int?
    private(set) var currentAgentItemID: String?
    private(set) var lastRetryStatusMessage: String?
    private(set) var pendingMarkdownCount = 0

    private var pendingAssistantDelta = ""
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var pendingMarkdown: [(UUID, String)] = []
    private var markdownTask: Task<Void, Never>?
    private var itemToolUseMessageIndex: [String: Int] = [:]
    private var itemOutputBuffers: [String: String] = [:]

    private static let assistantDeltaThrottleNanoseconds: UInt64 = 60_000_000
    private static let markdownPreRenderDelayNanoseconds: UInt64 = 80_000_000

    var needsAssistantDeltaFlushScheduling: Bool {
        assistantDeltaFlushTask == nil && !pendingAssistantDelta.isEmpty
    }

    var needsMarkdownScheduling: Bool {
        markdownTask == nil && !pendingMarkdown.isEmpty
    }

    func configureNewRun() {
        currentAssistantMessageIndex = nil
        currentAgentItemID = nil
        lastRetryStatusMessage = nil
        itemToolUseMessageIndex.removeAll()
        itemOutputBuffers.removeAll()
    }

    func stop(messages: inout [ChatMessage]) {
        flushPendingAssistantDelta(messages: &messages)
        clearAssistantDeltaWork()
        clearMarkdownPreRenderWork()
        itemToolUseMessageIndex.removeAll()
        itemOutputBuffers.removeAll()
        if let idx = currentAssistantMessageIndex, idx < messages.count {
            messages[idx].isStreaming = false
        }
        currentAssistantMessageIndex = nil
        currentAgentItemID = nil
    }

    func reset(messages: inout [ChatMessage]) {
        stop(messages: &messages)
        lastRetryStatusMessage = nil
    }

    func beginStreamingAssistantItem(
        item: [String: Any],
        type: String,
        interactionMode: ChatInteractionMode,
        messages: inout [ChatMessage]
    ) {
        clearAssistantDeltaWork()
        let itemID = (item["id"] as? String) ?? UUID().uuidString
        currentAgentItemID = itemID
        let text = (item["text"] as? String) ?? ""
        let presentationKind: ChatMessage.PresentationKind = type == "plan"
            ? .plan
            : (interactionMode == .plan ? .plan : .standard)
        let message = ChatMessage(
            role: .assistant,
            content: text,
            timestamp: Date(),
            isStreaming: true,
            isCollapsed: false,
            presentationKind: presentationKind
        )
        messages.append(message)
        currentAssistantMessageIndex = messages.count - 1
        if !text.isEmpty {
            enqueueMarkdownPreRender(for: message.id, text: text)
        }
    }

    func bufferAssistantDelta(
        _ delta: String,
        itemID: String?,
        messages: inout [ChatMessage]
    ) {
        guard !delta.isEmpty,
              let idx = assistantMessageIndex(for: itemID, messageCount: messages.count)
        else { return }
        if let itemID, currentAgentItemID == nil {
            currentAgentItemID = itemID
        }
        pendingAssistantDelta += delta
        messages[idx].isStreaming = true
    }

    func appendToolOutputDelta(itemID: String, delta: String) {
        guard !delta.isEmpty else { return }
        itemOutputBuffers[itemID, default: ""].append(delta)
    }

    func completeAssistantItem(item: [String: Any], messages: inout [ChatMessage]) {
        if let text = item["text"] as? String,
           let idx = currentAssistantMessageIndex,
           idx < messages.count,
           messages[idx].content.isEmpty {
            messages[idx].content = text
        }

        if let idx = currentAssistantMessageIndex, idx < messages.count {
            messages[idx].isStreaming = false
            enqueueMarkdownPreRender(for: messages[idx].id, text: messages[idx].content)
        }
        currentAssistantMessageIndex = nil
        currentAgentItemID = nil
    }

    func appendToolUseItem(
        itemID: String?,
        toolName: String,
        content: String,
        toolInput: String?,
        messages: inout [ChatMessage]
    ) {
        messages.append(
            ChatMessage(
                role: .toolUse,
                content: content,
                timestamp: Date(),
                toolName: toolName,
                toolInput: toolInput,
                isStreaming: false,
                isCollapsed: true
            )
        )
        if let itemID {
            itemToolUseMessageIndex[itemID] = messages.count - 1
        }
    }

    func completeToolItem(
        itemID: String?,
        toolName: String,
        summary: String?,
        messages: inout [ChatMessage]
    ) {
        guard let summary, !summary.isEmpty else { return }
        if let itemID,
           let idx = itemToolUseMessageIndex[itemID],
           idx < messages.count {
            messages[idx].toolOutput = summary
            messages[idx].isCollapsed = true
            itemToolUseMessageIndex.removeValue(forKey: itemID)
            itemOutputBuffers.removeValue(forKey: itemID)
            return
        }

        messages.append(
            ChatMessage(
                role: .toolResult,
                content: summary,
                timestamp: Date(),
                toolName: toolName,
                isStreaming: false,
                isCollapsed: false
            )
        )
    }

    func bufferedOutput(for itemID: String?) -> String? {
        guard let itemID else { return nil }
        return itemOutputBuffers[itemID]
    }

    func clearResolvedApproval(for itemID: String?) {
        guard let itemID else { return }
        itemToolUseMessageIndex.removeValue(forKey: itemID)
        itemOutputBuffers.removeValue(forKey: itemID)
    }

    func markRetryStatusMessage(_ message: String?) {
        lastRetryStatusMessage = message
    }

    func enqueuePlanUpdate(
        explanation: String?,
        plan: [[String: Any]],
        messages: inout [ChatMessage]
    ) {
        let text = CodexSessionPersistence.renderPlanText(plan: plan, explanation: explanation)
        messages.append(
            ChatMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                isStreaming: false,
                isCollapsed: false,
                presentationKind: .plan
            )
        )
        if let id = messages.last?.id {
            enqueueMarkdownPreRender(for: id, text: text)
        }
    }

    func flushPendingAssistantDelta(messages: inout [ChatMessage]) {
        guard !pendingAssistantDelta.isEmpty else { return }
        guard let idx = currentAssistantMessageIndex, idx < messages.count else {
            pendingAssistantDelta.removeAll()
            return
        }
        let merged = messages[idx].content + pendingAssistantDelta
        messages[idx].content = CodexSessionPersistence.sanitizeAssistantDisplayText(merged)
        messages[idx].isStreaming = true
        pendingAssistantDelta.removeAll()
    }

    func flushMarkdownPreRender(into messages: inout [ChatMessage]) {
        guard !pendingMarkdown.isEmpty else { return }
        let batch = pendingMarkdown
        pendingMarkdown.removeAll()
        pendingMarkdownCount = 0
        for (id, text) in batch {
            let attr = MarkdownBlockView.renderAttributedPreviewForBackground(text)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].preRenderedMarkdown = attr
                ChatMarkdownPolicy.applyPreRenderedMarkdownRetentionBudget(to: &messages)
            }
        }
        markdownTask = nil
    }

    func scheduleMarkdownPreRender(apply: @escaping @MainActor () -> Void) {
        markdownTask?.cancel()
        markdownTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: Self.markdownPreRenderDelayNanoseconds)
            await MainActor.run {
                guard let self else { return }
                apply()
                self.markdownTask = nil
            }
        }
    }

    func scheduleAssistantDeltaFlush(apply: @escaping @MainActor () -> Void) {
        assistantDeltaFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.assistantDeltaThrottleNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.assistantDeltaFlushTask = nil
            apply()
        }
    }

    func clearMarkdownPreRenderWork() {
        pendingMarkdown.removeAll()
        pendingMarkdownCount = 0
        markdownTask?.cancel()
        markdownTask = nil
    }

    func clearAssistantDeltaWork() {
        assistantDeltaFlushTask?.cancel()
        assistantDeltaFlushTask = nil
        pendingAssistantDelta.removeAll()
    }

    private func assistantMessageIndex(for itemID: String?, messageCount: Int) -> Int? {
        if let itemID,
           let currentAgentItemID,
           currentAgentItemID == itemID,
           let currentAssistantMessageIndex,
           currentAssistantMessageIndex < messageCount {
            return currentAssistantMessageIndex
        }
        if itemID == nil,
           let currentAssistantMessageIndex,
           currentAssistantMessageIndex < messageCount {
            return currentAssistantMessageIndex
        }
        return currentAssistantMessageIndex
    }
    private func enqueueMarkdownPreRender(for id: UUID, text: String) {
        guard !text.isEmpty else { return }
        guard !ChatMarkdownPolicy.shouldSkipFullMarkdown(for: text) else { return }
        pendingMarkdown.append((id, text))
        pendingMarkdownCount = pendingMarkdown.count
    }
}

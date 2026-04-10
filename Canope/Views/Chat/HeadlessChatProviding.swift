import Foundation

enum ChatVisualStyle {
    case standard
    case codex
}

struct ChatCustomInstructions: Equatable {
    var globalText: String
    var sessionText: String

    init(globalText: String = "", sessionText: String = "") {
        self.globalText = globalText
        self.sessionText = sessionText
    }

    var normalizedGlobalText: String {
        globalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedSessionText: String {
        sessionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasGlobal: Bool {
        !normalizedGlobalText.isEmpty
    }

    var hasSession: Bool {
        !normalizedSessionText.isEmpty
    }

    var hasAny: Bool {
        hasGlobal || hasSession
    }

    var summaryLabel: String {
        switch (hasGlobal, hasSession) {
        case (true, true):
            return "Global + session"
        case (true, false):
            return AppStrings.globalActive
        case (false, true):
            return AppStrings.sessionActive
        case (false, false):
            return AppStrings.noInstructions
        }
    }
}

/// Capabilities of the native headless chat beyond [`AIHeadlessProvider`](AIHeadlessProvider.swift).
@MainActor
protocol HeadlessChatProviding: AIHeadlessProvider {
    var chatWorkingDirectory: URL { get }
    var chatSessionDisplayName: String { get }
    var chatCanRenameCurrentSession: Bool { get }
    var chatVisualStyle: ChatVisualStyle { get }
    var chatUsesBottomPromptControls: Bool { get }
    var chatPromptEnvironmentLabel: String? { get }
    var chatPromptConfigurationLabel: String? { get }
    var chatSupportsCustomInstructions: Bool { get }
    var chatCustomInstructions: ChatCustomInstructions { get }
    var chatSupportsIDEContextToggle: Bool { get }
    var chatIncludesIDEContext: Bool { get set }
    var chatInteractionMode: ChatInteractionMode { get set }
    var chatSupportsPlanMode: Bool { get }
    var chatSupportsReview: Bool { get }
    var chatReviewStateDescription: String? { get }
    var chatStatusBadges: [ChatStatusBadge] { get }
    func chatStatusActions(for badge: ChatStatusBadge) -> [ChatStatusAction]
    func performChatStatusAction(_ action: ChatStatusAction)
    var pendingApprovalRequest: ChatApprovalRequest? { get }

    var chatAvailableModels: [String] { get }
    var chatSelectedModel: String { get set }
    var chatAvailableEfforts: [String] { get }
    var chatSelectedEffort: String { get set }

    func newChatSession()
    func resumeLastChatSession(matchingDirectory: URL?)
    func resumeChatSession(id: String)
    func renameCurrentChatSession(to name: String)
    func updateChatCustomInstructions(global: String, session: String)
    func resetSessionCustomInstructions()
    func editAndResendLastUser(newText: String)
    func forkChatFromUserMessage(newText: String)
    func sendMessageWithDisplay(displayText: String, items: [ChatInputItem])
    func sendMessageWithDisplay(displayText: String, prompt: String)
    func startChatReview(command: String?)
    func approvePendingApprovalRequest()
    func submitPendingApprovalRequest(fieldValues: [String: String])
    func dismissPendingApprovalRequest()
    func listChatSessions(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem]
    func listChatSessionsAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem]

    static func renameChatSession(id: String, name: String)
    static func toolIconName(for toolName: String) -> String
}

struct ChatSessionListItem: Identifiable, Hashable {
    let id: String
    let name: String
    let project: String
    let date: Date?

    var displayName: String {
        if !name.isEmpty { return name }
        return project
    }

    var dateString: String {
        guard let date else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

extension ClaudeHeadlessProvider: HeadlessChatProviding {
    var chatWorkingDirectory: URL { workingDirectoryURL }
    var chatSupportsReview: Bool { false }
    var chatReviewStateDescription: String? { nil }
    var chatSessionDisplayName: String {
        let trimmed = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return session.id == nil ? "Nouvelle conversation" : "Conversation"
    }
    var chatCanRenameCurrentSession: Bool { session.id != nil }

    var chatAvailableModels: [String] { Self.availableModels }
    var chatSelectedModel: String {
        get { selectedModel }
        set { selectedModel = newValue }
    }
    var chatAvailableEfforts: [String] { Self.availableEfforts }
    var chatSelectedEffort: String {
        get { selectedEffort }
        set { selectedEffort = newValue }
    }
    var chatSupportsIDEContextToggle: Bool { true }
    var chatIncludesIDEContext: Bool {
        get { includesIDEContext }
        set { includesIDEContext = newValue }
    }

    func newChatSession() { newSession() }
    func resumeLastChatSession(matchingDirectory: URL?) {
        resumeLastSession(matchingDirectory: matchingDirectory ?? workingDirectory)
    }
    func resumeChatSession(id: String) { resumeSession(id: id) }
    func renameCurrentChatSession(to name: String) { renameCurrentSession(to: name) }
    func editAndResendLastUser(newText: String) { editAndResend(newText: newText) }
    func forkChatFromUserMessage(newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newSession()
        sendMessageWithDisplay(displayText: trimmed, prompt: trimmed)
    }
    func listChatSessions(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem] {
        Self.listSessions(limit: limit, matchingDirectory: matchingDirectory ?? workingDirectory).map {
            ChatSessionListItem(id: $0.id, name: $0.name, project: $0.project, date: $0.date)
        }
    }

    static func renameChatSession(id: String, name: String) {
        renameSession(id: id, name: name)
    }

    static func toolIconName(for toolName: String) -> String {
        toolIcon(for: toolName)
    }
}

extension HeadlessChatProviding {
    var chatVisualStyle: ChatVisualStyle { .standard }
    var chatUsesBottomPromptControls: Bool { false }
    var chatPromptEnvironmentLabel: String? { nil }
    var chatPromptConfigurationLabel: String? { nil }
    var chatSupportsCustomInstructions: Bool { false }
    var chatCustomInstructions: ChatCustomInstructions { ChatCustomInstructions() }
    var chatSupportsIDEContextToggle: Bool { false }
    var chatIncludesIDEContext: Bool {
        get { true }
        set { _ = newValue }
    }
    var chatSupportsReview: Bool { false }
    var chatReviewStateDescription: String? { nil }
    var chatStatusBadges: [ChatStatusBadge] { [] }
    func chatStatusActions(for badge: ChatStatusBadge) -> [ChatStatusAction] {
        _ = badge
        return []
    }
    func performChatStatusAction(_ action: ChatStatusAction) {
        _ = action
    }

    func startChatReview(command: String?) {
        _ = command
    }

    func updateChatCustomInstructions(global: String, session: String) {
        _ = global
        _ = session
    }

    func resetSessionCustomInstructions() {}

    func submitPendingApprovalRequest(fieldValues: [String: String]) {
        _ = fieldValues
        approvePendingApprovalRequest()
    }

    func listChatSessionsAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem] {
        listChatSessions(limit: limit, matchingDirectory: matchingDirectory)
    }
}

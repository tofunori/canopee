import Foundation

/// Capabilities of the native headless chat beyond [`AIHeadlessProvider`](AIHeadlessProvider.swift).
@MainActor
protocol HeadlessChatProviding: AIHeadlessProvider {
    var chatWorkingDirectory: URL { get }
    var chatSessionDisplayName: String { get }
    var chatCanRenameCurrentSession: Bool { get }
    var chatInteractionMode: ChatInteractionMode { get set }
    var chatSupportsPlanMode: Bool { get }
    var chatSupportsReview: Bool { get }
    var chatReviewStateDescription: String? { get }
    var chatStatusBadges: [ChatStatusBadge] { get }
    var pendingApprovalRequest: ChatApprovalRequest? { get }

    var chatAvailableModels: [String] { get }
    var chatSelectedModel: String { get set }
    var chatAvailableEfforts: [String] { get }
    var chatSelectedEffort: String { get set }

    func newChatSession()
    func resumeLastChatSession(matchingDirectory: URL?)
    func resumeChatSession(id: String)
    func renameCurrentChatSession(to name: String)
    func editAndResendLastUser(newText: String)
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

    func newChatSession() { newSession() }
    func resumeLastChatSession(matchingDirectory: URL?) {
        resumeLastSession(matchingDirectory: matchingDirectory ?? workingDirectory)
    }
    func resumeChatSession(id: String) { resumeSession(id: id) }
    func renameCurrentChatSession(to name: String) { renameCurrentSession(to: name) }
    func editAndResendLastUser(newText: String) { editAndResend(newText: newText) }
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
    var chatSupportsReview: Bool { false }
    var chatReviewStateDescription: String? { nil }
    var chatStatusBadges: [ChatStatusBadge] { [] }

    func startChatReview(command: String?) {
        _ = command
    }

    func submitPendingApprovalRequest(fieldValues: [String: String]) {
        _ = fieldValues
        approvePendingApprovalRequest()
    }

    func listChatSessionsAsync(limit: Int, matchingDirectory: URL?) async -> [ChatSessionListItem] {
        listChatSessions(limit: limit, matchingDirectory: matchingDirectory)
    }
}

import Foundation

/// Capabilities of the native headless chat beyond [`AIHeadlessProvider`](AIHeadlessProvider.swift).
@MainActor
protocol HeadlessChatProviding: AIHeadlessProvider {
    var chatWorkingDirectory: URL { get }

    var chatAvailableModels: [String] { get }
    var chatSelectedModel: String { get set }
    var chatAvailableEfforts: [String] { get }
    var chatSelectedEffort: String { get set }

    func newChatSession()
    func resumeLastChatSession(matchingDirectory: URL?)
    func resumeChatSession(id: String)
    func editAndResendLastUser(newText: String)
    func sendMessageWithDisplay(displayText: String, prompt: String)
    func listChatSessions(limit: Int, matchingDirectory: URL?) -> [ChatSessionListItem]

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

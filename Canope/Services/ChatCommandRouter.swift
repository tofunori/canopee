import Foundation

enum ChatCommandAction: Equatable {
    case setMode(ChatInteractionMode)
    case startReview(command: String?)
    case newSession
    case resumeLastChatSession(matchingDirectory: URL)
    case showSessionPicker
    case sendText(String)
    case sendItems(displayText: String, items: [ChatInputItem])
}

enum ChatCommandRouter {
    static func route(
        inputText: String,
        attachedFiles: [AttachedFile],
        supportsReview: Bool,
        chatFileRootURL: URL
    ) -> ChatCommandAction? {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedFiles.isEmpty else { return nil }

        if text == "/plan" {
            return .setMode(.plan)
        }

        if text == "/agent" {
            return .setMode(.agent)
        }

        if text.hasPrefix("/review"), supportsReview {
            let command = String(text.dropFirst("/review".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .startReview(command: command.isEmpty ? nil : command)
        }

        if text == "/new" {
            return .newSession
        }

        if text == "/continue" {
            return .resumeLastChatSession(matchingDirectory: chatFileRootURL)
        }

        if text == "/resume" {
            return .showSessionPicker
        }

        if !attachedFiles.isEmpty {
            let displayText = AttachedFile.chatDisplayText(userText: text, attachedFiles: attachedFiles)
            let items = attachedFiles.map(\.chatInputItem) + (text.isEmpty ? [] : [.text(text)])
            return .sendItems(displayText: displayText, items: items)
        }

        return .sendText(text)
    }
}

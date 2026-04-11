import AppKit
import Foundation

enum ChatMessageActions {
    static func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    static func beginEditing(
        message: ChatMessage,
        editingMessageID: inout UUID?,
        editingText: inout String
    ) {
        editingMessageID = message.id
        editingText = message.content
    }

    @MainActor
    static func commitEditedMessage<Provider: HeadlessChatProviding>(
        message: ChatMessage,
        editingText: String,
        provider: Provider,
        isLatestEditableUserMessage: Bool
    ) {
        if isLatestEditableUserMessage {
            provider.editAndResendLastUser(newText: editingText)
        } else {
            provider.forkChatFromUserMessage(newText: editingText)
        }
    }

    @MainActor
    static func fork<Provider: HeadlessChatProviding>(
        message: ChatMessage,
        provider: Provider
    ) {
        provider.forkChatFromUserMessage(newText: message.content)
    }
}

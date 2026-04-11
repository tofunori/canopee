import Foundation

struct CodexCurrentRunState {
    var interactionMode: ChatInteractionMode = .agent
    var includesIDEContext = true
    var inputItems: [ChatInputItem] = []
    var prompt = ""
    var displayText = ""

    mutating func configure(
        interactionMode: ChatInteractionMode,
        includesIDEContext: Bool,
        inputItems: [ChatInputItem],
        prompt: String,
        displayText: String
    ) {
        self.interactionMode = interactionMode
        self.includesIDEContext = includesIDEContext
        self.inputItems = inputItems
        self.prompt = prompt
        self.displayText = displayText
    }

    mutating func reset() {
        self = CodexCurrentRunState()
    }
}

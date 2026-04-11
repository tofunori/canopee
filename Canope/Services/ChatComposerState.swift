import CoreGraphics
import Foundation

struct ChatComposerState {
    let inputText: String
    let attachedFiles: [AttachedFile]
    let interactionMode: ChatInteractionMode
    let providerName: String
    let usesCodexVisualStyle: Bool

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    var placeholder: String {
        "\(interactionMode.inputPlaceholderSuffix) to \(providerName)…"
    }

    var sendButtonHelp: String {
        interactionMode == .plan ? "Send planning request" : "Send"
    }

    var promptEditorHeight: CGFloat {
        let lineBreaks = inputText.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let wrappedLines = max(1, Int(ceil(Double(max(inputText.count, 1)) / 72.0)))
        let estimatedLines = max(lineBreaks, wrappedLines)

        switch estimatedLines {
        case ...1:
            return 34
        case 2:
            return 52
        case 3:
            return 70
        default:
            return min(110, 70 + CGFloat(estimatedLines - 3) * 18)
        }
    }

    var environmentExecutionLabel: String {
        switch interactionMode {
        case .plan:
            return "Read-only"
        case .agent, .acceptEdits:
            return "Local write"
        }
    }
}

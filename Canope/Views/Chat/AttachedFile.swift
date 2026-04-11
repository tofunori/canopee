import Foundation

struct AttachedFile: Identifiable {
    enum Kind { case textFile, image }

    let id = UUID()
    let name: String
    let path: String
    let content: String
    let kind: Kind

    init(name: String, path: String, content: String, kind: Kind = .textFile) {
        self.name = name
        self.path = path
        self.content = content
        self.kind = kind
    }
}

extension AttachedFile {
    var chatInputItem: ChatInputItem {
        switch kind {
        case .textFile:
            return .textFile(name: name, path: path, content: content)
        case .image:
            return .localImage(path: path)
        }
    }

    static func chatDisplayText(userText: String, attachedFiles: [AttachedFile]) -> String {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentSummary = chatDisplaySummary(for: attachedFiles)

        if trimmedText.isEmpty {
            return attachmentSummary ?? ""
        }

        guard let attachmentSummary else {
            return trimmedText
        }
        return "\(trimmedText)\n\(attachmentSummary)"
    }

    static func chatDisplaySummary(for attachedFiles: [AttachedFile]) -> String? {
        guard !attachedFiles.isEmpty else { return nil }

        let imageCount = attachedFiles.filter { $0.kind == .image }.count
        let textFiles = attachedFiles.filter { $0.kind == .textFile }
        var parts: [String] = []

        if imageCount == 1 {
            parts.append("🖼 1 image attached")
        } else if imageCount > 1 {
            parts.append("🖼 \(imageCount) images attached")
        }

        switch textFiles.count {
        case 0:
            break
        case 1:
            parts.append("📎 1 file attached")
        default:
            parts.append("📎 \(textFiles.count) files")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

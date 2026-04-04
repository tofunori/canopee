import Foundation

enum ArtifactKind: String, Codable, Equatable {
    case pdf
    case image
    case html
}

struct ArtifactDescriptor: Identifiable, Codable, Equatable {
    let url: URL
    let kind: ArtifactKind
    let displayName: String
    let sourceDocumentPath: String
    let runID: UUID?
    let updatedAt: Date

    var id: String { url.path }

    static func make(url: URL, sourceDocumentPath: String, runID: UUID?) -> ArtifactDescriptor? {
        let pathExtension = url.pathExtension.lowercased()
        let kind: ArtifactKind

        switch pathExtension {
        case "pdf":
            kind = .pdf
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "webp":
            kind = .image
        case "html", "htm", "svg":
            kind = .html
        default:
            return nil
        }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let updatedAt = values?.contentModificationDate ?? .distantPast

        return ArtifactDescriptor(
            url: url,
            kind: kind,
            displayName: url.lastPathComponent,
            sourceDocumentPath: sourceDocumentPath,
            runID: runID,
            updatedAt: updatedAt
        )
    }
}

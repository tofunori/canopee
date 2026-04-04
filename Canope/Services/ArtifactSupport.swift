import Foundation

enum ArtifactKind: String, Codable, Equatable {
    case pdf
    case image
    case html
}

enum CodeOutputPlacement: String, Codable, CaseIterable, Equatable {
    case right
    case bottom
}

typealias CodePanelArrangement = PanelArrangement

enum CodeOutputSplitAxis: String, Codable, CaseIterable, Equatable {
    case vertical
    case horizontal
}

struct CodeOutputLayoutState: Codable, Equatable {
    var isOutputVisible: Bool
    var editorTerminalSplitLayoutRawValue: String
    var outputPlacement: CodeOutputPlacement
    var panelArrangementRawValue: String?
    var secondaryPaneVisible: Bool
    var secondaryPaneAxis: CodeOutputSplitAxis
    var primaryOutputWidth: Double?
    var leadingPaneWidth: Double?
    var trailingPaneWidth: Double?
    var secondaryPaneFraction: Double

    init(
        isOutputVisible: Bool = true,
        editorTerminalSplitLayoutRawValue: String = "horizontal",
        outputPlacement: CodeOutputPlacement = .right,
        panelArrangementRawValue: String? = nil,
        secondaryPaneVisible: Bool = false,
        secondaryPaneAxis: CodeOutputSplitAxis = .vertical,
        primaryOutputWidth: Double? = nil,
        leadingPaneWidth: Double? = nil,
        trailingPaneWidth: Double? = nil,
        secondaryPaneFraction: Double = 0.36
    ) {
        self.isOutputVisible = isOutputVisible
        self.editorTerminalSplitLayoutRawValue = editorTerminalSplitLayoutRawValue
        self.outputPlacement = outputPlacement
        self.panelArrangementRawValue = panelArrangementRawValue
        self.secondaryPaneVisible = secondaryPaneVisible
        self.secondaryPaneAxis = secondaryPaneAxis
        self.primaryOutputWidth = primaryOutputWidth
        self.leadingPaneWidth = leadingPaneWidth
        self.trailingPaneWidth = trailingPaneWidth
        self.secondaryPaneFraction = secondaryPaneFraction
    }
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

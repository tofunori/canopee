import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - LaTeX Editor Sizing Constants

enum LaTeXEditorSidebarSizing {
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 220
    static let activityBarWidth: CGFloat = 44
    static let resizeHandleWidth: CGFloat = 8
}

enum LaTeXEditorThreePaneSizing {
    static let dividerWidth: CGFloat = 10
}

// MARK: - LaTeX Editor Layout

enum LaTeXEditorThreePaneRole {
    case terminal
    case editor
    case pdf
}

enum LaTeXEditorSplitLayout: String {
    case horizontal
    case vertical
    case editorOnly
}

// MARK: - LaTeX Editor Sidebar

enum LaTeXEditorSidebarSection: String {
    case files
    case annotations
    case diff
}

// MARK: - LaTeX Editor PDF Tabs

enum LaTeXEditorPdfPaneTab: Hashable {
    case compiled
    case reference(UUID)
}

// MARK: - LaTeX Editor Annotations

struct LaTeXEditorPendingAnnotation: Identifiable {
    let id = UUID()
    var draft: LaTeXAnnotationDraft
    var existingAnnotationID: UUID?
}

struct LaTeXEditorDiffGroup: Identifiable, Equatable {
    let review: ReviewDiffBlock

    var id: String { review.id }
    var block: TextDiffBlock { review.block }
    var rows: [ReviewDiffRow] { review.rows }
    var startLine: Int { review.block.startLine }
    var endLine: Int { review.block.endLine }
    var preferredRevealLine: Int { review.preferredRevealLine }
    var preferredRevealColumn: Int { review.preferredRevealColumn }
    var preferredRevealLength: Int { review.preferredRevealLength }
    var kind: TextDiffBlockKind { review.block.kind }

    static func == (lhs: LaTeXEditorDiffGroup, rhs: LaTeXEditorDiffGroup) -> Bool {
        lhs.review == rhs.review
    }
}

// MARK: - LaTeX Editor File Types

enum NewEditorFileKind {
    case latex
    case markdown

    var defaultFileName: String {
        switch self {
        case .latex:
            return "untitled.tex"
        case .markdown:
            return "notes.md"
        }
    }

    var contentType: UTType {
        switch self {
        case .latex:
            return UTType(filenameExtension: "tex") ?? .plainText
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        }
    }

    var title: String {
        switch self {
        case .latex:
            return "Nouveau fichier LaTeX"
        case .markdown:
            return "Nouveau fichier Markdown"
        }
    }

    var message: String {
        switch self {
        case .latex:
            return "Crée un nouveau fichier .tex dans le dossier courant"
        case .markdown:
            return "Crée un nouveau fichier .md dans le dossier courant"
        }
    }

    var template: String {
        switch self {
        case .latex:
            return """
            \\documentclass{article}

            \\begin{document}

            \\end{document}
            """
        case .markdown:
            return ""
        }
    }
}

enum EditorDocumentMode {
    case latex
    case markdown

    init(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "md":
            self = .markdown
        default:
            self = .latex
        }
    }

    var fileIconTint: Color {
        switch self {
        case .latex:
            return .green
        case .markdown:
            return .blue
        }
    }

    var primaryClusterTitle: String {
        switch self {
        case .latex:
            return "LaTeX"
        case .markdown:
            return "Markdown"
        }
    }

    var compiledTabTitle: String {
        switch self {
        case .latex:
            return "PDF compilé"
        case .markdown:
            return "PDF aperçu"
        }
    }

    var emptyPreviewTitle: String {
        switch self {
        case .latex:
            return "Pas encore compilé"
        case .markdown:
            return "Pas encore rendu"
        }
    }

    var emptyPreviewDescription: String {
        switch self {
        case .latex:
            return "⌘B pour compiler"
        case .markdown:
            return "Clique sur Rendre le PDF"
        }
    }

    var runningStatus: ToolbarStatusState {
        switch self {
        case .latex:
            return .compiling
        case .markdown:
            return .rendering
        }
    }

    var successStatus: ToolbarStatusState {
        switch self {
        case .latex:
            return .saved
        case .markdown:
            return .previewReady
        }
    }

    var outputSuccessTitle: String {
        switch self {
        case .latex:
            return "Compilation réussie"
        case .markdown:
            return "PDF prêt"
        }
    }
}

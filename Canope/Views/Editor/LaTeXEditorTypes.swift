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
    case python
    case r

    var defaultFileName: String {
        switch self {
        case .latex:
            return "untitled.tex"
        case .markdown:
            return "notes.md"
        case .python:
            return "analysis.py"
        case .r:
            return "analysis.R"
        }
    }

    var contentType: UTType {
        switch self {
        case .latex:
            return UTType(filenameExtension: "tex") ?? .plainText
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .python:
            return UTType(filenameExtension: "py") ?? .plainText
        case .r:
            return UTType(filenameExtension: "r") ?? .plainText
        }
    }

    var title: String {
        switch self {
        case .latex:
            return "Nouveau fichier LaTeX"
        case .markdown:
            return "Nouveau fichier Markdown"
        case .python:
            return "Nouveau script Python"
        case .r:
            return "Nouveau script R"
        }
    }

    var message: String {
        switch self {
        case .latex:
            return "Crée un nouveau fichier .tex dans le dossier courant"
        case .markdown:
            return "Crée un nouveau fichier .md dans le dossier courant"
        case .python:
            return "Crée un nouveau script .py dans le dossier courant"
        case .r:
            return "Crée un nouveau script .R dans le dossier courant"
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
        case .python:
            return """
            from pathlib import Path
            import os

            artifact_dir = Path(os.environ.get("CANOPE_ARTIFACT_DIR", "."))
            artifact_dir.mkdir(parents=True, exist_ok=True)

            # Écris tes sorties dans artifact_dir, par ex. artifact_dir / "plot.png"
            print(f"Artifacts: {artifact_dir}")
            """
        case .r:
            return """
            artifact_dir <- Sys.getenv("CANOPE_ARTIFACT_DIR", ".")
            dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

            # Écris tes sorties dans artifact_dir, par ex. file.path(artifact_dir, "plot.png")
            cat("Artifacts:", artifact_dir, "\\n")
            """
        }
    }
}

enum EditorDocumentMode {
    case latex
    case markdown
    case python
    case r

    init(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "md":
            self = .markdown
        case "py":
            self = .python
        case "r":
            self = .r
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
        case .python:
            return .orange
        case .r:
            return .purple
        }
    }

    var primaryClusterTitle: String {
        switch self {
        case .latex:
            return "LaTeX"
        case .markdown:
            return "Markdown"
        case .python:
            return "Python"
        case .r:
            return "R"
        }
    }

    var compiledTabTitle: String {
        switch self {
        case .latex:
            return "PDF compilé"
        case .markdown:
            return "PDF exporté"
        case .python, .r:
            return "Sortie"
        }
    }

    var emptyPreviewTitle: String {
        switch self {
        case .latex:
            return "Pas encore compilé"
        case .markdown:
            return "Pas encore exporté"
        case .python, .r:
            return "Aucun artefact"
        }
    }

    var emptyPreviewDescription: String {
        switch self {
        case .latex:
            return "⌘B pour compiler"
        case .markdown:
            return "⌘B pour exporter le PDF"
        case .python, .r:
            return "⌘B pour exécuter le script"
        }
    }

    var runningStatus: ToolbarStatusState {
        switch self {
        case .latex:
            return .compiling
        case .markdown:
            return .rendering
        case .python, .r:
            return .running
        }
    }

    var successStatus: ToolbarStatusState {
        switch self {
        case .latex:
            return .saved
        case .markdown:
            return .previewReady
        case .python, .r:
            return .completed
        }
    }

    var outputSuccessTitle: String {
        switch self {
        case .latex:
            return "Compilation réussie"
        case .markdown:
            return "Export PDF prêt"
        case .python, .r:
            return "Sortie prête"
        }
    }

    var isRunnableCode: Bool {
        switch self {
        case .python, .r:
            return true
        case .latex, .markdown:
            return false
        }
    }

    var usesDedicatedInlineEditor: Bool {
        self == .markdown
    }
}

enum EditorFileSupport {
    static let editorExtensions: Set<String> = ["tex", "md", "bib", "txt", "py", "r"]
    static let previewableArtifactExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "svg", "html", "htm"]
    static let browseableExtensions: Set<String> = editorExtensions.union(["sty", "cls", "eps"]).union(previewableArtifactExtensions)

    static func isEditorDocument(_ url: URL) -> Bool {
        editorExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPreviewableArtifact(_ url: URL) -> Bool {
        previewableArtifactExtensions.contains(url.pathExtension.lowercased())
    }

    static var importerContentTypes: [UTType] {
        ["tex", "bib", "md", "py", "r"].compactMap { UTType(filenameExtension: $0) }
    }
}

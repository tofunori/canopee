import Foundation
import PDFKit

@MainActor
final class ReferencePDFUIState: ObservableObject {
    @Published var currentTool: AnnotationTool = .pointer
    @Published var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var selectedText: String = ""
    @Published var hasUnsavedChanges = false
    @Published var annotationRefreshToken = UUID()
    @Published var pdfViewRefreshToken = UUID()
    @Published var lastKnownPageIndex = 0
    @Published var requestedRestorePageIndex: Int?
    @Published var clearSelectionAction: (() -> Void)?
    @Published var undoAction: (() -> Void)?
    @Published var fitToWidthAction: (() -> Void)?
    @Published var isEditingNote = false
    @Published var editingNoteText = ""
    @Published var bridgeCommandRegistrationToken = UUID()

    var pendingSaveWorkItem: DispatchWorkItem?
    private var pdfViewUndoAction: (() -> Void)?
    private(set) var applyBridgeAnnotationAction: ((_ selection: PDFSelection, _ type: PDFAnnotationSubtype, _ color: NSColor) -> Void)?
    private var localUndoStack: [() -> Void] = []

    func setPDFViewUndoAction(_ action: (() -> Void)?) {
        pdfViewUndoAction = action
        refreshUndoAction()
    }

    func setPDFViewApplyBridgeAnnotation(_ action: ((_ selection: PDFSelection, _ type: PDFAnnotationSubtype, _ color: NSColor) -> Void)?) {
        applyBridgeAnnotationAction = action
        bridgeCommandRegistrationToken = UUID()
    }

    func pushUndoAction(_ action: @escaping () -> Void) {
        localUndoStack.append(action)
        refreshUndoAction()
    }

    func performUndo() {
        if let action = localUndoStack.popLast() {
            action()
        } else {
            pdfViewUndoAction?()
        }
        refreshUndoAction()
    }

    private func refreshUndoAction() {
        guard !localUndoStack.isEmpty || pdfViewUndoAction != nil else {
            undoAction = nil
            return
        }

        undoAction = { [weak self] in
            self?.performUndo()
        }
    }
}

@MainActor
final class LaTeXWorkspaceUIState: ObservableObject {
    @Published var workspaceRoot: URL?
    @Published var showSidebar = false
    @Published var selectedSidebarSection = "files"
    @Published var sidebarWidth: Double = 220
    @Published var showEditorPane = true
    @Published var showPDFPreview = false
    @Published var showErrors = false
    @Published var splitLayout = "editorOnly"
    @Published var panelArrangement: PanelArrangement = .terminalEditorContent
    @Published var threePaneLeadingWidth: Double?
    @Published var threePaneTrailingWidth: Double?
    @Published var editorFontSize: Double = 14
    @Published var editorTheme = 0
    @Published var referencePaperIDs: [UUID] = []
    @Published var selectedReferencePaperID: UUID?
    @Published var layoutBeforeReference: String?
    @Published var referencePDFs: [UUID: PDFDocument] = [:]
    @Published var referencePDFUIStates: [UUID: ReferencePDFUIState] = [:]

    nonisolated static func preferredWorkspaceRoot(
        openPaths: [String],
        recentPaths: [String] = RecentTeXFilesStore.recentTeXFiles,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let openPath = openPaths.last {
            return URL(fileURLWithPath: openPath).deletingLastPathComponent()
        }
        if let recentPath = recentPaths.first {
            return URL(fileURLWithPath: recentPath).deletingLastPathComponent()
        }
        return homeDirectory
    }

    /// Same folder as `FileBrowserView`’s `rootURL` / `UnifiedEditorView.projectRoot` (workspace root, else active file’s parent).
    /// Mirrors `LaTeXEditorContainer.activePath` for choosing which file path drives the tree when the editor tab is not focused.
    func treeViewRootURL(openPaths: [String], selectedTab: TabItem) -> URL {
        if let root = workspaceRoot { return root.standardizedFileURL }
        let activePath: String?
        switch selectedTab {
        case .editor(let path):
            activePath = path
        case .editorWorkspace:
            activePath = nil
        default:
            activePath = openPaths.last
        }
        if let path = activePath ?? openPaths.last, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if url.scheme != "canope", url.isFileURL {
                return url.deletingLastPathComponent().standardizedFileURL
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return Self.preferredWorkspaceRoot(openPaths: openPaths)
    }
}

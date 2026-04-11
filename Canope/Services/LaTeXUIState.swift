import Foundation
import PDFKit

@MainActor
final class PDFSearchUIState: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var matchCount = 0
    @Published var currentMatchIndex = 0
    @Published var focusRequestToken = UUID()

    private var nextResultAction: (() -> Void)?
    private var previousResultAction: (() -> Void)?
    private var clearSearchAction: (() -> Void)?

    var hasResults: Bool { matchCount > 0 }

    func configureActions(
        next: (() -> Void)?,
        previous: (() -> Void)?,
        clear: (() -> Void)?
    ) {
        nextResultAction = next
        previousResultAction = previous
        clearSearchAction = clear
    }

    func present() {
        isVisible = true
        requestFocus()
    }

    func dismiss() {
        clearSearch()
        isVisible = false
    }

    func requestFocus() {
        focusRequestToken = UUID()
    }

    func clearSearch() {
        query = ""
        matchCount = 0
        currentMatchIndex = 0
        clearSearchAction?()
    }

    func goToNextResult() {
        nextResultAction?()
    }

    func goToPreviousResult() {
        previousResultAction?()
    }
}

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
    let searchState = PDFSearchUIState()

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
    @Published var selectedSidebarSection: LaTeXEditorSidebarSection = .files
    @Published var sidebarWidth: Double = 220
    @Published var showEditorPane = true
    @Published var showPDFPreview = false
    @Published var showErrors = false
    @Published var splitLayout: LaTeXEditorSplitLayout = .editorOnly
    @Published var panelArrangement: PanelArrangement = .terminalEditorContent
    @Published var threePaneLeadingWidth: Double?
    @Published var threePaneTrailingWidth: Double?
    @Published var editorFontSize: Double = 14
    @Published var editorTheme = 0
    @Published var markdownEditorMode: MarkdownEditorDisplayMode = .livePreview
    @Published var isCompiledPDFTabVisible = true
    @Published var referencePaperIDs: [UUID] = []
    @Published var selectedReferencePaperID: UUID?
    @Published var layoutBeforeReference: LaTeXEditorSplitLayout?
    @Published var referencePDFs: [UUID: PDFDocument] = [:]
    @Published var referencePDFUIStates: [UUID: ReferencePDFUIState] = [:]
    @Published var loadingReferencePDFIDs: Set<UUID> = []

    private var referenceAccessOrder: [UUID] = []
    private let retainedReferencePDFLimit = 3

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

    func ensureReferenceUIState(for id: UUID) {
        if referencePDFUIStates[id] == nil {
            referencePDFUIStates[id] = ReferencePDFUIState()
        }
    }

    func registerReference(id: UUID) {
        if !referencePaperIDs.contains(id) {
            referencePaperIDs.append(id)
        }
        ensureReferenceUIState(for: id)
        noteReferenceAccess(id)
    }

    func noteReferenceAccess(_ id: UUID) {
        referenceAccessOrder.removeAll { $0 == id }
        referenceAccessOrder.append(id)
        trimReferenceWorkingSet()
    }

    func setReferenceDocument(_ document: PDFDocument?, for id: UUID) {
        if let document {
            referencePDFs[id] = document
            noteReferenceAccess(id)
        } else {
            referencePDFs.removeValue(forKey: id)
        }
        trimReferenceWorkingSet()
    }

    func removeReference(id: UUID) {
        referencePaperIDs.removeAll { $0 == id }
        referencePDFs.removeValue(forKey: id)
        loadingReferencePDFIDs.remove(id)
        referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        referencePDFUIStates.removeValue(forKey: id)
        referenceAccessOrder.removeAll { $0 == id }

        if selectedReferencePaperID == id {
            selectedReferencePaperID = referencePaperIDs.first
        }
    }

    func beginReferenceLoad(id: UUID) {
        loadingReferencePDFIDs.insert(id)
    }

    func finishReferenceLoad(id: UUID) {
        loadingReferencePDFIDs.remove(id)
    }

    func isReferenceLoading(_ id: UUID) -> Bool {
        loadingReferencePDFIDs.contains(id)
    }

    func trimReferenceWorkingSet() {
        var retainedIDs: [UUID] = []
        if let selectedReferencePaperID, referencePaperIDs.contains(selectedReferencePaperID) {
            retainedIDs.append(selectedReferencePaperID)
        }

        for id in referenceAccessOrder.reversed() {
            guard referencePaperIDs.contains(id), !retainedIDs.contains(id) else { continue }
            retainedIDs.append(id)
            if retainedIDs.count >= retainedReferencePDFLimit {
                break
            }
        }

        let retainedSet = Set(retainedIDs)
        for id in referencePDFs.keys where !retainedSet.contains(id) {
            referencePDFs.removeValue(forKey: id)
        }
        referenceAccessOrder.removeAll { !referencePaperIDs.contains($0) }
    }
}

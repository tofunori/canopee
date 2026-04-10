import SwiftUI
import SwiftData
import PDFKit

// MARK: - LaTeX Editor Container (manages multiple .tex files with sub-tabs)

struct LaTeXEditorContainer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allPapers: [Paper]
    let openPaths: [String]
    @Binding var selectedTab: TabItem
    @Binding var showTerminal: Bool
    let openPaperIDs: [UUID]
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    /// When false, the embedded terminal must not override cwd for the shared `TerminalWorkspaceState` (main-window terminal owns it).
    var isEditorSectionActive: Bool
    var onOpenTeX: (URL) -> Void
    var onOpenPDF: (URL) -> Void
    var onCloseEditor: (String) -> Void
    @State private var didRestoreWorkspaceState = AppRuntime.isRunningTests
    @Namespace private var editorTabIndicatorNamespace
    @StateObject private var codeDocumentStateStore = CodeDocumentStateStore()
    @StateObject private var editorDocumentStateStore = EditorDocumentStateStore()

    /// The currently active editor path
    private var activePath: String? {
        if case .editor(let p) = selectedTab { return p }
        if selectedTab == .editorWorkspace { return nil }
        return openPaths.last
    }

    private func switchEditor(_ path: String) {
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            selectedTab = .editor(path)
        }
    }

    private func closeEditor(_ path: String) {
        codeDocumentStateStore.removeState(for: URL(fileURLWithPath: path))
        editorDocumentStateStore.removeState(for: URL(fileURLWithPath: path))
        onCloseEditor(path)
        if activePath == path {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                if let other = openPaths.first(where: { $0 != path }) {
                    selectedTab = .editor(other)
                } else {
                    selectedTab = .editorWorkspace
                }
            }
        }
    }

    private var resolvedWorkspaceRoot: URL {
        workspaceState.workspaceRoot ?? LaTeXWorkspaceUIState.preferredWorkspaceRoot(openPaths: openPaths)
    }

    @State private var hoveredTabPath: String?

    private var workspaceSnapshot: LaTeXEditorWorkspaceState {
        LaTeXEditorWorkspaceState(
            showSidebar: workspaceState.showSidebar,
            selectedSidebarSection: workspaceState.selectedSidebarSection,
            sidebarWidth: workspaceState.sidebarWidth,
            showEditorPane: workspaceState.showEditorPane,
            showPDFPreview: workspaceState.showPDFPreview,
            showErrors: workspaceState.showErrors,
            splitLayout: workspaceState.splitLayout,
            panelArrangement: workspaceState.panelArrangement,
            threePaneLeadingWidth: workspaceState.threePaneLeadingWidth,
            threePaneTrailingWidth: workspaceState.threePaneTrailingWidth,
            editorFontSize: workspaceState.editorFontSize,
            editorTheme: workspaceState.editorTheme,
            markdownEditorMode: workspaceState.markdownEditorMode,
            referencePaperIDs: workspaceState.referencePaperIDs,
            selectedReferencePaperID: workspaceState.selectedReferencePaperID,
            layoutBeforeReference: workspaceState.layoutBeforeReference,
            workspaceRootPath: workspaceState.workspaceRoot?.path
        )
    }

    private func persistWorkspaceState() {
        guard didRestoreWorkspaceState else { return }
        WorkspaceSessionStore.shared.saveLaTeXWorkspaceState(workspaceSnapshot)
    }

    private func restoreWorkspaceStateIfNeeded() {
        guard !didRestoreWorkspaceState else { return }
        didRestoreWorkspaceState = true

        guard let snapshot = WorkspaceSessionStore.shared.loadLaTeXWorkspaceState() else { return }

        workspaceState.showSidebar = snapshot.showSidebar
        workspaceState.selectedSidebarSection = snapshot.selectedSidebarSection
        workspaceState.sidebarWidth = snapshot.sidebarWidth
        workspaceState.showEditorPane = snapshot.showEditorPane
        workspaceState.showErrors = snapshot.showErrors
        workspaceState.splitLayout = snapshot.splitLayout
        workspaceState.showPDFPreview = snapshot.showPDFPreview
        workspaceState.panelArrangement = snapshot.panelArrangement
        workspaceState.threePaneLeadingWidth = snapshot.threePaneLeadingWidth
        workspaceState.threePaneTrailingWidth = snapshot.threePaneTrailingWidth
        workspaceState.editorFontSize = snapshot.editorFontSize
        workspaceState.editorTheme = snapshot.editorTheme
        workspaceState.markdownEditorMode = snapshot.markdownEditorMode
        workspaceState.layoutBeforeReference = snapshot.layoutBeforeReference
        workspaceState.workspaceRoot = snapshot.workspaceRootPath.map { URL(fileURLWithPath: $0) }

        var seen = Set<UUID>()
        let referenceIDs = snapshot.referencePaperIDs.filter { seen.insert($0).inserted }
        workspaceState.referencePaperIDs = referenceIDs
        workspaceState.selectedReferencePaperID = snapshot.selectedReferencePaperID
        workspaceState.referencePDFs = loadReferencePDFs(for: referenceIDs)
        workspaceState.referencePDFUIStates = Dictionary(uniqueKeysWithValues: referenceIDs.map { ($0, ReferencePDFUIState()) })
        if workspaceState.workspaceRoot == nil {
            workspaceState.workspaceRoot = LaTeXWorkspaceUIState.preferredWorkspaceRoot(openPaths: openPaths)
        }

        if let selectedID = workspaceState.selectedReferencePaperID,
           !referenceIDs.contains(selectedID) {
            workspaceState.selectedReferencePaperID = nil
        }
    }

    private func loadReferencePDFs(for ids: [UUID]) -> [UUID: PDFDocument] {
        var documents: [UUID: PDFDocument] = [:]
        for id in ids {
            guard let paper = allPapers.first(where: { $0.id == id }),
                  let pdf = PDFDocument(url: paper.fileURL) else { continue }
            AnnotationService.normalizeDocumentAnnotations(in: pdf)
            documents[id] = pdf
        }
        return documents
    }

    private func closeReference(_ id: UUID) {
        workspaceState.referencePaperIDs.removeAll { $0 == id }
        workspaceState.referencePDFs.removeValue(forKey: id)
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates.removeValue(forKey: id)

        if workspaceState.selectedReferencePaperID == id {
            workspaceState.selectedReferencePaperID = workspaceState.referencePaperIDs.first
        }
    }

    @ViewBuilder
    private var editorTabBar: some View {
        if openPaths.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(openPaths, id: \.self) { path in
                        let isCurrent = activePath == path
                        let isHov = hoveredTabPath == path
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Button {
                                closeEditor(path)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .opacity(isCurrent || isHov ? 1 : 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: AppChromeMetrics.tabBarHeight)
                        .background(AppChromePalette.tabFill(isSelected: isCurrent, isHovered: isHov, role: .terminal))
                        .overlay(alignment: .bottom) {
                            if isCurrent {
                                Rectangle()
                                    .fill(AppChromePalette.tabIndicator(for: .terminal))
                                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
                                    .matchedGeometryEffect(id: "editor-tab-indicator", in: editorTabIndicatorNamespace)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { switchEditor(path) }
                        .onHover { hoveredTabPath = $0 ? path : nil }
                        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHov)
                        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isCurrent)
                    }
                }
            }
            .frame(height: AppChromeMetrics.tabBarHeight)
            .background(AppChromePalette.surfaceSubbar)
        }
    }

    /// Sentinel URL used when no file is open — triggers the "no file" placeholder in UnifiedEditorView.
    private static let noFileURL = URL(string: "canope://no-file")!

    var body: some View {
        ZStack(alignment: .topLeading) {
            let activeURL: URL = {
                if let activePath, !activePath.isEmpty {
                    return URL(fileURLWithPath: activePath)
                }
                return Self.noFileURL
            }()
            editorView(for: activeURL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            DispatchQueue.main.async {
                if !AppRuntime.isRunningTests {
                    restoreWorkspaceStateIfNeeded()
                }
                ensureWorkspaceRoot()
                syncCodeDocumentStates()
            }
        }
        .onChange(of: workspaceSnapshot) {
            persistWorkspaceState()
        }
        .onChange(of: openPaths) {
            DispatchQueue.main.async {
                ensureWorkspaceRoot()
                syncCodeDocumentStates()
            }
        }
    }

    private func editorView(for fileURL: URL) -> some View {
        let editorDocumentState = editorDocumentStateStore.stateOrCreate(for: fileURL)
        let codeDocumentState = codeDocumentStateStore.stateOrCreate(for: fileURL)
        return UnifiedEditorView(
            fileURL: fileURL,
            // Keep the editor mounted to preserve per-file SwiftUI/AppKit state,
            // but let the view suspend watchers and command routing when hidden.
            isActive: isEditorSectionActive,
            showTerminal: $showTerminal,
            mainWindowTab: $selectedTab,
            openEditorPaths: openPaths,
            workspaceState: workspaceState,
            terminalWorkspaceState: terminalWorkspaceState,
            isEditorSectionActive: isEditorSectionActive,
            documentState: editorDocumentState,
            codeDocumentState: codeDocumentState,
            onOpenPDF: onOpenPDF,
            onOpenInNewTab: onOpenTeX,
            openPaperIDs: openPaperIDs,
            editorTabBar: openPaths.count > 1 ? AnyView(editorTabBar) : nil,
            onPersistWorkspaceState: {
                codeDocumentStateStore.persistState(for: fileURL)
                persistWorkspaceState()
            }
        )
        // Recreate the AppKit-backed editor host when the active file changes.
        // Per-file state lives in the external stores, so this avoids stale NSTextView/PDFView reuse
        // across .tex -> .md tab switches without losing document-local state.
        .id(editorViewIdentity(for: fileURL))
    }

    private func editorViewIdentity(for fileURL: URL) -> String {
        if fileURL.isFileURL {
            return fileURL.standardizedFileURL.path
        }
        return fileURL.absoluteString
    }

    private func openFolderFromLanding() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choisir un dossier de travail"
        panel.prompt = "Ouvrir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceState.workspaceRoot = url
    }

    private func ensureWorkspaceRoot() {
        if workspaceState.workspaceRoot == nil {
            workspaceState.workspaceRoot = LaTeXWorkspaceUIState.preferredWorkspaceRoot(openPaths: openPaths)
        }
    }

    private func syncCodeDocumentStates() {
        for path in openPaths {
            let url = URL(fileURLWithPath: path)
            editorDocumentStateStore.ensureState(for: url)
            codeDocumentStateStore.ensureState(for: url)
        }
        editorDocumentStateStore.removeMissingStates(keepingPaths: openPaths)
        codeDocumentStateStore.removeMissingStates(keepingPaths: openPaths)
    }
}

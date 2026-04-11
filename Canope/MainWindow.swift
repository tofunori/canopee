import SwiftUI
import SwiftData
import PDFKit
import OSLog

struct MainWindow: View {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.canope.app",
        category: "MainWindow"
    )

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var terminalAppearanceStore = TerminalAppearanceStore.shared
    @Query private var allPapers: [Paper]
    @StateObject private var tabController = MainWindowTabController()
    @State private var paperToOpen: UUID? = nil
    @State private var showTerminal = false
    @State private var isOpeningTeX = false
    @State private var isImportingPDF = false
    @State private var didRestoreWorkspace = AppRuntime.isRunningTests
    @StateObject private var latexWorkspaceState = LaTeXWorkspaceUIState()
    @StateObject private var terminalWorkspaceState = TerminalWorkspaceState()
    @State private var pendingTabSwitchStartUptime: TimeInterval?
    @Namespace private var documentTabIndicatorNamespace

    private var openPaperIDs: [UUID] { tabController.openPaperIDs }

    private var openEditorPaths: [String] { tabController.openEditorPaths }

    private var openPDFPaths: [String] { tabController.openPDFPaths }

    private var activeSplitPDFSurfaceCount: Int {
        guard case .paper(let paperID) = tabController.selectedTab,
              let splitID = tabController.splitPaperID,
              splitID != paperID,
              allPapers.contains(where: { $0.id == splitID }) else {
            return 0
        }
        return 1
    }

    private var mountedPDFSurfaceCount: Int {
        openPaperIDs.count + openPDFPaths.count + activeSplitPDFSurfaceCount
    }

    private var isEditorSelected: Bool {
        switch tabController.selectedTab {
        case .editorWorkspace, .editor:
            return true
        default:
            return false
        }
    }

    /// Same `cwd` as the file tree (`FileBrowserView` root), not the PDF path — see `LaTeXWorkspaceUIState.treeViewRootURL`.
    private var terminalStartupWorkingDirectoryForMainPane: URL? {
        switch tabController.selectedTab {
        case .editorWorkspace, .editor:
            return nil
        default:
            return latexWorkspaceState.treeViewRootURL(
                openPaths: openEditorPaths.filter { !$0.isEmpty },
                selectedTab: tabController.selectedTab
            )
        }
    }

    @ViewBuilder
    private var mainContentPane: some View {
        MainWindowMountedContentHost(
            librarySurface: {
                LibraryView(
                    paperToOpen: $paperToOpen,
                    isImportingPDF: $isImportingPDF
                )
                    .opacity(tabController.selectedTab == .library ? 1 : 0)
                    .allowsHitTesting(tabController.selectedTab == .library)
                    .zIndex(tabController.selectedTab == .library ? 1 : 0)
                    // Keep the library/editor switch immediate: crossfading a live PDFKit
                    // surface behind the library produces visible flashes.
                    .animation(nil, value: tabController.selectedTab)
            },
            paperSurfaces: {
                ForEach(openPaperIDs, id: \.self) { paperId in
                    if let paper = allPapers.first(where: { $0.id == paperId }) {
                        Group {
                            let isActive = tabController.selectedTab == .paper(paperId)
                            if let splitID = tabController.splitPaperID,
                               splitID != paperId,
                               isActive {
                                if let splitPaper = allPapers.first(where: { $0.id == splitID }) {
                                    HSplitView {
                                        PDFReaderView(paperID: paper.persistentModelID, isSplitMode: true, isActive: isActive, showTerminal: $showTerminal)
                                        PDFReaderView(paperID: splitPaper.persistentModelID, isSplitMode: true, isActive: isActive, showTerminal: $showTerminal)
                                    }
                                }
                            } else {
                                PDFReaderView(paperID: paper.persistentModelID, isActive: isActive, showTerminal: $showTerminal)
                            }
                        }
                        .opacity(tabController.selectedTab == .paper(paperId) ? 1 : 0)
                        .allowsHitTesting(tabController.selectedTab == .paper(paperId))
                        .zIndex(tabController.selectedTab == .paper(paperId) ? 1 : 0)
                    }
                }
            },
            editorSurface: {
                LaTeXEditorContainer(
                    openPaths: openEditorPaths.filter { !$0.isEmpty },
                    selectedTab: $tabController.selectedTab,
                    showTerminal: $showTerminal,
                    openPaperIDs: openPaperIDs,
                    workspaceState: latexWorkspaceState,
                    terminalWorkspaceState: terminalWorkspaceState,
                    isEditorSectionActive: isEditorSelected,
                    onOpenTeX: { url in openTeXFile(url) },
                    onOpenPDF: { url in openPDFFile(url) },
                    onCloseEditor: { path in
                        tabController.closeTab(.editor(path))
                    }
                )
                .opacity(isEditorSelected ? 1 : 0)
                .allowsHitTesting(isEditorSelected)
                .zIndex(isEditorSelected ? 1 : 0)
                // Preserve the mounted editor state, but avoid animating the hidden PDF
                // preview when the user jumps to the library and back.
                .animation(nil, value: tabController.selectedTab)
            },
            standalonePDFSurfaces: {
                ForEach(openPDFPaths, id: \.self) { path in
                    StandalonePDFView(url: URL(fileURLWithPath: path))
                        .opacity(tabController.selectedTab == .pdfFile(path) ? 1 : 0)
                        .allowsHitTesting(tabController.selectedTab == .pdfFile(path))
                        .zIndex(tabController.selectedTab == .pdfFile(path) ? 1 : 0)
                }
            }
        )
        // Keep large content-surface switches deterministic. Animating between
        // the library and a live PDF/editor stack still produces subtle flicker
        // and feels less fluid than an immediate swap.
    }

    private var terminalPane: some View {
        MainWindowExternalTerminalHost(
            isVisible: showTerminal && tabController.selectedTab != .library && !isEditorSelected,
            animation: AppChromeMotion.panel(reduceMotion: reduceMotion),
            animationTrigger: showTerminal,
            terminalContent: {
                TerminalPanel(
                    workspaceState: terminalWorkspaceState,
                    document: nil,
                    isVisible: showTerminal && tabController.selectedTab != .library && !isEditorSelected,
                    topInset: 0,
                    showsInlineControls: true,
                    startupWorkingDirectory: terminalStartupWorkingDirectoryForMainPane
                )
            }
        )
    }

    private func tabTitle(_ tab: TabItem) -> String {
        switch tab {
        case .library: return AppStrings.library
        case .paper(let id): return allPapers.first(where: { $0.id == id })?.title ?? "Paper"
        case .editorWorkspace: return AppStrings.editor
        case .editor(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .pdfFile(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    @ViewBuilder
    private func documentTabButton(for tab: TabItem) -> some View {
        let baseButton = TabButton(
            tab: tab,
            isSelected: tabController.selectedTab == tab,
            indicatorNamespace: documentTabIndicatorNamespace,
            title: tabTitle(tab),
            onSelect: { tabController.selectedTab = tab },
            onClose: {
                tabController.closeTab(tab)
            }
        )

        if case .paper(let currentPaperID) = tab {
            baseButton.contextMenu {
                if tabController.splitPaperID != nil {
                    Button(AppStrings.closeSplit) {
                        tabController.splitPaperID = nil
                    }

                    if openPaperIDs.contains(where: { $0 != currentPaperID }) {
                        Divider()
                    }
                }

                ForEach(openPaperIDs.filter { $0 != currentPaperID }, id: \.self) { otherPaperID in
                    if let paper = allPapers.first(where: { $0.id == otherPaperID }) {
                        Button("\(AppStrings.compare) with \(paper.title)") {
                            tabController.splitPaperID = otherPaperID
                            tabController.selectedTab = .paper(currentPaperID)
                        }
                    }
                }
            }
        } else {
            baseButton
        }
    }

    func openPaperAsReference(id: UUID) {
        guard allPapers.contains(where: { $0.id == id }) else { return }

        if !latexWorkspaceState.referencePaperIDs.contains(id) {
            latexWorkspaceState.registerReference(id: id)
        }

        latexWorkspaceState.selectedReferencePaperID = id
        latexWorkspaceState.noteReferenceAccess(id)

        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            if let activeEditor = tabController.openTabs.first(where: { if case .editor = $0 { return true } else { return false } }) {
                tabController.selectedTab = activeEditor
            } else {
                tabController.selectedTab = .editorWorkspace
            }
        }

        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            if latexWorkspaceState.splitLayout == .editorOnly {
                latexWorkspaceState.layoutBeforeReference = .editorOnly
            }
            latexWorkspaceState.splitLayout = .horizontal
            latexWorkspaceState.showPDFPreview = true
        }
    }

    func openPDFFile(_ url: URL) {
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            tabController.openPDFFile(url)
        }
    }

    /// Find all NSSplitViews and make dividers thick + easy to grab
    @MainActor
    private func makeSplitersEasyToGrab() {
        // Run multiple times to catch split views created after initial layout
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    SplitViewHelper.thickenSplitViews(contentView)
                }
            }
        }
    }

    func openTeXFile(_ url: URL) {
        tabController.openEditorTab(path: url.path, select: false)
        rebaseEditorWorkspaceIfNeeded(for: url)
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            tabController.selectedTab = .editor(url.path)
        }
        if EditorFileSupport.isEditorDocument(url) {
            RecentTeXFilesStore.addRecentTeXFile(url.path)
        }
    }

    private func rebaseEditorWorkspaceIfNeeded(for url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard let currentRoot = latexWorkspaceState.workspaceRoot?.standardizedFileURL else {
            latexWorkspaceState.workspaceRoot = parent
            return
        }

        let rootPath = currentRoot.path
        let filePath = url.standardizedFileURL.path
        let isInsideRoot = filePath == rootPath || filePath.hasPrefix(rootPath + "/")
        if !isInsideRoot {
            latexWorkspaceState.workspaceRoot = parent
        }
    }

    private func persistWorkspaceState() {
        guard didRestoreWorkspace else { return }

        let snapshot = tabController.makePersistSnapshot(showTerminal: showTerminal)
        WorkspaceSessionStore.shared.saveMainWindowState(snapshot)
    }

    private func describe(tab: TabItem) -> String {
        switch tab {
        case .library:
            return "library"
        case .paper(let id):
            return "paper:\(id.uuidString)"
        case .editorWorkspace:
            return "editorWorkspace"
        case .editor(let path):
            return "editor:\(URL(fileURLWithPath: path).lastPathComponent)"
        case .pdfFile(let path):
            return "pdf:\(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    private func logWindowMetrics(reason: String) {
        Self.logger.info(
            "Main window metrics reason=\(reason, privacy: .public) openTabs=\(tabController.openTabs.count, privacy: .public) mountedPDFSurfaces=\(mountedPDFSurfaceCount, privacy: .public) openPaperTabs=\(openPaperIDs.count, privacy: .public) openStandalonePDFTabs=\(openPDFPaths.count, privacy: .public) selected=\(describe(tab: tabController.selectedTab), privacy: .public)"
        )
    }

    private func scheduleTabSwitchMetrics(for selectedTab: TabItem) {
        let start = ProcessInfo.processInfo.systemUptime
        pendingTabSwitchStartUptime = start

        Task { @MainActor in
            await Task.yield()
            guard pendingTabSwitchStartUptime == start else { return }
            pendingTabSwitchStartUptime = nil

            let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
            Self.logger.info(
                "Tab switch completed target=\(describe(tab: selectedTab), privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) openTabs=\(tabController.openTabs.count, privacy: .public) mountedPDFSurfaces=\(mountedPDFSurfaceCount, privacy: .public)"
            )
        }
    }

    private func restoreWorkspaceStateIfNeeded() {
        guard !didRestoreWorkspace else { return }
        didRestoreWorkspace = true

        guard let snapshot = WorkspaceSessionStore.shared.loadMainWindowState() else { return }

        tabController.applyRestoredSnapshot(snapshot)
        showTerminal = snapshot.showTerminal
    }

    var body: some View {
        VStack(spacing: 0) {
            MainWindowDocumentTabsRow(
                tabs: tabController.openTabs.filter {
                    if case .paper = $0 { return true }
                    if case .pdfFile = $0 { return true }
                    return false
                },
                tabContent: { tab in
                    documentTabButton(for: tab)
                }
            )

            // Content + resizable shared terminal
            HSplitView {
                mainContentPane
                terminalPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TabBar(
                    tabs: $tabController.openTabs,
                    selectedTab: $tabController.selectedTab,
                    allPapers: allPapers,
                    onOpenTeX: { isOpeningTeX = true }
                )
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                if !AppRuntime.isRunningTests {
                    restoreWorkspaceStateIfNeeded()
                }
                makeSplitersEasyToGrab()
                logWindowMetrics(reason: "appear")
            }
        }
        .onChange(of: tabController.selectedTab) {
            makeSplitersEasyToGrab()
            persistWorkspaceState()
            scheduleTabSwitchMetrics(for: tabController.selectedTab)
            logWindowMetrics(reason: "selectedTab")
        }
        .onChange(of: tabController.openTabs) {
            persistWorkspaceState()
            logWindowMetrics(reason: "openTabs")
        }
        .onChange(of: showTerminal) { persistWorkspaceState() }
        .onChange(of: tabController.splitPaperID) {
            persistWorkspaceState()
            logWindowMetrics(reason: "splitPaper")
        }
        .onChange(of: paperToOpen) {
            guard let id = paperToOpen else { return }
            openPaperAsReference(id: id)
            paperToOpen = nil
        }
        .fileImporter(
            isPresented: $isOpeningTeX,
            allowedContentTypes: EditorFileSupport.importerContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if let urls = try? result.get(), let url = urls.first {
                openTeXFile(url)
            }
        }
        .onChange(of: tabController.selectedTab) {
            if tabController.selectedTab != .library {
                isImportingPDF = false
            }
        }
        .keyboardShortcut("o", modifiers: .command)
        .sheet(isPresented: $terminalAppearanceStore.isPresentingSettings) {
            TerminalAppearanceSheet(store: terminalAppearanceStore)
        }
    }
}

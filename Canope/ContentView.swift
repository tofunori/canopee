import SwiftUI
import SwiftData
import PDFKit

struct MainWindow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allPapers: [Paper]
    @State private var openTabs: [TabItem] = [.library]
    @State private var selectedTab: TabItem = .library
    @State private var paperToOpen: UUID? = nil
    @State private var splitPaperID: UUID? = nil
    @State private var showTerminal = false
    @State private var isOpeningTeX = false
    @State private var isImportingPDF = false
    @State private var didRestoreWorkspace = false
    @StateObject private var latexWorkspaceState = LaTeXWorkspaceUIState()
    @StateObject private var terminalWorkspaceState = TerminalWorkspaceState()
    @Namespace private var documentTabIndicatorNamespace

    private var openPaperIDs: [UUID] {
        openTabs.compactMap { if case .paper(let id) = $0 { return id } else { return nil } }
    }

    private var openEditorPaths: [String] {
        openTabs.compactMap { if case .editor(let path) = $0 { return path } else { return nil } }
    }

    private var openPDFPaths: [String] {
        openTabs.compactMap { if case .pdfFile(let path) = $0 { return path } else { return nil } }
    }

    private var isEditorSelected: Bool {
        if case .editor = selectedTab { return true }
        return false
    }

    @ViewBuilder
    private var mainContentPane: some View {
        ZStack {
            LibraryView(
                paperToOpen: $paperToOpen,
                isImportingPDF: $isImportingPDF
            )
                .opacity(selectedTab == .library ? 1 : 0)
                .allowsHitTesting(selectedTab == .library)

            ForEach(openPaperIDs, id: \.self) { paperId in
                if let paper = allPapers.first(where: { $0.id == paperId }) {
                    Group {
                        let isActive = selectedTab == .paper(paperId)
                        if let splitID = splitPaperID,
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
                    .opacity(selectedTab == .paper(paperId) ? 1 : 0)
                    .allowsHitTesting(selectedTab == .paper(paperId))
                }
            }

            LaTeXEditorContainer(
                openPaths: openEditorPaths.filter { !$0.isEmpty },
                selectedTab: $selectedTab,
                showTerminal: $showTerminal,
                openPaperIDs: openPaperIDs,
                workspaceState: latexWorkspaceState,
                terminalWorkspaceState: terminalWorkspaceState,
                onOpenTeX: { url in openTeXFile(url) },
                onOpenPDF: { url in openPDFFile(url) },
                onCloseEditor: { path in
                    let tab = TabItem.editor(path)
                    if let index = openTabs.firstIndex(of: tab) {
                        openTabs.remove(at: index)
                    }
                }
            )
            .opacity(isEditorSelected ? 1 : 0)
            .allowsHitTesting(isEditorSelected)

            ForEach(openPDFPaths, id: \.self) { path in
                StandalonePDFView(url: URL(fileURLWithPath: path))
                    .opacity(selectedTab == .pdfFile(path) ? 1 : 0)
                    .allowsHitTesting(selectedTab == .pdfFile(path))
            }
        }
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: selectedTab)
    }

    private var terminalPane: some View {
        TerminalPanel(
            workspaceState: terminalWorkspaceState,
            document: nil,
            isVisible: showTerminal && selectedTab != .library && !isEditorSelected,
            topInset: 0,
            showsInlineControls: true
        )
        .frame(
            minWidth: showTerminal && selectedTab != .library && !isEditorSelected ? 180 : 0,
            idealWidth: showTerminal && selectedTab != .library && !isEditorSelected ? 680 : 0,
            maxWidth: showTerminal && selectedTab != .library && !isEditorSelected ? .infinity : 0
        )
        .opacity(showTerminal && selectedTab != .library && !isEditorSelected ? 1 : 0)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showTerminal)
    }

    private func tabTitle(_ tab: TabItem) -> String {
        switch tab {
        case .library: return "Bibliothèque"
        case .paper(let id): return allPapers.first(where: { $0.id == id })?.title ?? "Article"
        case .editor(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .pdfFile(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func openPaperAsReference(id: UUID) {
        guard let paper = allPapers.first(where: { $0.id == id }) else { return }

        if !latexWorkspaceState.referencePaperIDs.contains(id) {
            guard let pdf = PDFDocument(url: paper.fileURL) else { return }
            AnnotationService.normalizeDocumentAnnotations(in: pdf)
            latexWorkspaceState.referencePaperIDs.append(id)
            latexWorkspaceState.referencePDFs[id] = pdf
            if latexWorkspaceState.referencePDFUIStates[id] == nil {
                latexWorkspaceState.referencePDFUIStates[id] = ReferencePDFUIState()
            }
        }

        latexWorkspaceState.selectedReferencePaperID = id

        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            if let activeEditor = openTabs.first(where: { if case .editor = $0 { return true } else { return false } }) {
                selectedTab = activeEditor
            } else {
                selectedTab = .editor("")
            }
        }

        if latexWorkspaceState.splitLayout == "editorOnly" {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                latexWorkspaceState.layoutBeforeReference = "editorOnly"
                latexWorkspaceState.splitLayout = "horizontal"
                latexWorkspaceState.showPDFPreview = true
            }
        }
    }

    func openPDFFile(_ url: URL) {
        let tab = TabItem.pdfFile(url.path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            selectedTab = tab
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
        let tab = TabItem.editor(url.path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            selectedTab = tab
        }
        RecentTeXFilesStore.addRecentTeXFile(url.path)
    }

    private func persistWorkspaceState() {
        guard didRestoreWorkspace else { return }

        var savedTabs = openTabs.compactMap(MainWindowWorkspaceState.SavedTab.init)
        if !savedTabs.contains(.library) {
            savedTabs.insert(.library, at: 0)
        }
        savedTabs = deduplicated(savedTabs)

        let selectedSavedTab = MainWindowWorkspaceState.SavedTab(selectedTab) ?? savedTabs.last ?? .library
        let snapshot = MainWindowWorkspaceState(
            openTabs: savedTabs,
            selectedTab: selectedSavedTab,
            showTerminal: showTerminal,
            splitPaperID: splitPaperID
        )
        WorkspaceSessionStore.shared.saveMainWindowState(snapshot)
    }

    private func restoreWorkspaceStateIfNeeded() {
        guard !didRestoreWorkspace else { return }
        didRestoreWorkspace = true

        guard let snapshot = WorkspaceSessionStore.shared.loadMainWindowState() else { return }

        var restoredTabs = snapshot.openTabs.compactMap(\.tabItem)
        if !restoredTabs.contains(.library) {
            restoredTabs.insert(.library, at: 0)
        }
        restoredTabs = deduplicated(restoredTabs)
        if restoredTabs.isEmpty {
            restoredTabs = [.library]
        }

        openTabs = restoredTabs

        if let restoredSelected = snapshot.selectedTab.tabItem {
            if !openTabs.contains(restoredSelected) {
                openTabs.append(restoredSelected)
            }
            selectedTab = restoredSelected
        } else {
            selectedTab = openTabs.last ?? .library
        }

        showTerminal = snapshot.showTerminal
        if let splitID = snapshot.splitPaperID, openTabs.contains(.paper(splitID)) {
            splitPaperID = splitID
        } else {
            splitPaperID = nil
        }
    }

    private func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Top: section tabs + action buttons
                HStack(spacing: 0) {
                    TabBar(
                        tabs: $openTabs,
                        selectedTab: $selectedTab,
                        allPapers: allPapers,
                        onOpenTeX: { isOpeningTeX = true }
                    )

                    // Action buttons (right side, aligned with section row)
                    HStack(spacing: 1) {
                        if selectedTab == .library {
                            Button {
                                isImportingPDF = true
                            } label: {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 11))
                                    .frame(width: AppChromeMetrics.topButtonSize, height: AppChromeMetrics.topButtonSize)
                            }
                            .buttonStyle(.plain)
                            .help("Importer un PDF")
                        } else {
                            // Open .tex file (with recent files)
                            Menu {
                                let recents = RecentTeXFilesStore.recentTeXFiles
                                if !recents.isEmpty {
                                    ForEach(recents, id: \.self) { path in
                                        Button {
                                            openTeXFile(URL(fileURLWithPath: path))
                                        } label: {
                                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.plaintext")
                                        }
                                    }
                                    Divider()
                                }
                                Button {
                                    isOpeningTeX = true
                                } label: {
                                    Label("Parcourir…", systemImage: "folder")
                                }
                            } label: {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 11))
                                    .frame(width: AppChromeMetrics.topButtonSize, height: AppChromeMetrics.topButtonSize)
                            }
                            .buttonStyle(.plain)
                            .help("Ouvrir un fichier .tex ou .md (⌘O)")
                        }

                        // Split toggle
                        if case .paper = selectedTab {
                            Menu {
                                if splitPaperID != nil {
                                    Button("Fermer le split") { splitPaperID = nil }
                                    Divider()
                                }
                                ForEach(openPaperIDs, id: \.self) { id in
                                    if let paper = allPapers.first(where: { $0.id == id }) {
                                        Button(paper.title) { splitPaperID = id }
                                    }
                                }
                            } label: {
                                Image(systemName: splitPaperID != nil ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                                    .font(.system(size: 11))
                                    .frame(width: AppChromeMetrics.topButtonSize, height: AppChromeMetrics.topButtonSize)
                            }
                            .buttonStyle(.plain)
                            .help("Split view")
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(height: AppChromeMetrics.topBarHeight)
                .background(AppChromePalette.surfaceBar)

                // Document tabs row (papers/PDFs from library)
                let docTabs = openTabs.filter {
                    if case .paper = $0 { return true }
                    if case .pdfFile = $0 { return true }
                    return false
                }
                if !docTabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(docTabs, id: \.self) { tab in
                                TabButton(
                                    tab: tab,
                                    isSelected: selectedTab == tab,
                                    indicatorNamespace: documentTabIndicatorNamespace,
                                    title: tabTitle(tab),
                                    onSelect: { selectedTab = tab },
                                    onClose: {
                                        if let i = openTabs.firstIndex(of: tab) {
                                            openTabs.remove(at: i)
                                            if selectedTab == tab {
                                                selectedTab = i > 0 ? openTabs[i-1] : (openTabs.first ?? .library)
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .frame(height: AppChromeMetrics.tabBarHeight)
                    .background(AppChromePalette.surfaceSubbar)
                }

                AppChromeDivider(role: .shell)
            }
            .modifier(MainWindowTitleBarBehavior())

            // Content + resizable shared terminal
            HSplitView {
                mainContentPane
                terminalPane
            }
        }
        .onAppear {
            restoreWorkspaceStateIfNeeded()
            makeSplitersEasyToGrab()
        }
        .onChange(of: selectedTab) {
            makeSplitersEasyToGrab()
            persistWorkspaceState()
        }
        .onChange(of: openTabs) { persistWorkspaceState() }
        .onChange(of: showTerminal) { persistWorkspaceState() }
        .onChange(of: splitPaperID) { persistWorkspaceState() }
        .onChange(of: paperToOpen) {
            guard let id = paperToOpen else { return }
            openPaperAsReference(id: id)
            paperToOpen = nil
        }
        .fileImporter(
            isPresented: $isOpeningTeX,
            allowedContentTypes: [
                .init(filenameExtension: "tex")!,
                .init(filenameExtension: "md")!,
            ],
            allowsMultipleSelection: false
        ) { result in
            if let urls = try? result.get(), let url = urls.first {
                openTeXFile(url)
            }
        }
        .onChange(of: selectedTab) {
            if selectedTab != .library {
                isImportingPDF = false
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }
}

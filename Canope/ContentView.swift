import SwiftUI
import SwiftData
import ObjectiveC

enum AppChromeMetrics {
    static let topBarHeight: CGFloat = 24
    static let topButtonSize: CGFloat = 24
}

enum SidebarSelection: Hashable {
    case allPapers
    case favorites
    case unread
    case recent
    case collection(PersistentIdentifier)
}

enum TabItem: Hashable {
    case library
    case paper(UUID)
    case editor(String) // file path as string (URL isn't Hashable)
    case pdfFile(String) // standalone PDF file path
}

@MainActor
private enum SplitViewGrabAssociation {
    static let delegateKey = malloc(1)!
}

private final class SplitViewGrabDelegate: NSObject, NSSplitViewDelegate {
    private let extraHitInset: CGFloat = 5

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        MainWindow.expandedDividerRect(for: splitView, dividerIndex: dividerIndex, inset: extraHitInset)
    }
}

struct MainWindow: View {
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
    }

    private func tabTitle(_ tab: TabItem) -> String {
        switch tab {
        case .library: return "Bibliothèque"
        case .paper(let id): return allPapers.first(where: { $0.id == id })?.title ?? "Article"
        case .editor(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .pdfFile(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func openPDFFile(_ url: URL) {
        let tab = TabItem.pdfFile(url.path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        selectedTab = tab
    }

    /// Find all NSSplitViews and make dividers thick + easy to grab
    @MainActor
    private func makeSplitersEasyToGrab() {
        // Run multiple times to catch split views created after initial layout
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    Self.thickenSplitViews(contentView)
                }
            }
        }
    }

    @MainActor
    static func thickenSplitViews(_ view: NSView) {
        if let splitView = view as? NSSplitView {
            splitView.dividerStyle = .thick
            if splitView.delegate == nil || splitView.delegate is SplitViewGrabDelegate {
                let delegate = (objc_getAssociatedObject(splitView, SplitViewGrabAssociation.delegateKey) as? SplitViewGrabDelegate)
                    ?? SplitViewGrabDelegate()
                objc_setAssociatedObject(
                    splitView,
                    SplitViewGrabAssociation.delegateKey,
                    delegate,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                splitView.delegate = delegate
            }
            splitView.needsDisplay = true
        }
        for sub in view.subviews { thickenSplitViews(sub) }
    }

    @MainActor
    static func expandedDividerRect(for splitView: NSSplitView, dividerIndex: Int, inset: CGFloat) -> NSRect {
        guard dividerIndex >= 0, dividerIndex < splitView.subviews.count - 1 else { return .zero }

        let precedingFrame = splitView.subviews[dividerIndex].frame
        let followingFrame = splitView.subviews[dividerIndex + 1].frame

        if splitView.isVertical {
            let gapStart = precedingFrame.maxX
            let gapEnd = followingFrame.minX
            let width = max(splitView.dividerThickness, gapEnd - gapStart)
            return NSRect(
                x: gapStart - inset,
                y: 0,
                width: width + inset * 2,
                height: splitView.bounds.height
            ).integral
        } else {
            let gapStart = precedingFrame.maxY
            let gapEnd = followingFrame.minY
            let height = max(splitView.dividerThickness, gapEnd - gapStart)
            return NSRect(
                x: 0,
                y: gapStart - inset,
                width: splitView.bounds.width,
                height: height + inset * 2
            ).integral
        }
    }

    func openTeXFile(_ url: URL) {
        let tab = TabItem.editor(url.path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        selectedTab = tab
        Self.addRecentTeXFile(url.path)
    }

    // MARK: - Recent .tex files

    private static let recentTeXKey = "recentTeXFiles"
    private static let maxRecent = 10

    static func addRecentTeXFile(_ path: String) {
        var recents = UserDefaults.standard.stringArray(forKey: recentTeXKey) ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > maxRecent { recents = Array(recents.prefix(maxRecent)) }
        UserDefaults.standard.set(recents, forKey: recentTeXKey)
    }

    static var recentTeXFiles: [String] {
        (UserDefaults.standard.stringArray(forKey: recentTeXKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
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
                            let recents = Self.recentTeXFiles
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
                        .help("Ouvrir un fichier .tex (⌘O)")
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
            .background(.bar)

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
                .frame(height: EditorChromeMetrics.tabBarHeight)
                .background(.bar.opacity(0.7))
            }

            Divider()

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
            let tab = TabItem.paper(id)
            if !openTabs.contains(tab) {
                openTabs.append(tab)
            }
            selectedTab = tab
            paperToOpen = nil
        }
        .fileImporter(
            isPresented: $isOpeningTeX,
            allowedContentTypes: [.init(filenameExtension: "tex")!],
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

// MARK: - Tab Bar

struct TabBar: View {
    @Binding var tabs: [TabItem]
    @Binding var selectedTab: TabItem
    let allPapers: [Paper]
    var onOpenTeX: () -> Void = {}

    /// The active editor tab (current selection if it's an editor, otherwise the last opened one)
    private var editorTab: TabItem? {
        if case .editor(let p) = selectedTab, !p.isEmpty { return selectedTab }
        return tabs.last { if case .editor(let p) = $0 { return !p.isEmpty } else { return false } }
    }

    /// Whether the selected tab is an editor tab
    private var isEditorSelected: Bool {
        if case .editor = selectedTab { return true }
        return false
    }

    /// All open editor tabs (excluding the empty placeholder)
    private var editorTabs: [TabItem] {
        tabs.filter { if case .editor(let p) = $0 { return !p.isEmpty } else { return false } }
    }

    /// Document tabs: papers + standalone PDFs (scrollable, bottom row)
    private var documentTabs: [TabItem] {
        tabs.filter {
            if case .paper = $0 { return true }
            if case .pdfFile = $0 { return true }
            return false
        }
    }

    var body: some View {
        // Section tabs only (Bibliothèque + LaTeX)
        HStack(spacing: 0) {
            SectionTab(
                icon: "books.vertical",
                label: "Bibliothèque",
                isSelected: selectedTab == .library
            ) { selectedTab = .library }

            SectionTab(
                icon: "chevron.left.forwardslash.chevron.right",
                iconColor: .green,
                label: editorTabs.count > 1 ? "LaTeX" : (editorTab.map { title(for: $0) } ?? "LaTeX"),
                isSelected: isEditorSelected
            ) {
                if let tab = editorTab {
                    selectedTab = tab
                } else {
                    selectedTab = .editor("")
                }
            }
        }
        .frame(height: AppChromeMetrics.topBarHeight)
        .clipped()
    }

    private func title(for tab: TabItem) -> String {
        switch tab {
        case .library: return "Bibliothèque"
        case .paper(let id):
            return allPapers.first(where: { $0.id == id })?.title ?? "Article"
        case .editor(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .pdfFile(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func closeTab(_ tab: TabItem) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = index > 0 ? tabs[index - 1] : (tabs.first ?? .library)
        }
    }
}

// MARK: - Section Tab (top row — Bibliothèque / LaTeX)

struct SectionTab: View {
    let icon: String
    var iconColor: Color? = nil
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconColor ?? (isSelected ? .primary : .secondary))
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.white.opacity(0.06)
                : isHovered ? Color.white.opacity(0.03)
                : Color.clear
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(Color.white.opacity(0.3)).frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Document Tab (bottom row — papers / PDFs)

struct TabButton: View {
    let tab: TabItem
    let isSelected: Bool
    let title: String
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovered = false

    private var tabIcon: String {
        switch tab {
        case .library: return "books.vertical"
        case .paper: return "doc.text"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .pdfFile: return "doc.richtext"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tabIcon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 160)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isSelected || isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            isSelected ? Color.accentColor.opacity(0.12)
            : isHovered ? Color.white.opacity(0.05)
            : Color.clear
        )
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(height: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @Binding var paperToOpen: UUID?
    @Binding var isImportingPDF: Bool
    @State private var sidebarSelection: SidebarSelection? = .allPapers
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    @State private var inspectedPaperID: UUID?
    @Query private var allPapers: [Paper]

    private var inspectedPaper: Paper? {
        guard let id = inspectedPaperID else { return nil }
        return allPapers.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            PaperTableView(
                sidebarSelection: sidebarSelection ?? .allPapers,
                inspectedPaperID: $inspectedPaperID,
                isImporting: $isImportingPDF,
                onOpenPaper: { paper in
                    paperToOpen = paper.id
                }
            )
        }
        .inspector(isPresented: $showInspector) {
            if let paper = inspectedPaper {
                PaperInfoPanel(paper: paper)
            } else {
                ContentUnavailableView(
                    "Aucun article sélectionné",
                    systemImage: "info.circle",
                    description: Text("Sélectionnez un article pour voir ses infos")
                )
            }
        }
        .onChange(of: inspectedPaperID) {
            if inspectedPaperID != nil && !showInspector {
                showInspector = true
            }
        }
    }
}

// MARK: - Standalone PDF Viewer (for files opened from file browser)

import PDFKit

struct StandalonePDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - LaTeX Landing View (empty editor state)

// MARK: - LaTeX Editor Container (manages multiple .tex files with sub-tabs)

struct LaTeXEditorContainer: View {
    @Query private var allPapers: [Paper]
    let openPaths: [String]
    @Binding var selectedTab: TabItem
    @Binding var showTerminal: Bool
    let openPaperIDs: [UUID]
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    var onOpenTeX: (URL) -> Void
    var onOpenPDF: (URL) -> Void
    var onCloseEditor: (String) -> Void
    @State private var didRestoreWorkspaceState = false

    /// The currently active editor path
    private var activePath: String? {
        if case .editor(let p) = selectedTab, !p.isEmpty { return p }
        return openPaths.last
    }

    private func switchEditor(_ path: String) {
        selectedTab = .editor(path)
    }

    private func closeEditor(_ path: String) {
        onCloseEditor(path)
        if activePath == path {
            if let other = openPaths.first(where: { $0 != path }) {
                selectedTab = .editor(other)
            } else {
                selectedTab = .editor("")
            }
        }
    }

    @State private var hoveredTabPath: String?

    private var workspaceSnapshot: LaTeXEditorWorkspaceState {
        LaTeXEditorWorkspaceState(
            showSidebar: workspaceState.showSidebar,
            selectedSidebarSection: workspaceState.selectedSidebarSection,
            sidebarWidth: workspaceState.sidebarWidth,
            showPDFPreview: workspaceState.showPDFPreview,
            showErrors: workspaceState.showErrors,
            splitLayout: workspaceState.splitLayout,
            panelArrangement: workspaceState.panelArrangement,
            editorFontSize: workspaceState.editorFontSize,
            editorTheme: workspaceState.editorTheme,
            referencePaperIDs: workspaceState.referencePaperIDs,
            selectedReferencePaperID: workspaceState.selectedReferencePaperID,
            layoutBeforeReference: workspaceState.layoutBeforeReference
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
        workspaceState.showErrors = snapshot.showErrors
        workspaceState.splitLayout = snapshot.splitLayout
        workspaceState.showPDFPreview = snapshot.splitLayout != "editorOnly"
        workspaceState.panelArrangement = snapshot.panelArrangement
        workspaceState.editorFontSize = snapshot.editorFontSize
        workspaceState.editorTheme = snapshot.editorTheme
        workspaceState.layoutBeforeReference = snapshot.layoutBeforeReference

        var seen = Set<UUID>()
        let referenceIDs = snapshot.referencePaperIDs.filter { seen.insert($0).inserted }
        workspaceState.referencePaperIDs = referenceIDs
        workspaceState.selectedReferencePaperID = snapshot.selectedReferencePaperID
        workspaceState.referencePDFs = loadReferencePDFs(for: referenceIDs)

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
                        .frame(height: EditorChromeMetrics.tabBarHeight)
                        .background(
                            isCurrent ? Color.white.opacity(0.06)
                            : isHov ? Color.white.opacity(0.03)
                            : Color.clear
                        )
                        .overlay(alignment: .bottom) {
                            if isCurrent {
                                Rectangle().fill(Color.green.opacity(0.5)).frame(height: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { switchEditor(path) }
                        .onHover { hoveredTabPath = $0 ? path : nil }
                    }
                }
            }
            .frame(height: EditorChromeMetrics.tabBarHeight)
            .background(.bar.opacity(0.5))
        }
    }

    var body: some View {
        ZStack {
            if openPaths.isEmpty {
                LaTeXLandingView(onOpenTeX: onOpenTeX, onOpenPDF: onOpenPDF)
            }

            if let activePath, !activePath.isEmpty {
                LaTeXEditorView(
                    fileURL: URL(fileURLWithPath: activePath),
                    isActive: true,
                    showTerminal: $showTerminal,
                    workspaceState: workspaceState,
                    terminalWorkspaceState: terminalWorkspaceState,
                    onOpenPDF: onOpenPDF,
                    onOpenInNewTab: onOpenTeX,
                    openPaperIDs: openPaperIDs,
                    editorTabBar: openPaths.count > 1 ? AnyView(editorTabBar) : nil
                )
            }
        }
        .onAppear {
            restoreWorkspaceStateIfNeeded()
        }
        .onChange(of: workspaceSnapshot) {
            persistWorkspaceState()
        }
    }
}

struct LaTeXLandingView: View {
    var onOpenTeX: (URL) -> Void
    var onOpenPDF: (URL) -> Void

    /// Root directory: parent of last opened .tex, or home as fallback
    private var rootURL: URL {
        if let lastPath = MainWindow.recentTeXFiles.first {
            return URL(fileURLWithPath: lastPath).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        HSplitView {
            FileBrowserView(rootURL: rootURL) { url in
                let ext = url.pathExtension.lowercased()
                if ext == "tex" || ext == "bib" || ext == "txt" || ext == "md" {
                    onOpenTeX(url)
                } else if ext == "pdf" {
                    onOpenPDF(url)
                }
            }
            .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)

            VStack(spacing: 16) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Éditeur LaTeX")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Ouvrez un fichier .tex depuis l'arborescence\nou utilisez le menu + en haut à droite")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                // Quick access: recent files
                let recents = MainWindow.recentTeXFiles
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Récents")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                        ForEach(recents.prefix(5), id: \.self) { path in
                            Button {
                                onOpenTeX(URL(fileURLWithPath: path))
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.plaintext")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.green)
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.03))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 300)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

import AppKit
import SwiftUI
import SwiftData
import PDFKit

private enum CodeThreePaneRole {
    case terminal
    case editor
    case output
}

struct CodeEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var terminalAppearanceStore = TerminalAppearanceStore.shared

    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    @ObservedObject var documentState: CodeDocumentUIState
    var onOpenInNewTab: ((URL) -> Void)?
    var openPaperIDs: [UUID] = []
    var editorTabBar: AnyView? = nil
    var onPersistWorkspaceState: (() -> Void)?

    @Query var allPapers: [Paper]
    @State private var fitToWidthTrigger = false
    @Namespace private var contentTabIndicatorNamespace

    @State private var text = ""
    @State private var savedText = ""
    @State private var lastModified: Date?
    @State private var pollTimer: Timer?
    @State private var sidebarResizeStartWidth: CGFloat?
    @State private var outputResizeStartWidth: CGFloat?
    @State private var toolbarStatus: ToolbarStatusState = .idle
    @State private var toolbarStatusClearWorkItem: DispatchWorkItem?
    @State private var fileCreationError: String?

    private var projectRoot: URL { fileURL.deletingLastPathComponent() }
    private var documentMode: EditorDocumentMode { EditorDocumentMode(fileURL: fileURL) }
    private var syntaxLanguage: CodeSyntaxLanguage {
        switch documentMode {
        case .python:
            return .python
        case .r:
            return .r
        case .latex, .markdown:
            return .python
        }
    }
    private var editorFontSize: CGFloat {
        CGFloat(workspaceState.editorFontSize)
    }
    private var codeTheme: CodeSyntaxTheme { .monokai }
    private var outputDirectoryURL: URL {
        if let manualPreviewArtifact = documentState.manualPreviewArtifact {
            return manualPreviewArtifact.url.deletingLastPathComponent()
        }
        if let selectedRun = documentState.selectedRun {
            return selectedRun.artifactDirectory
        }
        return CodeRunService.artifactRootDirectoryURL(for: fileURL)
    }
    private var outputStatusLabel: String {
        if documentState.manualPreviewArtifact != nil {
            return "Preview manuelle"
        }
        guard let selectedRun = documentState.selectedRun,
              let index = documentState.runHistory.firstIndex(where: { $0.runID == selectedRun.runID }) else {
            return "Aucun run"
        }
        let time = selectedRun.executedAt.formatted(date: .omitted, time: .standard)
        return "Run \(index + 1)/\(documentState.runHistory.count) · \(time) · \(selectedRun.artifacts.count) artefact\(selectedRun.artifacts.count > 1 ? "s" : "")"
    }

    // --- Layout flags: read from shared workspace state (same as LaTeX editor) ---

    private var isOutputVisible: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set { workspaceState.showPDFPreview = newValue }
    }

    private var editorTerminalSplitLayout: LaTeXEditorSplitLayout {
        get { LaTeXEditorSplitLayout(rawValue: workspaceState.splitLayout) ?? .horizontal }
        nonmutating set { workspaceState.splitLayout = newValue.rawValue }
    }

    private var panelArrangement: PanelArrangement {
        get { workspaceState.panelArrangement }
        nonmutating set { workspaceState.panelArrangement = newValue }
    }

    private var leadingPaneWidth: CGFloat? {
        get { workspaceState.threePaneLeadingWidth.map { CGFloat($0) } }
        nonmutating set { workspaceState.threePaneLeadingWidth = newValue.map { Double($0) } }
    }

    private var trailingPaneWidth: CGFloat? {
        get { workspaceState.threePaneTrailingWidth.map { CGFloat($0) } }
        nonmutating set { workspaceState.threePaneTrailingWidth = newValue.map { Double($0) } }
    }

    // --- Per-document state (code-specific) ---

    private var outputPlacement: CodeOutputPlacement {
        get { documentState.outputLayout.outputPlacement }
        nonmutating set {
            documentState.updateOutputLayout { $0.outputPlacement = newValue }
        }
    }

    private var primaryOutputWidth: CGFloat? {
        get { documentState.outputLayout.primaryOutputWidth.map { CGFloat($0) } }
        nonmutating set {
            documentState.updateOutputLayout { $0.primaryOutputWidth = newValue.map { Double($0) } }
        }
    }

    private var showSidebar: Bool {
        get { workspaceState.showSidebar }
        nonmutating set { workspaceState.showSidebar = newValue }
    }

    private var sidebarWidth: CGFloat {
        get {
            let stored = CGFloat(workspaceState.sidebarWidth)
            guard stored.isFinite, stored > 0 else { return LaTeXEditorSidebarSizing.defaultWidth }
            return min(max(stored, LaTeXEditorSidebarSizing.minWidth), LaTeXEditorSidebarSizing.maxWidth)
        }
        nonmutating set {
            workspaceState.sidebarWidth = Double(min(max(newValue, LaTeXEditorSidebarSizing.minWidth), LaTeXEditorSidebarSizing.maxWidth))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            AppChromeDivider(role: .shell)

            HSplitView {
                sidebarPane
                workAreaPane
            }
        }
        .alert("Impossible de créer le fichier", isPresented: Binding(
            get: { fileCreationError != nil },
            set: { if !$0 { fileCreationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileCreationError ?? "")
        }
        .onAppear {
            loadFile()
            if isActive {
                startFileWatcher()
            }
        }
        .onDisappear {
            stopFileWatcher()
            persistDocumentWorkspaceState()
        }
        .onChange(of: isActive) {
            if isActive {
                loadFile()
                startFileWatcher()
            } else {
                stopFileWatcher()
                persistDocumentWorkspaceState()
            }
        }
        .onChange(of: fileURL) {
            stopFileWatcher()
            toolbarStatus = .idle
            loadFile()
            if isActive {
                startFileWatcher()
            }
        }
        .onChange(of: documentState.outputLayout) { persistDocumentWorkspaceState() }
        .onChange(of: documentState.showLogs) { persistDocumentWorkspaceState() }
        .onChange(of: documentState.selectedRunID) { persistDocumentWorkspaceState() }
        .onChange(of: documentState.selectedArtifactPath) { persistDocumentWorkspaceState() }
        .onChange(of: documentState.secondaryArtifactPath) { persistDocumentWorkspaceState() }
        .onChange(of: showSidebar) { onPersistWorkspaceState?() }
        .onChange(of: workspaceState.sidebarWidth) { onPersistWorkspaceState?() }
        .onChange(of: workspaceState.editorFontSize) { onPersistWorkspaceState?() }
    }

    private var workAreaPane: some View {
        Group {
            if isActive && showTerminal && editorTerminalSplitLayout != .editorOnly {
                if editorTerminalSplitLayout == .vertical {
                    VSplitView {
                        editorAndOutputPane
                            .layoutPriority(1)
                        embeddedTerminalPane
                            .frame(minHeight: 150, idealHeight: 220, maxHeight: .infinity)
                    }
                } else if isOutputVisible && outputPlacement == .right {
                    horizontalThreePaneWorkspace
                } else {
                    HSplitView {
                        editorAndOutputPane
                            .layoutPriority(1)
                        embeddedTerminalPane
                    }
                }
            } else {
                editorAndOutputPane
            }
        }
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showTerminal)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: isOutputVisible)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: editorTerminalSplitLayout)
    }

    @ViewBuilder
    private var editorAndOutputPane: some View {
        if !isOutputVisible {
            editorPane
        } else if outputPlacement == .right {
            outputRightPlacementPane
        } else {
            VSplitView {
                editorPane
                contentPane
                    .frame(minHeight: 220, idealHeight: 320, maxHeight: .infinity)
            }
        }
    }

    private var embeddedTerminalPane: some View {
        TerminalPanel(
            workspaceState: terminalWorkspaceState,
            document: nil,
            isVisible: isActive && showTerminal,
            topInset: 0,
            showsInlineControls: false,
            startupWorkingDirectory: projectRoot
        )
        .frame(minWidth: 160, idealWidth: 320, maxWidth: .infinity)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if let editorTabBar {
                editorTabBar
                AppChromeDivider(role: .panel)
            }

            CodeTextEditor(
                text: $text,
                language: syntaxLanguage,
                fontSize: editorFontSize,
                theme: codeTheme,
                onTextChange: {}
            )

            if documentState.showLogs {
                AppChromeDivider(role: .panel)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: documentState.isRunning ? "hourglass" : "terminal")
                            .foregroundStyle(documentState.isRunning ? AppChromePalette.info : .secondary)
                        Text(documentState.lastCommandDescription.isEmpty ? "Journal d’exécution" : documentState.lastCommandDescription)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { documentState.showLogs = false }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppChromePalette.surfaceSubbar)

                    ScrollView {
                        Text(documentState.outputLog.isEmpty ? "Aucune sortie" : documentState.outputLog)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                .frame(height: 160)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(minWidth: 200, idealWidth: 680, maxWidth: .infinity)
        .layoutPriority(1)
    }

    private var outputRightPlacementPane: some View {
        GeometryReader { proxy in
            let dividerWidth = LaTeXEditorThreePaneSizing.dividerWidth
            let totalWidth = max(0, proxy.size.width - dividerWidth)
            let minEditor: CGFloat = 220
            let minOutput: CGFloat = 240
            let seededOutput = primaryOutputWidth ?? 380
            let maxOutput = max(minOutput, totalWidth - minEditor)
            let outputWidth = min(max(seededOutput, minOutput), maxOutput)
            let editorWidth = max(minEditor, totalWidth - outputWidth)

            HStack(spacing: 0) {
                editorPane
                    .frame(width: editorWidth)

                AppChromeResizeHandle(
                    width: dividerWidth,
                    onHoverChanged: { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    },
                    dragGesture: AnyGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = outputResizeStartWidth ?? outputWidth
                                if outputResizeStartWidth == nil {
                                    outputResizeStartWidth = outputWidth
                                }
                                let next = start - value.translation.width
                                primaryOutputWidth = min(max(next, minOutput), maxOutput)
                            }
                            .onEnded { _ in
                                outputResizeStartWidth = nil
                                persistDocumentWorkspaceState()
                            }
                    ),
                    axis: .vertical
                )

                contentPane
                    .frame(width: outputWidth)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private var horizontalThreePaneWorkspace: some View {
        let roles = codeThreePaneRoles
        return ThreePaneLayoutView(
            config: .code(arrangement: panelArrangement),
            leadingWidth: Binding(get: { leadingPaneWidth }, set: { leadingPaneWidth = $0 }),
            trailingWidth: Binding(get: { trailingPaneWidth }, set: { trailingPaneWidth = $0 }),
            leading: { codeThreePaneView(for: roles.0) },
            middle: { codeThreePaneView(for: roles.1) },
            trailing: { codeThreePaneView(for: roles.2) },
            onDragEnd: persistDocumentWorkspaceState
        )
    }

    private var outputWorkspace: some View {
        CodeOutputWorkspace(
            documentState: documentState,
            outputStatusLabel: outputStatusLabel,
            revealArtifactDirectoryInFinder: revealArtifactDirectoryInFinder,
            refreshSelectedRun: refreshSelectedRun,
            persist: persistDocumentWorkspaceState
        )
    }

    // MARK: - Content Pane (Output + Reference PDFs)

    private var contentPaneTabs: [LaTeXEditorPdfPaneTab] {
        [.compiled] + workspaceState.referencePaperIDs.map { .reference($0) }
    }

    private var selectedContentTab: LaTeXEditorPdfPaneTab {
        if let id = workspaceState.selectedReferencePaperID {
            return .reference(id)
        }
        return .compiled
    }

    private func paperFor(_ id: UUID) -> Paper? {
        allPapers.first { $0.id == id }
    }

    private var contentPane: some View {
        VStack(spacing: 0) {
            if contentPaneTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(contentPaneTabs, id: \.self) { tab in
                            contentTabButton(tab)
                        }
                    }
                }
                .frame(height: AppChromeMetrics.tabBarHeight)
                .background(AppChromePalette.surfaceSubbar)
                AppChromeDivider(role: .panel)
            }

            ZStack {
                outputWorkspace
                    .opacity(selectedContentTab == .compiled ? 1 : 0)
                    .allowsHitTesting(selectedContentTab == .compiled)

                ForEach(contentPaneTabs.compactMap { tab -> UUID? in
                    if case .reference(let id) = tab { return id } else { return nil }
                }, id: \.self) { id in
                    Group {
                        if let pdf = workspaceState.referencePDFs[id],
                           let state = workspaceState.referencePDFUIStates[id],
                           let paper = paperFor(id) {
                            ReferencePDFAnnotationPane(
                                document: pdf,
                                fileURL: paper.fileURL,
                                fitToWidthTrigger: selectedContentTab == .reference(id) ? fitToWidthTrigger : false,
                                isBridgeCommandTargetActive: selectedContentTab == .reference(id),
                                state: state,
                                onDocumentChanged: {
                                    referencePDFDocumentDidChange(id: id)
                                },
                                onMarkupAppearanceNeedsRefresh: {
                                    reloadReferencePDFDocument(id: id)
                                },
                                onSaveNote: {
                                    saveReferenceAnnotationNote(for: id)
                                },
                                onCancelNote: {
                                    workspaceState.referencePDFUIStates[id]?.isEditingNote = false
                                },
                                onAutoSave: {
                                    saveReferencePDF(id: id)
                                }
                            )
                        } else {
                            ContentUnavailableView(
                                "PDF introuvable",
                                systemImage: "exclamationmark.triangle",
                                description: Text("Le fichier PDF n'a pas pu être chargé")
                            )
                        }
                    }
                    .opacity(selectedContentTab == .reference(id) ? 1 : 0)
                    .allowsHitTesting(selectedContentTab == .reference(id))
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 380, maxWidth: .infinity)
    }

    @ViewBuilder
    private func contentTabButton(_ tab: LaTeXEditorPdfPaneTab) -> some View {
        let isSelected = tab == selectedContentTab
        HStack(spacing: 4) {
            Button {
                AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                    selectContentTab(tab)
                }
            } label: {
                HStack(spacing: 4) {
                    switch tab {
                    case .compiled:
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 9))
                        Text("Output")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    case .reference(let id):
                        Image(systemName: "book")
                            .font(.system(size: 9))
                        Text(paperFor(id)?.authorsShort ?? "Article")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if case .reference = tab {
                Button {
                    closeContentTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(AppChromePalette.tabFill(isSelected: isSelected, isHovered: false, role: .reference))
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(AppChromePalette.tabIndicator(for: .reference))
                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
                    .matchedGeometryEffect(id: "code-content-tab-indicator", in: contentTabIndicatorNamespace)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }

    private func selectContentTab(_ tab: LaTeXEditorPdfPaneTab) {
        switch tab {
        case .compiled:
            workspaceState.selectedReferencePaperID = nil
        case .reference(let id):
            workspaceState.selectedReferencePaperID = id
        }
    }

    private func closeContentTab(_ tab: LaTeXEditorPdfPaneTab) {
        guard case .reference(let id) = tab else { return }
        let pendingSave = workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges == true
        let documentToSave = workspaceState.referencePDFs[id]
        let fileURLToSave = paperFor(id)?.fileURL

        workspaceState.referencePaperIDs.removeAll { $0 == id }
        workspaceState.referencePDFs.removeValue(forKey: id)
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates.removeValue(forKey: id)
        if workspaceState.selectedReferencePaperID == id {
            workspaceState.selectedReferencePaperID = workspaceState.referencePaperIDs.first
        }

        guard pendingSave, let documentToSave, let fileURLToSave else { return }
        DispatchQueue.main.async {
            _ = AnnotationService.save(document: documentToSave, to: fileURLToSave)
        }
    }

    private func openReference(_ paper: Paper) {
        let tab = LaTeXEditorPdfPaneTab.reference(paper.id)
        if contentPaneTabs.contains(tab) {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = paper.id
            }
            return
        }
        guard let pdf = PDFDocument(url: paper.fileURL) else { return }
        AnnotationService.normalizeDocumentAnnotations(in: pdf)
        workspaceState.referencePDFs[paper.id] = pdf
        if workspaceState.referencePDFUIStates[paper.id] == nil {
            workspaceState.referencePDFUIStates[paper.id] = ReferencePDFUIState()
        }
        workspaceState.referencePaperIDs.append(paper.id)
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            workspaceState.selectedReferencePaperID = paper.id
        }
        if !isOutputVisible {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                isOutputVisible = true
            }
        }
    }

    // MARK: - Reference PDF Helpers

    private func referencePDFDocumentDidChange(id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.hasUnsavedChanges = true
        state.annotationRefreshToken = UUID()
        let delay: TimeInterval = (state.selectedAnnotation?.isTextBoxAnnotation == true || state.currentTool == .textBox) ? 0.9 : 0.25
        state.pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak state] in
            state?.pendingSaveWorkItem = nil
            saveReferencePDF(id: id)
        }
        state.pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func saveReferencePDF(id: UUID) {
        guard let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem = nil
        if AnnotationService.save(document: document, to: paper.fileURL) {
            workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges = false
        }
    }

    private func reloadReferencePDFDocument(id: UUID) {
        guard let paper = paperFor(id) else { return }
        let state = workspaceState.referencePDFUIStates[id]
        state?.selectedAnnotation = nil
        state?.requestedRestorePageIndex = state?.lastKnownPageIndex
        guard let data = try? Data(contentsOf: paper.fileURL),
              let refreshed = PDFDocument(data: data) else {
            if let loaded = PDFDocument(url: paper.fileURL) {
                AnnotationService.normalizeDocumentAnnotations(in: loaded)
                workspaceState.referencePDFs[id] = loaded
            }
            state?.annotationRefreshToken = UUID()
            state?.pdfViewRefreshToken = UUID()
            return
        }
        AnnotationService.normalizeDocumentAnnotations(in: refreshed)
        workspaceState.referencePDFs[id] = refreshed
        state?.annotationRefreshToken = UUID()
        state?.pdfViewRefreshToken = UUID()
    }

    private func saveReferenceAnnotationNote(for id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id],
              let annotation = state.selectedAnnotation else { return }
        annotation.contents = state.editingNoteText
        state.isEditingNote = false
        state.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    private var codeThreePaneRoles: (CodeThreePaneRole, CodeThreePaneRole, CodeThreePaneRole) {
        switch panelArrangement {
        case .editorContentTerminal:
            return (.editor, .output, .terminal)
        case .terminalEditorContent:
            return (.terminal, .editor, .output)
        case .contentEditorTerminal:
            return (.output, .editor, .terminal)
        }
    }

    @ViewBuilder
    private func codeThreePaneView(for role: CodeThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .output:
            contentPane
        }
    }

    private var sidebarPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(showSidebar ? AppChromePalette.info : .secondary)
                        .background(showSidebar ? AppChromePalette.selectedAccentFill : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Fichiers")

                Spacer()
            }
            .padding(.top, 10)
            .frame(width: 44)
            .background(AppChromePalette.surfaceSubbar)

            AppChromeDivider(role: .panel, axis: .vertical)

            FileBrowserView(rootURL: projectRoot, showsCreateFileMenu: true) { url in
                if EditorFileSupport.isEditorDocument(url) {
                    onOpenInNewTab?(url)
                } else if let artifact = ArtifactDescriptor.make(url: url, sourceDocumentPath: fileURL.path, runID: nil) {
                    if documentState.outputLayout.secondaryPaneVisible {
                        documentState.setSecondaryManualPreviewArtifact(artifact)
                    } else {
                        documentState.setManualPreviewArtifact(artifact)
                    }
                    persistDocumentWorkspaceState()
                }
            }
            .frame(
                minWidth: showSidebar ? sidebarWidth : 0,
                idealWidth: showSidebar ? sidebarWidth : 0,
                maxWidth: showSidebar ? sidebarWidth : 0
            )
            .opacity(showSidebar ? 1 : 0)
            .allowsHitTesting(showSidebar)
            .clipped()

            if showSidebar {
                AppChromeResizeHandle(
                    width: LaTeXEditorSidebarSizing.resizeHandleWidth,
                    onHoverChanged: { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    },
                    dragGesture: AnyGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let baseWidth = sidebarResizeStartWidth ?? sidebarWidth
                                if sidebarResizeStartWidth == nil {
                                    sidebarResizeStartWidth = sidebarWidth
                                }
                                sidebarWidth = baseWidth + value.translation.width
                            }
                            .onEnded { _ in
                                sidebarResizeStartWidth = nil
                                onPersistWorkspaceState?()
                            }
                    )
                )
            }
        }
        .frame(
            width: showSidebar
                ? LaTeXEditorSidebarSizing.activityBarWidth + sidebarWidth + LaTeXEditorSidebarSizing.resizeHandleWidth + AppChromeMetrics.dividerThickness
                : LaTeXEditorSidebarSizing.activityBarWidth
        )
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showSidebar)
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            toolbarCluster(zone: .leading, title: "Fichier") {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(documentMode.fileIconTint)
                Text(fileURL.lastPathComponent)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                AppChromeStatusCapsule(status: toolbarStatus)
                if !showSidebar {
                    Menu {
                        createFileMenuContent
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            toolbarCluster(zone: .primary, title: documentMode.primaryClusterTitle) {
                Button(action: runScript) {
                    Image(systemName: documentState.isRunning ? "hourglass" : "play.fill")
                        .foregroundStyle(AppChromePalette.success)
                }
                .buttonStyle(.plain)
                .disabled(documentState.isRunning)
                .help("Exécuter (⌘B)")
                .keyboardShortcut("b", modifiers: .command)

                Button(action: saveFile) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Enregistrer")

                Button(action: { documentState.showLogs.toggle() }) {
                    Image(systemName: documentState.showLogs ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                        .foregroundStyle(documentState.showLogs ? AppChromePalette.info : .secondary)
                }
                .buttonStyle(.plain)
                .help("Journal d’exécution")
            }

            toolbarCluster(zone: .primary, title: "Réf.") {
                Menu {
                    let openPapers = allPapers.filter { openPaperIDs.contains($0.id) }
                    if openPapers.isEmpty {
                        Text("Aucun article ouvert en onglet")
                    } else {
                        ForEach(openPapers) { paper in
                            Button {
                                openReference(paper)
                            } label: {
                                let alreadyOpen = contentPaneTabs.contains(.reference(paper.id))
                                Text("\(alreadyOpen ? "✓ " : "")\(paper.authorsShort) (\(paper.year.map { String($0) } ?? "—")) — \(paper.title)")
                            }
                        }
                    }
                } label: {
                    Image(systemName: contentPaneTabs.count > 1 ? "book.fill" : "book")
                        .foregroundStyle(contentPaneTabs.count > 1 ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help("Ouvrir un article de référence")
            }

            Spacer(minLength: 8)

            toolbarCluster(zone: .trailing, title: "Vue") {
                Button(action: {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        showSidebar.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.left")
                        .symbolVariant(showSidebar ? .none : .slash)
                        .foregroundStyle(showSidebar ? AppChromePalette.info : .secondary)
                }
                .buttonStyle(.plain)

                Button(action: {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        isOutputVisible.toggle()
                    }
                }) {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(isOutputVisible ? AppChromePalette.info : .secondary)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            outputPlacement = .right
                        }
                    } label: {
                        Label("Output à droite", systemImage: "rectangle.split.2x1")
                        if outputPlacement == .right { Image(systemName: "checkmark") }
                    }

                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            outputPlacement = .bottom
                        }
                    } label: {
                        Label("Output en bas", systemImage: "rectangle.split.1x2")
                        if outputPlacement == .bottom { Image(systemName: "checkmark") }
                    }
                } label: {
                    Label("Output", systemImage: outputPlacement == .right ? "rectangle.split.2x1" : "rectangle.split.1x2")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            editorTerminalSplitLayout = .horizontal
                        }
                    } label: {
                        Label("Disposition horizontale", systemImage: "rectangle.split.2x1")
                        if editorTerminalSplitLayout == .horizontal { Image(systemName: "checkmark") }
                    }

                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            editorTerminalSplitLayout = .vertical
                        }
                    } label: {
                        Label("Terminal en bas", systemImage: "rectangle.split.1x2")
                        if editorTerminalSplitLayout == .vertical { Image(systemName: "checkmark") }
                    }

                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            editorTerminalSplitLayout = .editorOnly
                        }
                    } label: {
                        Label("Sans terminal", systemImage: "doc.text")
                        if editorTerminalSplitLayout == .editorOnly { Image(systemName: "checkmark") }
                    }
                } label: {
                    Label("Disposition", systemImage: "slider.horizontal.3")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)

                if showTerminal && isOutputVisible && outputPlacement == .right && editorTerminalSplitLayout == .horizontal {
                    Menu {
                        ForEach(PanelArrangement.allCases, id: \.self) { arrangement in
                            Button {
                                AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                                    panelArrangement = arrangement
                                }
                            } label: {
                                HStack {
                                    if panelArrangement == arrangement {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(arrangement.title(contentLabel: "Output"))
                                }
                            }
                        }
                    } label: {
                        Label("Ordre", systemImage: "square.split.3x1")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Ordre des panneaux")
                }

                Button(action: {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        showTerminal.toggle()
                    }
                }) {
                    Image(systemName: showTerminal ? "terminal.fill" : "terminal")
                        .foregroundStyle(showTerminal ? AppChromePalette.success : .secondary)
                }
                .buttonStyle(.plain)
            }

            toolbarCluster(zone: .trailing, title: "Ed.") {
                Menu {
                    ForEach([11, 12, 13, 14, 15, 16, 18, 20, 24], id: \.self) { size in
                        Button {
                            workspaceState.editorFontSize = Double(size)
                        } label: {
                            HStack {
                                if Int(editorFontSize) == size { Image(systemName: "checkmark") }
                                Text("\(size) pt")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .buttonStyle(.plain)

                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(Color(nsColor: codeTheme.color(for: .keyword)))
                    .help(codeTheme.name)
            }

            if showTerminal {
                toolbarCluster(zone: .trailing, title: "Term.") {
                    Button(action: addTerminalTab) {
                        Image(systemName: "plus")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)

                    Button(action: terminalAppearanceStore.presentSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
    }

    @ViewBuilder
    private var createFileMenuContent: some View {
        Button {
            createNewEditorFile(.latex)
        } label: {
            Label("Nouveau fichier LaTeX", systemImage: "doc.badge.plus")
        }

        Button {
            createNewEditorFile(.markdown)
        } label: {
            Label("Nouveau fichier Markdown", systemImage: "text.badge.plus")
        }

        Button {
            createNewEditorFile(.python)
        } label: {
            Label("Nouveau script Python", systemImage: "play.rectangle")
        }

        Button {
            createNewEditorFile(.r)
        } label: {
            Label("Nouveau script R", systemImage: "chart.line.uptrend.xyaxis")
        }
    }

    private func toolbarCluster<Content: View>(
        zone: ToolbarZone,
        title: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AppChromeToolbarCluster(zone: zone, title: title, content: content)
    }

    private func loadFile(useAsBaseline: Bool = true) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        lastModified = modificationDate()
    }

    private func saveFile() {
        guard writeCurrentTextToDisk() else { return }
        setToolbarStatus(.saved, autoClearAfter: 1.4)
    }

    private func writeCurrentTextToDisk() -> Bool {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
            lastModified = modificationDate()
            return true
        } catch {
            documentState.outputLog = error.localizedDescription
            documentState.showLogs = true
            setToolbarStatus(.errors(1))
            return false
        }
    }

    private func runScript() {
        guard documentMode.isRunnableCode, !documentState.isRunning else { return }
        guard writeCurrentTextToDisk() else { return }

        let commandName = documentMode == .python ? "python3 \(fileURL.lastPathComponent)" : "Rscript \(fileURL.lastPathComponent)"
        documentState.beginRun(commandDescription: commandName)
        setToolbarStatus(documentMode.runningStatus)

        Task {
            let result = await CodeRunService.run(file: fileURL, mode: documentMode)
            await MainActor.run {
                documentState.applyRunResult(result)
                if result.succeeded {
                    setToolbarStatus(result.artifacts.isEmpty ? .completed : .previewReady, autoClearAfter: 1.6)
                } else {
                    setToolbarStatus(.errors(1))
                }
                persistDocumentWorkspaceState()
            }
        }
    }

    private func createNewEditorFile(_ kind: NewEditorFileKind) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = projectRoot
        panel.nameFieldStringValue = kind.defaultFileName
        panel.allowedContentTypes = [kind.contentType]
        panel.isExtensionHidden = false
        panel.title = kind.title
        panel.message = kind.message
        panel.prompt = "Créer"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try kind.template.write(to: url, atomically: true, encoding: .utf8)
            setToolbarStatus(.saved, autoClearAfter: 1.4)
            onOpenInNewTab?(url)
        } catch {
            fileCreationError = error.localizedDescription
        }
    }

    private func revealArtifactDirectoryInFinder() {
        if FileManager.default.fileExists(atPath: outputDirectoryURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([outputDirectoryURL])
        } else {
            NSWorkspace.shared.open(projectRoot)
        }
    }

    private func refreshSelectedRun() {
        guard let selectedRun = documentState.selectedRun else { return }
        let refreshed = CodeRunService.refresh(selectedRun, sourceDocumentPath: fileURL.path)
        documentState.applyRefreshedRun(refreshed)
        setToolbarStatus(refreshed.artifacts.isEmpty ? .completed : .previewReady, autoClearAfter: 1.2)
        persistDocumentWorkspaceState()
    }

    private func addTerminalTab() {
        NotificationCenter.default.post(name: .canopeTerminalAddTab, object: nil)
    }

    private func setToolbarStatus(_ status: ToolbarStatusState, autoClearAfter delay: TimeInterval? = nil) {
        toolbarStatusClearWorkItem?.cancel()
        toolbarStatusClearWorkItem = nil
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            toolbarStatus = status
        }

        guard let delay, status != .idle else { return }
        let workItem = DispatchWorkItem {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                toolbarStatus = .idle
            }
            toolbarStatusClearWorkItem = nil
        }
        toolbarStatusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func persistDocumentWorkspaceState() {
        onPersistWorkspaceState?()
    }

    private func startFileWatcher() {
        guard pollTimer == nil else { return }
        lastModified = modificationDate()
        let watchedURL = fileURL
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let currentMod = Self.modificationDate(for: watchedURL)
            Task { @MainActor in
                guard isActive else { return }
                if let currentMod, currentMod != lastModified {
                    lastModified = currentMod
                    loadFile(useAsBaseline: false)
                }
            }
        }
    }

    private func stopFileWatcher() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func modificationDate() -> Date? {
        Self.modificationDate(for: fileURL)
    }

    nonisolated private static func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

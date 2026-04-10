import AppKit
import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let syncTeXScrollToLine = Notification.Name("syncTeXScrollToLine")
    static let syncTeXForwardSync = Notification.Name("syncTeXForwardSync")
    static let editorRevealLocation = Notification.Name("editorRevealLocation")
    static let editorInsertText = Notification.Name("editorInsertText")
    static let markdownEditorCommand = Notification.Name("markdownEditorCommand")
}

private enum EditorThreePaneRole {
    case terminal
    case editor
    case content
}

struct UnifiedEditorView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ObservedObject private var terminalAppearanceStore = TerminalAppearanceStore.shared

    // MARK: - Init properties (from both editors)

    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    /// Drives `projectRoot` / file tree root together with `openEditorPaths` (same rules as `LaTeXWorkspaceUIState.treeViewRootURL`).
    @Binding var mainWindowTab: TabItem
    var openEditorPaths: [String]
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    /// When false, do not push `projectRoot` into the shared terminal/chat cwd (another pane owns it).
    var isEditorSectionActive: Bool = true
    @ObservedObject var documentState: EditorDocumentUIState
    @ObservedObject var codeDocumentState: CodeDocumentUIState
    var onOpenPDF: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var openPaperIDs: [UUID] = []
    var editorTabBar: AnyView? = nil
    var onPersistWorkspaceState: (() -> Void)?

    // MARK: - SwiftData

    @Query var allPapers: [Paper]

    // MARK: - State: Shared

    @State var pollTimer: Timer?
    @State var sidebarResizeStartWidth: CGFloat?
    @State var sidebarDragWidth: CGFloat?
    @State var fileCreationError: String?
    @State var fitToWidthTrigger = false

    // MARK: - State: LaTeX / Markdown specific

    @State var annotationExportError: String?
    @StateObject var compiledPDFSearchState = PDFSearchUIState()
    @Namespace var pdfTabIndicatorNamespace

    // MARK: - State: Code specific

    @State private var outputResizeStartWidth: CGFloat?
    @State private var outputDragTranslation: CGFloat?
    @Namespace var contentTabIndicatorNamespace

    // MARK: - Computed: Mode

    var documentMode: EditorDocumentMode { EditorDocumentMode(fileURL: fileURL) }
    var projectRoot: URL {
        workspaceState.treeViewRootURL(openPaths: openEditorPaths, selectedTab: mainWindowTab)
    }

    var text: String {
        get { documentState.text }
        nonmutating set { documentState.text = newValue }
    }

    var savedText: String {
        get { documentState.savedText }
        nonmutating set { documentState.savedText = newValue }
    }

    var lastModified: Date? {
        get { documentState.lastModified }
        nonmutating set { documentState.lastModified = newValue }
    }

    var toolbarStatus: ToolbarStatusState {
        get { documentState.toolbarStatus }
        nonmutating set { documentState.toolbarStatus = newValue }
    }

    var compiledPDF: PDFDocument? {
        get { documentState.compiledPDF }
        nonmutating set { documentState.compiledPDF = newValue }
    }

    var errors: [CompilationError] {
        get { documentState.errors }
        nonmutating set { documentState.errors = newValue }
    }

    var compileOutput: String {
        get { documentState.compileOutput }
        nonmutating set { documentState.compileOutput = newValue }
    }

    var isCompiling: Bool {
        get { documentState.isCompiling }
        nonmutating set { documentState.isCompiling = newValue }
    }

    var syncTarget: SyncTeXForwardResult? {
        get { documentState.syncTarget }
        nonmutating set { documentState.syncTarget = newValue }
    }

    var inverseSyncResult: SyncTeXInverseResult? {
        get { documentState.inverseSyncResult }
        nonmutating set { documentState.inverseSyncResult = newValue }
    }

    var latexAnnotations: [LaTeXAnnotation] {
        get { documentState.latexAnnotations }
        nonmutating set { documentState.latexAnnotations = newValue }
    }

    var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] {
        get { documentState.resolvedLaTeXAnnotations }
        nonmutating set { documentState.resolvedLaTeXAnnotations = newValue }
    }

    var selectedEditorRange: NSRange? {
        get { documentState.selectedEditorRange }
        nonmutating set { documentState.selectedEditorRange = newValue }
    }

    var pendingAnnotation: LaTeXEditorPendingAnnotation? {
        get { documentState.pendingAnnotation }
        nonmutating set { documentState.pendingAnnotation = newValue }
    }

    var referenceContextWriteID: UUID {
        get { documentState.referenceContextWriteID }
        nonmutating set { documentState.referenceContextWriteID = newValue }
    }

    var textBinding: Binding<String> {
        Binding(
            get: { documentState.text },
            set: { documentState.text = $0 }
        )
    }

    var pendingAnnotationBinding: Binding<LaTeXEditorPendingAnnotation?> {
        Binding(
            get: { documentState.pendingAnnotation },
            set: { documentState.pendingAnnotation = $0 }
        )
    }

    // MARK: - Computed: LaTeX themes

    static let editorThemes: [(name: String, bg: NSColor, fg: NSColor, comment: NSColor, command: NSColor, math: NSColor, env: NSColor, brace: NSColor)] = [
        ("Kaku Dark",
         NSColor(srgbRed: 0.082, green: 0.078, blue: 0.106, alpha: 1),
         NSColor(srgbRed: 0.929, green: 0.925, blue: 0.933, alpha: 1),
         NSColor(srgbRed: 0.43, green: 0.43, blue: 0.43, alpha: 1),
         NSColor(srgbRed: 0.37, green: 0.66, blue: 1.0, alpha: 1),
         NSColor(srgbRed: 0.38, green: 1.0, blue: 0.79, alpha: 1),
         NSColor(srgbRed: 0.635, green: 0.467, blue: 1.0, alpha: 1),
         NSColor(srgbRed: 1.0, green: 0.79, blue: 0.52, alpha: 1)),
        ("Monokai",
         NSColor(srgbRed: 0.15, green: 0.16, blue: 0.13, alpha: 1),
         NSColor(srgbRed: 0.97, green: 0.97, blue: 0.94, alpha: 1),
         NSColor(srgbRed: 0.45, green: 0.45, blue: 0.39, alpha: 1),
         NSColor(srgbRed: 0.40, green: 0.85, blue: 0.94, alpha: 1),
         NSColor(srgbRed: 0.90, green: 0.86, blue: 0.45, alpha: 1),
         NSColor(srgbRed: 0.65, green: 0.89, blue: 0.18, alpha: 1),
         NSColor(srgbRed: 0.98, green: 0.15, blue: 0.45, alpha: 1)),
        ("Dracula",
         NSColor(srgbRed: 0.16, green: 0.16, blue: 0.21, alpha: 1),
         NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1),
         NSColor(srgbRed: 0.38, green: 0.45, blue: 0.55, alpha: 1),
         NSColor(srgbRed: 0.51, green: 0.93, blue: 0.98, alpha: 1),
         NSColor(srgbRed: 0.94, green: 0.98, blue: 0.55, alpha: 1),
         NSColor(srgbRed: 0.94, green: 0.47, blue: 0.60, alpha: 1),
         NSColor(srgbRed: 1.0, green: 0.72, blue: 0.42, alpha: 1)),
        ("Nord",
         NSColor(srgbRed: 0.18, green: 0.20, blue: 0.25, alpha: 1),
         NSColor(srgbRed: 0.85, green: 0.87, blue: 0.91, alpha: 1),
         NSColor(srgbRed: 0.42, green: 0.48, blue: 0.55, alpha: 1),
         NSColor(srgbRed: 0.53, green: 0.75, blue: 0.82, alpha: 1),
         NSColor(srgbRed: 0.71, green: 0.81, blue: 0.66, alpha: 1),
         NSColor(srgbRed: 0.70, green: 0.56, blue: 0.75, alpha: 1),
         NSColor(srgbRed: 0.81, green: 0.63, blue: 0.48, alpha: 1)),
        ("Solarized",
         NSColor(srgbRed: 0.0, green: 0.17, blue: 0.21, alpha: 1),
         NSColor(srgbRed: 0.51, green: 0.58, blue: 0.59, alpha: 1),
         NSColor(srgbRed: 0.35, green: 0.43, blue: 0.46, alpha: 1),
         NSColor(srgbRed: 0.15, green: 0.55, blue: 0.82, alpha: 1),
         NSColor(srgbRed: 0.71, green: 0.54, blue: 0.0, alpha: 1),
         NSColor(srgbRed: 0.83, green: 0.21, blue: 0.51, alpha: 1),
         NSColor(srgbRed: 0.80, green: 0.29, blue: 0.09, alpha: 1)),
    ]

    var markdownTheme: MarkdownTheme {
        let theme = Self.editorThemes[editorTheme]
        return MarkdownTheme(
            backgroundColor: theme.bg,
            primaryTextColor: theme.fg,
            secondaryTextColor: theme.comment,
            accentColor: theme.command,
            headingColor: theme.brace,
            blockquoteColor: theme.comment.blended(withFraction: 0.35, of: theme.fg) ?? theme.comment,
            codeTextColor: theme.fg,
            codeBackgroundColor: theme.bg.blended(withFraction: 0.18, of: .black) ?? theme.bg,
            codeBorderColor: theme.fg.withAlphaComponent(0.08),
            syntaxMarkerColor: theme.comment
        )
    }

    /// True when no file is loaded (sentinel URL from container)
    var hasNoFile: Bool { fileURL.scheme == "canope" || !fileURL.isFileURL }

    // MARK: - Computed: LaTeX properties

    var previewPDFURL: URL { MarkdownPreviewRenderer.previewURL(for: fileURL) }

    var errorLines: Set<Int> {
        Set(errors.filter { !$0.isWarning && $0.line > 0 }.map { $0.line })
    }

    var canCreateAnnotationFromSelection: Bool {
        guard let range = selectedEditorRange, range.location != NSNotFound, range.length > 0 else {
            return false
        }
        return !resolvedLaTeXAnnotations.contains { resolved in
            resolved.resolvedRange == range
        }
    }

    var canAnnotateCurrentDocument: Bool {
        documentMode == .latex && canCreateAnnotationFromSelection
    }

    var isFileBrowserCreateMenuVisible: Bool {
        showSidebar && selectedSidebarSection == .files
    }

    private var showsLatexToolbarActions: Bool {
        documentMode == .latex
    }

    private var hasCompilationErrors: Bool {
        errors.contains(where: { !$0.isWarning })
    }

    private var documentPrimaryActionHelpText: String {
        switch documentMode {
        case .latex:
            return "Compiler (⌘B)"
        case .markdown:
            return "Exporter le PDF (⌘B)"
        case .python, .r:
            return "Exécuter (⌘B)"
        }
    }

    private var documentOutputLogHelpText: String {
        switch documentMode {
        case .latex:
            return "Console de compilation"
        case .markdown:
            return "Journal de l'export Markdown"
        case .python, .r:
            return "Journal d'exécution"
        }
    }

    private var isReferenceAnnotationSidebarVisible: Bool {
        showSidebar && selectedSidebarSection == .annotations
    }

    private var outputSummaryText: String {
        if errors.isEmpty {
            return documentMode.outputSuccessTitle
        }
        return "\(errors.filter { !$0.isWarning }.count) erreur(s), \(errors.filter { $0.isWarning }.count) avertissement(s)"
    }

    var sidebarAnnotations: [ResolvedLaTeXAnnotation] {
        resolvedLaTeXAnnotations.sorted { lhs, rhs in
            switch (lhs.resolvedRange, rhs.resolvedRange) {
            case let (left?, right?):
                return left.location < right.location
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.annotation.createdAt < rhs.annotation.createdAt
            }
        }
    }

    var diffGroups: [LaTeXEditorDiffGroup] {
        DiffEngine.reviewBlocks(old: savedText, new: text).map { LaTeXEditorDiffGroup(review: $0) }
    }

    // MARK: - Computed: Code properties

    var syntaxLanguage: CodeSyntaxLanguage {
        switch documentMode {
        case .python: return .python
        case .r: return .r
        case .latex, .markdown: return .python
        }
    }

    var codeTheme: CodeSyntaxTheme {
        let index = min(max(editorTheme, 0), CodeSyntaxTheme.allThemes.count - 1)
        return CodeSyntaxTheme.allThemes[index]
    }

    var outputDirectoryURL: URL {
        if let manualPreviewArtifact = codeDocumentState.manualPreviewArtifact {
            return manualPreviewArtifact.url.deletingLastPathComponent()
        }
        if let selectedRun = codeDocumentState.selectedRun {
            return selectedRun.artifactDirectory
        }
        return CodeRunService.artifactRootDirectoryURL(for: fileURL)
    }

    var outputStatusLabel: String {
        if codeDocumentState.manualPreviewArtifact != nil {
            return "Preview manuelle"
        }
        guard let selectedRun = codeDocumentState.selectedRun,
              let index = codeDocumentState.runHistory.firstIndex(where: { $0.runID == selectedRun.runID }) else {
            return "Aucun run"
        }
        let time = selectedRun.executedAt.formatted(date: .omitted, time: .standard)
        return "Run \(index + 1)/\(codeDocumentState.runHistory.count) · \(time) · \(selectedRun.artifacts.count) artefact\(selectedRun.artifacts.count > 1 ? "s" : "")"
    }

    // MARK: - Shared layout state (workspace-backed)

    var showSidebar: Bool {
        get { workspaceState.showSidebar }
        nonmutating set { workspaceState.showSidebar = newValue }
    }

    var selectedSidebarSection: LaTeXEditorSidebarSection {
        get { workspaceState.selectedSidebarSection }
        nonmutating set { workspaceState.selectedSidebarSection = newValue }
    }

    var sidebarWidth: CGFloat {
        get {
            let stored = CGFloat(workspaceState.sidebarWidth)
            guard stored.isFinite, stored > 0 else { return LaTeXEditorSidebarSizing.defaultWidth }
            return min(max(stored, LaTeXEditorSidebarSizing.minWidth), LaTeXEditorSidebarSizing.maxWidth)
        }
        nonmutating set {
            workspaceState.sidebarWidth = Double(min(max(newValue, LaTeXEditorSidebarSizing.minWidth), LaTeXEditorSidebarSizing.maxWidth))
        }
    }

    var isCompactDiffSidebar: Bool {
        sidebarWidth < 220
    }

    var showPDFPreview: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set { workspaceState.showPDFPreview = newValue }
    }

    var showEditorPane: Bool {
        get { workspaceState.showEditorPane }
        nonmutating set { workspaceState.showEditorPane = newValue }
    }

    var showErrors: Bool {
        get { workspaceState.showErrors }
        nonmutating set { workspaceState.showErrors = newValue }
    }

    var splitLayout: LaTeXEditorSplitLayout {
        get { workspaceState.splitLayout }
        nonmutating set {
            workspaceState.splitLayout = newValue
            workspaceState.showPDFPreview = newValue != .editorOnly
        }
    }

    var panelArrangement: PanelArrangement {
        get { workspaceState.panelArrangement }
        nonmutating set { workspaceState.panelArrangement = newValue }
    }

    var threePaneLeftWidth: CGFloat? {
        get { workspaceState.threePaneLeadingWidth.map { CGFloat($0) } }
        nonmutating set { workspaceState.threePaneLeadingWidth = newValue.map { Double($0) } }
    }

    var threePaneRightWidth: CGFloat? {
        get { workspaceState.threePaneTrailingWidth.map { CGFloat($0) } }
        nonmutating set { workspaceState.threePaneTrailingWidth = newValue.map { Double($0) } }
    }

    var isPDFLeadingInLayout: Bool {
        panelArrangement == .contentEditorTerminal
    }

    var editorFontSize: CGFloat {
        get { CGFloat(workspaceState.editorFontSize) }
        nonmutating set { workspaceState.editorFontSize = Double(newValue) }
    }

    var editorTheme: Int {
        get { min(max(workspaceState.editorTheme, 0), Self.editorThemes.count - 1) }
        nonmutating set { workspaceState.editorTheme = newValue }
    }

    var markdownEditorDisplayMode: MarkdownEditorDisplayMode {
        get { workspaceState.markdownEditorMode }
        nonmutating set { workspaceState.markdownEditorMode = newValue }
    }

    // Code: per-document visibility. LaTeX: shared visibility via showPDFPreview.
    var isOutputVisible: Bool {
        get { codeDocumentState.outputLayout.isOutputVisible }
        nonmutating set { codeDocumentState.updateOutputLayout { $0.isOutputVisible = newValue } }
    }

    private var isDocumentPreviewVisible: Bool {
        let hasReferences = !workspaceState.referencePaperIDs.isEmpty
        if documentMode == .latex {
            return showPDFPreview && (compiledPDF != nil || hasReferences)
        }
        // Markdown & other modes: show whenever toggled (for reference PDFs)
        return showPDFPreview
    }

    // MARK: - PDF pane tabs (shared for both modes)

    var pdfPaneTabs: [LaTeXEditorPdfPaneTab] {
        [.compiled] + workspaceState.referencePaperIDs.map { .reference($0) }
    }

    var selectedPdfTab: LaTeXEditorPdfPaneTab {
        if let id = workspaceState.selectedReferencePaperID {
            return .reference(id)
        }
        return .compiled
    }

    var layoutBeforeReference: LaTeXEditorSplitLayout? {
        get { workspaceState.layoutBeforeReference }
        nonmutating set { workspaceState.layoutBeforeReference = newValue }
    }

    // MARK: - Code-specific per-document state

    private var outputPlacement: CodeOutputPlacement {
        get { codeDocumentState.outputLayout.outputPlacement }
        nonmutating set {
            codeDocumentState.updateOutputLayout { $0.outputPlacement = newValue }
        }
    }

    private var primaryOutputWidth: CGFloat? {
        get { codeDocumentState.outputLayout.primaryOutputWidth.map { CGFloat($0) } }
        nonmutating set {
            codeDocumentState.updateOutputLayout { $0.primaryOutputWidth = newValue.map { Double($0) } }
        }
    }

    // MARK: - Body

    var body: some View {
        bodyCore
            .bodyAlerts(fileCreationError: $fileCreationError, annotationExportError: $annotationExportError)
            .background {
                Button("") { openFolderPicker() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .hidden()
            }
    }

    private var bodyCore: some View {
        VStack(spacing: 0) {
            editorToolbar
                .zIndex(30)
            AppChromeDivider(role: .shell)
                .zIndex(20)
            HSplitView {
                sidebarPane
                workAreaPane
            }
            .zIndex(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: pendingAnnotationBinding) { pending in
            LaTeXAnnotationNoteSheet(
                title: pending.existingAnnotationID == nil ? "Nouvelle annotation" : "Modifier l'annotation",
                selectedText: pending.draft.selectedText,
                initialNote: pending.draft.note,
                onCancel: { pendingAnnotation = nil },
                onSave: { note in saveLaTeXEditorPendingAnnotation(note: note) },
                onSaveAndSend: { note in saveLaTeXEditorPendingAnnotation(note: note, sendToClaude: true) }
            )
        }
        .onChange(of: inverseSyncResult) {
            if let result = inverseSyncResult {
                scrollEditorToInverseSyncResult(result)
                inverseSyncResult = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncTeXForwardSync)) { notification in
            guard documentMode == .latex else { return }
            if let line = notification.userInfo?["line"] as? Int { forwardSync(line: line) }
        }
        .onAppear {
            if !AppRuntime.isRunningTests { ClaudeIDEBridgeService.shared.startIfNeeded() }
            prepareEditorStateForDisplay()
            syncBibliographyCommandRouter()
        }
        .onDisappear {
            stopFileWatcher()
            if documentMode.isRunnableCode { persistDocumentWorkspaceState() }
            if isActive { BibliographyCommandRouter.shared.clearActions() }
        }
        .onChange(of: isActive) {
            if isActive {
                refreshEditorStateForActivation()
                configureDocumentLayoutIfNeeded()
                startFileWatcher()
                if !documentMode.isRunnableCode { refreshSplitGrabAreas() }
                syncBibliographyCommandRouter()
            } else {
                stopFileWatcher()
                if documentMode.isRunnableCode { persistDocumentWorkspaceState() }
                BibliographyCommandRouter.shared.clearActions()
            }
        }
        .onChange(of: fileURL) {
            stopFileWatcher()
            toolbarStatus = .idle
            documentState.resetTransientNavigationState()
            prepareEditorStateForDisplay()
            syncBibliographyCommandRouter()
        }
        .onChange(of: workspaceState.referencePaperIDs) { syncBibliographyCommandRouter() }
        .onChange(of: workspaceState.selectedReferencePaperID) { syncBibliographyCommandRouter() }
        .onChange(of: panelArrangement) {
            threePaneLeftWidth = nil; threePaneRightWidth = nil
            if !documentMode.isRunnableCode { refreshSplitGrabAreas() }
        }
        .onChange(of: showSidebar) {
            if documentMode.isRunnableCode { onPersistWorkspaceState?() }
            else { refreshSplitGrabAreas() }
        }
        .onChange(of: showPDFPreview) { if !documentMode.isRunnableCode { refreshSplitGrabAreas() } }
        .onChange(of: showTerminal) { if !documentMode.isRunnableCode { refreshSplitGrabAreas() } }
        .onChange(of: splitLayout) { if !documentMode.isRunnableCode { refreshSplitGrabAreas() } }
        .background(codePersistenceObservers)
    }

    /// Extracted to reduce type-checker load on bodyCore
    @ViewBuilder
    private var codePersistenceObservers: some View {
        Color.clear
            .onChange(of: codeDocumentState.outputLayout) { persistDocumentWorkspaceState() }
            .onChange(of: codeDocumentState.showLogs) { persistDocumentWorkspaceState() }
            .onChange(of: codeDocumentState.selectedRunID) { persistDocumentWorkspaceState() }
            .onChange(of: codeDocumentState.selectedArtifactPath) { persistDocumentWorkspaceState() }
            .onChange(of: codeDocumentState.secondaryArtifactPath) { persistDocumentWorkspaceState() }
            .onChange(of: workspaceState.sidebarWidth) { onPersistWorkspaceState?() }
            .onChange(of: workspaceState.editorFontSize) { onPersistWorkspaceState?() }
            .onChange(of: workspaceState.markdownEditorMode) { onPersistWorkspaceState?() }
    }

    // MARK: - Work Area Pane

    @ViewBuilder
    var workAreaPane: some View {
        Group {
            if isActive && showTerminal && showEditorPane {
                horizontalThreePaneLayout
            } else if isActive && showTerminal && !showEditorPane && isContentPaneVisible {
                HSplitView {
                    embeddedTerminalPane
                    contentPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if isActive && showTerminal {
                embeddedTerminalPane
            } else {
                editorAndContentPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showTerminal)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showPDFPreview)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showEditorPane)
    }

    // MARK: - Three-Pane Layout

    private var threePaneRoles: (EditorThreePaneRole, EditorThreePaneRole, EditorThreePaneRole) {
        switch panelArrangement {
        case .terminalEditorContent:
            return (.terminal, .editor, .content)
        case .editorContentTerminal:
            return (.editor, .content, .terminal)
        case .contentEditorTerminal:
            return (.content, .editor, .terminal)
        }
    }

    @ViewBuilder
    private func threePaneView(for role: EditorThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .content:
            contentPane
        }
    }

    var horizontalThreePaneLayout: some View {
        let roles = threePaneRoles
        let isCode = documentMode.isRunnableCode
        let showContent = isCode ? isOutputVisible : isDocumentPreviewVisible
        let config = isCode
            ? ThreePaneLayoutConfig.code(arrangement: panelArrangement, contentVisible: showContent)
            : ThreePaneLayoutConfig.latex(arrangement: panelArrangement, contentVisible: showContent)
        let dragEnd: (() -> Void)? = isCode ? { [self] in persistDocumentWorkspaceState() } : nil
        return ThreePaneLayoutView(
            config: config,
            leadingWidth: Binding(get: { threePaneLeftWidth }, set: { threePaneLeftWidth = $0 }),
            trailingWidth: Binding(get: { threePaneRightWidth }, set: { threePaneRightWidth = $0 }),
            leading: { threePaneView(for: roles.0) },
            middle: { threePaneView(for: roles.1) },
            trailing: { threePaneView(for: roles.2) },
            onDragEnd: dragEnd
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Editor And Content Pane (no terminal)

    @ViewBuilder
    var editorAndContentPane: some View {
        if documentMode.isRunnableCode {
            codeEditorAndContentPane
        } else {
            latexEditorAndContentPane
        }
    }

    // Code mode: editor + output (right or bottom)
    @ViewBuilder
    private var codeEditorAndContentPane: some View {
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

    // LaTeX mode: editor + PDF (split layouts)
    @ViewBuilder
    private var latexEditorAndContentPane: some View {
        if !showEditorPane && !isDocumentPreviewVisible {
            hiddenEditorPlaceholderPane
        } else if !showEditorPane {
            contentPane
        } else if !isDocumentPreviewVisible {
            editorPane
        } else if splitLayout == .horizontal {
            HSplitView {
                if isPDFLeadingInLayout { contentPane }
                editorPane
                if !isPDFLeadingInLayout { contentPane }
            }
        } else if splitLayout == .vertical {
            VSplitView {
                if isPDFLeadingInLayout { contentPane }
                editorPane
                if !isPDFLeadingInLayout { contentPane }
            }
        } else {
            editorPane
        }
    }

    var hiddenEditorPlaceholderPane: some View {
        ContentUnavailableView(
            "Panneau LaTeX fermé",
            systemImage: "doc.text",
            description: Text("Rouvre le panneau LaTeX depuis la barre d'outils, ou garde seulement le terminal et/ou le PDF.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Output Right Placement (Code mode)

    private func resolveOutputRightWidths(totalWidth: CGFloat) -> (editor: CGFloat, output: CGFloat) {
        let minEditor: CGFloat = 220
        let minOutput: CGFloat = 200
        let maxOutput = max(minOutput, totalWidth - minEditor)

        if let snap = outputResizeStartWidth {
            let dragged = snap - (outputDragTranslation ?? 0)
            let clamped = min(max(dragged, minOutput), maxOutput)
            return (max(minEditor, totalWidth - clamped), clamped)
        }
        let seeded = primaryOutputWidth ?? (totalWidth / 2)
        let clamped = min(max(seeded, minOutput), maxOutput)
        return (max(minEditor, totalWidth - clamped), clamped)
    }

    private var outputRightPlacementPane: some View {
        GeometryReader { proxy in
            let dividerWidth = LaTeXEditorThreePaneSizing.dividerWidth
            let totalWidth = max(0, proxy.size.width - dividerWidth)
            let widths = resolveOutputRightWidths(totalWidth: totalWidth)
            let minOutput: CGFloat = 200
            let maxOutput = max(minOutput, totalWidth - 220)

            HStack(spacing: 0) {
                editorPane
                    .frame(width: widths.editor)

                AppChromeResizeHandle(
                    width: dividerWidth,
                    onHoverChanged: { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    },
                    dragGesture: AnyGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if outputResizeStartWidth == nil {
                                    outputResizeStartWidth = widths.output
                                }
                                outputDragTranslation = value.translation.width
                                let start = outputResizeStartWidth ?? widths.output
                                primaryOutputWidth = min(max(start - value.translation.width, minOutput), maxOutput)
                            }
                            .onEnded { _ in
                                outputResizeStartWidth = nil
                                outputDragTranslation = nil
                                persistDocumentWorkspaceState()
                            }
                    ),
                    axis: .vertical
                )

                contentPane
                    .frame(width: widths.output)
            }
        }
        .transaction { t in t.animation = nil }
    }

    // MARK: - Embedded Terminal

    var embeddedTerminalPane: some View {
        TerminalPanel(
            workspaceState: terminalWorkspaceState,
            document: nil,
            isVisible: isActive && showTerminal,
            topInset: 0,
            showsInlineControls: false,
            startupWorkingDirectory: isEditorSectionActive ? projectRoot : nil
        )
        .frame(minWidth: 160, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor Pane

    var editorPane: some View {
        VStack(spacing: 0) {
            if let editorTabBar {
                editorTabBar
                AppChromeDivider(role: .panel)
            }

            // Text editor: branch on mode (or placeholder when no file)
            if hasNoFile {
                ContentUnavailableView(
                    "Ouvrir un fichier",
                    systemImage: "doc.text",
                    description: Text("Ouvre un fichier .tex, .bib, .md, .py ou .R pour commencer")
                )
            } else if documentMode.isRunnableCode {
                CodeTextEditor(
                    text: textBinding,
                    language: syntaxLanguage,
                    fontSize: editorFontSize,
                    theme: codeTheme,
                    onTextChange: {}
                )
            } else if documentMode.usesDedicatedInlineEditor && markdownEditorDisplayMode == .livePreview {
                MarkdownLiveEditor(
                    fileURL: fileURL,
                    text: textBinding,
                    fontSize: editorFontSize,
                    theme: markdownTheme,
                    displayMode: markdownEditorDisplayMode,
                    onTextChange: { setToolbarStatus(.idle) }
                )
            } else {
                LaTeXTextEditor(
                    fileURL: fileURL,
                    text: textBinding,
                    errorLines: errorLines,
                    fontSize: editorFontSize,
                    theme: Self.editorThemes[editorTheme],
                    baselineText: savedText,
                    resolvedAnnotations: resolvedLaTeXAnnotations,
                    onSelectionChange: { selectedEditorRange = $0 },
                    onAnnotationActivate: beginEditingAnnotation,
                    onCreateAnnotationFromSelection: beginAnnotationFromSelection,
                    onTextChange: reconcileAnnotations
                )
            }

            // Output log: LaTeX errors or Code logs
            if documentMode.isRunnableCode {
                if codeDocumentState.showLogs {
                    AppChromeDivider(role: .panel)
                    codeLogPanel
                }
            } else {
                if showErrors {
                    AppChromeDivider(role: .panel)
                    latexErrorPanel
                }
            }
        }
        .frame(minWidth: documentMode.isRunnableCode ? 200 : 160,
               idealWidth: documentMode.isRunnableCode ? 680 : 620,
               maxWidth: .infinity,
               maxHeight: .infinity)
        .layoutPriority(1)
    }

    private var codeLogPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: codeDocumentState.isRunning ? "hourglass" : "terminal")
                    .foregroundStyle(codeDocumentState.isRunning ? AppChromePalette.info : .secondary)
                Text(codeDocumentState.lastCommandDescription.isEmpty ? "Journal d'exécution" : codeDocumentState.lastCommandDescription)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button(action: { codeDocumentState.showLogs = false }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppChromePalette.surfaceSubbar)

            ScrollView {
                Text(codeDocumentState.outputLog.isEmpty ? "Aucune sortie" : codeDocumentState.outputLog)
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

    private var latexErrorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: errors.contains(where: { !$0.isWarning }) ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(errors.contains(where: { !$0.isWarning }) ? .red : .green)
                Text(outputSummaryText)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { showErrors = false }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppChromePalette.surfaceSubbar)

            ScrollView {
                Text(compileOutput.isEmpty ? "Aucune sortie" : compileOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
        .frame(height: 150)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content Pane (PDF or Output + Reference tabs)

    var contentPane: some View {
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
                primaryContentView
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
                                    cancelReferenceAnnotationNoteEdit(for: id)
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
        .frame(minWidth: documentMode.isRunnableCode ? 240 : 180,
               idealWidth: documentMode.isRunnableCode ? 380 : 320,
               maxWidth: .infinity,
               maxHeight: .infinity)
    }

    private var contentPaneTabs: [LaTeXEditorPdfPaneTab] {
        pdfPaneTabs
    }

    var selectedContentTab: LaTeXEditorPdfPaneTab {
        selectedPdfTab
    }

    private var activePDFSearchState: PDFSearchUIState? {
        switch selectedContentTab {
        case .compiled:
            return compiledPDF == nil ? nil : compiledPDFSearchState
        case .reference(let id):
            return workspaceState.referencePDFUIStates[id]?.searchState
        }
    }

    @ViewBuilder
    private var primaryContentView: some View {
        if documentMode.isRunnableCode {
            outputWorkspace
        } else if let pdf = compiledPDF {
            PDFPreviewView(
                document: pdf,
                syncTarget: documentMode == .latex && selectedPdfTab == .compiled ? syncTarget : nil,
                onInverseSync: documentMode == .latex ? { result in inverseSyncResult = result } : nil,
                allowsInverseSync: documentMode == .latex,
                restoredPageIndex: documentState.compiledPDFRequestedRestorePageIndex,
                fitToWidthTrigger: selectedPdfTab == .compiled ? fitToWidthTrigger : false,
                searchState: compiledPDFSearchState,
                onCurrentPageChanged: { pageIndex in
                    documentState.compiledPDFLastKnownPageIndex = pageIndex
                }
            )
        } else {
            ContentUnavailableView(
                documentMode.emptyPreviewTitle,
                systemImage: "doc.text",
                description: Text(documentMode.emptyPreviewDescription)
            )
        }
    }

    var outputWorkspace: some View {
        CodeOutputWorkspace(
            documentState: codeDocumentState,
            outputStatusLabel: outputStatusLabel,
            revealArtifactDirectoryInFinder: revealArtifactDirectoryInFinder,
            refreshSelectedRun: refreshSelectedRun,
            persist: persistDocumentWorkspaceState
        )
    }

    @ViewBuilder
    func contentTabButton(_ tab: LaTeXEditorPdfPaneTab) -> some View {
        if documentMode.isRunnableCode {
            codeContentTabButton(tab)
        } else {
            pdfTabButton(tab)
        }
    }

    // Code-style content tab button
    @ViewBuilder
    private func codeContentTabButton(_ tab: LaTeXEditorPdfPaneTab) -> some View {
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

    // Code-mode content tab selection
    private func selectContentTab(_ tab: LaTeXEditorPdfPaneTab) {
        switch tab {
        case .compiled:
            workspaceState.selectedReferencePaperID = nil
        case .reference(let id):
            workspaceState.selectedReferencePaperID = id
        }
    }

    // Code-mode content tab close
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

    // Code-mode reference open
    private func openCodeReference(_ paper: Paper) {
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

    // MARK: - Toolbar

    var editorToolbar: some View {
        HStack(spacing: 0) {
            // Left side: collapsible clusters, scrollable when all expanded
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    fileToolbarClusterView
                    documentActionsCluster
                    markdownFormattingToolbarClusterView
                    if documentMode.isRunnableCode {
                        codeActiveReferenceToolbarView
                    } else {
                        activeReferenceToolbarView
                    }
                    activePDFSearchToolbarView
                }
            }

            Spacer(minLength: 4)

            // Right side: always visible
            HStack(spacing: 8) {
                panneauxCluster
                dispositionCluster
                editorAppearanceToolbarClusterView
                terminalToolbarClusterView
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
        .zIndex(30)
        .background {
            Button("") { openActivePDFSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    /// Mode-specific document actions (compile/run, save, errors/logs)
    @ViewBuilder
    private var documentActionsCluster: some View {
        if documentMode.isRunnableCode {
            codeDocumentActionsCluster
        } else {
            documentToolbarClusterView
        }
    }

    private var codeDocumentActionsCluster: some View {
        toolbarCluster(zone: .primary, title: documentMode.primaryClusterTitle) {
            Button(action: runScript) {
                Image(systemName: codeDocumentState.isRunning ? "hourglass" : "play.fill")
                    .foregroundStyle(AppChromePalette.success)
            }
            .buttonStyle(.plain)
            .disabled(codeDocumentState.isRunning)
            .appChromeQuickHelp("Exécuter (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            Button(action: saveFile) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Enregistrer")

            Button(action: { codeDocumentState.showLogs.toggle() }) {
                Image(systemName: codeDocumentState.showLogs ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    .foregroundStyle(codeDocumentState.showLogs ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Journal d'exécution")
        }
    }

    @ViewBuilder
    private var markdownFormattingToolbarClusterView: some View {
        if documentMode == .markdown {
            toolbarCluster(zone: .primary, title: "Format", collapsible: true) {
                markdownModeToggle

                ToolbarIconButton(
                    systemName: "textformat.size.larger",
                    foregroundStyle: .secondary,
                    helpText: "Basculer le titre Markdown"
                ) {
                    sendMarkdownCommand(.heading)
                }

                ToolbarIconButton(
                    systemName: "list.bullet",
                    foregroundStyle: .secondary,
                    helpText: "Basculer la liste"
                ) {
                    sendMarkdownCommand(.list)
                }

                ToolbarIconButton(
                    systemName: "text.quote",
                    foregroundStyle: .secondary,
                    helpText: "Basculer la citation"
                ) {
                    sendMarkdownCommand(.blockquote)
                }

                ToolbarIconButton(
                    systemName: "curlybraces.square",
                    foregroundStyle: .secondary,
                    helpText: "Insérer un bloc de code"
                ) {
                    sendMarkdownCommand(.codeBlock)
                }
            }
        }
    }

    private var markdownModeToggle: some View {
        HStack(spacing: 4) {
            ForEach(MarkdownEditorDisplayMode.allCases, id: \.self) { mode in
                MarkdownToolbarModeButton(
                    title: mode.title,
                    isSelected: markdownEditorDisplayMode == mode
                ) {
                    markdownEditorDisplayMode = mode
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous)
                .fill(AppChromePalette.hoverFill.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous)
                .stroke(AppChromePalette.clusterStroke.opacity(0.7), lineWidth: 1)
        )
    }

    private var isContentPaneVisible: Bool {
        documentMode.isRunnableCode ? isOutputVisible : isDocumentPreviewVisible
    }

    /// 4 pane toggles: Files, Editor, Terminal, Content
    private var panneauxCluster: some View {
        toolbarCluster(zone: .trailing, title: "Panneaux") {
            Button(action: {
                AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                    showSidebar.toggle()
                }
            }) {
                Image(systemName: "folder")
                    .foregroundStyle(showSidebar ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Fichiers")

            Button(action: {
                AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                    toggleEditorPaneVisibility()
                }
            }) {
                Image(systemName: "doc.text")
                    .foregroundStyle(showEditorPane ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Éditeur")
            .disabled(showEditorPane && !showTerminal && !isContentPaneVisible)

            Button(action: {
                AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                    showTerminal.toggle()
                }
            }) {
                Image(systemName: "terminal")
                    .foregroundStyle(showTerminal ? AppChromePalette.success : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Terminal")

            Button(action: {
                AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                    if documentMode.isRunnableCode {
                        isOutputVisible.toggle()
                    } else if showPDFPreview {
                        splitLayout = .editorOnly
                    } else {
                        splitLayout = .horizontal
                    }
                }
            }) {
                Image(systemName: documentMode.isRunnableCode ? "chart.xyaxis.line" : "doc.richtext")
                    .foregroundStyle(isContentPaneVisible ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp(documentMode.isRunnableCode ? "Output" : "PDF")
        }
    }

    /// Shared disposition menu: panel arrangement
    private var dispositionCluster: some View {
        toolbarCluster(zone: .trailing) {
            Menu {
                Section("Ordre des panneaux") {
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
                                Text(arrangement.title(contentLabel: documentMode.isRunnableCode ? "Output" : "PDF"))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Disposition des panneaux")
        }
    }

    private var fileToolbarClusterView: some View {
        toolbarCluster(zone: .leading, title: "Dossier") {
            Button(action: openFolderPicker) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Ouvrir un dossier (⇧⌘O)")

            if !hasNoFile {
                AppChromeStatusCapsule(status: toolbarStatus)
            }

            if !isFileBrowserCreateMenuVisible {
                Menu {
                    createFileMenuContent
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .appChromeQuickHelp("Créer un nouveau fichier éditable")
            }
        }
    }

    private var documentToolbarClusterView: some View {
        EditorDocumentToolbarClusterView(
            title: documentMode.primaryClusterTitle,
            showsLatexActions: showsLatexToolbarActions,
            isCompiling: isCompiling,
            compiledPDFAvailable: selectedPdfTab == .compiled && compiledPDF != nil,
            activeMarkdownExportFileName: activeMarkdownExportFileName,
            companionExportFileName: compiledPDFCompanionExportFileName,
            canAnnotateCurrentDocument: canAnnotateCurrentDocument,
            showErrors: showErrors,
            hasCompilationErrors: hasCompilationErrors,
            primaryActionHelpText: documentPrimaryActionHelpText,
            outputLogHelpText: documentOutputLogHelpText,
            shortcutIdentity: fileURL.path,
            onRunPrimaryAction: runPrimaryDocumentAction,
            onSave: saveFile,
            onExportToActiveMarkdown: exportCompiledAnnotationsToActiveMarkdownAction,
            onExportToCompanionMarkdown: exportCompiledPDFAnnotationsToCompanionMarkdown,
            onChooseExportDestination: chooseCompiledPDFAnnotationsMarkdownDestination,
            onBeginAnnotation: beginAnnotationFromSelection,
            onReflow: reflowParagraphs,
            onToggleErrors: { showErrors.toggle() }
        )
    }

    private var referencePickerToolbarClusterView: some View {
        toolbarCluster(zone: .primary, title: "Réf.") {
            Menu {
                let openPapers = availableReferencePapers
                if openPapers.isEmpty {
                    Text("Aucun article disponible")
                } else {
                    ForEach(openPapers) { paper in
                        Button {
                            openReference(paper)
                        } label: {
                            let alreadyOpen = pdfPaneTabs.contains(.reference(paper.id))
                            Text("\(alreadyOpen ? "✓ " : "")\(paper.authorsShort) (\(paper.year.map { String($0) } ?? "—")) — \(paper.title)")
                        }
                    }
                }
            } label: {
                Image(systemName: pdfPaneTabs.count > 1 ? "book.fill" : "book")
                    .foregroundStyle(pdfPaneTabs.count > 1 ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Ouvrir un article de référence")
        }
    }

    private var activeReferenceToolbarView: some View {
        ActiveReferenceToolbarView(
            referenceState: activeReferencePDFState,
            annotationCount: activeReferenceAnnotationCount,
            isAnnotationSidebarVisible: isReferenceAnnotationSidebarVisible,
            activeMarkdownFileName: activeMarkdownExportFileName,
            companionExportFileName: activeReferenceCompanionExportFileName,
            onChangeSelectedColor: changeSelectedReferenceAnnotationColor,
            onFitToWidth: fitToWidth,
            onRefresh: refreshCurrentReference,
            onSave: saveCurrentReferencePDF,
            onExportToActiveMarkdown: exportActiveReferenceAnnotationsToActiveMarkdownAction,
            onExportToCompanionMarkdown: exportActiveReferencePDFAnnotationsToCompanionMarkdown,
            onExportToChosenMarkdownFile: chooseActiveReferencePDFAnnotationsMarkdownDestination,
            onDeleteSelected: deleteSelectedReferenceAnnotation,
            onDeleteAll: deleteAllReferenceAnnotations,
            onToggleAnnotations: toggleReferenceAnnotationSidebar
        )
    }

    private var activePDFSearchToolbarView: some View {
        ActivePDFSearchToolbarView(searchState: activePDFSearchState)
    }

    private var editorAppearanceToolbarClusterView: some View {
        toolbarCluster(zone: .trailing, title: "Ed.") {
            Menu {
                ForEach([11, 12, 13, 14, 15, 16, 18, 20, 24], id: \.self) { size in
                    Button {
                        editorFontSize = CGFloat(size)
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
            .appChromeQuickHelp("Taille police")

            Menu {
                ForEach(0..<Self.editorThemes.count, id: \.self) { i in
                    Button {
                        editorTheme = i
                    } label: {
                        HStack {
                            if i == editorTheme { Image(systemName: "checkmark") }
                            Text(Self.editorThemes[i].name)
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Thème éditeur")
        }
    }

    @ViewBuilder
    private var terminalToolbarClusterView: some View {
        if showTerminal {
            Menu {
                Button(action: addTerminalTab) {
                    Label("Nouveau terminal", systemImage: "plus")
                }
                Button(action: terminalAppearanceStore.presentSettings) {
                    Label("Réglages du terminal", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .appChromeQuickHelp("Terminal")
        }
    }

    // Code-mode reference toolbar
    private var codeActiveReferenceToolbarView: some View {
        ActiveReferenceToolbarView(
            referenceState: codeActiveReferencePDFState,
            annotationCount: codeActiveReferenceAnnotationCount,
            isAnnotationSidebarVisible: false,
            activeMarkdownFileName: nil,
            companionExportFileName: codeActiveReferenceCompanionExportFileName,
            onChangeSelectedColor: codeChangeSelectedReferenceAnnotationColor,
            onFitToWidth: { fitToWidthTrigger.toggle() },
            onRefresh: codeRefreshCurrentReference,
            onSave: codeSaveCurrentReferencePDF,
            onExportToActiveMarkdown: nil,
            onExportToCompanionMarkdown: codeExportActiveReferencePDFAnnotationsToCompanionMarkdown,
            onExportToChosenMarkdownFile: codeChooseActiveReferencePDFAnnotationsMarkdownDestination,
            onDeleteSelected: codeDeleteSelectedReferenceAnnotation,
            onDeleteAll: codeDeleteAllReferenceAnnotations,
            onToggleAnnotations: {}
        )
    }

    private func openActivePDFSearch() {
        activePDFSearchState?.present()
    }

    // MARK: - Shared Toolbar Helpers

    func toolbarCluster<Content: View>(
        zone: ToolbarZone,
        title: String? = nil,
        collapsible: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AppChromeToolbarCluster(zone: zone, title: title, collapsible: collapsible, content: content)
    }

    @ViewBuilder
    var createFileMenuContent: some View {
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

    func toggleSidebar(section: LaTeXEditorSidebarSection? = nil) {
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            if let section {
                if showSidebar && selectedSidebarSection == section {
                    showSidebar = false
                } else {
                    selectedSidebarSection = section
                    showSidebar = true
                }
            } else {
                showSidebar.toggle()
            }
        }
    }

    func toggleEditorPaneVisibility() {
        guard !(showEditorPane && !showTerminal && !isContentPaneVisible) else { return }
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            showEditorPane.toggle()
        }
    }

    func toggleTerminalVisibility() {
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            showTerminal.toggle()
        }
    }

    func toggleReferenceAnnotationSidebar() {
        toggleSidebar(section: .annotations)
    }

}

private struct MarkdownToolbarModeButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? AppChromePalette.selectedAccent : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: AppChromeMetrics.toolbarButtonSize - 2)
                .background(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius - 1, style: .continuous)
                        .stroke(borderColor, lineWidth: isSelected ? 1 : 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius - 1, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius - 1, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }

    private var backgroundFill: Color {
        if isSelected {
            return AppChromePalette.selectedAccentFill.opacity(0.9)
        }
        if isHovered {
            return AppChromePalette.hoverFill.opacity(0.9)
        }
        return .clear
    }

    private var borderColor: Color {
        isSelected ? AppChromePalette.selectedAccentStroke : AppChromePalette.clusterStroke.opacity(0.45)
    }
}

// MARK: - Alert helper (split to avoid Swift type-checker timeout)

private extension View {
    func bodyAlerts(
        fileCreationError: Binding<String?>,
        annotationExportError: Binding<String?>
    ) -> some View {
        self
            .alert("Impossible de créer le fichier", isPresented: Binding(
                get: { fileCreationError.wrappedValue != nil },
                set: { if !$0 { fileCreationError.wrappedValue = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(fileCreationError.wrappedValue ?? "")
            }
            .alert("Impossible d'exporter les annotations", isPresented: Binding(
                get: { annotationExportError.wrappedValue != nil },
                set: { if !$0 { annotationExportError.wrappedValue = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(annotationExportError.wrappedValue ?? "")
            }
    }
}

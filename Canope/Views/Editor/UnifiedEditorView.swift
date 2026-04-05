import AppKit
import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let syncTeXScrollToLine = Notification.Name("syncTeXScrollToLine")
    static let syncTeXForwardSync = Notification.Name("syncTeXForwardSync")
    static let editorRevealLocation = Notification.Name("editorRevealLocation")
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
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    @ObservedObject var codeDocumentState: CodeDocumentUIState
    var onOpenPDF: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var openPaperIDs: [UUID] = []
    var editorTabBar: AnyView? = nil
    var onPersistWorkspaceState: (() -> Void)?

    // MARK: - SwiftData

    @Query var allPapers: [Paper]

    // MARK: - State: Shared

    @State var text = ""
    @State var savedText = ""
    @State var lastModified: Date?
    @State var pollTimer: Timer?
    @State var sidebarResizeStartWidth: CGFloat?
    @State var sidebarDragWidth: CGFloat?
    @State private var toolbarStatus: ToolbarStatusState = .idle
    @State private var toolbarStatusClearWorkItem: DispatchWorkItem?
    @State private var fileCreationError: String?
    @State var fitToWidthTrigger = false

    // MARK: - State: LaTeX / Markdown specific

    @State var compiledPDF: PDFDocument?
    @State var errors: [CompilationError] = []
    @State private var compileOutput: String = ""
    @State private var isCompiling = false
    @State var syncTarget: SyncTeXForwardResult?
    @State var inverseSyncResult: SyncTeXInverseResult?
    @State private var latexAnnotations: [LaTeXAnnotation] = []
    @State private var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] = []
    @State private var selectedEditorRange: NSRange?
    @State private var pendingAnnotation: LaTeXEditorPendingAnnotation?
    @State var annotationExportError: String?
    @State var referenceContextWriteID = UUID()
    @Namespace var pdfTabIndicatorNamespace

    // MARK: - State: Code specific

    @State private var outputResizeStartWidth: CGFloat?
    @State private var outputDragTranslation: CGFloat?
    @Namespace var contentTabIndicatorNamespace

    // MARK: - Computed: Mode

    var documentMode: EditorDocumentMode { EditorDocumentMode(fileURL: fileURL) }
    var projectRoot: URL {
        if let root = workspaceState.workspaceRoot { return root }
        if hasNoFile { return FileManager.default.homeDirectoryForCurrentUser }
        return fileURL.deletingLastPathComponent()
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
        documentMode == .latex ? "Compiler (⌘B)" : "Rendre le PDF (⌘B)"
    }

    private var documentOutputLogHelpText: String {
        documentMode == .latex ? "Console de compilation" : "Journal du rendu"
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
        get { LaTeXEditorSidebarSection(rawValue: workspaceState.selectedSidebarSection) ?? .files }
        nonmutating set { workspaceState.selectedSidebarSection = newValue.rawValue }
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
        get { LaTeXEditorSplitLayout(rawValue: workspaceState.splitLayout) ?? .editorOnly }
        nonmutating set {
            workspaceState.splitLayout = newValue.rawValue
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

    // Code: per-document visibility. LaTeX: shared visibility via showPDFPreview.
    var isOutputVisible: Bool {
        get { codeDocumentState.outputLayout.isOutputVisible }
        nonmutating set { codeDocumentState.updateOutputLayout { $0.isOutputVisible = newValue } }
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
        get { workspaceState.layoutBeforeReference.flatMap(LaTeXEditorSplitLayout.init(rawValue:)) }
        nonmutating set { workspaceState.layoutBeforeReference = newValue?.rawValue }
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
            AppChromeDivider(role: .shell)
            HSplitView {
                sidebarPane
                workAreaPane
            }
        }
        .sheet(item: $pendingAnnotation) { pending in
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
            if hasNoFile { text = ""; savedText = "" }
            else {
                loadFile()
                if !documentMode.isRunnableCode { loadExistingPDF() }
                if isActive { startFileWatcher() }
                if !documentMode.isRunnableCode { refreshSplitGrabAreas() }
            }
        }
        .onDisappear {
            stopFileWatcher()
            if documentMode.isRunnableCode { persistDocumentWorkspaceState() }
        }
        .onChange(of: isActive) {
            if isActive {
                loadFile(); startFileWatcher()
                if !documentMode.isRunnableCode { refreshSplitGrabAreas() }
            } else {
                stopFileWatcher()
                if documentMode.isRunnableCode { persistDocumentWorkspaceState() }
            }
        }
        .onChange(of: fileURL) {
            stopFileWatcher()
            toolbarStatus = .idle
            if hasNoFile {
                text = ""; savedText = ""
            } else {
                loadFile()
                if !documentMode.isRunnableCode {
                    loadExistingPDF()
                    latexAnnotations = documentMode == .latex ? LaTeXAnnotationStore.load(for: fileURL) : []
                    reconcileAnnotations()
                }
                if isActive { startFileWatcher() }
            }
        }
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
        let showContent = isCode ? isOutputVisible : showPDFPreview
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
        if !showEditorPane && !showPDFPreview {
            hiddenEditorPlaceholderPane
        } else if !showEditorPane {
            contentPane
        } else if !showPDFPreview {
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
            startupWorkingDirectory: projectRoot
        )
        .frame(minWidth: 160, idealWidth: 320, maxWidth: .infinity)
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
                    description: Text("Ouvre un fichier .tex, .md, .py ou .R pour commencer")
                )
            } else if documentMode.isRunnableCode {
                CodeTextEditor(
                    text: $text,
                    language: syntaxLanguage,
                    fontSize: editorFontSize,
                    theme: codeTheme,
                    onTextChange: {}
                )
            } else {
                LaTeXTextEditor(
                    fileURL: fileURL,
                    text: $text,
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
               maxWidth: .infinity)
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
               maxWidth: .infinity)
    }

    private var contentPaneTabs: [LaTeXEditorPdfPaneTab] {
        pdfPaneTabs
    }

    private var selectedContentTab: LaTeXEditorPdfPaneTab {
        selectedPdfTab
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
                fitToWidthTrigger: selectedPdfTab == .compiled ? fitToWidthTrigger : false
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
        HStack(spacing: 8) {
            // Left side: file info + mode-specific actions + references
            fileToolbarClusterView
            documentActionsCluster
            referencePickerToolbarClusterView
            if documentMode.isRunnableCode {
                codeActiveReferenceToolbarView
            } else {
                activeReferenceToolbarView
            }

            Spacer(minLength: 8)

            // Right side: shared layout controls
            panneauxCluster
            dispositionCluster
            editorAppearanceToolbarClusterView
            terminalToolbarClusterView
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
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
            .help("Exécuter (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            Button(action: saveFile) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Enregistrer")

            Button(action: { codeDocumentState.showLogs.toggle() }) {
                Image(systemName: codeDocumentState.showLogs ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    .foregroundStyle(codeDocumentState.showLogs ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .help("Journal d'exécution")
        }
    }

    private var isContentPaneVisible: Bool {
        documentMode.isRunnableCode ? isOutputVisible : showPDFPreview
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
            .help("Fichiers")

            Button(action: {
                AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                    toggleEditorPaneVisibility()
                }
            }) {
                Image(systemName: "doc.text")
                    .foregroundStyle(showEditorPane ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .help("Éditeur")
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
            .help("Terminal")

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
            .help(documentMode.isRunnableCode ? "Output" : "PDF")
        }
    }

    /// Shared disposition menu: panel arrangement
    private var dispositionCluster: some View {
        toolbarCluster(zone: .trailing, title: "Disposition") {
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
            .help("Disposition des panneaux")
        }
    }

    private var fileToolbarClusterView: some View {
        toolbarCluster(zone: .leading, title: "Fichier") {
            Button(action: openFolderPicker) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ouvrir un dossier (⇧⌘O)")

            if !hasNoFile {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(documentMode.fileIconTint)
                Text(fileURL.lastPathComponent)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
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
                .help("Créer un nouveau fichier éditable")
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
                let openPapers = allPapers.filter { openPaperIDs.contains($0.id) }
                if openPapers.isEmpty {
                    Text("Aucun article ouvert en onglet")
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
            .help("Ouvrir un article de référence")
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
            .help("Taille police")

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
            .help("Thème éditeur")
        }
    }

    @ViewBuilder
    private var terminalToolbarClusterView: some View {
        if showTerminal {
            toolbarCluster(zone: .trailing, title: "Term.") {
                Button(action: addTerminalTab) {
                    Image(systemName: "plus")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Nouveau terminal")

                Button(action: terminalAppearanceStore.presentSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Réglages du terminal")
            }
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

    // MARK: - Shared Toolbar Helpers

    func toolbarCluster<Content: View>(
        zone: ToolbarZone,
        title: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AppChromeToolbarCluster(zone: zone, title: title, content: content)
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

    func setToolbarStatus(_ status: ToolbarStatusState, autoClearAfter delay: TimeInterval? = nil) {
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

    // MARK: - File Operations

    func loadFile(useAsBaseline: Bool = true) {
        guard !hasNoFile, let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        if !documentMode.isRunnableCode {
            latexAnnotations = documentMode == .latex ? LaTeXAnnotationStore.load(for: fileURL) : []
            reconcileAnnotations()
        }
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    func saveFile() {
        if documentMode.isRunnableCode {
            guard writeCurrentTextToDisk() else { return }
            setToolbarStatus(.saved, autoClearAfter: 1.4)
        } else if documentMode == .latex {
            compile()
        } else {
            renderMarkdownPreview()
        }
    }

    func createNewEditorFile(_ kind: NewEditorFileKind) {
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

    func openFile(_ url: URL) {
        if EditorFileSupport.isEditorDocument(url) {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
                savedText = content
                latexAnnotations = EditorDocumentMode(fileURL: url) == .latex ? LaTeXAnnotationStore.load(for: url) : []
                reconcileAnnotations()
            }
        }
    }

    func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choisir un dossier de travail"
        panel.prompt = "Ouvrir"
        panel.directoryURL = workspaceState.workspaceRoot ?? FileManager.default.homeDirectoryForCurrentUser
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.workspaceState.workspaceRoot = url
                if !self.showSidebar { self.showSidebar = true }
            }
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            workspaceState.workspaceRoot = url
            if !showSidebar { showSidebar = true }
        }
    }

    @discardableResult
    func writeCurrentTextToDisk() -> Bool {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
            if !documentMode.isRunnableCode {
                reconcileAnnotations()
            }
            lastModified = modificationDate()
            return true
        } catch {
            if documentMode.isRunnableCode {
                codeDocumentState.outputLog = error.localizedDescription
                codeDocumentState.showLogs = true
                setToolbarStatus(.errors(1))
            } else {
                errors = [
                    CompilationError(
                        line: 0,
                        message: error.localizedDescription,
                        file: fileURL.lastPathComponent,
                        isWarning: false
                    )
                ]
                compileOutput = error.localizedDescription
                showErrors = true
                setToolbarStatus(.errors(1))
            }
            return false
        }
    }

    /// Reflow: join paragraph lines into single lines. Visual word wrap handles display.
    /// Preserves blank lines and LaTeX structural commands.
    func reflowParagraphs() {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var currentParagraph: [String] = []

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                result.append(currentParagraph.joined(separator: " "))
                currentParagraph = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                result.append("")
                continue
            }

            let isStructural = trimmed.hasPrefix("\\begin") || trimmed.hasPrefix("\\end") ||
                trimmed.hasPrefix("\\section") || trimmed.hasPrefix("\\subsection") ||
                trimmed.hasPrefix("\\title") || trimmed.hasPrefix("\\author") ||
                trimmed.hasPrefix("\\date") || trimmed.hasPrefix("\\documentclass") ||
                trimmed.hasPrefix("\\usepackage") || trimmed.hasPrefix("\\maketitle") ||
                trimmed.hasPrefix("\\item") || trimmed.hasPrefix("\\label") ||
                trimmed.hasPrefix("\\input") || trimmed.hasPrefix("\\include") ||
                trimmed.hasPrefix("\\newcommand") || trimmed.hasPrefix("\\renewcommand") ||
                trimmed.hasPrefix("\\tableofcontents") || trimmed.hasPrefix("\\bibliography") ||
                trimmed.hasPrefix("\\onehalfspacing") || trimmed.hasPrefix("\\setlength") ||
                trimmed.hasPrefix("%")

            if isStructural {
                flushParagraph()
                result.append(line)
            } else {
                currentParagraph.append(trimmed)
            }
        }
        flushParagraph()

        text = result.joined(separator: "\n")
        savedText = text
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        reconcileAnnotations()
        lastModified = modificationDate()
    }

    func reconcileAnnotations() {
        guard documentMode == .latex else {
            resolvedLaTeXAnnotations = []
            return
        }
        resolvedLaTeXAnnotations = LaTeXAnnotationStore.resolve(latexAnnotations, in: text)
    }

    func persistAnnotations() {
        guard documentMode == .latex else { return }
        if latexAnnotations.isEmpty {
            try? LaTeXAnnotationStore.deleteSidecar(for: fileURL)
        } else {
            try? LaTeXAnnotationStore.save(latexAnnotations, for: fileURL)
        }
    }

    // MARK: - LaTeX Annotation Actions

    func beginAnnotationFromSelection() {
        guard documentMode == .latex else { return }
        guard let range = selectedEditorRange,
              canAnnotateCurrentDocument,
              let draft = LaTeXAnnotationStore.makeDraft(from: range, in: text) else {
            return
        }

        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            if !showSidebar {
                showSidebar = true
            }
            selectedSidebarSection = .annotations
        }
        pendingAnnotation = LaTeXEditorPendingAnnotation(draft: draft, existingAnnotationID: nil)
    }

    func saveLaTeXEditorPendingAnnotation(note: String, sendToClaude: Bool = false) {
        guard var draft = pendingAnnotation?.draft else { return }
        draft.note = note

        let annotationToSend: LaTeXAnnotation
        if let existingAnnotationID = pendingAnnotation?.existingAnnotationID,
           let index = latexAnnotations.firstIndex(where: { $0.id == existingAnnotationID }) {
            latexAnnotations[index] = LaTeXAnnotationStore.update(latexAnnotations[index], note: note, in: text)
            annotationToSend = latexAnnotations[index]
        } else {
            let annotation = LaTeXAnnotationStore.createAnnotation(from: draft)
            latexAnnotations.append(annotation)
            annotationToSend = annotation
        }
        persistAnnotations()
        reconcileAnnotations()
        pendingAnnotation = nil

        if sendToClaude,
           let resolved = LaTeXAnnotationStore.resolve([annotationToSend], in: text).first {
            sendAnnotationToClaude(resolved)
        }
    }

    func deleteAnnotation(_ annotationID: UUID) {
        latexAnnotations.removeAll { $0.id == annotationID }
        persistAnnotations()
        reconcileAnnotations()
    }

    func sendAnnotationToClaude(_ resolved: ResolvedLaTeXAnnotation) {
        let prompt = annotationPrompt(for: resolved)
        sendPromptToClaudeTerminal(prompt, selectionContent: resolved.annotation.selectedText)
    }

    func sendAllAnnotationsToClaude() {
        let prompt = batchAnnotationPrompt(for: sidebarAnnotations)
        let selectionContent = sidebarAnnotations
            .map(\.annotation.selectedText)
            .joined(separator: "\n\n---\n\n")
        sendPromptToClaudeTerminal(prompt, selectionContent: selectionContent)
    }

    func sendPromptToClaudeTerminal(_ prompt: String, selectionContent: String) {
        CanopeContextFiles.writeAnnotationPrompt(prompt)
        CanopeContextFiles.writeIDESelectionState(
            ClaudeIDESelectionState.makeSnapshot(
                selectedText: selectionContent,
                fileURL: fileURL
            )
        )
        CanopeContextFiles.clearLegacySelectionMirror()
        showTerminal = true

        let userInfo = ["prompt": prompt]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .canopeSendPromptToTerminal, object: nil, userInfo: userInfo)
        }
    }

    func addTerminalTab() {
        NotificationCenter.default.post(name: .canopeTerminalAddTab, object: nil)
    }

    private func annotationPrompt(for resolved: ResolvedLaTeXAnnotation) -> String {
        let annotation = resolved.annotation
        let status = resolved.isDetached ? "detached" : "anchored"

        return """
        <canope_annotation>
        file: \(fileURL.path)
        status: \(status)

        selected_text:
        \(annotation.selectedText)

        note:
        \(annotation.note)
        </canope_annotation>

        Aide-moi avec cette annotation LaTeX. Réponds d'abord sur ce passage précis en tenant compte de la note.
        """
    }

    func batchAnnotationPrompt(for annotations: [ResolvedLaTeXAnnotation]) -> String {
        let blocks = annotations.enumerated().map { index, resolved in
            let annotation = resolved.annotation
            let status = resolved.isDetached ? "detached" : "anchored"

            return """
            <annotation index="\(index + 1)">
            status: \(status)

            selected_text:
            \(annotation.selectedText)

            note:
            \(annotation.note)
            </annotation>
            """
        }
        .joined(separator: "\n\n")

        return """
        <canope_annotation_batch>
        file: \(fileURL.path)
        count: \(annotations.count)

        \(blocks)
        </canope_annotation_batch>

        Aide-moi avec ce lot d'annotations LaTeX. Traite-les une par une, puis propose au besoin une synthèse courte des problèmes principaux du texte.
        """
    }

    func beginEditingAnnotation(_ annotationID: UUID) {
        guard let resolved = resolvedLaTeXAnnotations.first(where: { $0.annotation.id == annotationID }) else {
            return
        }

        if let range = resolved.resolvedRange,
           let draft = LaTeXAnnotationStore.makeDraft(from: range, in: text, note: resolved.annotation.note) {
            pendingAnnotation = LaTeXEditorPendingAnnotation(draft: draft, existingAnnotationID: annotationID)
            return
        }

        pendingAnnotation = LaTeXEditorPendingAnnotation(
            draft: LaTeXAnnotationDraft(
                selectedText: resolved.annotation.selectedText,
                note: resolved.annotation.note,
                utf16Range: resolved.annotation.utf16Range,
                prefixContext: resolved.annotation.prefixContext,
                suffixContext: resolved.annotation.suffixContext
            ),
            existingAnnotationID: annotationID
        )
    }

    @ViewBuilder
    func sidebarButton(for section: LaTeXEditorSidebarSection, systemImage: String) -> some View {
        let isActive = showSidebar && selectedSidebarSection == section

        Button {
            toggleSidebar(section: section)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(section == .files ? "Fichiers" : "Annotations")
    }

    func annotationRow(_ resolved: ResolvedLaTeXAnnotation) -> some View {
        let annotation = resolved.annotation

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(resolved.isDetached ? Color.orange : Color.yellow)
                    .frame(width: 7, height: 7)
                Text(resolved.isDetached ? "À recoller" : "Ancrée")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    deleteAnnotation(annotation.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Supprimer l'annotation")
            }

            Button {
                beginEditingAnnotation(annotation.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(annotation.selectedText.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    if !annotation.note.isEmpty {
                        Text(annotation.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Button("Modifier") {
                    beginEditingAnnotation(annotation.id)
                }
                .buttonStyle(.plain)
                .font(.caption)

                Button("Envoyer") {
                    sendAnnotationToClaude(resolved)
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Diff Actions

    func acceptLaTeXEditorDiffGroup(_ group: LaTeXEditorDiffGroup) {
        savedText = DiffEngine.replacingOldBlock(in: savedText, with: group.block)
    }

    func rejectLaTeXEditorDiffGroup(_ group: LaTeXEditorDiffGroup) {
        text = DiffEngine.replacingNewBlock(in: text, with: group.block)
        reconcileAnnotations()
    }

    func acceptAllDiffs() {
        savedText = text
        reconcileAnnotations()
    }

    func rejectAllDiffs() {
        text = savedText
        reconcileAnnotations()
    }

    // MARK: - PDF / Compilation

    func loadExistingPDF() {
        if FileManager.default.fileExists(atPath: previewPDFURL.path) {
            compiledPDF = PDFDocument(url: previewPDFURL)
        } else {
            compiledPDF = nil
        }
    }

    func reloadActiveFileState() {
        stopFileWatcher()
        pendingAnnotation = nil
        selectedEditorRange = nil
        syncTarget = nil
        inverseSyncResult = nil
        errors = []
        compileOutput = ""
        setToolbarStatus(.idle)
        loadFile()
        loadExistingPDF()
        if isActive {
            startFileWatcher()
        }
        refreshSplitGrabAreas()
    }

    func refreshSplitGrabAreas() {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    SplitViewHelper.thickenSplitViews(contentView)
                }
            }
        }
    }

    func scrollEditorToLine(_ lineNumber: Int, selectingLine: Bool = true) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += (lines[i] as NSString).length + 1
        }
        let lineLength = (lines[lineNumber - 1] as NSString).length
        let range = NSRange(location: charOffset, length: lineLength)
        NotificationCenter.default.post(
            name: .syncTeXScrollToLine,
            object: nil,
            userInfo: [
                "range": range,
                "select": selectingLine,
            ]
        )
    }

    func scrollEditorToInverseSyncResult(_ result: SyncTeXInverseResult) {
        let lines = text.components(separatedBy: "\n")
        guard result.line > 0 && result.line <= lines.count else { return }

        let lineText = lines[result.line - 1]
        let lineNSString = lineText as NSString
        let column = resolvedInverseSyncColumn(in: lineText, result: result)
        let clampedColumn = min(max(column, 0), lineNSString.length)
        revealEditorLocationForLine(
            result.line,
            columnOffset: clampedColumn,
            highlightLength: inverseSyncHighlightLength(in: lineText, result: result)
        )
    }

    func resolvedInverseSyncColumn(in lineText: String, result: SyncTeXInverseResult) -> Int {
        let lineNSString = lineText as NSString
        if let column = result.column, column >= 0 {
            return min(column, lineNSString.length)
        }

        guard let context = result.context?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              context.isEmpty == false,
              let offset = result.offset,
              offset >= 0 else {
            return 0
        }

        if let fullContextRange = lineText.range(of: context, options: [.caseInsensitive]) {
            let utf16Range = NSRange(fullContextRange, in: lineText)
            return min(utf16Range.location + offset, lineNSString.length)
        }

        let anchor = syncHintAnchor(in: context, offset: offset)
        if anchor.isEmpty == false,
           let anchorRange = lineText.range(of: anchor, options: [.caseInsensitive]) {
            return NSRange(anchorRange, in: lineText).location
        }

        return 0
    }

    func syncHintAnchor(in context: String, offset: Int) -> String {
        let nsContext = context as NSString
        let length = nsContext.length
        guard length > 0 else { return "" }
        let clampedOffset = min(max(offset, 0), max(length - 1, 0))
        let wordSeparators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var start = clampedOffset
        var end = clampedOffset

        while start > 0 {
            let scalar = UnicodeScalar(nsContext.character(at: start - 1))
            if let scalar, wordSeparators.contains(scalar) { break }
            start -= 1
        }
        while end < length {
            let scalar = UnicodeScalar(nsContext.character(at: end))
            if let scalar, wordSeparators.contains(scalar) { break }
            end += 1
        }

        return nsContext.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    func inverseSyncHighlightLength(in lineText: String, result: SyncTeXInverseResult) -> Int {
        guard let context = result.context?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              context.isEmpty == false,
              let offset = result.offset,
              offset >= 0 else {
            return 1
        }

        let anchor = syncHintAnchor(in: context, offset: offset)
        guard anchor.isEmpty == false,
              let anchorRange = lineText.range(of: anchor, options: [.caseInsensitive]) else {
            return 1
        }

        return max(1, NSRange(anchorRange, in: lineText).length)
    }

    func revealEditorLocation(for group: LaTeXEditorDiffGroup) {
        revealEditorLocationForLine(
            max(group.preferredRevealLine, 1),
            columnOffset: group.preferredRevealColumn,
            highlightLength: group.preferredRevealLength
        )
    }

    func revealEditorLocationForLine(
        _ lineNumber: Int,
        columnOffset: Int = 0,
        highlightLength: Int = 1
    ) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += (lines[i] as NSString).length + 1
        }
        let lineNSString = lines[lineNumber - 1] as NSString
        let clampedColumnOffset = min(max(columnOffset, 0), lineNSString.length)
        NotificationCenter.default.post(
            name: .editorRevealLocation,
            object: nil,
            userInfo: [
                "location": charOffset + clampedColumnOffset,
                "length": max(1, highlightLength),
            ]
        )
    }

    // MARK: - SyncTeX

    func forwardSync(line: Int) {
        guard documentMode == .latex else { return }
        let pdfPath = previewPDFURL.path
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        let texFile = fileURL.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = SyncTeXService.forwardSync(line: line, texFile: texFile, pdfPath: pdfPath) {
                DispatchQueue.main.async {
                    syncTarget = result
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        syncTarget = nil
                    }
                }
            }
        }
    }

    // MARK: - Compilation

    func runPrimaryDocumentAction() {
        switch documentMode {
        case .latex:
            compile()
        case .markdown:
            renderMarkdownPreview()
        case .python, .r:
            break
        }
    }

    func compile() {
        guard documentMode == .latex, !isCompiling else { return }
        guard writeCurrentTextToDisk() else { return }
        isCompiling = true
        setToolbarStatus(documentMode.runningStatus)
        Task {
            let result = await LaTeXCompiler.compile(file: fileURL)
            await MainActor.run {
                errors = result.errors
                compileOutput = result.log
                showErrors = true
                if let pdfURL = result.pdfURL {
                    compiledPDF = PDFDocument(url: pdfURL)
                }
                isCompiling = false
                if activeErrorCount > 0 {
                    setToolbarStatus(.errors(activeErrorCount))
                } else {
                    setToolbarStatus(documentMode.successStatus, autoClearAfter: 1.6)
                }
            }
        }
    }

    func renderMarkdownPreview() {
        guard documentMode == .markdown, !isCompiling else { return }
        guard writeCurrentTextToDisk() else { return }
        isCompiling = true
        setToolbarStatus(documentMode.runningStatus)
        Task {
            let result = await MarkdownPreviewRenderer.render(file: fileURL)
            await MainActor.run {
                errors = result.errors
                compileOutput = result.log
                showErrors = !result.success || !result.errors.isEmpty
                if let pdfURL = result.pdfURL {
                    compiledPDF = PDFDocument(url: pdfURL)
                } else if !result.success {
                    compiledPDF = nil
                }
                isCompiling = false
                if activeErrorCount > 0 {
                    setToolbarStatus(.errors(activeErrorCount))
                } else {
                    setToolbarStatus(documentMode.successStatus, autoClearAfter: 1.6)
                }
            }
        }
    }

    // MARK: - Code Run

    private func runScript() {
        guard documentMode.isRunnableCode, !codeDocumentState.isRunning else { return }
        guard writeCurrentTextToDisk() else { return }

        let commandName = documentMode == .python ? "python3 \(fileURL.lastPathComponent)" : "Rscript \(fileURL.lastPathComponent)"
        codeDocumentState.beginRun(commandDescription: commandName)
        setToolbarStatus(documentMode.runningStatus)

        Task {
            let result = await CodeRunService.run(file: fileURL, mode: documentMode)
            await MainActor.run {
                codeDocumentState.applyRunResult(result)
                if result.succeeded {
                    setToolbarStatus(result.artifacts.isEmpty ? .completed : .previewReady, autoClearAfter: 1.6)
                } else {
                    setToolbarStatus(.errors(1))
                }
                persistDocumentWorkspaceState()
            }
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
        guard let selectedRun = codeDocumentState.selectedRun else { return }
        let refreshed = CodeRunService.refresh(selectedRun, sourceDocumentPath: fileURL.path)
        codeDocumentState.applyRefreshedRun(refreshed)
        setToolbarStatus(refreshed.artifacts.isEmpty ? .completed : .previewReady, autoClearAfter: 1.2)
        persistDocumentWorkspaceState()
    }

    func persistDocumentWorkspaceState() {
        onPersistWorkspaceState?()
    }

    // MARK: - Code Reference PDF Helpers

    private var codeActiveReferencePDFID: UUID? {
        if case .reference(let id) = selectedContentTab { return id }
        return nil
    }

    private var codeActiveReferencePDFState: ReferencePDFUIState? {
        guard let id = codeActiveReferencePDFID else { return nil }
        return workspaceState.referencePDFUIStates[id]
    }

    private var codeActiveReferencePDFDocument: PDFDocument? {
        guard let id = codeActiveReferencePDFID else { return nil }
        return workspaceState.referencePDFs[id]
    }

    private var codeActiveReferenceAnnotationCount: Int {
        guard let document = codeActiveReferencePDFDocument else { return 0 }
        return (0..<document.pageCount).reduce(0) { count, pageIndex in
            guard let page = document.page(at: pageIndex) else { return count }
            return count + page.annotations.filter { $0.type != "Link" && $0.type != "Widget" }.count
        }
    }

    private func codeDeleteSelectedReferenceAnnotation() {
        guard let id = codeActiveReferencePDFID,
              let annotation = codeActiveReferencePDFState?.selectedAnnotation,
              let page = annotation.page else { return }
        let state = workspaceState.referencePDFUIStates[id]
        let wasSelected = state?.selectedAnnotation === annotation
        state?.pushUndoAction { [weak state] in
            page.addAnnotation(annotation)
            if wasSelected { state?.selectedAnnotation = annotation }
            state?.annotationRefreshToken = UUID()
            codeReferencePDFDocumentDidChange(id: id)
        }
        if wasSelected { state?.selectedAnnotation = nil }
        page.removeAnnotation(annotation)
        state?.annotationRefreshToken = UUID()
        codeReferencePDFDocumentDidChange(id: id)
    }

    private func codeDeleteAllReferenceAnnotations() {
        guard let id = codeActiveReferencePDFID,
              let document = codeActiveReferencePDFDocument else { return }
        var removed: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for ann in page.annotations where ann.type != "Link" && ann.type != "Widget" {
                removed.append((page, ann))
                page.removeAnnotation(ann)
            }
        }
        workspaceState.referencePDFUIStates[id]?.pushUndoAction {
            for (page, ann) in removed { page.addAnnotation(ann) }
            workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
            codeReferencePDFDocumentDidChange(id: id)
        }
        codeActiveReferencePDFState?.selectedAnnotation = nil
        workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
        codeReferencePDFDocumentDidChange(id: id)
    }

    private func codeChangeSelectedReferenceAnnotationColor(_ color: NSColor) {
        guard let id = codeActiveReferencePDFID,
              let state = codeActiveReferencePDFState,
              let annotation = state.selectedAnnotation else { return }
        let prevCurrent = state.currentColor
        let prevAnnotation = annotation.isTextBoxAnnotation ? annotation.textBoxFillColor : annotation.color
        state.pushUndoAction { [weak state] in
            guard let state else { return }
            state.currentColor = prevCurrent
            AnnotationService.applyColor(prevAnnotation, to: annotation)
            state.selectedAnnotation = annotation
            state.annotationRefreshToken = UUID()
            codeReferencePDFDocumentDidChange(id: id)
        }
        state.currentColor = color
        state.selectedAnnotation = annotation
        AnnotationService.applyColor(color, to: annotation)
        codeReferencePDFDocumentDidChange(id: id)
    }

    private func codeSaveCurrentReferencePDF() {
        guard let id = codeActiveReferencePDFID else { return }
        codeSaveReferencePDF(id: id)
    }

    private func codeRefreshCurrentReference() {
        guard let id = codeActiveReferencePDFID else { return }
        codeReloadReferencePDFDocument(id: id)
    }

    private var codeActiveReferenceCompanionExportFileName: String {
        guard let id = codeActiveReferencePDFID,
              let paper = paperFor(id) else { return "annotations.md" }
        return PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL).lastPathComponent
    }

    private func codeExportActiveReferencePDFAnnotationsToCompanionMarkdown() {
        guard let id = codeActiveReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        let companionURL = PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL)
        try? PDFAnnotationMarkdownExporter.export(
            document: document,
            source: .reference(pdfURL: paper.fileURL),
            target: .companionFile(companionURL)
        )
    }

    private func codeChooseActiveReferencePDFAnnotationsMarkdownDestination() {
        guard let id = codeActiveReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL).lastPathComponent
        panel.directoryURL = paper.fileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PDFAnnotationMarkdownExporter.export(
            document: document,
            source: .reference(pdfURL: paper.fileURL),
            target: .companionFile(url)
        )
    }

    private func codeReferencePDFDocumentDidChange(id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.hasUnsavedChanges = true
        state.annotationRefreshToken = UUID()
        let delay: TimeInterval = (state.selectedAnnotation?.isTextBoxAnnotation == true || state.currentTool == .textBox) ? 0.9 : 0.25
        state.pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak state] in
            state?.pendingSaveWorkItem = nil
            codeSaveReferencePDF(id: id)
        }
        state.pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func codeSaveReferencePDF(id: UUID) {
        guard let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem = nil
        if AnnotationService.save(document: document, to: paper.fileURL) {
            workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges = false
        }
    }

    private func codeReloadReferencePDFDocument(id: UUID) {
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

    private func codeSaveReferenceAnnotationNote(for id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id],
              let annotation = state.selectedAnnotation else { return }
        annotation.contents = state.editingNoteText
        state.isEditingNote = false
        state.annotationRefreshToken = UUID()
        codeReferencePDFDocumentDidChange(id: id)
    }

    // MARK: - File Watching (polling-based for reliability with external editors)

    func startFileWatcher() {
        guard !hasNoFile, pollTimer == nil else { return }
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

    func stopFileWatcher() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func modificationDate() -> Date? {
        Self.modificationDate(for: fileURL)
    }

    nonisolated static func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
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

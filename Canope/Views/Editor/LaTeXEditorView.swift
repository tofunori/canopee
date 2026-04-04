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

struct LaTeXEditorView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ObservedObject private var terminalAppearanceStore = TerminalAppearanceStore.shared
    private static let threePaneCoordinateSpace = "LaTeXThreePaneLayout"

    // Types extracted to LaTeXEditorTypes.swift

    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    var onOpenPDF: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var openPaperIDs: [UUID] = []
    var editorTabBar: AnyView? = nil
    @State var text = ""
    @State var savedText = ""
    @State var compiledPDF: PDFDocument?
    @State var errors: [CompilationError] = []
    @State private var compileOutput: String = ""
    @State private var isCompiling = false
    @State var syncTarget: SyncTeXForwardResult?
    @State var inverseSyncResult: SyncTeXInverseResult?
    @State var lastModified: Date?
    @State private var latexAnnotations: [LaTeXAnnotation] = []
    @State private var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] = []
    @State private var selectedEditorRange: NSRange?
    @State private var pendingAnnotation: LaTeXEditorPendingAnnotation?
    @State var sidebarResizeStartWidth: CGFloat?
    @State private var threePaneLeftWidth: CGFloat?
    @State private var threePaneRightWidth: CGFloat?
    @State private var threePaneDragStartLeftWidth: CGFloat?
    @State private var threePaneDragStartRightWidth: CGFloat?
    @State private var isDraggingThreePaneDivider = false
    @State private var toolbarStatus: ToolbarStatusState = .idle
    @State private var toolbarStatusClearWorkItem: DispatchWorkItem?
    @State private var fileCreationError: String?
    @State var annotationExportError: String?

    // PDF pane tabs — type extracted to LaTeXEditorTypes.swift
    @Query var allPapers: [Paper]
    @State var fitToWidthTrigger = false
    @State var referenceContextWriteID = UUID()
    @Namespace var pdfTabIndicatorNamespace

    // LaTeXEditorSplitLayout extracted to LaTeXEditorTypes.swift

    static let editorThemes: [(name: String, bg: NSColor, fg: NSColor, comment: NSColor, command: NSColor, math: NSColor, env: NSColor, brace: NSColor)] = [
        ("Kaku Dark",
         NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1),
         NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1),
         NSColor(red: 0.43, green: 0.43, blue: 0.43, alpha: 1),
         NSColor(red: 0.37, green: 0.66, blue: 1.0, alpha: 1),
         NSColor(red: 0.38, green: 1.0, blue: 0.79, alpha: 1),
         NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1),
         NSColor(red: 1.0, green: 0.79, blue: 0.52, alpha: 1)),
        ("Monokai",
         NSColor(red: 0.15, green: 0.16, blue: 0.13, alpha: 1),
         NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1),
         NSColor(red: 0.45, green: 0.45, blue: 0.39, alpha: 1),
         NSColor(red: 0.40, green: 0.85, blue: 0.94, alpha: 1),
         NSColor(red: 0.90, green: 0.86, blue: 0.45, alpha: 1),
         NSColor(red: 0.65, green: 0.89, blue: 0.18, alpha: 1),
         NSColor(red: 0.98, green: 0.15, blue: 0.45, alpha: 1)),
        ("Dracula",
         NSColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1),
         NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1),
         NSColor(red: 0.38, green: 0.45, blue: 0.55, alpha: 1),
         NSColor(red: 0.51, green: 0.93, blue: 0.98, alpha: 1),
         NSColor(red: 0.94, green: 0.98, blue: 0.55, alpha: 1),
         NSColor(red: 0.94, green: 0.47, blue: 0.60, alpha: 1),
         NSColor(red: 1.0, green: 0.72, blue: 0.42, alpha: 1)),
        ("Nord",
         NSColor(red: 0.18, green: 0.20, blue: 0.25, alpha: 1),
         NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1),
         NSColor(red: 0.42, green: 0.48, blue: 0.55, alpha: 1),
         NSColor(red: 0.53, green: 0.75, blue: 0.82, alpha: 1),
         NSColor(red: 0.71, green: 0.81, blue: 0.66, alpha: 1),
         NSColor(red: 0.70, green: 0.56, blue: 0.75, alpha: 1),
         NSColor(red: 0.81, green: 0.63, blue: 0.48, alpha: 1)),
        ("Solarized",
         NSColor(red: 0.0, green: 0.17, blue: 0.21, alpha: 1),
         NSColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1),
         NSColor(red: 0.35, green: 0.43, blue: 0.46, alpha: 1),
         NSColor(red: 0.15, green: 0.55, blue: 0.82, alpha: 1),
         NSColor(red: 0.71, green: 0.54, blue: 0.0, alpha: 1),
         NSColor(red: 0.83, green: 0.21, blue: 0.51, alpha: 1),
         NSColor(red: 0.80, green: 0.29, blue: 0.09, alpha: 1)),
    ]

    var projectRoot: URL { fileURL.deletingLastPathComponent() }
    var documentMode: EditorDocumentMode { EditorDocumentMode(fileURL: fileURL) }
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

    var panelArrangement: LaTeXPanelArrangement {
        get { workspaceState.panelArrangement }
        nonmutating set { workspaceState.panelArrangement = newValue }
    }

    var isPDFLeadingInLayout: Bool {
        panelArrangement == .pdfEditorTerminal
    }

    var editorFontSize: CGFloat {
        get { CGFloat(workspaceState.editorFontSize) }
        nonmutating set { workspaceState.editorFontSize = Double(newValue) }
    }

    var editorTheme: Int {
        get { min(max(workspaceState.editorTheme, 0), Self.editorThemes.count - 1) }
        nonmutating set { workspaceState.editorTheme = newValue }
    }

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

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
            AppChromeDivider(role: .shell)

            // Main content: file browser | (editor / pdf split)
            HSplitView {
                // File browser (left, resizable)
                sidebarPane

                // Right side: file tabs + editor + PDF
                VStack(spacing: 0) {
                    workAreaPane
                } // close VStack (file tabs + editor/PDF)
            }
        }
        .sheet(item: $pendingAnnotation) { pending in
            LaTeXAnnotationNoteSheet(
                title: pending.existingAnnotationID == nil ? "Nouvelle annotation" : "Modifier l’annotation",
                selectedText: pending.draft.selectedText,
                initialNote: pending.draft.note,
                onCancel: {
                    pendingAnnotation = nil
                },
                onSave: { note in
                    saveLaTeXEditorPendingAnnotation(note: note)
                },
                onSaveAndSend: { note in
                    saveLaTeXEditorPendingAnnotation(note: note, sendToClaude: true)
                }
            )
        }
        .onChange(of: inverseSyncResult) {
            if let result = inverseSyncResult {
                scrollEditorToInverseSyncResult(result)
                inverseSyncResult = nil
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
        .alert("Impossible d’exporter les annotations", isPresented: Binding(
            get: { annotationExportError != nil },
            set: { if !$0 { annotationExportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(annotationExportError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncTeXForwardSync)) { notification in
            guard documentMode == .latex else { return }
            if let line = notification.userInfo?["line"] as? Int {
                forwardSync(line: line)
            }
        }
        .onAppear {
            if !AppRuntime.isRunningTests {
                ClaudeIDEBridgeService.shared.startIfNeeded()
            }
            loadFile()
            loadExistingPDF()
            if isActive {
                startFileWatcher()
            }
            refreshSplitGrabAreas()
        }
        .onDisappear {
            stopFileWatcher()
        }
        .onChange(of: isActive) {
            if isActive {
                loadFile()
                startFileWatcher()
                refreshSplitGrabAreas()
            } else {
                stopFileWatcher()
            }
        }
        .onChange(of: fileURL) {
            reloadActiveFileState()
        }
        .onChange(of: splitLayout) {
            refreshSplitGrabAreas()
        }
        .onChange(of: showSidebar) {
            refreshSplitGrabAreas()
        }
        .onChange(of: showPDFPreview) {
            refreshSplitGrabAreas()
        }
        .onChange(of: showTerminal) {
            refreshSplitGrabAreas()
        }
        .onChange(of: panelArrangement) {
            threePaneLeftWidth = nil
            threePaneRightWidth = nil
            refreshSplitGrabAreas()
        }
    }

    // MARK: - Panes

    @ViewBuilder
    var workAreaPane: some View {
        Group {
            if isActive && showTerminal && showPDFPreview && showEditorPane && splitLayout == .horizontal {
                horizontalThreePaneLayout
            } else if isActive && showTerminal {
                switch panelArrangement {
                case .terminalEditorPDF:
                    HSplitView {
                        embeddedTerminalPane
                        editorAndPDFPane
                            .layoutPriority(1)
                    }
                case .editorPDFTerminal, .pdfEditorTerminal:
                    HSplitView {
                        editorAndPDFPane
                            .layoutPriority(1)
                        embeddedTerminalPane
                    }
                }
            } else {
                editorAndPDFPane
            }
        }
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showTerminal)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showPDFPreview)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showEditorPane)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: splitLayout)
    }

    @ViewBuilder
    var horizontalThreePaneLayout: some View {
        GeometryReader { proxy in
            let roles = threePaneRoles
            let totalContentWidth = max(0, proxy.size.width - (LaTeXEditorThreePaneSizing.dividerWidth * 2))
            let widths = resolvedThreePaneWidths(for: roles, totalContentWidth: totalContentWidth)

            HStack(spacing: 0) {
                threePaneView(for: roles.0)
                    .frame(width: widths.left)

                threePaneResizeHandle {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.resizeLeftRight.set()
                } onExit: {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.arrow.set()
                } drag: {
                    AnyGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.threePaneCoordinateSpace))
                        .onChanged { value in
                            if !isDraggingThreePaneDivider {
                                isDraggingThreePaneDivider = true
                                NSCursor.resizeLeftRight.set()
                            }
                            if threePaneDragStartLeftWidth == nil {
                                threePaneDragStartLeftWidth = widths.left
                            }
                            let startLeft = threePaneDragStartLeftWidth ?? widths.left
                            let leftMin = paneMinWidth(for: roles.0)
                            let middleMin = paneMinWidth(for: roles.1)
                            let maxLeft = max(leftMin, totalContentWidth - widths.right - middleMin)
                            threePaneLeftWidth = min(max(startLeft + value.translation.width, leftMin), maxLeft)
                        }
                        .onEnded { _ in
                            threePaneDragStartLeftWidth = nil
                            isDraggingThreePaneDivider = false
                            NSCursor.arrow.set()
                        }
                    )
                }

                threePaneView(for: roles.1)
                    .frame(width: widths.middle)

                threePaneResizeHandle {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.resizeLeftRight.set()
                } onExit: {
                    guard !isDraggingThreePaneDivider else { return }
                    NSCursor.arrow.set()
                } drag: {
                    AnyGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.threePaneCoordinateSpace))
                        .onChanged { value in
                            if !isDraggingThreePaneDivider {
                                isDraggingThreePaneDivider = true
                                NSCursor.resizeLeftRight.set()
                            }
                            if threePaneDragStartRightWidth == nil {
                                threePaneDragStartRightWidth = widths.right
                            }
                            let startRight = threePaneDragStartRightWidth ?? widths.right
                            let middleMin = paneMinWidth(for: roles.1)
                            let rightMin = paneMinWidth(for: roles.2)
                            let maxRight = max(rightMin, totalContentWidth - widths.left - middleMin)
                            threePaneRightWidth = min(max(startRight - value.translation.width, rightMin), maxRight)
                        }
                        .onEnded { _ in
                            threePaneDragStartRightWidth = nil
                            isDraggingThreePaneDivider = false
                            NSCursor.arrow.set()
                        }
                    )
                }

                threePaneView(for: roles.2)
                    .frame(width: widths.right)
            }
            .coordinateSpace(name: Self.threePaneCoordinateSpace)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    var threePaneRoles: (LaTeXEditorThreePaneRole, LaTeXEditorThreePaneRole, LaTeXEditorThreePaneRole) {
        switch panelArrangement {
        case .terminalEditorPDF:
            return (.terminal, .editor, .pdf)
        case .editorPDFTerminal:
            return (.editor, .pdf, .terminal)
        case .pdfEditorTerminal:
            return (.pdf, .editor, .terminal)
        }
    }

    @ViewBuilder
    func threePaneView(for role: LaTeXEditorThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .pdf:
            pdfPane
        }
    }

    func paneMinWidth(for role: LaTeXEditorThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 160
        case .editor:
            return 160
        case .pdf:
            return 180
        }
    }

    func paneIdealWidth(for role: LaTeXEditorThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 320
        case .editor:
            return 620
        case .pdf:
            return 320
        }
    }

    func resolvedThreePaneWidths(
        for roles: (LaTeXEditorThreePaneRole, LaTeXEditorThreePaneRole, LaTeXEditorThreePaneRole),
        totalContentWidth: CGFloat
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let leftMin = paneMinWidth(for: roles.0)
        let middleMin = paneMinWidth(for: roles.1)
        let rightMin = paneMinWidth(for: roles.2)
        let minimumTotal = leftMin + middleMin + rightMin
        let availableWidth = max(totalContentWidth, minimumTotal)

        let seededLeft = threePaneLeftWidth ?? paneIdealWidth(for: roles.0)
        let seededRight = threePaneRightWidth ?? paneIdealWidth(for: roles.2)

        let leftMaxBeforeRightClamp = max(leftMin, availableWidth - middleMin - rightMin)
        let left = min(max(seededLeft, leftMin), leftMaxBeforeRightClamp)

        let rightMaxBeforeLeftClamp = max(rightMin, availableWidth - left - middleMin)
        let right = min(max(seededRight, rightMin), rightMaxBeforeLeftClamp)

        let leftMax = max(leftMin, availableWidth - right - middleMin)
        let clampedLeft = min(left, leftMax)
        let rightMax = max(rightMin, availableWidth - clampedLeft - middleMin)
        let clampedRight = min(right, rightMax)
        let middle = max(middleMin, availableWidth - clampedLeft - clampedRight)

        return (clampedLeft, middle, clampedRight)
    }

    func threePaneResizeHandle(
        onEnter: @escaping () -> Void,
        onExit: @escaping () -> Void,
        drag: @escaping () -> AnyGesture<DragGesture.Value>
    ) -> some View {
        AppChromeResizeHandle(
            width: LaTeXEditorThreePaneSizing.dividerWidth,
            onHoverChanged: { hovering in
                if hovering {
                    onEnter()
                } else {
                    onExit()
                }
            },
            dragGesture: drag()
        )
    }

    @ViewBuilder
    var editorAndPDFPane: some View {
        if !showEditorPane && !showPDFPreview {
            hiddenEditorPlaceholderPane
        } else if !showEditorPane {
            pdfPane
        } else if !showPDFPreview {
            editorPane
        } else if splitLayout == .horizontal {
            HSplitView {
                if isPDFLeadingInLayout { pdfPane }
                editorPane
                if !isPDFLeadingInLayout { pdfPane }
            }
        } else if splitLayout == .vertical {
            VSplitView {
                if isPDFLeadingInLayout { pdfPane }
                editorPane
                if !isPDFLeadingInLayout { pdfPane }
            }
        } else {
            editorPane
        }
    }

    var hiddenEditorPlaceholderPane: some View {
        ContentUnavailableView(
            "Panneau LaTeX fermé",
            systemImage: "doc.text",
            description: Text("Rouvre le panneau LaTeX depuis la barre d’outils, ou garde seulement le terminal et/ou le PDF.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

    var editorPane: some View {
        VStack(spacing: 0) {
            if let editorTabBar {
                editorTabBar
                AppChromeDivider(role: .panel)
            }

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
            if showErrors {
                AppChromeDivider(role: .panel)
                VStack(alignment: .leading, spacing: 0) {
                    // Header
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

                    // Console output
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
        }
        .frame(minWidth: 160, idealWidth: 620, maxWidth: .infinity)
        .layoutPriority(1)
    }

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

    // MARK: - Toolbar

    var editorToolbar: some View {
        HStack(spacing: 8) {
            fileToolbarClusterView
            documentToolbarClusterView
            referencePickerToolbarClusterView
            activeReferenceToolbarView
            Spacer(minLength: 8)
            viewToolbarClusterView
            editorAppearanceToolbarClusterView
            terminalToolbarClusterView
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
    }

    private var fileToolbarClusterView: some View {
        toolbarCluster(zone: .leading, title: "Fichier") {
            Image(systemName: "doc.plaintext")
                .foregroundStyle(documentMode.fileIconTint)
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
            AppChromeStatusCapsule(status: toolbarStatus)
            if !isFileBrowserCreateMenuVisible {
                Menu {
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

    private var viewToolbarClusterView: some View {
        toolbarCluster(zone: .trailing, title: "Vue") {
            Button(action: {
                toggleSidebar()
            }) {
                Image(systemName: "sidebar.left")
                    .symbolVariant(showSidebar ? .none : .slash)
                    .foregroundStyle(showSidebar ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .help("Afficher la barre latérale")

            Menu {
                Button {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        splitLayout = .horizontal
                        showPDFPreview = true
                    }
                } label: {
                    Label("Côte à côte", systemImage: "rectangle.split.2x1")
                    if splitLayout == .horizontal { Image(systemName: "checkmark") }
                }
                Button {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        splitLayout = .vertical
                        showPDFPreview = true
                    }
                } label: {
                    Label("Haut / Bas", systemImage: "rectangle.split.1x2")
                    if splitLayout == .vertical { Image(systemName: "checkmark") }
                }
                Button {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        splitLayout = .editorOnly
                        showPDFPreview = false
                    }
                } label: {
                    Label("Éditeur seul", systemImage: "doc.text")
                    if splitLayout == .editorOnly { Image(systemName: "checkmark") }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .help("Disposition")

            Menu {
                ForEach(LaTeXPanelArrangement.allCases, id: \.self) { arrangement in
                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            panelArrangement = arrangement
                        }
                    } label: {
                        HStack {
                            if panelArrangement == arrangement {
                                Image(systemName: "checkmark")
                            }
                            Text(arrangement.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Ordre des panneaux")

            Button(action: {
                toggleEditorPaneVisibility()
            }) {
                Image(systemName: showEditorPane ? "doc.text.fill" : "doc.text")
                    .foregroundStyle(showEditorPane ? AppChromePalette.info : .secondary)
            }
            .buttonStyle(.plain)
            .help("Panneau LaTeX")
            .disabled(showEditorPane && !showTerminal && !showPDFPreview)

            Button(action: {
                toggleTerminalVisibility()
            }) {
                Image(systemName: showTerminal ? "terminal.fill" : "terminal")
                    .foregroundStyle(showTerminal ? AppChromePalette.success : .secondary)
            }
            .buttonStyle(.plain)
            .help("Terminal")
        }
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

    func toolbarCluster<Content: View>(
        zone: ToolbarZone,
        title: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AppChromeToolbarCluster(zone: zone, title: title, content: content)
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
        guard !(showEditorPane && !showTerminal && !showPDFPreview) else { return }
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
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        latexAnnotations = documentMode == .latex ? LaTeXAnnotationStore.load(for: fileURL) : []
        reconcileAnnotations()
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    func saveFile() {
        if documentMode == .latex {
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

        Aide-moi avec cette annotation LaTeX. Réponds d’abord sur ce passage précis en tenant compte de la note.
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

        Aide-moi avec ce lot d’annotations LaTeX. Traite-les une par une, puis propose au besoin une synthèse courte des problèmes principaux du texte.
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
                .help("Supprimer l’annotation")
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
                    // Clear after a moment so it can be re-triggered
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        syncTarget = nil
                    }
                }
            }
        }
    }

    // MARK: - PDF Pane Tabs

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

    @discardableResult
    func writeCurrentTextToDisk() -> Bool {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
            reconcileAnnotations()
            lastModified = modificationDate()
            return true
        } catch {
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
            return false
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

    // MARK: - File Watching (polling-based for reliability with external editors)

    @State var pollTimer: Timer?

    func startFileWatcher() {
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

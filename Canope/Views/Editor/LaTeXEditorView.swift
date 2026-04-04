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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let threePaneCoordinateSpace = "LaTeXThreePaneLayout"

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
    @State var compileOutput: String = ""
    @State var isCompiling = false
    @State var syncTarget: SyncTeXForwardResult?
    @State var inverseSyncResult: SyncTeXInverseResult?
    @State var lastModified: Date?
    @State var latexAnnotations: [LaTeXAnnotation] = []
    @State var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] = []
    @State var selectedEditorRange: NSRange?
    @State var pendingAnnotation: LaTeXEditorPendingAnnotation?
    @State var sidebarResizeStartWidth: CGFloat?
    @State var threePaneLeftWidth: CGFloat?
    @State var threePaneRightWidth: CGFloat?
    @State var threePaneDragStartLeftWidth: CGFloat?
    @State var threePaneDragStartRightWidth: CGFloat?
    @State var isDraggingThreePaneDivider = false
    @State var toolbarStatus: ToolbarStatusState = .idle
    @State var toolbarStatusClearWorkItem: DispatchWorkItem?
    @State var fileCreationError: String?

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

    varprojectRoot: URL { fileURL.deletingLastPathComponent() }
    vardocumentMode: EditorDocumentMode { EditorDocumentMode(fileURL: fileURL) }
    varpreviewPDFURL: URL { MarkdownPreviewRenderer.previewURL(for: fileURL) }
    varerrorLines: Set<Int> {
        Set(errors.filter { !$0.isWarning && $0.line > 0 }.map { $0.line })
    }
    varcanCreateAnnotationFromSelection: Bool {
        guard let range = selectedEditorRange, range.location != NSNotFound, range.length > 0 else {
            return false
        }

        return !resolvedLaTeXAnnotations.contains { resolved in
            resolved.resolvedRange == range
        }
    }

    varcanAnnotateCurrentDocument: Bool {
        documentMode == .latex && canCreateAnnotationFromSelection
    }

    varisFileBrowserCreateMenuVisible: Bool {
        showSidebar && selectedLaTeXEditorSidebarSection == .files
    }

    varoutputSummaryText: String {
        if errors.isEmpty {
            return documentMode.outputSuccessTitle
        }

        return "\(errors.filter { !$0.isWarning }.count) erreur(s), \(errors.filter { $0.isWarning }.count) avertissement(s)"
    }

    varsidebarAnnotations: [ResolvedLaTeXAnnotation] {
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

    vardiffGroups: [LaTeXEditorDiffGroup] {
        DiffEngine.reviewBlocks(old: savedText, new: text).map { LaTeXEditorDiffGroup(review: $0) }
    }

    varshowSidebar: Bool {
        get { workspaceState.showSidebar }
        nonmutating set { workspaceState.showSidebar = newValue }
    }

    varselectedLaTeXEditorSidebarSection: LaTeXEditorSidebarSection {
        get { LaTeXEditorSidebarSection(rawValue: workspaceState.selectedLaTeXEditorSidebarSection) ?? .files }
        nonmutating set { workspaceState.selectedLaTeXEditorSidebarSection = newValue.rawValue }
    }

    varsidebarWidth: CGFloat {
        get {
            let stored = CGFloat(workspaceState.sidebarWidth)
            guard stored.isFinite, stored > 0 else { return LaTeXEditorSidebarSizing.defaultWidth }
            return min(max(stored, LaTeXEditorSidebarSizing.minWidth), LaTeXEditorSidebarSizing.maxWidth)
        }
        nonmutating set {
            workspaceState.sidebarWidth = Double(min(max(newValue, LaTeXEditorSidebarSizing.minWidth), LaTeXEditorSidebarSizing.maxWidth))
        }
    }

    varisCompactDiffSidebar: Bool {
        sidebarWidth < 220
    }

    varshowPDFPreview: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set { workspaceState.showPDFPreview = newValue }
    }

    varshowEditorPane: Bool {
        get { workspaceState.showEditorPane }
        nonmutating set { workspaceState.showEditorPane = newValue }
    }

    varshowErrors: Bool {
        get { workspaceState.showErrors }
        nonmutating set { workspaceState.showErrors = newValue }
    }

    varsplitLayout: LaTeXEditorSplitLayout {
        get { LaTeXEditorSplitLayout(rawValue: workspaceState.splitLayout) ?? .editorOnly }
        nonmutating set {
            workspaceState.splitLayout = newValue.rawValue
            workspaceState.showPDFPreview = newValue != .editorOnly
        }
    }

    varpanelArrangement: LaTeXPanelArrangement {
        get { workspaceState.panelArrangement }
        nonmutating set { workspaceState.panelArrangement = newValue }
    }

    varisPDFLeadingInLayout: Bool {
        panelArrangement == .pdfEditorTerminal
    }

    vareditorFontSize: CGFloat {
        get { CGFloat(workspaceState.editorFontSize) }
        nonmutating set { workspaceState.editorFontSize = Double(newValue) }
    }

    vareditorTheme: Int {
        get { min(max(workspaceState.editorTheme, 0), Self.editorThemes.count - 1) }
        nonmutating set { workspaceState.editorTheme = newValue }
    }

    varpdfPaneTabs: [LaTeXEditorPdfPaneTab] {
        [.compiled] + workspaceState.referencePaperIDs.map { .reference($0) }
    }

    varselectedPdfTab: LaTeXEditorPdfPaneTab {
        if let id = workspaceState.selectedReferencePaperID {
            return .reference(id)
        }
        return .compiled
    }

    varlayoutBeforeReference: LaTeXEditorSplitLayout? {
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
        .onReceive(NotificationCenter.default.publisher(for: .syncTeXForwardSync)) { notification in
            guard documentMode == .latex else { return }
            if let line = notification.userInfo?["line"] as? Int {
                forwardSync(line: line)
            }
        }
        .onAppear {
            ClaudeIDEBridgeService.shared.startIfNeeded()
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
    varworkAreaPane: some View {
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
    varhorizontalThreePaneLayout: some View {
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

    varthreePaneRoles: (LaTeXEditorThreePaneRole, LaTeXEditorThreePaneRole, LaTeXEditorThreePaneRole) {
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
    functhreePaneView(for role: LaTeXEditorThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .pdf:
            pdfPane
        }
    }

    funcpaneMinWidth(for role: LaTeXEditorThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 160
        case .editor:
            return 160
        case .pdf:
            return 180
        }
    }

    funcpaneIdealWidth(for role: LaTeXEditorThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 320
        case .editor:
            return 620
        case .pdf:
            return 320
        }
    }

    funcresolvedThreePaneWidths(
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

    functhreePaneResizeHandle(
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
    vareditorAndPDFPane: some View {
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

    varhiddenEditorPlaceholderPane: some View {
        ContentUnavailableView(
            "Panneau LaTeX fermé",
            systemImage: "doc.text",
            description: Text("Rouvre le panneau LaTeX depuis la barre d’outils, ou garde seulement le terminal et/ou le PDF.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    varembeddedTerminalPane: some View {
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

    varsidebarPane: some View {
        HStack(spacing: 0) {
            sidebarActivityBar
            AppChromeDivider(role: .panel, axis: .vertical)
            Group {
                switch selectedLaTeXEditorSidebarSection {
                case .files:
                    fileBrowserSidebar
                case .annotations:
                    annotationSidebar
                case .diff:
                    diffSidebar
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
                sidebarResizeHandle
            }
        }
        .frame(
            width: showSidebar
                ? LaTeXEditorSidebarSizing.activityBarWidth + sidebarWidth + LaTeXEditorSidebarSizing.resizeHandleWidth + AppChromeMetrics.dividerThickness
                : LaTeXEditorSidebarSizing.activityBarWidth
        )
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showSidebar)
    }

    varsidebarResizeHandle: some View {
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
                    }
            )
        )
    }

    varsidebarActivityBar: some View {
        VStack(spacing: 8) {
            sidebarButton(for: .files, systemImage: "folder")
            sidebarButton(for: .annotations, systemImage: "note.text")
            sidebarButton(for: .diff, systemImage: "arrow.left.arrow.right.square")
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 44)
        .background(AppChromePalette.surfaceSubbar)
    }

    varfileBrowserSidebar: some View {
        FileBrowserView(rootURL: projectRoot, showsCreateFileMenu: true) { url in
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                onOpenPDF?(url)
            } else if ext == "md" || ext == "tex" || ext == "bib" || ext == "txt" {
                onOpenInNewTab?(url)
            } else {
                openFile(url)
            }
        }
    }

    varannotationSidebar: some View {
        Group {
            if let referenceID = activeReferencePDFID,
               let document = activeReferencePDFDocument,
               let state = activeReferencePDFState {
                referenceAnnotationSidebar(referenceID: referenceID, document: document, state: state)
            } else {
                latexAnnotationSidebar
            }
        }
    }

    varlatexAnnotationSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Annotations", systemImage: "note.text")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if !sidebarAnnotations.isEmpty {
                    Button("Tout envoyer") {
                        sendAllAnnotationsToClaude()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !sidebarAnnotations.isEmpty {
                    Text("\(sidebarAnnotations.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            AppChromeDivider(role: .panel)

            if sidebarAnnotations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("Aucune annotation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Sélectionne un passage puis clique sur le surligneur dans la barre du haut.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sidebarAnnotations, id: \.annotation.id) { resolved in
                            annotationRow(resolved)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    funcreferenceAnnotationSidebar(
        referenceID: UUID,
        document: PDFDocument,
        state: ReferencePDFUIState
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Annotations", systemImage: "note.text")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if activeReferenceAnnotationCount > 0 {
                    Text("\(activeReferenceAnnotationCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            AppChromeDivider(role: .panel)

            AnnotationSidebarView(
                document: document,
                selectedAnnotation: Binding(
                    get: { state.selectedAnnotation },
                    set: { state.selectedAnnotation = $0 }
                ),
                onNavigate: { annotation in
                    state.selectedAnnotation = annotation
                },
                onDelete: { annotation in
                    deleteReferenceAnnotation(annotation, in: referenceID)
                },
                onEditNote: { annotation in
                    beginEditingReferenceAnnotationNote(annotation, in: referenceID)
                },
                onChangeColor: { annotation, color in
                    changeReferenceAnnotationColor(annotation, to: color, in: referenceID)
                }
            )
            .id(state.annotationRefreshToken)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    vardiffSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Diff", systemImage: "arrow.left.arrow.right.square")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if !diffGroups.isEmpty {
                    Text("\(diffGroups.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if !diffGroups.isEmpty {
                HStack(spacing: 6) {
                    Text(isCompactDiffSidebar ? "Global" : "Toutes les modifications")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 6) {
                        diffBatchActionButton(
                            title: "Tout rejeter",
                            systemImage: "xmark",
                            tint: .red,
                            compact: isCompactDiffSidebar,
                            action: rejectAllDiffs
                        )

                        diffBatchActionButton(
                            title: "Tout accepter",
                            systemImage: "checkmark",
                            tint: .green,
                            compact: isCompactDiffSidebar,
                            action: acceptAllDiffs
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            AppChromeDivider(role: .panel)

            if diffGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("Aucun changement")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Les modifications non sauvegardées du fichier apparaîtront ici.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(diffGroups) { group in
                            diffRow(group)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    funcdiffBatchActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        compact: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if compact {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                } else {
                    Label(title, systemImage: systemImage)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 4)
        .background(tint.opacity(0.08))
        .clipShape(Capsule())
        .help(title)
    }

    vareditorPane: some View {
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

    @ViewBuilder
    funcdiffRow(_ group: LaTeXEditorDiffGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(diffLabel(for: group))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(diffAccentColor(for: group))
                Text(diffLineLabel(for: group))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    rejectLaTeXEditorDiffGroup(group)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Rejeter ce bloc")

                Button {
                    acceptLaTeXEditorDiffGroup(group)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .help("Accepter ce bloc")

                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                    reviewRow(row)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            revealEditorLocation(for: group)
        }
    }

    @ViewBuilder
    funcreviewRow(_ row: ReviewDiffRow) -> some View {
        switch row.kind {
        case .added:
            compactDiffSnippet(
                prefix: "+",
                text: reviewText(from: row.newSpans, accent: .green),
                accent: .green
            )
        case .removed:
            compactDiffSnippet(
                prefix: "-",
                text: reviewText(from: row.oldSpans, accent: .red),
                accent: .red
            )
        case .modified:
            VStack(alignment: .leading, spacing: 6) {
                compactDiffSnippet(
                    prefix: "-",
                    text: reviewText(from: row.oldSpans, accent: .red),
                    accent: .red
                )
                compactDiffSnippet(
                    prefix: "+",
                    text: reviewText(from: row.newSpans, accent: .green),
                    accent: .green
                )
            }
        }
    }

    funccompactDiffSnippet(
        prefix: String,
        text: Text,
        accent: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)

            text
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    funcreviewText(from spans: [ReviewInlineSpan], accent: Color) -> Text {
        guard !spans.isEmpty else { return Text(" ") }

        return spans.reduce(Text("")) { partial, span in
            partial + reviewSpanText(span, accent: accent)
        }
    }

    funcreviewSpanText(_ span: ReviewInlineSpan, accent: Color) -> Text {
        let text = Text(verbatim: span.text.isEmpty ? " " : span.text)
        switch span.kind {
        case .equal:
            return text.foregroundStyle(.secondary)
        case .insert:
            return text.foregroundStyle(.primary).bold()
        case .delete:
            return text
                .foregroundStyle(accent)
                .strikethrough(true, color: accent)
                .underline(true, color: accent)
        }
    }

    funcdiffLabel(for group: LaTeXEditorDiffGroup) -> String {
        switch group.kind {
        case .added:
            return "Ajout"
        case .removed:
            return "Suppression"
        case .modified:
            return "Modification"
        }
    }

    funcdiffLineLabel(for group: LaTeXEditorDiffGroup) -> String {
        if group.startLine == group.endLine {
            return "Ligne \(group.startLine)"
        }
        return "Lignes \(group.startLine)-\(group.endLine)"
    }

    funcdiffAccentColor(for group: LaTeXEditorDiffGroup) -> Color {
        switch group.kind {
        case .added:
            return .green
        case .removed:
            return .red
        case .modified:
            return .orange
        }
    }

    funcacceptLaTeXEditorDiffGroup(_ group: LaTeXEditorDiffGroup) {
        savedText = DiffEngine.replacingOldBlock(in: savedText, with: group.block)
    }

    funcrejectLaTeXEditorDiffGroup(_ group: LaTeXEditorDiffGroup) {
        text = DiffEngine.replacingNewBlock(in: text, with: group.block)
        reconcileAnnotations()
    }

    funcacceptAllDiffs() {
        savedText = text
        reconcileAnnotations()
    }

    funcrejectAllDiffs() {
        text = savedText
        reconcileAnnotations()
    }

    /// The PDF document for the currently selected pane tab
    vardisplayedPDF: PDFDocument? {
        switch selectedPdfTab {
        case .compiled: return compiledPDF
        case .reference(let id): return workspaceState.referencePDFs[id]
        }
    }

    varactiveReferencePDFID: UUID? {
        if case .reference(let id) = selectedPdfTab { return id }
        return nil
    }

    varactiveReferencePDFDocument: PDFDocument? {
        guard let id = activeReferencePDFID else { return nil }
        return workspaceState.referencePDFs[id]
    }

    varactiveReferencePDFState: ReferencePDFUIState? {
        guard let id = activeReferencePDFID else { return nil }
        return workspaceState.referencePDFUIStates[id]
    }

    varisShowingReference: Bool {
        if case .reference = selectedPdfTab { return true }
        return false
    }

    varactiveReferenceAnnotationCount: Int {
        guard let document = activeReferencePDFDocument else { return 0 }
        return (0..<document.pageCount).reduce(0) { count, pageIndex in
            guard let page = document.page(at: pageIndex) else { return count }
            return count + page.annotations.filter { annotation in
                annotation.type != "Link" && annotation.type != "Widget"
            }.count
        }
    }

    varactiveErrorCount: Int {
        errors.filter { !$0.isWarning }.count
    }

    funcpaperFor(_ id: UUID) -> Paper? {
        allPapers.first { $0.id == id }
    }

    varpdfPane: some View {
        VStack(spacing: 0) {
            // Tab bar (only shown when more than just compiled)
            if pdfPaneTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(pdfPaneTabs, id: \.self) { tab in
                            pdfTabButton(tab)
                        }
                    }
                }
                .frame(height: AppChromeMetrics.tabBarHeight)
                .background(AppChromePalette.surfaceSubbar)
                AppChromeDivider(role: .panel)
            }

            // PDF content — each tab keeps its own PDFView to preserve scroll position
            ZStack {
                // Compiled PDF tab
                Group {
                    if let pdf = compiledPDF {
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
                .opacity(selectedPdfTab == .compiled ? 1 : 0)
                .allowsHitTesting(selectedPdfTab == .compiled)

                // Reference PDF tabs
                ForEach(pdfPaneTabs.compactMap { tab -> UUID? in
                    if case .reference(let id) = tab { return id } else { return nil }
                }, id: \.self) { id in
                    Group {
                        if let pdf = workspaceState.referencePDFs[id],
                           let state = workspaceState.referencePDFUIStates[id],
                           let paper = paperFor(id) {
                            ReferencePDFAnnotationPane(
                                document: pdf,
                                fileURL: paper.fileURL,
                                fitToWidthTrigger: selectedPdfTab == .reference(id) ? fitToWidthTrigger : false,
                                isBridgeCommandTargetActive: selectedPdfTab == .reference(id),
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
                    .opacity(selectedPdfTab == .reference(id) ? 1 : 0)
                    .allowsHitTesting(selectedPdfTab == .reference(id))
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 320, maxWidth: .infinity)
    }

    @ViewBuilder
    funcpdfTabButton(_ tab: LaTeXEditorPdfPaneTab) -> some View {
        let isSelected = tab == selectedPdfTab
        HStack(spacing: 4) {
            Button {
                AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                    selectPdfTab(tab)
                }
            } label: {
                HStack(spacing: 4) {
                    switch tab {
                    case .compiled:
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                        Text(documentMode.compiledTabTitle)
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
                    closePdfTab(tab)
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
        .background(isSelected ? AppChromePalette.selectedAccentFill : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(AppChromePalette.selectedAccent)
                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
                    .matchedGeometryEffect(id: "pdf-tab-indicator", in: pdfTabIndicatorNamespace)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }

    // MARK: - Toolbar

    vareditorToolbar: some View {
        HStack(spacing: 8) {
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
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Créer un nouveau fichier .tex ou .md")
                }
            }

            toolbarCluster(zone: .primary, title: documentMode.primaryClusterTitle) {
                Button(action: runPrimaryDocumentAction) {
                    if isCompiling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.plain)
                .help(documentMode == .latex ? "Compiler (⌘B)" : "Rendre le PDF (⌘B)")
                .keyboardShortcut("b", modifiers: .command)
                .disabled(isCompiling)

                Button(action: saveFile) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Sauvegarder (⌘S)")
                .keyboardShortcut("s", modifiers: .command)

                if documentMode == .latex {
                    Button(action: beginAnnotationFromSelection) {
                        Image(systemName: "highlighter")
                    }
                    .buttonStyle(.plain)
                    .help("Annoter la sélection (⇧⌘A)")
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!canAnnotateCurrentDocument)

                    Button(action: reflowParagraphs) {
                        Image(systemName: "text.justify.leading")
                    }
                    .buttonStyle(.plain)
                    .help("Reflow paragraphes (⌘⇧W)")
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                }

                Button(action: { showErrors.toggle() }) {
                    Image(systemName: "doc.text.below.ecg")
                        .foregroundStyle(showErrors ? .green : errors.contains(where: { !$0.isWarning }) ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(documentMode == .latex ? "Console de compilation" : "Journal du rendu")
            }
            .id("document-toolbar-shortcuts:\(fileURL.path)")

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

            if let referenceState = activeReferencePDFState {
                ReferencePDFToolCluster(title: "Outils", state: referenceState)

                ReferencePDFActionsCluster(
                    title: "Actions",
                    state: referenceState,
                    annotationCount: activeReferenceAnnotationCount,
                    isAnnotationSidebarVisible: showSidebar && selectedLaTeXEditorSidebarSection == .annotations,
                    onChangeSelectedColor: changeSelectedReferenceAnnotationColor,
                    onFitToWidth: fitToWidth,
                    onRefresh: refreshCurrentReference,
                    onSave: saveCurrentReferencePDF,
                    onDeleteSelected: deleteSelectedReferenceAnnotation,
                    onDeleteAll: deleteAllReferenceAnnotations,
                    onToggleAnnotations: {
                        toggleReferenceAnnotationSidebar()
                    }
                )
            }

            Spacer(minLength: 8)

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

            if showTerminal {
                toolbarCluster(zone: .trailing, title: "Term.") {
                    Button(action: addTerminalTab) {
                        Image(systemName: "plus")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Nouveau terminal")

                    Menu {
                        ForEach(0..<TerminalPanel.themes.count, id: \.self) { index in
                            Button {
                                applyTerminalTheme(index)
                            } label: {
                                Text(TerminalPanel.themes[index].name)
                            }
                        }
                    } label: {
                        Image(systemName: "paintpalette")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Thème du terminal")

                    Menu {
                        ForEach(TerminalPanel.fontSizes, id: \.self) { size in
                            Button {
                                applyTerminalFontSize(size)
                            } label: {
                                Text("\(size) pt")
                            }
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Taille de la police du terminal")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
    }

    functoolbarCluster<Content: View>(
        zone: ToolbarZone,
        title: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        AppChromeToolbarCluster(zone: zone, title: title, content: content)
    }

    funcsetToolbarStatus(_ status: ToolbarStatusState, autoClearAfter delay: TimeInterval? = nil) {
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

    functoggleSidebar(section: LaTeXEditorSidebarSection? = nil) {
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            if let section {
                if showSidebar && selectedLaTeXEditorSidebarSection == section {
                    showSidebar = false
                } else {
                    selectedLaTeXEditorSidebarSection = section
                    showSidebar = true
                }
            } else {
                showSidebar.toggle()
            }
        }
    }

    functoggleEditorPaneVisibility() {
        guard !(showEditorPane && !showTerminal && !showPDFPreview) else { return }
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            showEditorPane.toggle()
        }
    }

    functoggleTerminalVisibility() {
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            showTerminal.toggle()
        }
    }

    functoggleReferenceAnnotationSidebar() {
        toggleSidebar(section: .annotations)
    }

    // MARK: - File Operations

    funcloadFile(useAsBaseline: Bool = true) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        latexAnnotations = documentMode == .latex ? LaTeXAnnotationStore.load(for: fileURL) : []
        reconcileAnnotations()
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    funcsaveFile() {
        if documentMode == .latex {
            compile()
        } else {
            renderMarkdownPreview()
        }
    }

    funccreateNewEditorFile(_ kind: NewEditorFileKind) {
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

    funcopenFile(_ url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "tex" || fileExtension == "md" || fileExtension == "bib" || fileExtension == "txt" {
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
    funcreflowParagraphs() {
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

    funcreconcileAnnotations() {
        guard documentMode == .latex else {
            resolvedLaTeXAnnotations = []
            return
        }
        resolvedLaTeXAnnotations = LaTeXAnnotationStore.resolve(latexAnnotations, in: text)
    }

    funcpersistAnnotations() {
        guard documentMode == .latex else { return }
        if latexAnnotations.isEmpty {
            try? LaTeXAnnotationStore.deleteSidecar(for: fileURL)
        } else {
            try? LaTeXAnnotationStore.save(latexAnnotations, for: fileURL)
        }
    }

    funcbeginAnnotationFromSelection() {
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
            selectedLaTeXEditorSidebarSection = .annotations
        }
        pendingAnnotation = LaTeXEditorPendingAnnotation(draft: draft, existingAnnotationID: nil)
    }

    funcsaveLaTeXEditorPendingAnnotation(note: String, sendToClaude: Bool = false) {
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

    funcdeleteAnnotation(_ annotationID: UUID) {
        latexAnnotations.removeAll { $0.id == annotationID }
        persistAnnotations()
        reconcileAnnotations()
    }

    funcsendAnnotationToClaude(_ resolved: ResolvedLaTeXAnnotation) {
        let prompt = annotationPrompt(for: resolved)
        sendPromptToClaudeTerminal(prompt, selectionContent: resolved.annotation.selectedText)
    }

    funcsendAllAnnotationsToClaude() {
        let prompt = batchAnnotationPrompt(for: sidebarAnnotations)
        let selectionContent = sidebarAnnotations
            .map(\.annotation.selectedText)
            .joined(separator: "\n\n---\n\n")
        sendPromptToClaudeTerminal(prompt, selectionContent: selectionContent)
    }

    funcsendPromptToClaudeTerminal(_ prompt: String, selectionContent: String) {
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

    funcaddTerminalTab() {
        NotificationCenter.default.post(name: .canopeTerminalAddTab, object: nil)
    }

    funcapplyTerminalTheme(_ index: Int) {
        let userInfo = ["themeIndex": index]
        NotificationCenter.default.post(name: .canopeTerminalApplyTheme, object: nil, userInfo: userInfo)
    }

    funcapplyTerminalFontSize(_ size: Int) {
        let userInfo = ["fontSize": CGFloat(size)]
        NotificationCenter.default.post(name: .canopeTerminalApplyFontSize, object: nil, userInfo: userInfo)
    }

    funcannotationPrompt(for resolved: ResolvedLaTeXAnnotation) -> String {
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

    funcbatchAnnotationPrompt(for annotations: [ResolvedLaTeXAnnotation]) -> String {
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

    funcbeginEditingAnnotation(_ annotationID: UUID) {
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
    funcsidebarButton(for section: LaTeXEditorSidebarSection, systemImage: String) -> some View {
        let isActive = showSidebar && selectedLaTeXEditorSidebarSection == section

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

    funcannotationRow(_ resolved: ResolvedLaTeXAnnotation) -> some View {
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

    funcloadExistingPDF() {
        if FileManager.default.fileExists(atPath: previewPDFURL.path) {
            compiledPDF = PDFDocument(url: previewPDFURL)
        } else {
            compiledPDF = nil
        }
    }

    funcreloadActiveFileState() {
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

    funcrefreshSplitGrabAreas() {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    SplitViewHelper.thickenSplitViews(contentView)
                }
            }
        }
    }

    funcscrollEditorToLine(_ lineNumber: Int, selectingLine: Bool = true) {
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

    funcscrollEditorToInverseSyncResult(_ result: SyncTeXInverseResult) {
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

    funcresolvedInverseSyncColumn(in lineText: String, result: SyncTeXInverseResult) -> Int {
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

    funcsyncHintAnchor(in context: String, offset: Int) -> String {
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

    funcinverseSyncHighlightLength(in lineText: String, result: SyncTeXInverseResult) -> Int {
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

    funcrevealEditorLocation(for group: LaTeXEditorDiffGroup) {
        revealEditorLocationForLine(
            max(group.preferredRevealLine, 1),
            columnOffset: group.preferredRevealColumn,
            highlightLength: group.preferredRevealLength
        )
    }

    funcrevealEditorLocationForLine(
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

    funcforwardSync(line: Int) {
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

    funcopenReference(_ paper: Paper) {
        let tab = LaTeXEditorPdfPaneTab.reference(paper.id)
        if pdfPaneTabs.contains(tab) {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = paper.id
            }
            writeReferencePaperContext(for: paper.id)
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
        writeReferencePaperContext(for: paper.id)
        if splitLayout == .editorOnly {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                layoutBeforeReference = .editorOnly
                splitLayout = .horizontal
                showPDFPreview = true
            }
        }
    }

    funcselectPdfTab(_ tab: LaTeXEditorPdfPaneTab) {
        switch tab {
        case .compiled:
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = nil
            }
            invalidateReferencePaperContextWrites()
        case .reference(let id):
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = id
            }
            writeReferencePaperContext(for: id)
        }
    }

    funcclosePdfTab(_ tab: LaTeXEditorPdfPaneTab) {
        guard case .reference(let id) = tab else { return }
        let pendingSave = workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges == true
        let documentToSave = workspaceState.referencePDFs[id]
        let fileURLToSave = paperFor(id)?.fileURL
        let remainingReferenceIDs = workspaceState.referencePaperIDs.filter { $0 != id }

        workspaceState.referencePaperIDs.removeAll { $0 == id }
        workspaceState.referencePDFs.removeValue(forKey: id)
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates.removeValue(forKey: id)
        if selectedPdfTab == tab || workspaceState.selectedReferencePaperID == id {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = remainingReferenceIDs.first
            }
            if let nextID = remainingReferenceIDs.first {
                writeReferencePaperContext(for: nextID)
            } else {
                invalidateReferencePaperContextWrites()
            }
        }
        // Restore layout only if no more references AND user hasn't changed layout since
        if pdfPaneTabs == [.compiled],
           let previous = layoutBeforeReference,
           compiledPDF == nil {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                splitLayout = previous
                showPDFPreview = previous != .editorOnly
                layoutBeforeReference = nil
            }
        }

        guard pendingSave,
              let documentToSave,
              let fileURLToSave else { return }

        DispatchQueue.main.async {
            _ = AnnotationService.save(document: documentToSave, to: fileURLToSave)
        }
    }

    funcfitToWidth() {
        fitToWidthTrigger.toggle()
    }

    funcrefreshCurrentReference() {
        guard let id = activeReferencePDFID else { return }
        reloadReferencePDFDocument(id: id)
    }

    funcreferencePDFDocumentDidChange(id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.hasUnsavedChanges = true
        state.annotationRefreshToken = UUID()
        scheduleReferencePDFAutoSave(for: id, delay: preferredReferencePDFAutoSaveDelay(for: state))
    }

    funcpreferredReferencePDFAutoSaveDelay(for state: ReferencePDFUIState) -> TimeInterval {
        if state.selectedAnnotation?.isTextBoxAnnotation == true || state.currentTool == .textBox {
            return 0.9
        }
        return 0.25
    }

    funcscheduleReferencePDFAutoSave(for id: UUID, delay: TimeInterval) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak state] in
            state?.pendingSaveWorkItem = nil
            saveReferencePDF(id: id)
        }

        state.pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    funcsaveCurrentReferencePDF() {
        guard let id = activeReferencePDFID else { return }
        saveReferencePDF(id: id)
    }

    funcsaveReferencePDF(id: UUID) {
        guard let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }

        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem = nil

        if AnnotationService.save(document: document, to: paper.fileURL) {
            workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges = false
        }
    }

    funcreloadReferencePDFDocument(id: UUID) {
        guard let paper = paperFor(id) else { return }
        let state = workspaceState.referencePDFUIStates[id]
        state?.selectedAnnotation = nil
        state?.requestedRestorePageIndex = state?.lastKnownPageIndex

        guard let data = try? Data(contentsOf: paper.fileURL),
              let refreshedDocument = PDFDocument(data: data) else {
            if let loadedDocument = PDFDocument(url: paper.fileURL) {
                AnnotationService.normalizeDocumentAnnotations(in: loadedDocument)
                workspaceState.referencePDFs[id] = loadedDocument
            }
            state?.annotationRefreshToken = UUID()
            state?.pdfViewRefreshToken = UUID()
            return
        }

        AnnotationService.normalizeDocumentAnnotations(in: refreshedDocument)
        workspaceState.referencePDFs[id] = refreshedDocument
        state?.annotationRefreshToken = UUID()
        state?.pdfViewRefreshToken = UUID()
        if activeReferencePDFID == id {
            writeReferencePaperContext(for: id)
        }
    }

    funcwriteReferencePaperContext(for id: UUID) {
        guard let paper = paperFor(id) else { return }
        let title = paper.title
        let authors = paper.authors
        let year = paper.year.map(String.init) ?? "unknown"
        let journal = paper.journal ?? "unknown"
        let doi = paper.doi ?? "unknown"
        let fileURL = paper.fileURL
        let writeID = UUID()

        referenceContextWriteID = writeID

        DispatchQueue.global(qos: .utility).async {
            guard let snapshotDocument = PDFDocument(url: fileURL) else { return }

            var fullText = """
            ========================================
            CURRENTLY OPEN PAPER IN CANOPÉE
            ========================================
            Title: \(title)
            Authors: \(authors)
            Year: \(year)
            Journal: \(journal)
            DOI: \(doi)
            Pages: \(snapshotDocument.pageCount)
            ========================================

            """

            for index in 0..<snapshotDocument.pageCount {
                if let page = snapshotDocument.page(at: index), let text = page.string {
                    fullText += "--- Page \(index + 1) ---\n\(text)\n\n"
                }
            }

            let shouldWrite = DispatchQueue.main.sync {
                referenceContextWriteID == writeID && activeReferencePDFID == id
            }
            guard shouldWrite else { return }

            CanopeContextFiles.writePaper(fullText)
            CanopeContextFiles.writeIDESelectionState(
                ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: fileURL)
            )
            CanopeContextFiles.clearLegacySelectionMirror()
        }
    }

    funcinvalidateReferencePaperContextWrites() {
        referenceContextWriteID = UUID()
    }

    funcdeleteSelectedReferenceAnnotation() {
        guard let id = activeReferencePDFID,
              let annotation = activeReferencePDFState?.selectedAnnotation else { return }
        deleteReferenceAnnotation(annotation, in: id)
    }

    funcdeleteReferenceAnnotation(_ annotation: PDFAnnotation, in id: UUID) {
        guard let page = annotation.page else { return }
        let state = workspaceState.referencePDFUIStates[id]
        let wasSelected = state?.selectedAnnotation === annotation

        state?.pushUndoAction { [weak state] in
            page.addAnnotation(annotation)
            if wasSelected {
                state?.selectedAnnotation = annotation
            }
            state?.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        if wasSelected {
            state?.selectedAnnotation = nil
        }
        page.removeAnnotation(annotation)
        state?.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    funcdeleteAllReferenceAnnotations() {
        guard let id = activeReferencePDFID,
              let document = activeReferencePDFDocument else { return }

        var removedAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.type != "Link" && annotation.type != "Widget" {
                removedAnnotations.append((page: page, annotation: annotation))
                page.removeAnnotation(annotation)
            }
        }

        workspaceState.referencePDFUIStates[id]?.pushUndoAction {
            for (page, annotation) in removedAnnotations {
                page.addAnnotation(annotation)
            }
            workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        activeReferencePDFState?.selectedAnnotation = nil
        workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    funcchangeSelectedReferenceAnnotationColor(_ color: NSColor) {
        guard let id = activeReferencePDFID,
              let state = activeReferencePDFState else { return }

        guard let annotation = state.selectedAnnotation else { return }
        changeReferenceAnnotationColor(annotation, to: color, in: id)
    }

    funcchangeReferenceAnnotationColor(_ annotation: PDFAnnotation, to color: NSColor, in id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }

        let previousCurrentColor = state.currentColor
        let previousAnnotationColor = annotation.isTextBoxAnnotation ? annotation.textBoxFillColor : annotation.color

        state.pushUndoAction { [weak state] in
            guard let state else { return }
            state.currentColor = previousCurrentColor
            AnnotationService.applyColor(previousAnnotationColor, to: annotation)
            state.selectedAnnotation = annotation
            state.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        state.currentColor = color
        state.selectedAnnotation = annotation
        AnnotationService.applyColor(color, to: annotation)
        referencePDFDocumentDidChange(id: id)
    }

    funcbeginEditingReferenceAnnotationNote(_ annotation: PDFAnnotation, in id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.selectedAnnotation = annotation
        state.editingNoteText = annotation.contents ?? ""
        state.isEditingNote = true
    }

    funcsaveReferenceAnnotationNote(for id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id],
              let annotation = state.selectedAnnotation else { return }
        let previousContents = annotation.contents ?? ""
        let newContents = state.editingNoteText

        state.pushUndoAction { [weak state] in
            guard let state else { return }
            annotation.contents = previousContents
            state.selectedAnnotation = annotation
            state.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        annotation.contents = newContents
        state.isEditingNote = false
        state.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    funccancelReferenceAnnotationNoteEdit(for id: UUID) {
        workspaceState.referencePDFUIStates[id]?.isEditingNote = false
    }

    // MARK: - Compilation

    funcrunPrimaryDocumentAction() {
        switch documentMode {
        case .latex:
            compile()
        case .markdown:
            renderMarkdownPreview()
        }
    }

    @discardableResult
    funcwriteCurrentTextToDisk() -> Bool {
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

    funccompile() {
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

    funcrenderMarkdownPreview() {
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

    funcstartFileWatcher() {
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

    funcstopFileWatcher() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    funcmodificationDate() -> Date? {
        Self.modificationDate(for: fileURL)
    }

    nonisolated static func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

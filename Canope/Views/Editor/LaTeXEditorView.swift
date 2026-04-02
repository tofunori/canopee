import SwiftUI
import SwiftData
import PDFKit

enum EditorChromeMetrics {
    static let toolbarHeight: CGFloat = 32
    static let tabBarHeight: CGFloat = 24
}

extension Notification.Name {
    static let syncTeXScrollToLine = Notification.Name("syncTeXScrollToLine")
    static let syncTeXForwardSync = Notification.Name("syncTeXForwardSync")
    static let editorRevealLocation = Notification.Name("editorRevealLocation")
}

struct LaTeXEditorView: View {
    private static let threePaneCoordinateSpace = "LaTeXThreePaneLayout"

    private enum SidebarSizing {
        static let minWidth: CGFloat = 160
        static let maxWidth: CGFloat = 320
        static let defaultWidth: CGFloat = 220
        static let activityBarWidth: CGFloat = 44
        static let resizeHandleWidth: CGFloat = 8
    }

    private enum ThreePaneSizing {
        static let dividerWidth: CGFloat = 10
    }

    private enum ThreePaneRole {
        case terminal
        case editor
        case pdf
    }

    private struct PendingAnnotation: Identifiable {
        let id = UUID()
        var draft: LaTeXAnnotationDraft
        var existingAnnotationID: UUID?
    }

    private struct DiffGroup: Identifiable, Equatable {
        let review: ReviewDiffBlock

        var id: String { review.id }
        var block: TextDiffBlock { review.block }
        var rows: [ReviewDiffRow] { review.rows }
        var startLine: Int { review.block.startLine }
        var endLine: Int { review.block.endLine }
        var preferredRevealLine: Int { review.preferredRevealLine }
        var preferredRevealColumn: Int { review.preferredRevealColumn }
        var preferredRevealLength: Int { review.preferredRevealLength }
        var kind: TextDiffBlockKind { review.block.kind }

        static func == (lhs: DiffGroup, rhs: DiffGroup) -> Bool {
            lhs.review == rhs.review
        }
    }

    private enum SidebarSection: String {
        case files
        case annotations
        case diff
    }

    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    var onOpenPDF: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var openPaperIDs: [UUID] = []
    var editorTabBar: AnyView? = nil
    @State private var text = ""
    @State private var savedText = ""
    @State private var compiledPDF: PDFDocument?
    @State private var errors: [CompilationError] = []
    @State private var compileOutput: String = ""
    @State private var isCompiling = false
    @State private var syncTarget: SyncTeXForwardResult?
    @State private var inverseSyncResult: SyncTeXInverseResult?
    @State private var lastModified: Date?
    @State private var latexAnnotations: [LaTeXAnnotation] = []
    @State private var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] = []
    @State private var selectedEditorRange: NSRange?
    @State private var pendingAnnotation: PendingAnnotation?
    @State private var sidebarResizeStartWidth: CGFloat?
    @State private var threePaneLeftWidth: CGFloat?
    @State private var threePaneRightWidth: CGFloat?
    @State private var threePaneDragStartLeftWidth: CGFloat?
    @State private var threePaneDragStartRightWidth: CGFloat?
    @State private var isDraggingThreePaneDivider = false

    // PDF pane tabs (compiled + reference articles)
    enum PdfPaneTab: Hashable {
        case compiled
        case reference(UUID)
    }
    @Query private var allPapers: [Paper]
    @State private var fitToWidthTrigger = false

    enum SplitLayout: String {
        case horizontal
        case vertical
        case editorOnly
    }

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

    private var projectRoot: URL { fileURL.deletingLastPathComponent() }
    private var errorLines: Set<Int> {
        Set(errors.filter { !$0.isWarning && $0.line > 0 }.map { $0.line })
    }
    private var canCreateAnnotationFromSelection: Bool {
        guard let range = selectedEditorRange, range.location != NSNotFound, range.length > 0 else {
            return false
        }

        return !resolvedLaTeXAnnotations.contains { resolved in
            resolved.resolvedRange == range
        }
    }

    private var sidebarAnnotations: [ResolvedLaTeXAnnotation] {
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

    private var diffGroups: [DiffGroup] {
        DiffEngine.reviewBlocks(old: savedText, new: text).map { DiffGroup(review: $0) }
    }

    private var showSidebar: Bool {
        get { workspaceState.showSidebar }
        nonmutating set { workspaceState.showSidebar = newValue }
    }

    private var selectedSidebarSection: SidebarSection {
        get { SidebarSection(rawValue: workspaceState.selectedSidebarSection) ?? .files }
        nonmutating set { workspaceState.selectedSidebarSection = newValue.rawValue }
    }

    private var sidebarWidth: CGFloat {
        get {
            let stored = CGFloat(workspaceState.sidebarWidth)
            guard stored.isFinite, stored > 0 else { return SidebarSizing.defaultWidth }
            return min(max(stored, SidebarSizing.minWidth), SidebarSizing.maxWidth)
        }
        nonmutating set {
            workspaceState.sidebarWidth = Double(min(max(newValue, SidebarSizing.minWidth), SidebarSizing.maxWidth))
        }
    }

    private var isCompactDiffSidebar: Bool {
        sidebarWidth < 220
    }

    private var showPDFPreview: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set { workspaceState.showPDFPreview = newValue }
    }

    private var showEditorPane: Bool {
        get { workspaceState.showEditorPane }
        nonmutating set { workspaceState.showEditorPane = newValue }
    }

    private var showErrors: Bool {
        get { workspaceState.showErrors }
        nonmutating set { workspaceState.showErrors = newValue }
    }

    private var splitLayout: SplitLayout {
        get { SplitLayout(rawValue: workspaceState.splitLayout) ?? .editorOnly }
        nonmutating set {
            workspaceState.splitLayout = newValue.rawValue
            workspaceState.showPDFPreview = newValue != .editorOnly
        }
    }

    private var panelArrangement: LaTeXPanelArrangement {
        get { workspaceState.panelArrangement }
        nonmutating set { workspaceState.panelArrangement = newValue }
    }

    private var isPDFLeadingInLayout: Bool {
        panelArrangement == .pdfEditorTerminal
    }

    private var editorFontSize: CGFloat {
        get { CGFloat(workspaceState.editorFontSize) }
        nonmutating set { workspaceState.editorFontSize = Double(newValue) }
    }

    private var editorTheme: Int {
        get { min(max(workspaceState.editorTheme, 0), Self.editorThemes.count - 1) }
        nonmutating set { workspaceState.editorTheme = newValue }
    }

    private var pdfPaneTabs: [PdfPaneTab] {
        [.compiled] + workspaceState.referencePaperIDs.map { .reference($0) }
    }

    private var selectedPdfTab: PdfPaneTab {
        if let id = workspaceState.selectedReferencePaperID {
            return .reference(id)
        }
        return .compiled
    }

    private var layoutBeforeReference: SplitLayout? {
        get { workspaceState.layoutBeforeReference.flatMap(SplitLayout.init(rawValue:)) }
        nonmutating set { workspaceState.layoutBeforeReference = newValue?.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
            Divider()

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
                    savePendingAnnotation(note: note)
                },
                onSaveAndSend: { note in
                    savePendingAnnotation(note: note, sendToClaude: true)
                }
            )
        }
        .onChange(of: inverseSyncResult) {
            if let result = inverseSyncResult {
                scrollEditorToInverseSyncResult(result)
                inverseSyncResult = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncTeXForwardSync)) { notification in
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
    private var workAreaPane: some View {
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

    @ViewBuilder
    private var horizontalThreePaneLayout: some View {
        GeometryReader { proxy in
            let roles = threePaneRoles
            let totalContentWidth = max(0, proxy.size.width - (ThreePaneSizing.dividerWidth * 2))
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

    private var threePaneRoles: (ThreePaneRole, ThreePaneRole, ThreePaneRole) {
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
    private func threePaneView(for role: ThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .pdf:
            pdfPane
        }
    }

    private func paneMinWidth(for role: ThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 160
        case .editor:
            return 160
        case .pdf:
            return 180
        }
    }

    private func paneIdealWidth(for role: ThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 320
        case .editor:
            return 620
        case .pdf:
            return 320
        }
    }

    private func resolvedThreePaneWidths(
        for roles: (ThreePaneRole, ThreePaneRole, ThreePaneRole),
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

    private func threePaneResizeHandle(
        onEnter: @escaping () -> Void,
        onExit: @escaping () -> Void,
        drag: @escaping () -> AnyGesture<DragGesture.Value>
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: ThreePaneSizing.dividerWidth)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
            }
            .onHover { hovering in
                if hovering {
                    onEnter()
                } else {
                    onExit()
                }
            }
            .gesture(drag())
    }

    @ViewBuilder
    private var editorAndPDFPane: some View {
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

    private var hiddenEditorPlaceholderPane: some View {
        ContentUnavailableView(
            "Panneau LaTeX fermé",
            systemImage: "doc.text",
            description: Text("Rouvre le panneau LaTeX depuis la barre d’outils, ou garde seulement le terminal et/ou le PDF.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var embeddedTerminalPane: some View {
        TerminalPanel(
            workspaceState: terminalWorkspaceState,
            document: nil,
            isVisible: isActive && showTerminal,
            topInset: 0,
            showsInlineControls: false
        )
        .frame(minWidth: 160, idealWidth: 320, maxWidth: .infinity)
    }

    private var sidebarPane: some View {
        HStack(spacing: 0) {
            sidebarActivityBar
            Divider()
            Group {
                switch selectedSidebarSection {
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
                ? SidebarSizing.activityBarWidth + sidebarWidth + SidebarSizing.resizeHandleWidth + 1
                : SidebarSizing.activityBarWidth
        )
        .animation(nil, value: showSidebar)
    }

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: SidebarSizing.resizeHandleWidth)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
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
    }

    private var sidebarActivityBar: some View {
        VStack(spacing: 8) {
            sidebarButton(for: .files, systemImage: "folder")
            sidebarButton(for: .annotations, systemImage: "note.text")
            sidebarButton(for: .diff, systemImage: "arrow.left.arrow.right.square")
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 44)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var fileBrowserSidebar: some View {
        FileBrowserView(rootURL: projectRoot) { url in
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

    private var annotationSidebar: some View {
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

    private var latexAnnotationSidebar: some View {
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
            Divider()

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

    private func referenceAnnotationSidebar(
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
            Divider()

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
                }
            )
            .id(state.annotationRefreshToken)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var diffSidebar: some View {
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

            Divider()

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
    private func diffBatchActionButton(
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

    private var editorPane: some View {
        VStack(spacing: 0) {
            if let editorTabBar {
                editorTabBar
                Divider()
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
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        Image(systemName: errors.contains(where: { !$0.isWarning }) ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(errors.contains(where: { !$0.isWarning }) ? .red : .green)
                        Text(errors.isEmpty ? "Compilation réussie" : "\(errors.filter { !$0.isWarning }.count) erreur(s), \(errors.filter { $0.isWarning }.count) avertissement(s)")
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
                    .background(.bar)

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
    private func diffRow(_ group: DiffGroup) -> some View {
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
                    rejectDiffGroup(group)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Rejeter ce bloc")

                Button {
                    acceptDiffGroup(group)
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
    private func reviewRow(_ row: ReviewDiffRow) -> some View {
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

    private func compactDiffSnippet(
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

    private func reviewText(from spans: [ReviewInlineSpan], accent: Color) -> Text {
        guard !spans.isEmpty else { return Text(" ") }

        return spans.reduce(Text("")) { partial, span in
            partial + reviewSpanText(span, accent: accent)
        }
    }

    private func reviewSpanText(_ span: ReviewInlineSpan, accent: Color) -> Text {
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

    private func diffLabel(for group: DiffGroup) -> String {
        switch group.kind {
        case .added:
            return "Ajout"
        case .removed:
            return "Suppression"
        case .modified:
            return "Modification"
        }
    }

    private func diffLineLabel(for group: DiffGroup) -> String {
        if group.startLine == group.endLine {
            return "Ligne \(group.startLine)"
        }
        return "Lignes \(group.startLine)-\(group.endLine)"
    }

    private func diffAccentColor(for group: DiffGroup) -> Color {
        switch group.kind {
        case .added:
            return .green
        case .removed:
            return .red
        case .modified:
            return .orange
        }
    }

    private func acceptDiffGroup(_ group: DiffGroup) {
        savedText = DiffEngine.replacingOldBlock(in: savedText, with: group.block)
    }

    private func rejectDiffGroup(_ group: DiffGroup) {
        text = DiffEngine.replacingNewBlock(in: text, with: group.block)
        reconcileAnnotations()
    }

    private func acceptAllDiffs() {
        savedText = text
        reconcileAnnotations()
    }

    private func rejectAllDiffs() {
        text = savedText
        reconcileAnnotations()
    }

    /// The PDF document for the currently selected pane tab
    private var displayedPDF: PDFDocument? {
        switch selectedPdfTab {
        case .compiled: return compiledPDF
        case .reference(let id): return workspaceState.referencePDFs[id]
        }
    }

    private var activeReferencePDFID: UUID? {
        if case .reference(let id) = selectedPdfTab { return id }
        return nil
    }

    private var activeReferencePDFDocument: PDFDocument? {
        guard let id = activeReferencePDFID else { return nil }
        return workspaceState.referencePDFs[id]
    }

    private var activeReferencePDFState: ReferencePDFUIState? {
        guard let id = activeReferencePDFID else { return nil }
        return workspaceState.referencePDFUIStates[id]
    }

    private var isShowingReference: Bool {
        if case .reference = selectedPdfTab { return true }
        return false
    }

    private var activeReferenceAnnotationCount: Int {
        guard let document = activeReferencePDFDocument else { return 0 }
        return (0..<document.pageCount).reduce(0) { count, pageIndex in
            guard let page = document.page(at: pageIndex) else { return count }
            return count + page.annotations.filter { annotation in
                annotation.type != "Link" && annotation.type != "Widget"
            }.count
        }
    }

    private func paperFor(_ id: UUID) -> Paper? {
        allPapers.first { $0.id == id }
    }

    private var pdfPane: some View {
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
                .frame(height: EditorChromeMetrics.tabBarHeight)
                .background(.bar)
                Divider()
            }

            // PDF content — each tab keeps its own PDFView to preserve scroll position
            ZStack {
                // Compiled PDF tab
                Group {
                    if let pdf = compiledPDF {
                        PDFPreviewView(
                            document: pdf,
                            syncTarget: selectedPdfTab == .compiled ? syncTarget : nil,
                            onInverseSync: { result in inverseSyncResult = result },
                            fitToWidthTrigger: selectedPdfTab == .compiled ? fitToWidthTrigger : false
                        )
                    } else {
                        ContentUnavailableView(
                            "Pas encore compilé",
                            systemImage: "doc.text",
                            description: Text("⌘B pour compiler")
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
    private func pdfTabButton(_ tab: PdfPaneTab) -> some View {
        let isSelected = tab == selectedPdfTab
        HStack(spacing: 4) {
            Button {
                selectPdfTab(tab)
            } label: {
                HStack(spacing: 4) {
                    switch tab {
                    case .compiled:
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                        Text("PDF compilé")
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            toolbarCluster {
                Button(action: {
                    showSidebar.toggle()
                }) {
                    Image(systemName: "sidebar.left")
                        .symbolVariant(showSidebar ? .none : .slash)
                }
                .buttonStyle(.plain)
                .help("Afficher la barre latérale")

                toolbarInnerDivider

                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.green)
                Text(fileURL.lastPathComponent)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            toolbarCluster {
                Button(action: compile) {
                    if isCompiling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.plain)
                .help("Compiler (⌘B)")
                .keyboardShortcut("b", modifiers: .command)
                .disabled(isCompiling)

                Button(action: saveFile) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Sauvegarder (⌘S)")
                .keyboardShortcut("s", modifiers: .command)

                Button(action: beginAnnotationFromSelection) {
                    Image(systemName: "highlighter")
                }
                .buttonStyle(.plain)
                .help("Annoter la sélection (⇧⌘A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!canCreateAnnotationFromSelection)

                Button(action: reflowParagraphs) {
                    Image(systemName: "text.justify.leading")
                }
                .buttonStyle(.plain)
                .help("Reflow paragraphes (⌘⇧W)")
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button(action: { showErrors.toggle() }) {
                    Image(systemName: "doc.text.below.ecg")
                        .foregroundStyle(showErrors ? .green : errors.contains(where: { !$0.isWarning }) ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help("Console de compilation")
            }

            toolbarCluster {
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

                toolbarInnerDivider

                Menu {
                    Button {
                        splitLayout = .horizontal
                        showPDFPreview = true
                    } label: {
                        Label("Côte à côte", systemImage: "rectangle.split.2x1")
                        if splitLayout == .horizontal { Image(systemName: "checkmark") }
                    }
                    Button {
                        splitLayout = .vertical
                        showPDFPreview = true
                    } label: {
                        Label("Haut / Bas", systemImage: "rectangle.split.1x2")
                        if splitLayout == .vertical { Image(systemName: "checkmark") }
                    }
                    Button {
                        splitLayout = .editorOnly
                        showPDFPreview = false
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
                            panelArrangement = arrangement
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
            }

            if let referenceState = activeReferencePDFState {
                ReferencePDFToolCluster(state: referenceState)

                ReferencePDFActionsCluster(
                    state: referenceState,
                    annotationCount: activeReferenceAnnotationCount,
                    isAnnotationSidebarVisible: showSidebar && selectedSidebarSection == .annotations,
                    onChangeSelectedColor: changeSelectedReferenceAnnotationColor,
                    onFitToWidth: fitToWidth,
                    onRefresh: refreshCurrentReference,
                    onSave: saveCurrentReferencePDF,
                    onDeleteSelected: deleteSelectedReferenceAnnotation,
                    onDeleteAll: deleteAllReferenceAnnotations,
                    onToggleAnnotations: {
                        if showSidebar && selectedSidebarSection == .annotations {
                            showSidebar = false
                        } else {
                            selectedSidebarSection = .annotations
                            showSidebar = true
                        }
                    }
                )
            }

            Spacer(minLength: 8)

            toolbarCluster {
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

            toolbarCluster {
                Button(action: {
                    if showEditorPane && !showTerminal && !showPDFPreview {
                        return
                    }
                    showEditorPane.toggle()
                }) {
                    Image(systemName: showEditorPane ? "doc.text.fill" : "doc.text")
                        .foregroundStyle(showEditorPane ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .help("Panneau LaTeX")
                .disabled(showEditorPane && !showTerminal && !showPDFPreview)

                toolbarInnerDivider

                Button(action: { showTerminal.toggle() }) {
                    Image(systemName: showTerminal ? "terminal.fill" : "terminal")
                        .foregroundStyle(showTerminal ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Terminal")

                if showTerminal {
                    toolbarInnerDivider

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
        .frame(height: EditorChromeMetrics.toolbarHeight)
        .background(.bar)
    }

    private var toolbarInnerDivider: some View {
        Divider()
            .frame(height: 12)
    }

    private func toolbarCluster<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    // MARK: - File Operations

    private func loadFile(useAsBaseline: Bool = true) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        latexAnnotations = LaTeXAnnotationStore.load(for: fileURL)
        reconcileAnnotations()
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func saveFile() {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        savedText = text
        reconcileAnnotations()
        lastModified = modificationDate()
        compile()
    }

    private func openFile(_ url: URL) {
        if url.pathExtension == "tex" {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
                savedText = content
                latexAnnotations = LaTeXAnnotationStore.load(for: url)
                reconcileAnnotations()
            }
        }
    }

    /// Reflow: join paragraph lines into single lines. Visual word wrap handles display.
    /// Preserves blank lines and LaTeX structural commands.
    private func reflowParagraphs() {
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

    private func reconcileAnnotations() {
        resolvedLaTeXAnnotations = LaTeXAnnotationStore.resolve(latexAnnotations, in: text)
    }

    private func persistAnnotations() {
        if latexAnnotations.isEmpty {
            try? LaTeXAnnotationStore.deleteSidecar(for: fileURL)
        } else {
            try? LaTeXAnnotationStore.save(latexAnnotations, for: fileURL)
        }
    }

    private func beginAnnotationFromSelection() {
        guard let range = selectedEditorRange,
              canCreateAnnotationFromSelection,
              let draft = LaTeXAnnotationStore.makeDraft(from: range, in: text) else {
            return
        }

        if !showSidebar {
            showSidebar = true
        }
        selectedSidebarSection = .annotations
        pendingAnnotation = PendingAnnotation(draft: draft, existingAnnotationID: nil)
    }

    private func savePendingAnnotation(note: String, sendToClaude: Bool = false) {
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

    private func deleteAnnotation(_ annotationID: UUID) {
        latexAnnotations.removeAll { $0.id == annotationID }
        persistAnnotations()
        reconcileAnnotations()
    }

    private func sendAnnotationToClaude(_ resolved: ResolvedLaTeXAnnotation) {
        let prompt = annotationPrompt(for: resolved)
        sendPromptToClaudeTerminal(prompt, selectionContent: resolved.annotation.selectedText)
    }

    private func sendAllAnnotationsToClaude() {
        let prompt = batchAnnotationPrompt(for: sidebarAnnotations)
        let selectionContent = sidebarAnnotations
            .map(\.annotation.selectedText)
            .joined(separator: "\n\n---\n\n")
        sendPromptToClaudeTerminal(prompt, selectionContent: selectionContent)
    }

    private func sendPromptToClaudeTerminal(_ prompt: String, selectionContent: String) {
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

    private func addTerminalTab() {
        NotificationCenter.default.post(name: .canopeTerminalAddTab, object: nil)
    }

    private func applyTerminalTheme(_ index: Int) {
        let userInfo = ["themeIndex": index]
        NotificationCenter.default.post(name: .canopeTerminalApplyTheme, object: nil, userInfo: userInfo)
    }

    private func applyTerminalFontSize(_ size: Int) {
        let userInfo = ["fontSize": CGFloat(size)]
        NotificationCenter.default.post(name: .canopeTerminalApplyFontSize, object: nil, userInfo: userInfo)
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

    private func batchAnnotationPrompt(for annotations: [ResolvedLaTeXAnnotation]) -> String {
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

    private func beginEditingAnnotation(_ annotationID: UUID) {
        guard let resolved = resolvedLaTeXAnnotations.first(where: { $0.annotation.id == annotationID }) else {
            return
        }

        if let range = resolved.resolvedRange,
           let draft = LaTeXAnnotationStore.makeDraft(from: range, in: text, note: resolved.annotation.note) {
            pendingAnnotation = PendingAnnotation(draft: draft, existingAnnotationID: annotationID)
            return
        }

        pendingAnnotation = PendingAnnotation(
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
    private func sidebarButton(for section: SidebarSection, systemImage: String) -> some View {
        let isActive = showSidebar && selectedSidebarSection == section

        Button {
            if isActive {
                showSidebar = false
            } else {
                selectedSidebarSection = section
                showSidebar = true
            }
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

    private func annotationRow(_ resolved: ResolvedLaTeXAnnotation) -> some View {
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

    private func loadExistingPDF() {
        let pdfURL = fileURL.deletingPathExtension().appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: pdfURL.path) {
            compiledPDF = PDFDocument(url: pdfURL)
        } else {
            compiledPDF = nil
        }
    }

    private func reloadActiveFileState() {
        stopFileWatcher()
        pendingAnnotation = nil
        selectedEditorRange = nil
        syncTarget = nil
        inverseSyncResult = nil
        errors = []
        compileOutput = ""
        loadFile()
        loadExistingPDF()
        if isActive {
            startFileWatcher()
        }
        refreshSplitGrabAreas()
    }

    private func refreshSplitGrabAreas() {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    MainWindow.thickenSplitViews(contentView)
                }
            }
        }
    }

    private func scrollEditorToLine(_ lineNumber: Int, selectingLine: Bool = true) {
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

    private func scrollEditorToInverseSyncResult(_ result: SyncTeXInverseResult) {
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

    private func resolvedInverseSyncColumn(in lineText: String, result: SyncTeXInverseResult) -> Int {
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

    private func syncHintAnchor(in context: String, offset: Int) -> String {
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

    private func inverseSyncHighlightLength(in lineText: String, result: SyncTeXInverseResult) -> Int {
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

    private func revealEditorLocation(for group: DiffGroup) {
        revealEditorLocationForLine(
            max(group.preferredRevealLine, 1),
            columnOffset: group.preferredRevealColumn,
            highlightLength: group.preferredRevealLength
        )
    }

    private func revealEditorLocationForLine(
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

    private func forwardSync(line: Int) {
        let pdfPath = fileURL.deletingPathExtension().appendingPathExtension("pdf").path
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

    private func openReference(_ paper: Paper) {
        let tab = PdfPaneTab.reference(paper.id)
        if pdfPaneTabs.contains(tab) {
            workspaceState.selectedReferencePaperID = paper.id
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
        workspaceState.selectedReferencePaperID = paper.id
        writeReferencePaperContext(for: paper.id)
        if splitLayout == .editorOnly {
            layoutBeforeReference = .editorOnly
            splitLayout = .horizontal
            showPDFPreview = true
        }
    }

    private func selectPdfTab(_ tab: PdfPaneTab) {
        switch tab {
        case .compiled:
            workspaceState.selectedReferencePaperID = nil
        case .reference(let id):
            workspaceState.selectedReferencePaperID = id
            writeReferencePaperContext(for: id)
        }
    }

    private func closePdfTab(_ tab: PdfPaneTab) {
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
            workspaceState.selectedReferencePaperID = remainingReferenceIDs.first
            if let nextID = remainingReferenceIDs.first {
                writeReferencePaperContext(for: nextID)
            }
        }
        // Restore layout only if no more references AND user hasn't changed layout since
        if pdfPaneTabs == [.compiled],
           let previous = layoutBeforeReference,
           compiledPDF == nil {
            splitLayout = previous
            showPDFPreview = previous != .editorOnly
            layoutBeforeReference = nil
        }

        guard pendingSave,
              let documentToSave,
              let fileURLToSave else { return }

        DispatchQueue.main.async {
            _ = AnnotationService.save(document: documentToSave, to: fileURLToSave)
        }
    }

    private func fitToWidth() {
        fitToWidthTrigger.toggle()
    }

    private func refreshCurrentReference() {
        guard let id = activeReferencePDFID else { return }
        reloadReferencePDFDocument(id: id)
    }

    private func referencePDFDocumentDidChange(id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.hasUnsavedChanges = true
        state.annotationRefreshToken = UUID()
        scheduleReferencePDFAutoSave(for: id, delay: preferredReferencePDFAutoSaveDelay(for: state))
    }

    private func preferredReferencePDFAutoSaveDelay(for state: ReferencePDFUIState) -> TimeInterval {
        if state.selectedAnnotation?.isTextBoxAnnotation == true || state.currentTool == .textBox {
            return 0.9
        }
        return 0.25
    }

    private func scheduleReferencePDFAutoSave(for id: UUID, delay: TimeInterval) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak state] in
            state?.pendingSaveWorkItem = nil
            saveReferencePDF(id: id)
        }

        state.pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func saveCurrentReferencePDF() {
        guard let id = activeReferencePDFID else { return }
        saveReferencePDF(id: id)
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

    private func writeReferencePaperContext(for id: UUID) {
        guard let paper = paperFor(id) else { return }
        let title = paper.title
        let authors = paper.authors
        let year = paper.year.map(String.init) ?? "unknown"
        let journal = paper.journal ?? "unknown"
        let doi = paper.doi ?? "unknown"
        let fileURL = paper.fileURL

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

            CanopeContextFiles.writePaper(fullText)
            CanopeContextFiles.writeIDESelectionState(
                ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: fileURL)
            )
            CanopeContextFiles.clearLegacySelectionMirror()
        }
    }

    private func deleteSelectedReferenceAnnotation() {
        guard let id = activeReferencePDFID,
              let annotation = activeReferencePDFState?.selectedAnnotation else { return }
        deleteReferenceAnnotation(annotation, in: id)
    }

    private func deleteReferenceAnnotation(_ annotation: PDFAnnotation, in id: UUID) {
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

    private func deleteAllReferenceAnnotations() {
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

    private func changeSelectedReferenceAnnotationColor(_ color: NSColor) {
        guard let id = activeReferencePDFID,
              let state = activeReferencePDFState else { return }

        guard let annotation = state.selectedAnnotation else { return }
        let previousCurrentColor = state.currentColor
        let previousAnnotationColor = annotation.color

        state.pushUndoAction { [weak state] in
            guard let state else { return }
            state.currentColor = previousCurrentColor
            if annotation.isTextBoxAnnotation {
                annotation.setTextBoxFillColor(previousAnnotationColor)
            } else {
                annotation.color = previousAnnotationColor
            }
            state.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        state.currentColor = color
        if annotation.isTextBoxAnnotation {
            annotation.setTextBoxFillColor(AnnotationColor.annotationColor(color, for: "FreeText"))
        } else {
            annotation.color = AnnotationColor.annotationColor(color, for: annotation.type ?? "")
        }

        workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    private func beginEditingReferenceAnnotationNote(_ annotation: PDFAnnotation, in id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.selectedAnnotation = annotation
        state.editingNoteText = annotation.contents ?? ""
        state.isEditingNote = true
    }

    private func saveReferenceAnnotationNote(for id: UUID) {
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

    private func cancelReferenceAnnotationNoteEdit(for id: UUID) {
        workspaceState.referencePDFUIStates[id]?.isEditingNote = false
    }

    // MARK: - Compilation

    private func compile() {
        guard !isCompiling else { return }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        isCompiling = true
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
            }
        }
    }

    // MARK: - File Watching (polling-based for reliability with external editors)

    @State private var pollTimer: Timer?

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

// MARK: - PDF Preview with SyncTeX inverse sync

struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument
    var syncTarget: SyncTeXForwardResult?
    var onInverseSync: ((SyncTeXInverseResult) -> Void)?
    var fitToWidthTrigger: Bool = false

    func makeNSView(context: Context) -> NSView {
        let container = PDFPreviewContainerView()
        let pdfView = container.pdfView
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        let deselectionOverlay = container.deselectionOverlay
        deselectionOverlay.shouldConsumeClick = { [weak coordinator = context.coordinator, weak pdfView] point, event in
            guard let coordinator, let pdfView else { return false }
            return coordinator.shouldConsumeDeselectionClick(at: point, event: event, in: pdfView)
        }
        deselectionOverlay.onConsumeClick = { [weak coordinator = context.coordinator, weak pdfView] point, event in
            guard let coordinator, let pdfView else { return }
            coordinator.consumeDeselectionClick(at: point, event: event, in: pdfView)
        }

        // Enable pinch-to-zoom: auto-scale sets the initial fit,
        // then we disable it so manual zoom gestures work.
        DispatchQueue.main.async {
            pdfView.autoScales = false
        }

        // Add ⌘+click gesture for inverse sync
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        clickGesture.numberOfClicksRequired = 1
        pdfView.addGestureRecognizer(clickGesture)
        context.coordinator.configureSelectionObservation(for: pdfView)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? PDFPreviewContainerView else { return }
        let pdfView = container.pdfView
        if pdfView.document !== document {
            pdfView.document = document
            // Fit to view first, then allow manual zoom
            pdfView.autoScales = true
            DispatchQueue.main.async {
                pdfView.autoScales = false
            }
        }
        context.coordinator.onInverseSync = onInverseSync
        context.coordinator.configureSelectionObservation(for: pdfView)

        // Fit to width
        if fitToWidthTrigger != context.coordinator.lastFitTrigger {
            context.coordinator.lastFitTrigger = fitToWidthTrigger
            pdfView.autoScales = true
            DispatchQueue.main.async {
                pdfView.autoScales = false
            }
        }

        // Forward sync: scroll to target
        if let target = syncTarget,
           let page = document.page(at: target.page - 1) {
            let displayBox = pdfView.displayBox
            let pageBounds = page.bounds(for: displayBox)
            let pdfKitX = pageBounds.minX + target.h
            let pdfKitY = pageBounds.maxY - target.v
            let rect = CGRect(
                x: pdfKitX,
                y: pdfKitY,
                width: max(target.width, 100),
                height: max(target.height, 14)
            )
            pdfView.go(to: rect, on: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator: NSObject {
        private static let selectionFileQueue = DispatchQueue(label: "canope.pdf-preview-selection", qos: .utility)

        weak var pdfView: PDFView?
        weak var observedSelectionPDFView: PDFView?
        var onInverseSync: ((SyncTeXInverseResult) -> Void)?
        var lastFitTrigger: Bool = false
        private var hadSelectionAtMouseDown = false
        private var clickedInsideSelectionAtMouseDown = false

        func shouldConsumeDeselectionClick(at locationInView: NSPoint, event: NSEvent, in pdfView: PDFView) -> Bool {
            guard event.type == .leftMouseDown,
                  event.modifierFlags.contains(.command) == false,
                  pdfView.currentSelection != nil else {
                return false
            }

            return isPointInsideCurrentSelection(locationInView, in: pdfView) == false
        }

        func consumeDeselectionClick(at locationInView: NSPoint, event: NSEvent, in pdfView: PDFView) {
            guard shouldConsumeDeselectionClick(at: locationInView, event: event, in: pdfView) else { return }
            clearSelection(in: pdfView)
            hadSelectionAtMouseDown = false
            clickedInsideSelectionAtMouseDown = false
        }

        func configureSelectionObservation(for pdfView: PDFView) {
            self.pdfView = pdfView
            guard observedSelectionPDFView !== pdfView else { return }

            if let observedSelectionPDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: observedSelectionPDFView
                )
            }

            observedSelectionPDFView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChangedNotification(_:)),
                name: Notification.Name.PDFViewSelectionChanged,
                object: pdfView
            )
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView,
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return }

            let locationInView = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: locationInView, nearest: true),
                  let pageIndex = pdfView.document?.index(for: page) else { return }

            let pagePoint = pdfView.convert(locationInView, to: page)
            let displayBox = pdfView.displayBox
            let pageBounds = page.bounds(for: displayBox)

            let synctexX = pagePoint.x - pageBounds.minX
            let synctexY = pageBounds.maxY - pagePoint.y

            let pdfPath = pdfView.document?.documentURL?.path ?? ""
            guard !pdfPath.isEmpty else { return }
            let pg = pageIndex + 1

            let hint = syncTeXHint(for: page, point: pagePoint)
            if let result = SyncTeXService.inverseSync(page: pg, x: synctexX, y: synctexY, pdfPath: pdfPath, hint: hint) {
                onInverseSync?(result)
            }
        }

        private func syncTeXHint(for page: PDFPage, point: CGPoint) -> SyncTeXHint? {
            func normalized(_ string: String?) -> String {
                (string ?? "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let lineText = normalized(page.selectionForLine(at: point)?.string)
            guard lineText.isEmpty == false else { return nil }

            let wordText = normalized(page.selectionForWord(at: point)?.string)
            guard wordText.isEmpty == false else {
                return SyncTeXHint(offset: 0, context: lineText)
            }

            let nsLine = lineText as NSString
            let wordRange = nsLine.range(of: wordText)
            guard wordRange.location != NSNotFound else {
                return SyncTeXHint(offset: 0, context: lineText)
            }

            let contextPadding = 24
            let contextStart = max(0, wordRange.location - contextPadding)
            let contextEnd = min(nsLine.length, wordRange.location + wordRange.length + contextPadding)
            let contextRange = NSRange(location: contextStart, length: contextEnd - contextStart)
            let context = nsLine.substring(with: contextRange)
            let offset = wordRange.location - contextStart

            return SyncTeXHint(offset: offset, context: context)
        }

        @objc
        private func handleSelectionChangedNotification(_ notification: Notification) {
            guard let pdfView,
                  let fileURL = pdfView.document?.documentURL else {
                return
            }

            let selectedText = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let state = ClaudeIDESelectionState.makeSnapshot(selectedText: selectedText, fileURL: fileURL)

            Self.selectionFileQueue.async {
                CanopeContextFiles.writeIDESelectionState(state)
                CanopeContextFiles.clearLegacySelectionMirror()
            }
        }

        func handlePreMouseDown(event: NSEvent, at locationInView: NSPoint, in pdfView: SelectablePDFPreviewView) -> Bool {
            let canHandleDeselection = event.modifierFlags.contains(.command) == false && pdfView.currentSelection != nil
            let clickedInsideSelection = canHandleDeselection && isPointInsideCurrentSelection(locationInView, in: pdfView)

            hadSelectionAtMouseDown = canHandleDeselection
            clickedInsideSelectionAtMouseDown = clickedInsideSelection

            guard canHandleDeselection, clickedInsideSelection == false else {
                return false
            }

            clearSelection(in: pdfView)
            hadSelectionAtMouseDown = false
            clickedInsideSelectionAtMouseDown = false
            return true
        }

        func handlePostMouseUp(
            event: NSEvent,
            at locationInView: NSPoint,
            didDrag: Bool,
            in pdfView: SelectablePDFPreviewView
        ) {
            defer {
                hadSelectionAtMouseDown = false
                clickedInsideSelectionAtMouseDown = false
            }

            guard event.modifierFlags.contains(.command) == false,
                  event.clickCount == 1,
                  hadSelectionAtMouseDown,
                  clickedInsideSelectionAtMouseDown == false,
                  didDrag == false else {
                return
            }
            let clickedPoint = locationInView
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                if self.isPointInsideCurrentSelection(clickedPoint, in: pdfView) {
                    return
                }
                self.clearSelection(in: pdfView)
            }
        }

        private func isPointInsideCurrentSelection(_ locationInView: NSPoint, in pdfView: PDFView) -> Bool {
            guard let selection = pdfView.currentSelection else { return false }

            for lineSelection in selection.selectionsByLine() {
                for page in lineSelection.pages {
                    let pageBounds = lineSelection.bounds(for: page)
                    guard pageBounds.isNull == false, pageBounds.isEmpty == false else { continue }
                    let selectionRect = pdfView.convert(pageBounds, from: page).insetBy(dx: -4, dy: -4)
                    if selectionRect.contains(locationInView) {
                        return true
                    }
                }
            }

            return false
        }

        private func clearSelection(in pdfView: PDFView) {
            if let selection = pdfView.currentSelection?.copy() as? PDFSelection {
                selection.color = .clear
                pdfView.setCurrentSelection(selection, animate: false)
                pdfView.documentView?.displayIfNeeded()
                pdfView.displayIfNeeded()
            }

            pdfView.clearSelection()
            pdfView.setCurrentSelection(nil, animate: false)
            pdfView.documentView?.needsDisplay = true
            pdfView.needsDisplay = true

            guard let fileURL = pdfView.document?.documentURL else { return }
            let state = ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: fileURL)
            Self.selectionFileQueue.async {
                CanopeContextFiles.writeIDESelectionState(state)
                CanopeContextFiles.clearLegacySelectionMirror()
            }
        }
    }
}

final class PDFPreviewContainerView: NSView {
    let pdfView = SelectablePDFPreviewView()
    let deselectionOverlay = PDFPreviewDeselectionOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        deselectionOverlay.translatesAutoresizingMaskIntoConstraints = false

        addSubview(pdfView)
        addSubview(deselectionOverlay)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            deselectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            deselectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            deselectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            deselectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SelectablePDFPreviewView: PDFView {
    var onPreMouseDown: ((NSEvent, NSPoint, SelectablePDFPreviewView) -> Bool)?
    var onPostMouseUp: ((NSEvent, NSPoint, Bool, SelectablePDFPreviewView) -> Void)?
    private var didDragDuringMouseSession = false

    override func mouseDown(with event: NSEvent) {
        didDragDuringMouseSession = false
        let location = convert(event.locationInWindow, from: nil)
        if onPreMouseDown?(event, location, self) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        didDragDuringMouseSession = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let location = convert(event.locationInWindow, from: nil)
        onPostMouseUp?(event, location, didDragDuringMouseSession, self)
        didDragDuringMouseSession = false
    }
}

final class PDFPreviewDeselectionOverlayView: NSView {
    var shouldConsumeClick: ((NSPoint, NSEvent) -> Bool)?
    var onConsumeClick: ((NSPoint, NSEvent) -> Void)?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent ?? NSApp.currentEvent,
              shouldConsumeClick?(point, event) == true else {
            return nil
        }

        return self
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onConsumeClick?(location, event)
    }
}

private struct ReferencePDFAnnotationPane: View {
    let document: PDFDocument
    let fileURL: URL
    let fitToWidthTrigger: Bool
    let isBridgeCommandTargetActive: Bool
    @ObservedObject var state: ReferencePDFUIState
    let onDocumentChanged: () -> Void
    let onMarkupAppearanceNeedsRefresh: () -> Void
    let onSaveNote: () -> Void
    let onCancelNote: () -> Void
    let onAutoSave: () -> Void

    var body: some View {
        PDFKitView(
            document: document,
            fileURL: fileURL,
            currentTool: $state.currentTool,
            currentColor: $state.currentColor,
            selectedAnnotation: $state.selectedAnnotation,
            selectedText: $state.selectedText,
            restoredPageIndex: state.requestedRestorePageIndex,
            onDocumentChanged: {
                onDocumentChanged()
            },
            onCurrentPageChanged: { pageIndex in
                state.lastKnownPageIndex = pageIndex
            },
            onMarkupAppearanceNeedsRefresh: {
                onMarkupAppearanceNeedsRefresh()
            },
            clearSelectionAction: $state.clearSelectionAction,
            undoAction: Binding(
                get: { state.undoAction },
                set: { state.setPDFViewUndoAction($0) }
            ),
            applyBridgeAnnotation: Binding(
                get: { state.applyBridgeAnnotationAction },
                set: { state.setPDFViewApplyBridgeAnnotation($0) }
            )
        )
        .id(state.pdfViewRefreshToken)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        .onAppear {
            refreshBridgeCommandTarget()
        }
        .onChange(of: state.selectedAnnotation) {
            guard let annotation = state.selectedAnnotation, annotation.type == "Text" else { return }
            state.editingNoteText = annotation.contents ?? ""
            state.isEditingNote = true
        }
        .onChange(of: fitToWidthTrigger) {
            state.requestedRestorePageIndex = state.lastKnownPageIndex
            state.pdfViewRefreshToken = UUID()
        }
        .onChange(of: isBridgeCommandTargetActive) {
            refreshBridgeCommandTarget()
        }
        .onChange(of: state.bridgeCommandRegistrationToken) {
            refreshBridgeCommandTarget()
        }
        .onDisappear {
            BridgeCommandRouter.shared.removeActiveHandler(id: bridgeCommandTargetID)
            if state.hasUnsavedChanges {
                onAutoSave()
            }
        }
        .sheet(isPresented: $state.isEditingNote) {
            NoteEditorSheet(
                text: $state.editingNoteText,
                onSave: onSaveNote,
                onCancel: onCancelNote
            )
        }
    }

    private var bridgeCommandTargetID: String {
        "reference-pdf:\(fileURL.path)"
    }

    private func refreshBridgeCommandTarget() {
        guard isBridgeCommandTargetActive else {
            BridgeCommandRouter.shared.removeActiveHandler(id: bridgeCommandTargetID)
            return
        }

        BridgeCommandRouter.shared.setActiveHandler(id: bridgeCommandTargetID) { command in
            _ = BridgeCommandWatcher.handleCommand(
                command,
                document: document,
                applyBridgeAnnotation: state.applyBridgeAnnotationAction
            )
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.key == KeyEquivalent("z") && press.modifiers.contains(.command) {
            state.undoAction?()
            return .handled
        }

        if press.key == .escape {
            if !state.selectedText.isEmpty {
                state.clearSelectionAction?()
            } else if state.selectedAnnotation != nil {
                state.selectedAnnotation = nil
            } else {
                state.currentTool = .pointer
            }
            return .handled
        }

        return .ignored
    }
}

private struct ReferencePDFToolCluster: View {
    @ObservedObject var state: ReferencePDFUIState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(AnnotationTool.allCases), id: \.id) { tool in
                ReferencePDFToolbarIconButton(
                    systemName: tool.icon,
                    isActive: state.currentTool == tool,
                    help: tool.displayName,
                    action: {
                        state.currentTool = tool
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct ReferencePDFActionsCluster: View {
    @ObservedObject var state: ReferencePDFUIState
    let annotationCount: Int
    let isAnnotationSidebarVisible: Bool
    let onChangeSelectedColor: (NSColor) -> Void
    let onFitToWidth: () -> Void
    let onRefresh: () -> Void
    let onSave: () -> Void
    let onDeleteSelected: () -> Void
    let onDeleteAll: () -> Void
    let onToggleAnnotations: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AnnotationColor.all, id: \.name) { item in
                    Button {
                        onChangeSelectedColor(item.color)
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: annotationColorSwatchImage(item.color))
                                .renderingMode(.original)

                            Text(item.name)

                            if colorsMatch(item.color, state.currentColor) {
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                ReferencePDFToolbarIconLabel(systemName: "paintpalette", isActive: false)
            }
            .buttonStyle(.plain)
            .help("Couleur d’annotation")

            Divider()
                .frame(height: 12)

            ReferencePDFToolbarIconButton(
                systemName: "arrow.left.and.right.square",
                isActive: false,
                help: "Ajuster à la largeur",
                action: onFitToWidth
            )

            ReferencePDFToolbarIconButton(
                systemName: "arrow.clockwise",
                isActive: false,
                help: "Actualiser le PDF de référence",
                action: onRefresh
            )

            ReferencePDFToolbarIconButton(
                systemName: "square.and.arrow.down",
                isActive: state.hasUnsavedChanges,
                help: "Enregistrer les annotations du PDF",
                action: onSave
            )

            ReferencePDFToolbarIconButton(
                systemName: "trash",
                isActive: state.selectedAnnotation != nil,
                activeTint: .red,
                help: "Supprimer l’annotation sélectionnée",
                action: onDeleteSelected
            )
            .disabled(state.selectedAnnotation == nil)

            ReferencePDFToolbarIconButton(
                systemName: "trash.slash",
                isActive: false,
                help: "Effacer toutes les annotations du PDF",
                action: onDeleteAll
            )
            .disabled(annotationCount == 0)

            ReferencePDFToolbarIconButton(
                systemName: "sidebar.right",
                symbolVariant: isAnnotationSidebarVisible ? .none : .slash,
                isActive: isAnnotationSidebarVisible,
                help: "Afficher les annotations PDF",
                action: onToggleAnnotations
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
    let ac = AnnotationColor.normalized(a)
    let bc = AnnotationColor.normalized(b)
    return abs(ac.redComponent - bc.redComponent) < 0.01 &&
           abs(ac.greenComponent - bc.greenComponent) < 0.01 &&
           abs(ac.blueComponent - bc.blueComponent) < 0.01 &&
           abs(ac.alphaComponent - bc.alphaComponent) < 0.01
}

private func annotationColorSwatchImage(_ color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    AnnotationColor.normalized(color).setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
    image.unlockFocus()
    return image
}

private struct ReferencePDFToolbarIconButton: View {
    let systemName: String
    var symbolVariant: SymbolVariants = .none
    let isActive: Bool
    var activeTint: Color = .accentColor
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolVariant(symbolVariant)
                .foregroundStyle(iconTint)
                .frame(width: 16, height: 16)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(backgroundTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(borderTint, lineWidth: borderTint == .clear ? 0 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var iconTint: Color {
        if isActive { return activeTint }
        if isHovered { return .primary }
        return .secondary
    }

    private var backgroundTint: Color {
        if isActive { return activeTint.opacity(0.18) }
        if isHovered { return Color.white.opacity(0.08) }
        return .clear
    }

    private var borderTint: Color {
        if isActive { return activeTint.opacity(0.32) }
        if isHovered { return Color.white.opacity(0.10) }
        return .clear
    }
}

private struct ReferencePDFToolbarIconLabel: View {
    let systemName: String
    let isActive: Bool

    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(isActive ? Color.accentColor : (isHovered ? Color.primary : Color.secondary))
            .frame(width: 16, height: 16)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : (isHovered ? Color.white.opacity(0.08) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.32) : (isHovered ? Color.white.opacity(0.10) : .clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

private struct LaTeXAnnotationNoteSheet: View {
    let title: String
    let selectedText: String
    let initialNote: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    let onSaveAndSend: (String) -> Void

    @State private var note: String

    init(
        title: String,
        selectedText: String,
        initialNote: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void,
        onSaveAndSend: @escaping (String) -> Void
    ) {
        self.title = title
        self.selectedText = selectedText
        self.initialNote = initialNote
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSaveAndSend = onSaveAndSend
        _note = State(initialValue: initialNote)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Extrait")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(selectedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 90, maxHeight: 140)
                .background(Color.yellow.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Note")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $note)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button("Annuler", action: onCancel)
                Spacer()
                Button(initialNote.isEmpty ? "Ajouter et envoyer" : "Enregistrer et envoyer") {
                    onSaveAndSend(trimmedNote)
                }
                .disabled(trimmedNote.isEmpty)

                Button(initialNote.isEmpty ? "Ajouter" : "Enregistrer") {
                    onSave(trimmedNote)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedNote.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 480, idealWidth: 540)
    }
}

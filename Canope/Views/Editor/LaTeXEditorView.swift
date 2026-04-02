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
    static let threePaneCoordinateSpace = "LaTeXThreePaneLayout"

    enum SidebarSizing {
        static let minWidth: CGFloat = 160
        static let maxWidth: CGFloat = 320
        static let defaultWidth: CGFloat = 220
        static let activityBarWidth: CGFloat = 44
        static let resizeHandleWidth: CGFloat = 8
    }

    enum ThreePaneSizing {
        static let dividerWidth: CGFloat = 10
    }

    enum ThreePaneRole {
        case terminal
        case editor
        case pdf
    }

    struct PendingAnnotation: Identifiable {
        let id = UUID()
        var draft: LaTeXAnnotationDraft
        var existingAnnotationID: UUID?
    }

    struct DiffGroup: Identifiable, Equatable {
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

    enum SidebarSection: String {
        case files
        case annotations
        case diff
    }

    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    var onOpenInNewTab: ((URL) -> Void)?
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
    @State var pendingAnnotation: PendingAnnotation?
    @State var sidebarResizeStartWidth: CGFloat?
    @State var threePaneLeftWidth: CGFloat?
    @State var threePaneRightWidth: CGFloat?
    @State var threePaneDragStartLeftWidth: CGFloat?
    @State var threePaneDragStartRightWidth: CGFloat?
    @State var isDraggingThreePaneDivider = false

    // PDF pane tabs (compiled + reference articles)
    enum PdfPaneTab: Hashable {
        case compiled
        case reference(UUID)
    }
    @Query var allPapers: [Paper]
    @State var fitToWidthTrigger = false

    enum SplitLayout: String {
        case horizontal
        case vertical
        case editorOnly
    }

    var projectRoot: URL { fileURL.deletingLastPathComponent() }
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

    var diffGroups: [DiffGroup] {
        DiffEngine.reviewBlocks(old: savedText, new: text).map { DiffGroup(review: $0) }
    }

    var showSidebar: Bool {
        get { workspaceState.showSidebar }
        nonmutating set { workspaceState.showSidebar = newValue }
    }

    var selectedSidebarSection: SidebarSection {
        get { SidebarSection(rawValue: workspaceState.selectedSidebarSection) ?? .files }
        nonmutating set { workspaceState.selectedSidebarSection = newValue.rawValue }
    }

    var sidebarWidth: CGFloat {
        get {
            let stored = CGFloat(workspaceState.sidebarWidth)
            guard stored.isFinite, stored > 0 else { return SidebarSizing.defaultWidth }
            return min(max(stored, SidebarSizing.minWidth), SidebarSizing.maxWidth)
        }
        nonmutating set {
            workspaceState.sidebarWidth = Double(min(max(newValue, SidebarSizing.minWidth), SidebarSizing.maxWidth))
        }
    }

    var isCompactDiffSidebar: Bool {
        sidebarWidth < 220
    }

    var showPDFPreview: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set { workspaceState.showPDFPreview = newValue }
    }

    var showErrors: Bool {
        get { workspaceState.showErrors }
        nonmutating set { workspaceState.showErrors = newValue }
    }

    var splitLayout: SplitLayout {
        get { SplitLayout(rawValue: workspaceState.splitLayout) ?? .editorOnly }
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

    var pdfPaneTabs: [PdfPaneTab] {
        [.compiled] + workspaceState.referencePaperIDs.map { .reference($0) }
    }

    var selectedPdfTab: PdfPaneTab {
        if let id = workspaceState.selectedReferencePaperID {
            return .reference(id)
        }
        return .compiled
    }

    var layoutBeforeReference: SplitLayout? {
        get { workspaceState.layoutBeforeReference.flatMap(SplitLayout.init(rawValue:)) }
        nonmutating set { workspaceState.layoutBeforeReference = newValue?.rawValue }
    }

    // MARK: - File Watching

    @State var pollTimer: Timer?

    // MARK: - Body

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
                title: pending.existingAnnotationID == nil ? "Nouvelle annotation" : "Modifier l'annotation",
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
}

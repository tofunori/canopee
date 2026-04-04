import AppKit
import PDFKit
import SwiftUI
import WebKit

private enum CodeEditorThreePaneRole {
    case terminal
    case editor
    case output
}

struct CodeEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var terminalAppearanceStore = TerminalAppearanceStore.shared
    private static let threePaneCoordinateSpace = "CodeThreePaneLayout"

    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    @ObservedObject var workspaceState: LaTeXWorkspaceUIState
    @ObservedObject var terminalWorkspaceState: TerminalWorkspaceState
    @ObservedObject var documentState: CodeDocumentUIState
    var onOpenInNewTab: ((URL) -> Void)?
    var editorTabBar: AnyView? = nil
    var onPersistWorkspaceState: (() -> Void)?

    @State private var text = ""
    @State private var savedText = ""
    @State private var lastModified: Date?
    @State private var pollTimer: Timer?
    @State private var sidebarResizeStartWidth: CGFloat?
    @State private var threePaneDragStartLeftWidth: CGFloat?
    @State private var threePaneDragStartRightWidth: CGFloat?
    @State private var isDraggingThreePaneDivider = false
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
    private var activeArtifact: ArtifactDescriptor? {
        documentState.activeArtifact
    }
    private var activeArtifacts: [ArtifactDescriptor] {
        documentState.activeArtifacts
    }
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

    private var showOutputPane: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set {
            workspaceState.showPDFPreview = newValue
            documentState.showOutputPane = newValue
        }
    }

    private var splitLayout: LaTeXEditorSplitLayout {
        get { LaTeXEditorSplitLayout(rawValue: workspaceState.splitLayout) ?? .editorOnly }
        nonmutating set {
            workspaceState.splitLayout = newValue.rawValue
            let shouldShowOutput = newValue != .editorOnly
            workspaceState.showPDFPreview = shouldShowOutput
            documentState.showOutputPane = shouldShowOutput
        }
    }

    private var panelArrangement: LaTeXPanelArrangement {
        get { workspaceState.panelArrangement }
        nonmutating set { workspaceState.panelArrangement = newValue }
    }

    private var isOutputLeadingInLayout: Bool {
        panelArrangement == .pdfEditorTerminal
    }

    private var threePaneLeftWidth: CGFloat? {
        get { workspaceState.threePaneLeadingWidth.map { CGFloat($0) } }
        nonmutating set { workspaceState.threePaneLeadingWidth = newValue.map { Double($0) } }
    }

    private var threePaneRightWidth: CGFloat? {
        get { workspaceState.threePaneTrailingWidth.map { CGFloat($0) } }
        nonmutating set { workspaceState.threePaneTrailingWidth = newValue.map { Double($0) } }
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
            syncOutputPaneVisibilityFromWorkspace()
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
                syncOutputPaneVisibilityFromWorkspace()
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
            syncOutputPaneVisibilityFromWorkspace()
            if isActive {
                startFileWatcher()
            }
        }
        .onChange(of: documentState.showOutputPane) {
            if workspaceState.showPDFPreview != documentState.showOutputPane {
                workspaceState.showPDFPreview = documentState.showOutputPane
                onPersistWorkspaceState?()
            }
            persistDocumentWorkspaceState()
        }
        .onChange(of: workspaceState.showPDFPreview) {
            if documentState.showOutputPane != workspaceState.showPDFPreview {
                documentState.showOutputPane = workspaceState.showPDFPreview
            }
            onPersistWorkspaceState?()
        }
        .onChange(of: documentState.showLogs) { persistDocumentWorkspaceState() }
        .onChange(of: documentState.selectedRunID) { persistDocumentWorkspaceState() }
        .onChange(of: documentState.selectedArtifactPath) { persistDocumentWorkspaceState() }
        .onChange(of: showSidebar) { onPersistWorkspaceState?() }
        .onChange(of: workspaceState.sidebarWidth) { onPersistWorkspaceState?() }
        .onChange(of: workspaceState.editorFontSize) { onPersistWorkspaceState?() }
        .onChange(of: workspaceState.splitLayout) { onPersistWorkspaceState?() }
        .onChange(of: workspaceState.panelArrangement) {
            threePaneLeftWidth = nil
            threePaneRightWidth = nil
            onPersistWorkspaceState?()
        }
    }

    private var workAreaPane: some View {
        Group {
            if isActive && showTerminal && showOutputPane && splitLayout == .horizontal {
                horizontalThreePaneLayout
            } else if isActive && showTerminal {
                switch panelArrangement {
                case .terminalEditorPDF:
                    HSplitView {
                        embeddedTerminalPane
                        editorAndOutputPane
                            .layoutPriority(1)
                    }
                case .editorPDFTerminal, .pdfEditorTerminal:
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
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showOutputPane)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: splitLayout)
    }

    @ViewBuilder
    private var horizontalThreePaneLayout: some View {
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

    private var threePaneRoles: (CodeEditorThreePaneRole, CodeEditorThreePaneRole, CodeEditorThreePaneRole) {
        switch panelArrangement {
        case .terminalEditorPDF:
            return (.terminal, .editor, .output)
        case .editorPDFTerminal:
            return (.editor, .output, .terminal)
        case .pdfEditorTerminal:
            return (.output, .editor, .terminal)
        }
    }

    @ViewBuilder
    private func threePaneView(for role: CodeEditorThreePaneRole) -> some View {
        switch role {
        case .terminal:
            embeddedTerminalPane
        case .editor:
            editorPane
        case .output:
            outputPane
        }
    }

    private func paneMinWidth(for role: CodeEditorThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 160
        case .editor:
            return 200
        case .output:
            return 220
        }
    }

    private func paneIdealWidth(for role: CodeEditorThreePaneRole) -> CGFloat {
        switch role {
        case .terminal:
            return 320
        case .editor:
            return 620
        case .output:
            return 360
        }
    }

    private func resolvedThreePaneWidths(
        for roles: (CodeEditorThreePaneRole, CodeEditorThreePaneRole, CodeEditorThreePaneRole),
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
    private var editorAndOutputPane: some View {
        if !showOutputPane {
            editorPane
        } else if splitLayout == .horizontal {
            HSplitView {
                if isOutputLeadingInLayout { outputPane }
                editorPane
                if !isOutputLeadingInLayout { outputPane }
            }
        } else if splitLayout == .vertical {
            VSplitView {
                if isOutputLeadingInLayout { outputPane }
                editorPane
                if !isOutputLeadingInLayout { outputPane }
            }
        } else {
            editorPane
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

    private var outputPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Output", systemImage: "chart.xyaxis.line")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(outputStatusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if documentState.manualPreviewArtifact != nil {
                    Button(action: {
                        documentState.returnToSelectedRun()
                        persistDocumentWorkspaceState()
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Retourner au dernier run")
                } else {
                    Button(action: {
                        documentState.selectPreviousRun()
                        persistDocumentWorkspaceState()
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(documentState.canSelectPreviousRun ? .secondary : .tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!documentState.canSelectPreviousRun)
                    .help("Run précédent")

                    Button(action: {
                        documentState.selectNextRun()
                        persistDocumentWorkspaceState()
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(documentState.canSelectNextRun ? .secondary : .tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!documentState.canSelectNextRun)
                    .help("Run suivant")

                    Button(action: refreshSelectedRun) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(documentState.selectedRun == nil)
                    .help("Actualiser le run sélectionné")
                }
                Button(action: revealArtifactDirectoryInFinder) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Afficher le dossier d’artefacts")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppChromePalette.surfaceSubbar)

            if activeArtifacts.count > 1 {
                AppChromeDivider(role: .panel)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(activeArtifacts) { artifact in
                            artifactTabButton(artifact)
                        }
                    }
                }
                .frame(height: AppChromeMetrics.tabBarHeight)
                .background(AppChromePalette.surfaceSubbar)
            }

            AppChromeDivider(role: .panel)

            ArtifactPreviewPane(artifact: activeArtifact)
        }
        .frame(minWidth: 220, idealWidth: 360, maxWidth: .infinity)
    }

    private func artifactTabButton(_ artifact: ArtifactDescriptor) -> some View {
        let isSelected = artifact.url.path == activeArtifact?.url.path
        return Button {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                documentState.selectedArtifactPath = artifact.url.path
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: artifact.kind))
                    .font(.system(size: 9))
                Text(artifact.displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AppChromePalette.tabFill(isSelected: isSelected, isHovered: false, role: .reference))
            .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconName(for artifactKind: ArtifactKind) -> String {
        switch artifactKind {
        case .pdf:
            return "doc.richtext"
        case .image:
            return "photo"
        case .html:
            return "globe"
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
                    documentState.setManualPreviewArtifact(artifact)
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
                        showOutputPane.toggle()
                    }
                }) {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(showOutputPane ? AppChromePalette.info : .secondary)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            splitLayout = .horizontal
                        }
                    } label: {
                        Label("Côte à côte", systemImage: "rectangle.split.2x1")
                        if splitLayout == .horizontal { Image(systemName: "checkmark") }
                    }

                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            splitLayout = .vertical
                        }
                    } label: {
                        Label("Haut / Bas", systemImage: "rectangle.split.1x2")
                        if splitLayout == .vertical { Image(systemName: "checkmark") }
                    }

                    Button {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            splitLayout = .editorOnly
                        }
                    } label: {
                        Label("Éditeur seul", systemImage: "doc.text")
                        if splitLayout == .editorOnly { Image(systemName: "checkmark") }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)

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

    private func syncOutputPaneVisibilityFromWorkspace() {
        if documentState.showOutputPane != workspaceState.showPDFPreview {
            documentState.showOutputPane = workspaceState.showPDFPreview
        }
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

private struct ArtifactPreviewPane: View {
    let artifact: ArtifactDescriptor?

    var body: some View {
        Group {
            if let artifact {
                switch artifact.kind {
                case .pdf:
                    if let document = PDFDocument(url: artifact.url) {
                        PDFPreviewView(document: document, allowsInverseSync: false)
                    } else {
                        unavailableView(
                            title: "PDF introuvable",
                            systemImage: "doc.richtext",
                            description: "Le PDF n’a pas pu être chargé."
                        )
                    }
                case .image:
                    ImageArtifactView(url: artifact.url)
                case .html:
                    WebArtifactView(url: artifact.url)
                }
            } else {
                unavailableView(
                    title: "Aucune sortie",
                    systemImage: "chart.xyaxis.line",
                    description: "Exécute le script pour voir le dernier artefact généré."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
    }
}

private struct ImageArtifactView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        imageView.image = NSImage(contentsOf: url)
        imageView.frame = CGRect(origin: .zero, size: imageView.image?.size ?? .zero)
    }
}

private struct WebArtifactView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let accessURL = url.deletingLastPathComponent()
        webView.loadFileURL(url, allowingReadAccessTo: accessURL)
    }
}

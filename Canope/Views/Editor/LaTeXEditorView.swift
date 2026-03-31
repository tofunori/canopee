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
}

struct LaTeXEditorView: View {
    private struct PendingAnnotation: Identifiable {
        let id = UUID()
        var draft: LaTeXAnnotationDraft
        var existingAnnotationID: UUID?
    }

    private enum SidebarSection: String {
        case files
        case annotations
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
    @State private var syncToLine: Int?
    @State private var lastModified: Date?
    @State private var latexAnnotations: [LaTeXAnnotation] = []
    @State private var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] = []
    @State private var selectedEditorRange: NSRange?
    @State private var pendingAnnotation: PendingAnnotation?

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

    private var showSidebar: Bool {
        get { workspaceState.showSidebar }
        nonmutating set { workspaceState.showSidebar = newValue }
    }

    private var selectedSidebarSection: SidebarSection {
        get { SidebarSection(rawValue: workspaceState.selectedSidebarSection) ?? .files }
        nonmutating set { workspaceState.selectedSidebarSection = newValue.rawValue }
    }

    private var showPDFPreview: Bool {
        get { workspaceState.showPDFPreview }
        nonmutating set { workspaceState.showPDFPreview = newValue }
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
        .onChange(of: syncToLine) {
            if let line = syncToLine {
                scrollEditorToLine(line)
                syncToLine = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncTeXForwardSync)) { notification in
            if let line = notification.userInfo?["line"] as? Int {
                forwardSync(line: line)
            }
        }
        .onAppear {
            loadFile()
            loadExistingPDF()
            if isActive {
                startFileWatcher()
            }
        }
        .onDisappear {
            stopFileWatcher()
        }
        .onChange(of: isActive) {
            if isActive {
                loadFile()
                startFileWatcher()
            } else {
                stopFileWatcher()
            }
        }
        .onChange(of: splitLayout) {
            // Thicken dividers when layout changes (new split views are created)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    MainWindow.thickenSplitViews(contentView)
                }
            }
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var workAreaPane: some View {
        if isActive && showTerminal {
            switch panelArrangement {
            case .terminalEditorPDF:
                HSplitView {
                    embeddedTerminalPane
                    editorAndPDFPane
                }
            case .editorPDFTerminal, .pdfEditorTerminal:
                HSplitView {
                    editorAndPDFPane
                    embeddedTerminalPane
                }
            }
        } else {
            editorAndPDFPane
        }
    }

    @ViewBuilder
    private var editorAndPDFPane: some View {
        if splitLayout == .horizontal {
            HSplitView {
                if showPDFPreview && isPDFLeadingInLayout { pdfPane }
                editorPane
                if showPDFPreview && !isPDFLeadingInLayout { pdfPane }
            }
        } else if splitLayout == .vertical {
            VSplitView {
                if showPDFPreview && isPDFLeadingInLayout { pdfPane }
                editorPane
                if showPDFPreview && !isPDFLeadingInLayout { pdfPane }
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
            showsInlineControls: false
        )
        .frame(minWidth: 160, idealWidth: 360, maxWidth: .infinity)
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
                }
            }
            .frame(
                minWidth: showSidebar ? 160 : 0,
                idealWidth: showSidebar ? 220 : 0,
                maxWidth: showSidebar ? 320 : 0
            )
            .opacity(showSidebar ? 1 : 0)
            .allowsHitTesting(showSidebar)
            .clipped()
        }
        .frame(
            minWidth: 44,
            idealWidth: showSidebar ? 264 : 44,
            maxWidth: showSidebar ? 364 : 44
        )
    }

    private var sidebarActivityBar: some View {
        VStack(spacing: 8) {
            sidebarButton(for: .files, systemImage: "folder")
            sidebarButton(for: .annotations, systemImage: "note.text")
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
                    LazyVStack(spacing: 8) {
                        ForEach(sidebarAnnotations, id: \.annotation.id) { resolved in
                            annotationRow(resolved)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if let editorTabBar {
                editorTabBar
                Divider()
            }

            LaTeXTextEditor(
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
    }

    /// The PDF document for the currently selected pane tab
    private var displayedPDF: PDFDocument? {
        switch selectedPdfTab {
        case .compiled: return compiledPDF
        case .reference(let id): return workspaceState.referencePDFs[id]
        }
    }

    private var isShowingReference: Bool {
        if case .reference = selectedPdfTab { return true }
        return false
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

            // Toolbar for reference tabs
            if isShowingReference {
                HStack(spacing: 6) {
                    Spacer()
                    Button { fitToWidth() } label: {
                        Image(systemName: "arrow.left.and.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Ajuster à la largeur")
                    Button { refreshCurrentReference() } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Actualiser (annotations)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }

            // PDF content — each tab keeps its own PDFView to preserve scroll position
            ZStack {
                // Compiled PDF tab
                Group {
                    if let pdf = compiledPDF {
                        PDFPreviewView(
                            document: pdf,
                            syncTarget: selectedPdfTab == .compiled ? syncTarget : nil,
                            onInverseSync: { line in syncToLine = line },
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
                        if let pdf = workspaceState.referencePDFs[id] {
                            PDFPreviewView(
                                document: pdf,
                                syncTarget: nil,
                                onInverseSync: nil,
                                fitToWidthTrigger: selectedPdfTab == .reference(id) ? fitToWidthTrigger : false
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
    }

    @ViewBuilder
    private func pdfTabButton(_ tab: PdfPaneTab) -> some View {
        let isSelected = tab == selectedPdfTab
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
        .contentShape(Rectangle())
        .onTapGesture {
            // Only switch tab if this tab still exists (not just closed by ✕)
            if pdfPaneTabs.contains(tab) {
                switch tab {
                case .compiled:
                    workspaceState.selectedReferencePaperID = nil
                case .reference(let id):
                    workspaceState.selectedReferencePaperID = id
                }
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            toolbarCluster {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSidebar.toggle()
                    }
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

    private func loadFile() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        savedText = content
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
        CanopeContextFiles.writeSelection(selectionContent)
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
            withAnimation(.easeInOut(duration: 0.15)) {
                if isActive {
                    showSidebar = false
                } else {
                    selectedSidebarSection = section
                    showSidebar = true
                }
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

        return HStack(alignment: .top, spacing: 8) {
            Button {
                beginEditingAnnotation(annotation.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(resolved.isDetached ? Color.orange : Color.yellow)
                            .frame(width: 7, height: 7)
                        Text(resolved.isDetached ? "À recoller" : "Ancrée")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    Text(annotation.selectedText.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

                    if !annotation.note.isEmpty {
                        Text(annotation.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }

                    HStack(spacing: 10) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                deleteAnnotation(annotation.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Supprimer l’annotation")
        }
    }

    private func loadExistingPDF() {
        let pdfURL = fileURL.deletingPathExtension().appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: pdfURL.path) {
            compiledPDF = PDFDocument(url: pdfURL)
        }
    }

    private func scrollEditorToLine(_ lineNumber: Int) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += lines[i].count + 1
        }
        // Select entire line so it highlights in yellow (showFindIndicator)
        let lineLength = lines[lineNumber - 1].count
        let range = NSRange(location: charOffset, length: lineLength)
        NotificationCenter.default.post(name: .syncTeXScrollToLine, object: nil, userInfo: ["range": range])
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
            return
        }
        guard let pdf = PDFDocument(url: paper.fileURL) else { return }
        AnnotationService.normalizeDocumentAnnotations(in: pdf)
        workspaceState.referencePDFs[paper.id] = pdf
        workspaceState.referencePaperIDs.append(paper.id)
        workspaceState.selectedReferencePaperID = paper.id
        if splitLayout == .editorOnly {
            layoutBeforeReference = .editorOnly
            splitLayout = .horizontal
            showPDFPreview = true
        }
    }

    private func closePdfTab(_ tab: PdfPaneTab) {
        guard case .reference(let id) = tab else { return }
        workspaceState.referencePaperIDs.removeAll { $0 == id }
        workspaceState.referencePDFs.removeValue(forKey: id)
        if selectedPdfTab == tab {
            workspaceState.selectedReferencePaperID = nil
        }
        // Restore layout only if no more references AND user hasn't changed layout since
        if pdfPaneTabs == [.compiled],
           let previous = layoutBeforeReference,
           compiledPDF == nil {
            splitLayout = previous
            showPDFPreview = previous != .editorOnly
            layoutBeforeReference = nil
        }
    }

    private func fitToWidth() {
        fitToWidthTrigger.toggle()
    }

    private func refreshCurrentReference() {
        guard case .reference(let id) = selectedPdfTab,
              let paper = paperFor(id),
              let pdf = PDFDocument(url: paper.fileURL) else { return }
        AnnotationService.normalizeDocumentAnnotations(in: pdf)
        workspaceState.referencePDFs[id] = pdf
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
                    loadFile()
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
    var onInverseSync: ((Int) -> Void)?
    var fitToWidthTrigger: Bool = false

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous

        // Enable pinch-to-zoom: auto-scale sets the initial fit,
        // then we disable it so manual zoom gestures work.
        DispatchQueue.main.async {
            pdfView.autoScales = false
        }

        // Add ⌘+click gesture for inverse sync
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        clickGesture.numberOfClicksRequired = 1
        pdfView.addGestureRecognizer(clickGesture)
        context.coordinator.pdfView = pdfView

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
            // Fit to view first, then allow manual zoom
            pdfView.autoScales = true
            DispatchQueue.main.async {
                pdfView.autoScales = false
            }
        }
        context.coordinator.onInverseSync = onInverseSync
        context.coordinator.pdfView = pdfView

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
            let pageBounds = page.bounds(for: .mediaBox)
            let pdfKitY = pageBounds.height - target.v
            let rect = CGRect(x: target.h, y: pdfKitY, width: max(target.width, 100), height: max(target.height, 14))
            pdfView.go(to: rect, on: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onInverseSync: ((Int) -> Void)?
        var lastFitTrigger: Bool = false

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let pdfView = pdfView,
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return }

            let locationInView = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: locationInView, nearest: true),
                  let pageIndex = pdfView.document?.index(for: page) else { return }

            let pagePoint = pdfView.convert(locationInView, to: page)
            let pageBounds = page.bounds(for: .mediaBox)

            let synctexX = pagePoint.x
            let synctexY = pageBounds.height - pagePoint.y

            let pdfPath = pdfView.document?.documentURL?.path ?? ""
            guard !pdfPath.isEmpty else { return }
            let pg = pageIndex + 1

            if let result = SyncTeXService.inverseSync(page: pg, x: synctexX, y: synctexY, pdfPath: pdfPath) {
                onInverseSync?(result.line)
            }
        }
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

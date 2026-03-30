import SwiftUI
import SwiftData
import PDFKit

extension Notification.Name {
    static let syncTeXScrollToLine = Notification.Name("syncTeXScrollToLine")
    static let syncTeXForwardSync = Notification.Name("syncTeXForwardSync")
}

struct LaTeXEditorView: View {
    let fileURL: URL
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    var onOpenPDF: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var openPaperIDs: [UUID] = []
    var siblingPaths: [String] = []
    var onSwitchEditor: ((String) -> Void)?
    var onCloseEditor: ((String) -> Void)?
    @State private var text = ""
    @State private var savedText = ""
    @State private var compiledPDF: PDFDocument?
    @State private var errors: [CompilationError] = []
    @State private var compileOutput: String = ""
    @State private var isCompiling = false
    @State private var showFileBrowser = true
    @State private var showPDFPreview = false
    @State private var showErrors = false
    @State private var splitLayout: SplitLayout = .editorOnly
    @State private var editorFontSize: CGFloat = 14
    @State private var editorTheme: Int = 0
    @State private var syncTarget: SyncTeXForwardResult?
    @State private var syncToLine: Int?
    @State private var lastModified: Date?

    // PDF pane tabs (compiled + reference articles)
    enum PdfPaneTab: Hashable {
        case compiled
        case reference(UUID)
    }
    @Query private var allPapers: [Paper]
    @State private var pdfPaneTabs: [PdfPaneTab] = [.compiled]
    @State private var selectedPdfTab: PdfPaneTab = .compiled
    @State private var referencePDFs: [UUID: PDFDocument] = [:]
    @State private var layoutBeforeReference: SplitLayout?
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

    @State private var hoveredEditorPath: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
            Divider()

            // Main content: file browser | (editor / pdf split)
            HSplitView {
                // File browser (left, resizable)
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
                .frame(
                    minWidth: showFileBrowser ? 140 : 0,
                    idealWidth: showFileBrowser ? 190 : 0,
                    maxWidth: showFileBrowser ? 280 : 0
                )
                .opacity(showFileBrowser ? 1 : 0)
                .allowsHitTesting(showFileBrowser)
                .clipped()

                // Right side: file tabs + editor + PDF
                VStack(spacing: 0) {
                    // File tabs (when multiple .tex files open)
                    if siblingPaths.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(siblingPaths, id: \.self) { path in
                                    let isCurrent = path == fileURL.path
                                    let isHov = hoveredEditorPath == path
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.green)
                                        Text(URL(fileURLWithPath: path).lastPathComponent)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        if let onCloseEditor {
                                            Button {
                                                onCloseEditor(path)
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 7, weight: .bold))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .opacity(isCurrent || isHov ? 1 : 0)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
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
                                    .onTapGesture {
                                        if !isCurrent { onSwitchEditor?(path) }
                                    }
                                    .onHover { hoveredEditorPath = $0 ? path : nil }
                                }
                            }
                        }
                        .frame(height: 24)
                        .background(.bar.opacity(0.5))
                        Divider()
                    }

                // Editor + PDF split (horizontal or vertical)
                if splitLayout == .horizontal {
                    HSplitView {
                        editorPane
                        if showPDFPreview { pdfPane }
                    }
                } else if splitLayout == .vertical {
                    VSplitView {
                        editorPane
                        if showPDFPreview { pdfPane }
                    }
                } else {
                    editorPane
                }
                } // close VStack (file tabs + editor/PDF)
            }
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

    private var editorPane: some View {
        VStack(spacing: 0) {
            LaTeXTextEditor(
                text: $text,
                errorLines: errorLines,
                fontSize: editorFontSize,
                theme: Self.editorThemes[editorTheme],
                baselineText: savedText,
                onTextChange: {}
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
        case .reference(let id): return referencePDFs[id]
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
                .frame(height: 26)
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
                        if let pdf = referencePDFs[id] {
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
                selectedPdfTab = tab
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            // Left group: file browser + LaTeX actions
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showFileBrowser.toggle()
                }
            }) {
                Image(systemName: "sidebar.left")
                    .symbolVariant(showFileBrowser ? .none : .slash)
            }
            .buttonStyle(.plain)
            .help("Fichiers")

            Divider().frame(height: 16)

            Image(systemName: "doc.plaintext")
                .foregroundStyle(.green)
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .fontWeight(.semibold)

            Divider().frame(height: 16)

            // Compile
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

            // Save
            Button(action: saveFile) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Sauvegarder (⌘S)")
            .keyboardShortcut("s", modifiers: .command)

            // Reflow
            Button(action: reflowParagraphs) {
                Image(systemName: "text.justify.leading")
            }
            .buttonStyle(.plain)
            .help("Reflow paragraphes (⌘⇧W)")
            .keyboardShortcut("w", modifiers: [.command, .shift])

            // Console
            Button(action: { showErrors.toggle() }) {
                Image(systemName: "doc.text.below.ecg")
                    .foregroundStyle(showErrors ? .green : errors.contains(where: { !$0.isWarning }) ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Console de compilation")

            Divider().frame(height: 16)

            // Reference paper picker (only papers open in tabs)
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

            Spacer()

            // Layout options
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

            // Font size
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

            // Theme
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

            // Terminal toggle
            Button(action: { showTerminal.toggle() }) {
                Image(systemName: showTerminal ? "terminal.fill" : "terminal")
                    .foregroundStyle(showTerminal ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - File Operations

    private func loadFile() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        savedText = content
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func saveFile() {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        savedText = text
        lastModified = modificationDate()
        compile()
    }

    private func openFile(_ url: URL) {
        if url.pathExtension == "tex" {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
                savedText = content
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
        lastModified = modificationDate()
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
            selectedPdfTab = tab
            return
        }
        guard let pdf = PDFDocument(url: paper.fileURL) else { return }
        AnnotationService.normalizeDocumentAnnotations(in: pdf)
        referencePDFs[paper.id] = pdf
        pdfPaneTabs.append(tab)
        selectedPdfTab = tab
        if splitLayout == .editorOnly {
            layoutBeforeReference = .editorOnly
            splitLayout = .horizontal
            showPDFPreview = true
        }
    }

    private func closePdfTab(_ tab: PdfPaneTab) {
        guard case .reference(let id) = tab else { return }
        pdfPaneTabs.removeAll { $0 == tab }
        referencePDFs.removeValue(forKey: id)
        if selectedPdfTab == tab {
            selectedPdfTab = .compiled
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
        referencePDFs[id] = pdf
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

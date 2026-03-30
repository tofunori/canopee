import SwiftUI
import PDFKit

struct LaTeXEditorView: View {
    let fileURL: URL
    @Binding var showTerminal: Bool
    var onOpenPDF: ((URL) -> Void)?
    @State private var text = ""
    @State private var savedText = ""
    @State private var compiledPDF: PDFDocument?
    @State private var errors: [CompilationError] = []
    @State private var compileOutput: String = ""
    @State private var isCompiling = false
    @State private var showFileBrowser = true
    @State private var showPDFPreview = true
    @State private var showErrors = false
    @State private var splitLayout: SplitLayout = .horizontal
    @State private var editorFontSize: CGFloat = 14
    @State private var editorTheme: Int = 0
    @State private var lastModified: Date?

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

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            editorToolbar
            Divider()

            // Main content: file browser | (editor / pdf split)
            HSplitView {
                // File browser (left, resizable)
                if showFileBrowser {
                    FileBrowserView(rootURL: projectRoot) { url in
                        let ext = url.pathExtension.lowercased()
                        if ext == "pdf" {
                            onOpenPDF?(url)
                        } else {
                            openFile(url)
                        }
                    }
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
            }
        }
        .onAppear {
            loadFile()
            loadExistingPDF()
            startFileWatcher()
        }
        .onDisappear {
            stopFileWatcher()
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

    private var pdfPane: some View {
        Group {
            if let pdf = compiledPDF {
                PDFPreviewView(document: pdf)
            } else {
                ContentUnavailableView(
                    "Pas encore compilé",
                    systemImage: "doc.text",
                    description: Text("⌘B pour compiler")
                )
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            // Left group: file browser + LaTeX actions
            Button(action: { showFileBrowser.toggle() }) {
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
        lastModified = modificationDate()
        // Poll every 1 second — more reliable than DispatchSource for atomic writes
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let currentMod = modificationDate()
            if let currentMod, currentMod != lastModified {
                lastModified = currentMod
                loadFile()
            }
        }
    }

    private func stopFileWatcher() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }
}

// MARK: - PDF Preview

struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }
    }
}

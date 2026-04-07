import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct PDFReaderView: View {
    let paperID: PersistentIdentifier
    var isSplitMode: Bool = false
    var isActive: Bool = true
    @Binding var showTerminal: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var document: PDFDocument?
    @State private var selectedText = ""
    @State private var currentTool: AnnotationTool = .pointer
    @State private var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    @State private var showAnnotationSidebar = false
    @State private var hasUnsavedChanges = false
    @State private var annotationRefreshToken = UUID()
    @State private var selectedAnnotation: PDFAnnotation?
    @State private var isEditingNote = false
    @State private var editingNoteText = ""
    @State private var toolbarStatus: ToolbarStatusState = .idle
    @State private var toolbarStatusClearWorkItem: DispatchWorkItem?
    @State private var annotationExportError: String?
    @State private var undoAction: (() -> Void)?
    @State private var clearSelectionAction: (() -> Void)?
    @State private var applyBridgeAnnotation: ((_ selection: PDFSelection, _ type: PDFAnnotationSubtype, _ color: NSColor) -> Void)?
    @State private var contextWriteID = UUID()
    @State private var pdfViewRefreshToken = UUID()
    @State private var lastKnownPageIndex = 0
    @State private var requestedRestorePageIndex: Int?
    @State private var pendingSaveWorkItem: DispatchWorkItem?
    @StateObject private var searchState = PDFSearchUIState()

    private var paper: Paper? {
        try? modelContext.fetch(
            FetchDescriptor<Paper>(predicate: #Predicate { $0.persistentModelID == paperID })
        ).first
    }

    var body: some View {
        VStack(spacing: 0) {
            AnnotationToolbar(
                currentTool: $currentTool,
                currentColor: $currentColor,
                status: toolbarStatus,
                selectedAnnotation: selectedAnnotation,
                showTerminal: $showTerminal,
                showAnnotations: $showAnnotationSidebar,

                onSave: savePDF,
                activeMarkdownExportFileName: nil,
                companionExportFileName: companionExportFileName,
                onExportToActiveMarkdown: nil,
                onExportToCompanionMarkdown: exportAnnotationsToCompanionMarkdown,
                onExportToChosenMarkdownFile: exportAnnotationsToChosenMarkdownFile,
                onDeleteSelected: deleteSelectedAnnotation,
                onDeleteAll: deleteAllAnnotations,
                onChangeColor: changeSelectedAnnotationColor
            )
            AppChromeDivider(role: .shell)

            if let document, let paper {
                HStack(spacing: 0) {
                    // PDF viewer — takes all available space
                    PDFKitView(
                        document: document,
                        fileURL: paper.fileURL,
                        currentTool: $currentTool,
                        currentColor: $currentColor,
                        selectedAnnotation: $selectedAnnotation,
                        selectedText: $selectedText,
                        restoredPageIndex: requestedRestorePageIndex,
                        searchState: searchState,
                        onDocumentChanged: {
                            hasUnsavedChanges = true
                            annotationRefreshToken = UUID()
                            scheduleAutoSave(delay: preferredAutoSaveDelay())
                        },
                        onCurrentPageChanged: { pageIndex in
                            lastKnownPageIndex = pageIndex
                        },
                        onMarkupAppearanceNeedsRefresh: {
                            DispatchQueue.main.async {
                                reloadDocumentFromDisk()
                            }
                        },
                        clearSelectionAction: $clearSelectionAction,
                        undoAction: $undoAction,
                        fitToWidthAction: .constant(nil),
                        applyBridgeAnnotation: $applyBridgeAnnotation,
                        onUserInteraction: {
                            setPreferredBridgeCommandTarget()
                        }
                    )
                    .id(pdfViewRefreshToken)
                    .onKeyPress(phases: .down) { press in
                        handleKeyPress(press)
                    }
                    .frame(maxWidth: .infinity)

                    if showAnnotationSidebar {
                        AppChromeDivider(role: .panel, axis: .vertical)
                        AnnotationSidebarView(
                            document: document,
                            selectedAnnotation: $selectedAnnotation,
                            onNavigate: { selectedAnnotation = $0 },
                            onDelete: { deleteAnnotation($0) },
                            onEditNote: { annotation in
                                selectedAnnotation = annotation
                                editingNoteText = annotation.contents ?? ""
                                isEditingNote = true
                            },
                            onChangeColor: { annotation, color in
                                changeAnnotationColor(annotation, to: color)
                            }
                        )
                        .id(annotationRefreshToken)
                        .frame(width: 250)
                    }

                }
            } else {
                ContentUnavailableView(
                    "Impossible d'ouvrir le PDF",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showAnnotationSidebar)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showTerminal)
        .navigationTitle(paper?.title ?? "Article")
        .onAppear {
            loadDocument()
            if isSplitMode { showAnnotationSidebar = false }
            refreshBridgeCommandTarget()
        }
        .onChange(of: paperID) {
            loadDocument()
            refreshBridgeCommandTarget()
        }
        .onChange(of: isActive) {
            if isActive { writePaperContext() }
            refreshBridgeCommandTarget()
        }
        .onChange(of: document?.documentURL) { refreshBridgeCommandTarget() }
        .onChange(of: applyBridgeAnnotation != nil) { refreshBridgeCommandTarget() }
        .onDisappear { BridgeCommandRouter.shared.removeActiveHandler(id: bridgeCommandTargetID) }
        .onDisappear { autoSave() }
        .onChange(of: selectedAnnotation) {
            if let annotation = selectedAnnotation, annotation.type == "Text" {
                editingNoteText = annotation.contents ?? ""
                isEditingNote = true
            }
        }
        .sheet(isPresented: $isEditingNote) {
            NoteEditorSheet(
                text: $editingNoteText,
                onSave: {
                    selectedAnnotation?.contents = editingNoteText
                    annotationRefreshToken = UUID()
                    isEditingNote = false
                    savePDF()
                },
                onCancel: { isEditingNote = false }
            )
        }
        .alert("Impossible d’exporter les annotations", isPresented: Binding(
            get: { annotationExportError != nil },
            set: { if !$0 { annotationExportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(annotationExportError ?? "")
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Cmd+Z → undo
        if press.key == KeyEquivalent("z") && press.modifiers.contains(.command) {
            undoAction?()
            return .handled
        }
        // Delete
        if press.key == .delete || press.key == .deleteForward {
            deleteSelectedAnnotation()
            return .handled
        }
        // Escape → pointer
        if press.key == .escape {
            if !selectedText.isEmpty {
                clearSelectedText()
            } else if selectedAnnotation != nil {
                selectedAnnotation = nil
            } else {
                currentTool = .pointer
            }
            return .handled
        }
        // 1-8 → tool selection
        if let char = press.characters.first, let digit = Int(String(char)),
           digit >= 1, digit <= AnnotationTool.allCases.count {
            currentTool = AnnotationTool.allCases[digit - 1]
            return .handled
        }
        return .ignored
    }

    // MARK: - Actions

    private func loadDocument() {
        guard let paper else { return }
        if let loadedDocument = PDFDocument(url: paper.fileURL) {
            AnnotationService.normalizeDocumentAnnotations(in: loadedDocument)
            document = loadedDocument
        } else {
            document = nil
        }
        selectedAnnotation = nil
        if !paper.isRead { paper.isRead = true }

        if isActive {
            writePaperContext()
        }
    }

    private func writePaperContext() {
        guard document != nil, let paper else { return }
        selectedText = ""
        CanopeContextFiles.writeIDESelectionState(
            ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: paper.fileURL)
        )
        CanopeContextFiles.clearLegacySelectionMirror()

        let paperURL = paper.fileURL
        let title = paper.title
        let authors = paper.authors
        let year = paper.year.map(String.init) ?? "unknown"
        let journal = paper.journal ?? "unknown"
        let doi = paper.doi ?? "unknown"
        let writeID = UUID()
        contextWriteID = writeID

        DispatchQueue.global(qos: .utility).async {
            guard let snapshotDocument = PDFDocument(url: paperURL) else { return }

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
            for i in 0..<snapshotDocument.pageCount {
                if let page = snapshotDocument.page(at: i), let text = page.string {
                    fullText += "--- Page \(i + 1) ---\n\(text)\n\n"
                }
            }

            let shouldWrite = DispatchQueue.main.sync { contextWriteID == writeID }
            guard shouldWrite else { return }
            CanopeContextFiles.writePaper(fullText)
        }
    }

    private func savePDF() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard let document, let paper else { return }
        if AnnotationService.save(document: document, to: paper.fileURL) {
            hasUnsavedChanges = false
            paper.dateModified = Date()
        }
    }

    private var companionExportFileName: String {
        guard let paper else { return "annotations.md" }
        return PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL).lastPathComponent
    }

    private func exportAnnotationsToCompanionMarkdown() {
        guard let paper else { return }
        exportAnnotationsToMarkdown(target: .companionFile(PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL)))
    }

    private func exportAnnotationsToChosenMarkdownFile() {
        guard let paper else { return }
        let suggestedURL = PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL)
        guard let targetURL = presentMarkdownExportPanel(suggestedURL: suggestedURL) else { return }
        exportAnnotationsToMarkdown(target: .companionFile(targetURL))
    }

    private func exportAnnotationsToMarkdown(target: PDFAnnotationExportTarget) {
        guard let document, let paper else { return }

        do {
            _ = try PDFAnnotationMarkdownExporter.export(
                document: document,
                source: .reference(pdfURL: paper.fileURL),
                target: target
            )
            setToolbarStatus(.exported, autoClearAfter: 1.6)
        } catch {
            annotationExportError = error.localizedDescription
        }
    }

    private func presentMarkdownExportPanel(suggestedURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.isExtensionHidden = false
        panel.title = "Exporter les annotations"
        panel.message = "Choisis un fichier Markdown à mettre à jour avec ces annotations."
        panel.prompt = "Exporter"
        return panel.runModal() == .OK ? panel.url : nil
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

    private func preferredAutoSaveDelay() -> TimeInterval {
        if selectedAnnotation?.isTextBoxAnnotation == true || currentTool == .textBox {
            return 0.9
        }
        return 0.25
    }

    private func scheduleAutoSave(delay: TimeInterval = 0.25) {
        pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            savePDF()
        }

        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func reloadDocumentFromDisk() {
        guard let paper else { return }
        selectedAnnotation = nil
        requestedRestorePageIndex = lastKnownPageIndex
        guard let data = try? Data(contentsOf: paper.fileURL),
              let refreshedDocument = PDFDocument(data: data) else {
            if let loadedDocument = PDFDocument(url: paper.fileURL) {
                AnnotationService.normalizeDocumentAnnotations(in: loadedDocument)
                document = loadedDocument
            } else {
                document = nil
            }
            annotationRefreshToken = UUID()
            pdfViewRefreshToken = UUID()
            return
        }
        AnnotationService.normalizeDocumentAnnotations(in: refreshedDocument)
        document = refreshedDocument
        annotationRefreshToken = UUID()
        pdfViewRefreshToken = UUID()
    }

    private func autoSave() {
        if hasUnsavedChanges { savePDF() }
    }

    private func clearSelectedText() {
        clearSelectionAction?()
        selectedText = ""
    }

    private func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation else { return }
        deleteAnnotation(annotation)
    }

    private func deleteAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        if selectedAnnotation === annotation { selectedAnnotation = nil }
        page.removeAnnotation(annotation)
        hasUnsavedChanges = true
        annotationRefreshToken = UUID()
        scheduleAutoSave()
    }

    private func deleteAllAnnotations() {
        guard let document else { return }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for annotation in page.annotations where annotation.type != "Link" && annotation.type != "Widget" {
                page.removeAnnotation(annotation)
            }
        }
        selectedAnnotation = nil
        hasUnsavedChanges = true
        annotationRefreshToken = UUID()
        scheduleAutoSave()
    }

    private func changeSelectedAnnotationColor(_ color: NSColor) {
        guard let annotation = selectedAnnotation else { return }
        changeAnnotationColor(annotation, to: color)
    }

    private func changeAnnotationColor(_ annotation: PDFAnnotation, to color: NSColor) {
        selectedAnnotation = annotation
        AnnotationService.applyColor(color, to: annotation)
        hasUnsavedChanges = true
        annotationRefreshToken = UUID()
        scheduleAutoSave()
    }

    private var bridgeCommandTargetID: String {
        "library-pdf:\(String(describing: paperID))"
    }

    private func refreshBridgeCommandTarget() {
        guard isActive else {
            BridgeCommandRouter.shared.removeActiveHandler(id: bridgeCommandTargetID)
            return
        }

        BridgeCommandRouter.shared.setActiveHandler(id: bridgeCommandTargetID) { command in
            _ = BridgeCommandWatcher.handleCommand(
                command,
                document: document,
                applyBridgeAnnotation: applyBridgeAnnotation
            )
        }

        if !isSplitMode {
            setPreferredBridgeCommandTarget()
        }
    }

    private func setPreferredBridgeCommandTarget() {
        guard isActive else { return }
        BridgeCommandRouter.shared.setPreferredHandler(id: bridgeCommandTargetID)
    }
}

// MARK: - Note Editor Sheet

struct NoteEditorSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Modifier la note")
                .font(.headline)
            TextEditor(text: $text)
                .frame(minWidth: 300, minHeight: 150)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Enregistrer", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

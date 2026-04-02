import SwiftUI
import SwiftData
import PDFKit

struct PDFReaderView: View {
    let paperID: PersistentIdentifier
    var isSplitMode: Bool = false
    var isActive: Bool = true
    @Binding var showTerminal: Bool
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
    @State private var undoAction: (() -> Void)?
    @State private var clearSelectionAction: (() -> Void)?
    @State private var applyBridgeAnnotation: ((_ selection: PDFSelection, _ type: PDFAnnotationSubtype, _ color: NSColor) -> Void)?
    @State private var contextWriteID = UUID()
    @State private var pdfViewRefreshToken = UUID()
    @State private var lastKnownPageIndex = 0
    @State private var requestedRestorePageIndex: Int?
    @State private var pendingSaveWorkItem: DispatchWorkItem?

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
                selectedAnnotation: selectedAnnotation,
                showTerminal: $showTerminal,
                showAnnotations: $showAnnotationSidebar,

                onSave: savePDF,
                onDeleteSelected: deleteSelectedAnnotation,
                onDeleteAll: deleteAllAnnotations,
                onChangeColor: changeSelectedAnnotationColor
            )
            Divider()

            if let document {
                HStack(spacing: 0) {
                    // PDF viewer — takes all available space
                    PDFKitView(
                        document: document,
                        currentTool: $currentTool,
                        currentColor: $currentColor,
                        selectedAnnotation: $selectedAnnotation,
                        selectedText: $selectedText,
                        restoredPageIndex: requestedRestorePageIndex,
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
                        applyBridgeAnnotation: $applyBridgeAnnotation
                    )
                    .id(pdfViewRefreshToken)
                    .onKeyPress(phases: .down) { press in
                        handleKeyPress(press)
                    }
                    .frame(maxWidth: .infinity)

                    if showAnnotationSidebar {
                        Divider()
                        AnnotationSidebarView(
                            document: document,
                            selectedAnnotation: $selectedAnnotation,
                            onNavigate: { selectedAnnotation = $0 },
                            onDelete: { deleteAnnotation($0) },
                            onEditNote: { annotation in
                                selectedAnnotation = annotation
                                editingNoteText = annotation.contents ?? ""
                                isEditingNote = true
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
        .navigationTitle(paper?.title ?? "Article")
        .onAppear {
            loadDocument()
            if isSplitMode { showAnnotationSidebar = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: BridgeCommandWatcher.commandNotification)) { notification in
            handleBridgeCommand(notification)
        }
        .onChange(of: paperID) { loadDocument() }
        .onChange(of: isActive) {
            if isActive { writePaperContext() }
        }
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
            try? fullText.write(toFile: "/tmp/canope_paper.txt", atomically: true, encoding: .utf8)
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

    // MARK: - Bridge Command Handling

    private func handleBridgeCommand(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any],
              let commandID = info["id"] as? String,
              let commandName = info["command"] as? String,
              let args = info["arguments"] as? [String: Any],
              let text = args["text"] as? String,
              let document
        else {
            if let commandID = (notification.userInfo as? [String: Any])?["id"] as? String {
                BridgeCommandWatcher.writeResult(id: commandID, status: "error", message: "Invalid command or no PDF open")
            }
            return
        }

        guard applyBridgeAnnotation != nil else {
            BridgeCommandWatcher.writeResult(id: commandID, status: "error", message: "PDF view not ready")
            return
        }

        let annotationType: PDFAnnotationSubtype = switch commandName {
            case "underlineText": .underline
            case "strikethroughText": .strikeOut
            default: .highlight
        }

        let colorName = args["color"] as? String ?? "yellow"
        let color = bridgeColorFromName(colorName)

        // Search for text in document
        var selections = document.findString(text, withOptions: [.caseInsensitive])

        // If page specified, filter to that page
        if let pageNum = args["page"] as? Int, pageNum >= 1, pageNum <= document.pageCount {
            selections = selections.filter { sel in
                sel.pages.contains { document.index(for: $0) == pageNum - 1 }
            }
        }

        guard let match = selections.first else {
            // Retry with normalized whitespace
            let normalized = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if normalized != text {
                var retrySelections = document.findString(normalized, withOptions: [.caseInsensitive])
                if let pageNum = args["page"] as? Int, pageNum >= 1, pageNum <= document.pageCount {
                    retrySelections = retrySelections.filter { sel in
                        sel.pages.contains { document.index(for: $0) == pageNum - 1 }
                    }
                }
                if let retryMatch = retrySelections.first {
                    applyBridgeAnnotation?(retryMatch, annotationType, color)
                    let pages = retryMatch.pages.map { document.index(for: $0) + 1 }
                    BridgeCommandWatcher.writeResult(
                        id: commandID, status: "completed",
                        message: "Applied \(commandName) on page(s) \(pages)",
                        matchedPages: pages
                    )
                    return
                }
            }

            BridgeCommandWatcher.writeResult(
                id: commandID, status: "error",
                message: "Text not found: '\(String(text.prefix(80)))'"
            )
            return
        }

        applyBridgeAnnotation?(match, annotationType, color)
        let matchedPages = match.pages.map { document.index(for: $0) + 1 }
        BridgeCommandWatcher.writeResult(
            id: commandID, status: "completed",
            message: "Applied \(commandName) on page(s) \(matchedPages)",
            matchedPages: matchedPages
        )
    }

    private func bridgeColorFromName(_ name: String) -> NSColor {
        switch name {
        case "green": return AnnotationColor.green
        case "red": return AnnotationColor.red
        case "blue": return AnnotationColor.blue
        case "orange": return NSColor.orange
        case "pink": return NSColor(red: 0.95, green: 0.5, blue: 0.7, alpha: 1.0)
        default: return AnnotationColor.yellow
        }
    }

    private func changeSelectedAnnotationColor(_ color: NSColor) {
        guard let annotation = selectedAnnotation else { return }
        if annotation.isTextBoxAnnotation {
            annotation.setTextBoxFillColor(AnnotationColor.annotationColor(color, for: "FreeText"))
        } else {
            annotation.color = AnnotationColor.annotationColor(color, for: annotation.type ?? "")
        }
        hasUnsavedChanges = true
        annotationRefreshToken = UUID()
        scheduleAutoSave()
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

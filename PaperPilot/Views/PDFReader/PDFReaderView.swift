import SwiftUI
import SwiftData
import PDFKit

struct PDFReaderView: View {
    let paperID: PersistentIdentifier
    var isSplitMode: Bool = false
    @Environment(\.modelContext) private var modelContext
    @State private var document: PDFDocument?
    @State private var currentTool: AnnotationTool = .pointer
    @State private var currentColor: NSColor = AnnotationColor.loadFavorites().first ?? AnnotationColor.yellow
    @State private var showAnnotationSidebar = true
    @State private var hasUnsavedChanges = false
    @State private var annotationRefreshToken = UUID()
    @State private var selectedAnnotation: PDFAnnotation?
    @State private var isEditingNote = false
    @State private var editingNoteText = ""
    @State private var undoAction: (() -> Void)?

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
                onSave: savePDF,
                onDeleteSelected: deleteSelectedAnnotation,
                onDeleteAll: deleteAllAnnotations,
                onChangeColor: changeSelectedAnnotationColor
            )
            Divider()

            if let document {
                HSplitView {
                    PDFKitView(
                        document: document,
                        currentTool: $currentTool,
                        currentColor: $currentColor,
                        selectedAnnotation: $selectedAnnotation,
                        onDocumentChanged: {
                            hasUnsavedChanges = true
                            annotationRefreshToken = UUID()
                            savePDF()
                        },
                        undoAction: $undoAction
                    )
                    .onKeyPress(phases: .down) { press in
                        handleKeyPress(press)
                    }

                    if showAnnotationSidebar {
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
                    }
                }
            } else {
                ContentUnavailableView(
                    "Impossible d'ouvrir le PDF",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAnnotationSidebar.toggle() }) {
                    Image(systemName: "sidebar.right")
                        .symbolVariant(showAnnotationSidebar ? .none : .slash)
                }
                .help("Annotations")
            }
        }
        .navigationTitle(paper?.title ?? "Article")
        .onAppear {
            loadDocument()
            if isSplitMode { showAnnotationSidebar = false }
        }
        .onChange(of: paperID) { loadDocument() }
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
            currentTool = .pointer
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
        document = PDFDocument(url: paper.fileURL)
        selectedAnnotation = nil
        if !paper.isRead { paper.isRead = true }
    }

    private func savePDF() {
        guard let document, let paper else { return }
        if AnnotationService.save(document: document, to: paper.fileURL) {
            hasUnsavedChanges = false
            paper.dateModified = Date()
        }
    }

    private func autoSave() {
        if hasUnsavedChanges { savePDF() }
    }

    private func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation else { return }
        deleteAnnotation(annotation)
    }

    private func deleteAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        if selectedAnnotation === annotation { selectedAnnotation = nil }
        hasUnsavedChanges = true
        annotationRefreshToken = UUID()
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
    }

    private func changeSelectedAnnotationColor(_ color: NSColor) {
        guard let annotation = selectedAnnotation else { return }
        annotation.color = annotation.type == "Highlight" ? color.withAlphaComponent(0.4) : color
        hasUnsavedChanges = true
        annotationRefreshToken = UUID()
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

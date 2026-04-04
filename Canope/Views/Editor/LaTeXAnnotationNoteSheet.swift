import SwiftUI

struct LaTeXAnnotationNoteSheet: View {
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

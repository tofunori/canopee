import SwiftUI
import SwiftData

struct PaperInfoPanel: View {
    @Bindable var paper: Paper

    var body: some View {
        Form {
            Section("Métadonnées") {
                LabeledContent("Titre") {
                    TextField("Titre", text: $paper.title)
                        .textFieldStyle(.plain)
                }
                LabeledContent("Auteurs") {
                    TextField("Auteurs", text: $paper.authors)
                        .textFieldStyle(.plain)
                }
                LabeledContent("Année") {
                    TextField("Année", value: $paper.year, format: .number)
                        .textFieldStyle(.plain)
                }
                LabeledContent("Journal") {
                    TextField("Journal", text: Binding(
                        get: { paper.journal ?? "" },
                        set: { paper.journal = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                }
                LabeledContent("DOI") {
                    TextField("DOI", text: Binding(
                        get: { paper.doi ?? "" },
                        set: { paper.doi = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                }
            }

            Section("Évaluation") {
                LabeledContent("Note") {
                    RatingView(rating: $paper.rating)
                }
                Toggle("Favori", isOn: $paper.isFavorite)
                Toggle("Lu", isOn: $paper.isRead)
                Toggle("Signalé", isOn: $paper.isFlagged)
            }

            Section("Notes") {
                TextEditor(text: Binding(
                    get: { paper.notes ?? "" },
                    set: { paper.notes = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 80)
                .font(.body)
            }

            Section("Info") {
                LabeledContent("Ajouté") {
                    Text(paper.dateAdded, style: .date)
                }
                LabeledContent("Modifié") {
                    Text(paper.dateModified, style: .date)
                }
            }

            if let doi = paper.doi, !doi.isEmpty {
                Section {
                    Button("Ouvrir le DOI dans le navigateur") {
                        if let url = URL(string: "https://doi.org/\(doi)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 250, idealWidth: 280, maxWidth: 350)
    }
}

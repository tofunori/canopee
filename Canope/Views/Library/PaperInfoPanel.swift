import SwiftUI
import SwiftData

struct PaperInfoPanel: View {
    @Bindable var paper: Paper

    var body: some View {
        Form {
            Section(AppStrings.metadata) {
                LabeledContent(AppStrings.title) {
                    TextField(AppStrings.title, text: $paper.title)
                        .textFieldStyle(.plain)
                }
                LabeledContent(AppStrings.authors) {
                    TextField(AppStrings.authors, text: $paper.authors)
                        .textFieldStyle(.plain)
                }
                LabeledContent(AppStrings.year) {
                    TextField(AppStrings.year, value: $paper.year, format: .number)
                        .textFieldStyle(.plain)
                }
                LabeledContent(AppStrings.journal) {
                    TextField(AppStrings.journal, text: Binding(
                        get: { paper.journal ?? "" },
                        set: { paper.journal = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                }
                LabeledContent(AppStrings.doi) {
                    TextField(AppStrings.doi, text: Binding(
                        get: { paper.doi ?? "" },
                        set: { paper.doi = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                }
            }

            Section(AppStrings.rating) {
                LabeledContent("Rating") {
                    RatingView(rating: $paper.rating)
                }
                Toggle(AppStrings.favorite, isOn: $paper.isFavorite)
                Toggle(AppStrings.read, isOn: $paper.isRead)
                Toggle(AppStrings.flagged, isOn: $paper.isFlagged)
            }

            Section(AppStrings.notes) {
                TextEditor(text: Binding(
                    get: { paper.notes ?? "" },
                    set: { paper.notes = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 80)
                .font(.body)
            }

            Section(AppStrings.info) {
                LabeledContent(AppStrings.added) {
                    Text(paper.dateAdded, style: .date)
                }
                LabeledContent(AppStrings.modified) {
                    Text(paper.dateModified, style: .date)
                }
            }

            if let doi = paper.doi, !doi.isEmpty {
                Section {
                    Button(AppStrings.openDOI) {
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

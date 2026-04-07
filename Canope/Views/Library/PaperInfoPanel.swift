import AppKit
import SwiftUI
import SwiftData

struct PaperInfoPanel: View {
    @Bindable var paper: Paper
    let allPapers: [Paper]
    let isActive: Bool
    let projectRoot: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCard
                metadataSection
                bibliographySection
                evaluationSection
                notesSection
                infoSection

                if let doi = paper.doi, !doi.isEmpty {
                    PanelSection(title: "DOI", systemImage: "link") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(doi)
                                .font(.system(size: 11, weight: .medium))
                                .textSelection(.enabled)

                            panelActionButton("Ouvrir le DOI dans le navigateur", systemImage: "safari") {
                                if let url = URL(string: "https://doi.org/\(doi)") {
                                    NSWorkspace.shared.open(url)
                                }
                            }

                            panelActionButton("Rafraîchir depuis le DOI", systemImage: "arrow.clockwise") {
                                refreshMetadataFromDOI()
                            }
                        }
                    }
                }

                bibliographyActionsSection
            }
            .padding(12)
        }
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
        .background(AppChromePalette.surfaceSubbar)
    }

    private var bibliographicRecord: BibliographicRecord? {
        BibliographyExportService.records(for: [paper], allPapers: allPapers, assignMissingKeys: false).first
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Article sélectionné")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(paper.title)
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 6) {
                Text(paper.authorsShort)
                    .foregroundStyle(.secondary)

                if let year = paper.year {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(String(year))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppChromePalette.surfaceBar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
        )
    }

    private var metadataSection: some View {
        PanelSection(title: "Métadonnées", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 10) {
                panelTextField("Titre", text: $paper.title)
                panelTextField("Auteurs", text: $paper.authors)
                panelTextField("Année", text: yearBinding)
                panelTextField("Journal", text: optionalStringBinding(\.journal))
                panelTextField("DOI", text: optionalStringBinding(\.doi))
            }
        }
    }

    private var bibliographySection: some View {
        PanelSection(title: "Bibliographie", systemImage: "quote.opening") {
            VStack(alignment: .leading, spacing: 10) {
                panelTextField("Cite key", text: optionalStringBinding(\.citeKey))
                panelTextField("Type", text: optionalStringBinding(\.entryType))
                panelTextField("URL", text: optionalStringBinding(\.url))
                panelTextField("Volume", text: optionalStringBinding(\.volume))
                panelTextField("Numéro", text: optionalStringBinding(\.issue))
                panelTextField("Pages", text: optionalStringBinding(\.pages))
                panelTextField("Éditeur", text: optionalStringBinding(\.publisher))
                panelTextField("Booktitle", text: optionalStringBinding(\.booktitle))
            }
        }
    }

    private var evaluationSection: some View {
        PanelSection(title: "Évaluation", systemImage: "star.leadinghalf.filled") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Note")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    RatingView(rating: $paper.rating)
                }

                Toggle("Favori", isOn: $paper.isFavorite)
                Toggle("Lu", isOn: $paper.isRead)
                Toggle("Signalé", isOn: $paper.isFlagged)
            }
            .toggleStyle(.switch)
        }
    }

    private var notesSection: some View {
        PanelSection(title: "Notes", systemImage: "square.and.pencil") {
            TextEditor(text: Binding(
                get: { paper.notes ?? "" },
                set: { paper.notes = $0.isEmpty ? nil : $0 }
            ))
            .font(.system(size: 12))
            .frame(minHeight: 120)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppChromePalette.surfaceSubbar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
            )
        }
    }

    private var infoSection: some View {
        PanelSection(title: "Info", systemImage: "clock") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Ajouté", value: paper.dateAdded.formatted(date: .abbreviated, time: .omitted))
                infoRow("Modifié", value: paper.dateModified.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private var bibliographyActionsSection: some View {
        PanelSection(title: "Actions bibliographiques", systemImage: "text.quote") {
            VStack(alignment: .leading, spacing: 8) {
                panelActionButton("Régénérer la cite key", systemImage: "wand.and.stars") {
                    regenerateCiteKey()
                }

                panelActionButton("Copier la cite key", systemImage: "doc.on.doc") {
                    copyCiteKey()
                }
                .disabled(bibliographicRecord == nil)

                panelActionButton("Copier le BibTeX", systemImage: "text.append") {
                    copyBibTeX()
                }
                .disabled(bibliographicRecord == nil)

                panelActionButton("Exporter en .bib", systemImage: "square.and.arrow.up") {
                    exportBibTeX()
                }
                .disabled(bibliographicRecord == nil)

                panelActionButton("Ajouter à references.bib", systemImage: "books.vertical") {
                    appendToProjectBibliography()
                }
                .disabled(bibliographicRecord == nil || projectRoot == nil)
            }
        }
    }

    private var yearBinding: Binding<String> {
        Binding(
            get: { paper.year.map(String.init) ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                paper.year = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }

    private func optionalStringBinding(_ keyPath: ReferenceWritableKeyPath<Paper, String?>) -> Binding<String> {
        Binding(
            get: { paper[keyPath: keyPath] ?? "" },
            set: { paper[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    @ViewBuilder
    private func panelTextField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppChromePalette.surfaceSubbar)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
        }
    }

    private func panelActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppChromePalette.surfaceSubbar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func regenerateCiteKey() {
        let existingKeys = Set(
            allPapers
                .filter { $0.id != paper.id }
                .compactMap { $0.citeKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        paper.citeKey = CitationKeyService.uniqueKey(for: paper, existingKeys: existingKeys)
    }

    private func copyCiteKey() {
        guard let bibliographicRecord else { return }
        ClipboardCitationService.copy(bibliographicRecord.citeKey)
    }

    private func copyBibTeX() {
        guard let bibliographicRecord else { return }
        ClipboardCitationService.copy(BibTeXSerializer.serialize(bibliographicRecord))
    }

    private func exportBibTeX() {
        _ = BibliographyExportService.exportBibTeX(
            papers: [paper],
            allPapers: allPapers,
            suggestedFileName: "\(bibliographicRecord?.citeKey ?? "references").bib"
        )
    }

    private func appendToProjectBibliography() {
        guard let projectRoot else { return }
        _ = BibliographyExportService.appendToProjectBibliography(
            papers: [paper],
            allPapers: allPapers,
            projectRoot: projectRoot
        )
    }

    private func refreshMetadataFromDOI() {
        guard let doi = paper.doi, !doi.isEmpty else { return }
        MetadataExtractor.enrichWithCrossRef(doi: doi) { metadata in
            guard let metadata else { return }
            apply(metadata: metadata)
        }
    }

    private func apply(metadata: PaperMetadata) {
        if let title = metadata.title { paper.title = title }
        if let authors = metadata.authors { paper.authors = authors }
        if let year = metadata.year { paper.year = year }
        if let journal = metadata.journal { paper.journal = journal }
        if let entryType = metadata.entryType { paper.entryType = entryType }
        if let url = metadata.url { paper.url = url }
        if let volume = metadata.volume { paper.volume = volume }
        if let issue = metadata.issue { paper.issue = issue }
        if let pages = metadata.pages { paper.pages = pages }
        if let publisher = metadata.publisher { paper.publisher = publisher }
        if let booktitle = metadata.booktitle { paper.booktitle = booktitle }
        if paper.citeKey == nil || paper.citeKey?.isEmpty == true {
            regenerateCiteKey()
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppChromePalette.info)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppChromePalette.clusterFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
        )
    }
}

import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PaperTableView: View {
    let sidebarSelection: SidebarSelection
    @Binding var inspectedPaperID: UUID?
    @Binding var showInspector: Bool
    @Binding var isImporting: Bool
    let isActive: Bool
    let projectRoot: URL?
    var onOpenPaper: (Paper) -> Void
    @Query(sort: \Paper.dateAdded, order: .reverse) private var allPapers: [Paper]
    @Query(sort: \PaperCollection.sortOrder) private var allCollections: [PaperCollection]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var commandRouter = BibliographyCommandRouter.shared
    @State private var selection = Set<UUID>()
    @State private var sortOption: LibrarySortOption = .dateAddedDescending
    @State private var searchText = ""
    @State private var hoveredPaperID: UUID?
    @State private var selectionAnchorID: UUID?

    private var filteredPapers: [Paper] {
        var base: [Paper]
        switch sidebarSelection {
        case .allPapers:
            base = allPapers
        case .favorites:
            base = allPapers.filter { $0.isFavorite }
        case .unread:
            base = allPapers.filter { !$0.isRead }
        case .recent:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            base = allPapers.filter { $0.dateAdded > cutoff }
        case .collection(let collectionID):
            base = allPapers.filter { paper in
                paper.collections.contains { $0.persistentModelID == collectionID }
            }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            base = base.filter { paper in
                paper.title.lowercased().contains(query)
                || paper.authors.lowercased().contains(query)
                || (paper.journal?.lowercased().contains(query) ?? false)
                || (paper.doi?.lowercased().contains(query) ?? false)
                || (paper.citeKey?.lowercased().contains(query) ?? false)
                || (paper.year.map { String($0).contains(query) } ?? false)
            }
        }

        return base.sorted(by: sortOption.areInIncreasingOrder)
    }

    private var selectedPapers: [Paper] {
        allPapers.filter { selection.contains($0.id) }
    }

    private var selectionSummary: String {
        if selection.isEmpty {
            return "\(filteredPapers.count) article\(filteredPapers.count > 1 ? "s" : "")"
        }
        return "\(selection.count) sélectionné\(selection.count > 1 ? "s" : "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryToolbar
            AppChromeDivider(role: .panel)

            if filteredPapers.isEmpty {
                emptyState
            } else {
                libraryList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppChromePalette.surfaceSubbar)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.pdf],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .onAppear { syncCommandRouter() }
        .onChange(of: isActive) { syncCommandRouter() }
        .onChange(of: selection) { updateSelectionState() }
        .onChange(of: allPapers.map(\.id)) { ids in
            let availableIDs = Set(ids)
            selection.formIntersection(availableIDs)
            if let inspectedPaperID, !availableIDs.contains(inspectedPaperID) {
                self.inspectedPaperID = nil
            }
            syncCommandRouter()
        }
    }

    private var libraryToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            searchField

            sortMenu

            ToolbarIconButton(
                systemName: "plus",
                foregroundStyle: AppChromePalette.info,
                helpText: "Importer un PDF"
            ) {
                isImporting = true
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(AppChromePalette.surfaceBar.opacity(0.95))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortOption.allCases, id: \.self) { option in
                Button {
                    sortOption = option
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sortOption.systemImage)
                    .imageScale(.small)
                Text("Sort")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppChromePalette.hoverFill.opacity(0.5))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search My Papers", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 190)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(AppChromePalette.hoverFill.opacity(0.4))
        )
    }

    private var libraryList: some View {
        VStack(spacing: 0) {
            papersHeaderRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredPapers) { paper in
                    paperRow(paper)
                }
            }
            }
        }
    }

    private var papersHeaderRow: some View {
        HStack(spacing: 0) {
            headerColumn("", width: 34, alignment: .center)
            headerColumn("Authors", width: 140)
            headerColumn("Last Author", width: 110)
            headerColumn("Title", minWidth: 230)
            headerColumn("Journal", width: 180)
            headerColumn("Year", width: 58, alignment: .trailing)
            headerColumn("Notes", width: 136)
            headerColumn("Rating", width: 92, alignment: .trailing)
        }
        .frame(height: 26)
        .padding(.horizontal, 6)
        .background(AppChromePalette.surfaceBar.opacity(0.98))
        .overlay(
            Rectangle()
                .fill(AppChromePalette.dividerStrong)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func headerColumn(
        _ title: String,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        alignment: Alignment = .leading
    ) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(minWidth: minWidth, maxWidth: width == nil ? .infinity : width, alignment: alignment)
            .padding(.horizontal, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Aucun article")
                    .font(.system(size: 15, weight: .semibold))
                Text("Importez un PDF avec le bouton + ou glissez-le dans la bibliothèque.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Importer un PDF") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(AppChromePalette.surfaceSubbar)
    }

    private func paperRow(_ paper: Paper) -> some View {
        let isSelected = selection.contains(paper.id)
        let isHovered = hoveredPaperID == paper.id

        return PaperRowView(paper: paper, isSelected: isSelected, isHovered: isHovered)
            .onTapGesture {
                handleSelection(for: paper.id)
            }
            .onTapGesture(count: 2) {
                handleSelection(for: paper.id)
                onOpenPaper(paper)
            }
            .onHover { hovering in
                if hovering {
                    hoveredPaperID = paper.id
                } else if hoveredPaperID == paper.id {
                    hoveredPaperID = nil
                }
            }
            .contextMenu {
                contextMenuContent(effectiveSelection(forContextPaperID: paper.id))
            }
    }

    private func effectiveSelection(forContextPaperID paperID: UUID) -> Set<UUID> {
        selection.contains(paperID) ? selection : [paperID]
    }

    private func handleSelection(for paperID: UUID) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])

        if modifiers.contains(.shift) {
            extendSelection(to: paperID)
            return
        }

        if modifiers.contains(.command) {
            toggleSelection(for: paperID)
            selectionAnchorID = paperID
            return
        }

        selection = [paperID]
        selectionAnchorID = paperID
    }

    private func toggleSelection(for paperID: UUID) {
        if selection.contains(paperID) {
            selection.remove(paperID)
        } else {
            selection.insert(paperID)
        }
    }

    private func extendSelection(to paperID: UUID) {
        guard let anchorID = selectionAnchorID,
              let anchorIndex = filteredPapers.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = filteredPapers.firstIndex(where: { $0.id == paperID }) else {
            selection = [paperID]
            selectionAnchorID = paperID
            return
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        selection = Set(filteredPapers[lowerBound...upperBound].map(\.id))
    }

    private func updateSelectionState() {
        inspectedPaperID = selection.count == 1 ? selection.first : nil
        if inspectedPaperID != nil && !showInspector {
            showInspector = true
        }
        syncCommandRouter()
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuContent(_ items: Set<UUID>) -> some View {
        Group {
            if !items.isEmpty {
                Button("Ouvrir") {
                    for id in items {
                        if let paper = allPapers.first(where: { $0.id == id }) {
                            onOpenPaper(paper)
                        }
                    }
                }
                Divider()
                Button("Copier la cite key") { copyCiteKeys(for: items) }
                Button("Copier le BibTeX") { copyBibTeX(for: items) }
                Button("Exporter en .bib") { exportBibTeX(for: items) }
                Button("Ajouter à references.bib") { appendToProjectBibliography(for: items) }
                    .disabled(projectRoot == nil)
                Button("Rafraîchir depuis le DOI") { refreshMetadata(for: items) }
                Divider()
                Button("Favori") { toggleFavorite(items) }
                Button("Marquer lu/non-lu") { toggleRead(items) }
                Button(items.compactMap({ id in allPapers.first { $0.id == id } }).allSatisfy(\.isFlagged) ? "Retirer le drapeau" : "Signaler") {
                    toggleFlag(items)
                }
                Divider()
                Menu("Couleur") {
                    ForEach(Paper.labelColors, id: \.key) { label in
                        Button {
                            setLabel(items, color: label.key)
                        } label: {
                            Label(label.name, systemImage: currentShape(for: items))
                                .tint(Color(nsColor: label.color))
                        }
                    }
                    Divider()
                    Button("Aucune") { setLabel(items, color: nil) }
                }
                Menu("Forme") {
                    ForEach(Paper.labelShapes, id: \.key) { shape in
                        Button {
                            setShape(items, shape: shape.key)
                        } label: {
                            Label(shape.name, systemImage: shape.icon)
                        }
                    }
                }
                Divider()
                Menu("Ajouter à…") {
                    ForEach(allCollections) { collection in
                        Button {
                            addToCollection(items, collection: collection)
                        } label: {
                            Label(collection.name, systemImage: "folder")
                        }
                    }
                }
                Menu("Retirer de…") {
                    ForEach(collectionsForPapers(items)) { collection in
                        Button {
                            removeFromCollection(items, collection: collection)
                        } label: {
                            Label(collection.name, systemImage: "folder.badge.minus")
                        }
                    }
                }
                Divider()
                Button("Supprimer", role: .destructive) { deletePapers(items) }
            }
        }
    }

    private var navigationTitle: String {
        switch sidebarSelection {
        case .allPapers: return "Tous les articles"
        case .favorites: return "Favoris"
        case .unread: return "À lire"
        case .recent: return "Récents"
        case .collection: return "Collection"
        }
    }

    // MARK: - Actions

    private func toggleFavorite(_ ids: Set<UUID>) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.isFavorite.toggle()
        }
        syncCommandRouter()
    }

    private func toggleRead(_ ids: Set<UUID>) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.isRead.toggle()
        }
        syncCommandRouter()
    }

    private func toggleFlag(_ ids: Set<UUID>) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.isFlagged.toggle()
        }
        syncCommandRouter()
    }

    private func setLabel(_ ids: Set<UUID>, color: String?) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.labelColor = color
        }
        syncCommandRouter()
    }

    private func setShape(_ ids: Set<UUID>, shape: String) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.labelShape = shape
        }
        syncCommandRouter()
    }

    private func currentShape(for ids: Set<UUID>) -> String {
        if let id = ids.first, let paper = allPapers.first(where: { $0.id == id }) {
            return paper.labelIconName
        }
        return "circle.fill"
    }

    private func addToCollection(_ ids: Set<UUID>, collection: PaperCollection) {
        for paper in allPapers where ids.contains(paper.id) {
            if !paper.collections.contains(where: { $0.id == collection.id }) {
                paper.collections.append(collection)
            }
        }
        syncCommandRouter()
    }

    private func removeFromCollection(_ ids: Set<UUID>, collection: PaperCollection) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.collections.removeAll { $0.id == collection.id }
        }
        syncCommandRouter()
    }

    private func collectionsForPapers(_ ids: Set<UUID>) -> [PaperCollection] {
        let papers = allPapers.filter { ids.contains($0.id) }
        var collections = Set<UUID>()
        var result: [PaperCollection] = []
        for paper in papers {
            for col in paper.collections {
                if !collections.contains(col.id) {
                    collections.insert(col.id)
                    result.append(col)
                }
            }
        }
        return result
    }

    private func deletePapers(_ ids: Set<UUID>) {
        for paper in allPapers where ids.contains(paper.id) {
            PDFFileManager.deletePDF(fileName: paper.fileName)
            modelContext.delete(paper)
        }
        syncCommandRouter()
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            print("[Canope] fileImporter returned \(urls.count) URLs")
            for url in urls {
                print("[Canope] importing: \(url.lastPathComponent)")
                let accessed = url.startAccessingSecurityScopedResource()
                print("[Canope] security scope accessed: \(accessed)")
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                importPDF(from: url)
            }
        case .failure(let error):
            print("[Canope] fileImporter error: \(error)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { importPDF(from: url) }
            }
        }
    }

    private func importPDF(from url: URL) {
        print("[Canope] importPDF called for: \(url.lastPathComponent)")
        do {
            let (fileName, metadata) = try PDFFileManager.importPDF(from: url)
            print("[Canope] imported as \(fileName), title: \(metadata.title ?? "nil")")
            let paper = Paper(title: metadata.title ?? url.deletingPathExtension().lastPathComponent, fileName: fileName)
            paper.authors = metadata.authors ?? ""
            paper.year = metadata.year
            paper.doi = metadata.doi
            paper.journal = metadata.journal
            paper.entryType = metadata.entryType
            paper.url = metadata.url
            paper.volume = metadata.volume
            paper.issue = metadata.issue
            paper.pages = metadata.pages
            paper.publisher = metadata.publisher
            paper.booktitle = metadata.booktitle
            paper.citeKey = CitationKeyService.uniqueKey(
                for: paper,
                existingKeys: Set(allPapers.compactMap { normalizedKey($0.citeKey) })
            )
            if case .collection(let collectionID) = sidebarSelection {
                let descriptor = FetchDescriptor<PaperCollection>(
                    predicate: #Predicate { $0.persistentModelID == collectionID }
                )
                if let collection = try? modelContext.fetch(descriptor).first {
                    paper.collections.append(collection)
                }
            }
            modelContext.insert(paper)

            // Enrich with CrossRef in background (if DOI found)
            if let doi = metadata.doi {
                MetadataExtractor.enrichWithCrossRef(doi: doi) { crossRef in
                    guard let crossRef else { return }
                    apply(metadata: crossRef, to: paper)
                    syncCommandRouter()
                }
            }
            syncCommandRouter()
        } catch {
            print("Failed to import PDF: \(error)")
        }
    }

    private func copyCiteKeys(for ids: Set<UUID>) {
        let records = BibliographyExportService.records(for: papers(for: ids), allPapers: allPapers)
        let citeKeys = records.map(\.citeKey)
        guard !citeKeys.isEmpty else { return }
        ClipboardCitationService.copy(citeKeys.joined(separator: ","))
        syncCommandRouter()
    }

    private func copyBibTeX(for ids: Set<UUID>) {
        let papers = papers(for: ids)
        guard !papers.isEmpty else { return }
        ClipboardCitationService.copy(BibliographyExportService.bibTeX(for: papers, allPapers: allPapers))
        syncCommandRouter()
    }

    private func exportBibTeX(for ids: Set<UUID>) {
        let papers = papers(for: ids)
        guard !papers.isEmpty else { return }
        let suggestedFileName = papers.count == 1
            ? "\(BibliographyExportService.records(for: papers, allPapers: allPapers).first?.citeKey ?? "references").bib"
            : "references.bib"
        _ = BibliographyExportService.exportBibTeX(
            papers: papers,
            allPapers: allPapers,
            suggestedFileName: suggestedFileName
        )
        syncCommandRouter()
    }

    private func appendToProjectBibliography(for ids: Set<UUID>) {
        guard let projectRoot else { return }
        let papers = papers(for: ids)
        guard !papers.isEmpty else { return }
        _ = BibliographyExportService.appendToProjectBibliography(
            papers: papers,
            allPapers: allPapers,
            projectRoot: projectRoot
        )
        syncCommandRouter()
    }

    private func refreshMetadata(for ids: Set<UUID>) {
        for paper in papers(for: ids) {
            guard let doi = paper.doi, !doi.isEmpty else { continue }
            MetadataExtractor.enrichWithCrossRef(doi: doi) { metadata in
                guard let metadata else { return }
                apply(metadata: metadata, to: paper)
                syncCommandRouter()
            }
        }
    }

    private func papers(for ids: Set<UUID>) -> [Paper] {
        allPapers.filter { ids.contains($0.id) }
    }

    private func apply(metadata: PaperMetadata, to paper: Paper) {
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
        if normalizedKey(paper.citeKey) == nil {
            paper.citeKey = CitationKeyService.uniqueKey(
                for: paper,
                existingKeys: Set(
                    allPapers
                        .filter { $0.id != paper.id }
                        .compactMap { normalizedKey($0.citeKey) }
                )
            )
        }
    }

    private func normalizedKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private func syncCommandRouter() {
        guard isActive else {
            commandRouter.clearActions()
            return
        }

        guard !selectedPapers.isEmpty else {
            commandRouter.setLibraryActions(
                copyCiteKey: nil,
                copyBibTeX: nil,
                exportBibTeX: nil,
                appendToBibliography: nil
            )
            return
        }

        let selectedIDs = selection
        commandRouter.setLibraryActions(
            copyCiteKey: { copyCiteKeys(for: selectedIDs) },
            copyBibTeX: { copyBibTeX(for: selectedIDs) },
            exportBibTeX: { exportBibTeX(for: selectedIDs) },
            appendToBibliography: projectRoot == nil ? nil : { appendToProjectBibliography(for: selectedIDs) }
        )
    }
}

private enum LibrarySortOption: CaseIterable {
    case dateAddedDescending
    case dateAddedAscending
    case yearDescending
    case titleAscending
    case authorAscending
    case ratingDescending

    var title: String {
        switch self {
        case .dateAddedDescending:
            return "Ajout récent"
        case .dateAddedAscending:
            return "Ajout ancien"
        case .yearDescending:
            return "Année décroissante"
        case .titleAscending:
            return "Titre"
        case .authorAscending:
            return "Auteur"
        case .ratingDescending:
            return "Note"
        }
    }

    var shortTitle: String {
        switch self {
        case .dateAddedDescending:
            return "Récent"
        case .dateAddedAscending:
            return "Ancien"
        case .yearDescending:
            return "Année"
        case .titleAscending:
            return "Titre"
        case .authorAscending:
            return "Auteur"
        case .ratingDescending:
            return "Note"
        }
    }

    var systemImage: String {
        switch self {
        case .dateAddedDescending:
            return "clock.arrow.circlepath"
        case .dateAddedAscending:
            return "clock"
        case .yearDescending:
            return "calendar"
        case .titleAscending:
            return "textformat.abc"
        case .authorAscending:
            return "person.text.rectangle"
        case .ratingDescending:
            return "star.leadinghalf.filled"
        }
    }

    func areInIncreasingOrder(_ lhs: Paper, _ rhs: Paper) -> Bool {
        switch self {
        case .dateAddedDescending:
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
        case .dateAddedAscending:
            if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
        case .yearDescending:
            let leftYear = lhs.year ?? Int.min
            let rightYear = rhs.year ?? Int.min
            if leftYear != rightYear { return leftYear > rightYear }
        case .titleAscending:
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .authorAscending:
            let comparison = lhs.authorsShort.localizedCaseInsensitiveCompare(rhs.authorsShort)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .ratingDescending:
            if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
        }

        return lhs.dateAdded > rhs.dateAdded
    }
}

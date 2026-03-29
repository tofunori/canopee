import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PaperTableView: View {
    let sidebarSelection: SidebarSelection
    @Binding var inspectedPaperID: UUID?
    var onOpenPaper: (Paper) -> Void
    @Query(sort: \Paper.dateAdded, order: .reverse) private var allPapers: [Paper]
    @Query(sort: \PaperCollection.sortOrder) private var allCollections: [PaperCollection]
    @Environment(\.modelContext) private var modelContext
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Paper.dateAdded, order: .reverse)]
    @State private var isImporting = false
    @State private var searchText = ""

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

        // Apply search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            base = base.filter { paper in
                paper.title.lowercased().contains(query)
                || paper.authors.lowercased().contains(query)
                || (paper.doi?.lowercased().contains(query) ?? false)
                || (paper.year.map { String($0).contains(query) } ?? false)
            }
        }

        return base.sorted(using: sortOrder)
    }

    var body: some View {
        tableContent
            .contextMenu(forSelectionType: UUID.self) { items in
                contextMenuContent(items)
            } primaryAction: { items in
                for id in items {
                    if let paper = allPapers.first(where: { $0.id == id }) {
                        onOpenPaper(paper)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Rechercher titre, auteurs, DOI…")
            .onChange(of: selection) {
                inspectedPaperID = selection.count == 1 ? selection.first : nil
            }
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
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
            .overlay {
                if filteredPapers.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun article", systemImage: "doc.text")
                    } description: {
                        Text("Importez un PDF avec le bouton + ou glissez-le ici")
                    }
                }
            }
    }

    // MARK: - Table

    @ViewBuilder
    private var tableContent: some View {
        Table(filteredPapers, selection: $selection, sortOrder: $sortOrder) {
            // Label color/shape + Read status + Flag
            TableColumn("") { paper in
                HStack(spacing: 3) {
                    if let key = paper.labelColor,
                       let lc = Paper.labelColors.first(where: { $0.key == key }) {
                        Image(systemName: paper.labelIconName)
                            .font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: lc.color))
                    }
                    if !paper.isRead {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                    if paper.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(42)

            // Authors (short: last names)
            TableColumn("Auteurs", sortUsing: KeyPathComparator(\Paper.authors)) { paper in
                Text(paper.authorsShort)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 150, max: 200)

            // Last Author
            TableColumn("Dernier auteur") { paper in
                Text(paper.lastAuthor)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 120, max: 160)

            // Title
            TableColumn("Titre", sortUsing: KeyPathComparator(\Paper.title)) { paper in
                Text(paper.title)
                    .lineLimit(1)
            }

            // Journal
            TableColumn("Journal") { paper in
                Text(paper.journal ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 160, max: 250)

            // Year
            TableColumn("Année", sortUsing: KeyPathComparator(\Paper.dateAdded)) { paper in
                Text(paper.year.map(String.init) ?? "")
                    .monospacedDigit()
            }
            .width(50)

            // Rating (5 stars)
            TableColumn("Note") { paper in
                RatingView(rating: Binding(
                    get: { paper.rating },
                    set: { paper.rating = $0 }
                ))
            }
            .width(90)
        }
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: { isImporting = true }) {
                Image(systemName: "plus")
            }
            .help("Importer un PDF")
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
    }

    private func toggleRead(_ ids: Set<UUID>) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.isRead.toggle()
        }
    }

    private func toggleFlag(_ ids: Set<UUID>) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.isFlagged.toggle()
        }
    }

    private func setLabel(_ ids: Set<UUID>, color: String?) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.labelColor = color
        }
    }

    private func setShape(_ ids: Set<UUID>, shape: String) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.labelShape = shape
        }
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
    }

    private func removeFromCollection(_ ids: Set<UUID>, collection: PaperCollection) {
        for paper in allPapers where ids.contains(paper.id) {
            paper.collections.removeAll { $0.id == collection.id }
        }
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
                    if let title = crossRef.title { paper.title = title }
                    if let authors = crossRef.authors { paper.authors = authors }
                    if let year = crossRef.year { paper.year = year }
                    if let journal = crossRef.journal { paper.journal = journal }
                }
            }
        } catch {
            print("Failed to import PDF: \(error)")
        }
    }
}

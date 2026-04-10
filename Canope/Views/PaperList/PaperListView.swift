import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import OSLog

struct PaperListView: View {
    let sidebarSelection: SidebarSelection
    @Binding var selectedPaperID: PersistentIdentifier?
    @Query(sort: \Paper.dateAdded, order: .reverse) private var allPapers: [Paper]
    @Environment(\.modelContext) private var modelContext
    @State private var isImporting = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.canope.app",
        category: "PaperList"
    )

    private var filteredPapers: [Paper] {
        switch sidebarSelection {
        case .allPapers:
            return allPapers
        case .favorites:
            return allPapers.filter { $0.isFavorite }
        case .unread:
            return allPapers.filter { !$0.isRead }
        case .recent:
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            return allPapers.filter { $0.dateAdded > thirtyDaysAgo }
        case .collection(let collectionID):
            return allPapers.filter { paper in
                paper.collections.contains { $0.persistentModelID == collectionID }
            }
        }
    }

    var body: some View {
        List(selection: $selectedPaperID) {
            ForEach(filteredPapers) { paper in
                PaperRowView(paper: paper)
                    .tag(paper.persistentModelID)
                    .contextMenu {
                        Button(paper.isFavorite ? "Remove from favorites" : "Add to favorites") {
                            paper.isFavorite.toggle()
                        }
                        Button(paper.isRead ? "Mark unread" : "Mark read") {
                            paper.isRead.toggle()
                        }
                        Divider()
                        Button(AppStrings.delete, role: .destructive) {
                            deletePaper(paper)
                        }
                    }
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { isImporting = true }) {
                    Image(systemName: "plus")
                }
                .help(AppStrings.importPDF)
            }
        }
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
        .onChange(of: selectedPaperID) {
            let value = selectedPaperID.map { String(describing: $0) } ?? "nil"
            Self.logger.info("Selected paper persistent id: \(value, privacy: .public)")
        }
        .overlay {
            if filteredPapers.isEmpty {
                ContentUnavailableView {
                    Label(AppStrings.noPapers, systemImage: "doc.text")
                } description: {
                    Text(AppStrings.importPDFHint)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch sidebarSelection {
        case .allPapers: return AppStrings.allPapers
        case .favorites: return AppStrings.favorites
        case .unread: return AppStrings.unread
        case .recent: return AppStrings.recent
        case .collection: return AppStrings.collection
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let urls = try? result.get() else {
            Self.logger.error("PDF import failed before processing file list")
            return
        }
        Self.logger.info("Import requested for \(urls.count, privacy: .public) PDF file(s)")
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            importPDF(from: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    importPDF(from: url)
                }
            }
        }
    }

    private func importPDF(from url: URL) {
        do {
            let (fileName, metadata) = try PDFFileManager.importPDF(from: url)
            let paper = Paper(title: metadata.title ?? url.deletingPathExtension().lastPathComponent, fileName: fileName)
            paper.authors = metadata.authors ?? ""
            paper.year = metadata.year
            paper.doi = metadata.doi
            paper.journal = metadata.journal

            // If we're viewing a specific collection, add the paper to it
            if case .collection(let collectionID) = sidebarSelection {
                let descriptor = FetchDescriptor<PaperCollection>(
                    predicate: #Predicate { $0.persistentModelID == collectionID }
                )
                if let collection = try? modelContext.fetch(descriptor).first {
                    paper.collections.append(collection)
                }
            }

            modelContext.insert(paper)
            Self.logger.info("Imported PDF: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("Failed to import PDF \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deletePaper(_ paper: Paper) {
        PDFFileManager.deletePDF(fileName: paper.fileName)
        modelContext.delete(paper)
        Self.logger.info("Deleted paper: \(paper.title, privacy: .public)")
    }
}

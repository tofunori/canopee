import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Query(sort: \PaperCollection.sortOrder) private var allCollections: [PaperCollection]
    @Environment(\.modelContext) private var modelContext
    @State private var isAddingCollection = false
    @State private var newCollectionName = ""
    @State private var addingToParent: PaperCollection? = nil
    @State private var expandedCollections: Set<PersistentIdentifier> = []

    private var rootCollections: [PaperCollection] {
        allCollections.filter { $0.parent == nil }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Bibliothèque") {
                Label("Tous les articles", systemImage: "doc.on.doc")
                    .tag(SidebarSelection.allPapers)
                Label("Favoris", systemImage: "star.fill")
                    .tag(SidebarSelection.favorites)
                Label("À lire", systemImage: "book.closed")
                    .tag(SidebarSelection.unread)
                Label("Récents", systemImage: "clock")
                    .tag(SidebarSelection.recent)
            }

            Section("Collections") {
                ForEach(rootCollections) { collection in
                    collectionRow(collection, depth: 0)
                }

                if isAddingCollection {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        TextField("Nouvelle collection", text: $newCollectionName)
                            .onSubmit { addCollection() }
                            .onExitCommand {
                                isAddingCollection = false
                                newCollectionName = ""
                                addingToParent = nil
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Canope")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    addingToParent = nil
                    isAddingCollection = true
                    newCollectionName = ""
                }) {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Nouvelle collection")
            }
        }
    }

    // MARK: - Collection Row (recursive via flat list)

    @ViewBuilder
    private func collectionRow(_ collection: PaperCollection, depth: Int) -> some View {
        let hasChildren = !collection.children.isEmpty
        let isExpanded = expandedCollections.contains(collection.persistentModelID)

        HStack(spacing: 4) {
            // Expand/collapse button for collections with children
            if hasChildren {
                Button(action: { toggleExpand(collection) }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: collection.icon)
                .foregroundStyle(Color.accentColor)
            Text(collection.name)
            Spacer()
            Text("\(collection.papers.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.gray.opacity(0.15))
                .clipShape(Capsule())
        }
        .tag(SidebarSelection.collection(collection.persistentModelID))
        .contextMenu {
            Button("Nouvelle sous-collection…") {
                addingToParent = collection
                isAddingCollection = true
                newCollectionName = ""
            }
            Button("Renommer…") {
                // TODO: inline rename
            }
            Divider()
            Button("Supprimer", role: .destructive) {
                modelContext.delete(collection)
            }
        }

        // Show children if expanded
        if hasChildren && isExpanded {
            let sorted = collection.children.sorted { $0.sortOrder < $1.sortOrder }
            ForEach(sorted) { child in
                AnyView(collectionRow(child, depth: depth + 1)
                    .padding(.leading, 16))
            }
        }
    }

    private func toggleExpand(_ collection: PaperCollection) {
        let id = collection.persistentModelID
        if expandedCollections.contains(id) {
            expandedCollections.remove(id)
        } else {
            expandedCollections.insert(id)
        }
    }

    // MARK: - Add Collection

    private func addCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            isAddingCollection = false
            addingToParent = nil
            return
        }
        let collection = PaperCollection(name: name, parent: addingToParent)
        collection.sortOrder = (addingToParent?.children.count ?? rootCollections.count)
        modelContext.insert(collection)
        isAddingCollection = false
        newCollectionName = ""
        addingToParent = nil
    }
}

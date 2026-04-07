import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Query private var allPapers: [Paper]
    @Query(sort: \PaperCollection.sortOrder) private var allCollections: [PaperCollection]
    @Environment(\.modelContext) private var modelContext
    @State private var isAddingCollection = false
    @State private var newCollectionName = ""
    @State private var addingToParent: PaperCollection? = nil
    @State private var expandedCollections: Set<PersistentIdentifier> = []

    private var unreadCount: Int {
        allPapers.filter { !$0.isRead }.count
    }

    private var favoriteCount: Int {
        allPapers.filter(\.isFavorite).count
    }

    private var recentCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        return allPapers.filter { $0.dateAdded > cutoff }.count
    }

    private var rootCollections: [PaperCollection] {
        allCollections.filter { $0.parent == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            AppChromeDivider(role: .panel)

            List(selection: $selection) {
                Section {
                    sidebarItemRow(
                        title: "Tous les articles",
                        systemImage: "doc.on.doc",
                        count: allPapers.count,
                        tint: AppChromePalette.info
                    )
                    .tag(SidebarSelection.allPapers)

                    sidebarItemRow(
                        title: "Favoris",
                        systemImage: "star.fill",
                        count: favoriteCount,
                        tint: Color.yellow
                    )
                    .tag(SidebarSelection.favorites)

                    sidebarItemRow(
                        title: "À lire",
                        systemImage: "book.closed",
                        count: unreadCount,
                        tint: AppChromePalette.info
                    )
                    .tag(SidebarSelection.unread)

                    sidebarItemRow(
                        title: "Récents",
                        systemImage: "clock",
                        count: recentCount,
                        tint: .secondary
                    )
                    .tag(SidebarSelection.recent)
                } header: {
                    sidebarSectionHeader("Bibliothèque")
                }

                Section {
                    ForEach(rootCollections) { collection in
                        collectionRow(collection, depth: 0)
                    }

                    if isAddingCollection {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(AppChromePalette.info)
                            TextField("Nouvelle collection", text: $newCollectionName)
                                .textFieldStyle(.plain)
                                .onSubmit { addCollection() }
                                .onExitCommand {
                                    isAddingCollection = false
                                    newCollectionName = ""
                                    addingToParent = nil
                                }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AppChromePalette.clusterFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                } header: {
                    sidebarSectionHeader("Collections")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(AppChromePalette.surfaceSubbar)
        }
        .background(AppChromePalette.surfaceSubbar)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bibliothèque")
                    .font(.system(size: 13, weight: .semibold))
            }

            Spacer()

            ToolbarIconButton(
                systemName: "folder.badge.plus",
                foregroundStyle: AppChromePalette.info,
                helpText: "Nouvelle collection"
            ) {
                addingToParent = nil
                isAddingCollection = true
                newCollectionName = ""
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(AppChromePalette.surfaceBar.opacity(0.95))
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private func sidebarItemRow(
        title: String,
        systemImage: String,
        count: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 8)

            SidebarCountBadge(count: count)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
    }

    // MARK: - Collection Row (recursive via flat list)

    @ViewBuilder
    private func collectionRow(_ collection: PaperCollection, depth: Int) -> some View {
        let hasChildren = !collection.children.isEmpty
        let isExpanded = expandedCollections.contains(collection.persistentModelID)

        HStack(spacing: 8) {
            if hasChildren {
                Button(action: { toggleExpand(collection) }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: 12)
            }

            Image(systemName: collection.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppChromePalette.info)
                .frame(width: 14)

            Text(collection.name)
                .font(.system(size: 11, weight: .medium))

            Spacer(minLength: 8)

            SidebarCountBadge(count: collection.papers.count)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(depth) * 10)
        .contentShape(Rectangle())
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
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)

        if hasChildren && isExpanded {
            let sorted = collection.children.sorted { $0.sortOrder < $1.sortOrder }
            ForEach(sorted) { child in
                AnyView(collectionRow(child, depth: depth + 1))
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

private struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(AppChromePalette.hoverFill.opacity(0.45))
            )
    }
}

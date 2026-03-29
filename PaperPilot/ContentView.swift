import SwiftUI
import SwiftData

enum SidebarSelection: Hashable {
    case allPapers
    case favorites
    case unread
    case recent
    case collection(PersistentIdentifier)
}

enum TabItem: Hashable {
    case library
    case paper(UUID)
}

struct MainWindow: View {
    @Query private var allPapers: [Paper]
    @State private var openTabs: [TabItem] = [.library]
    @State private var selectedTab: TabItem = .library
    @State private var paperToOpen: UUID? = nil
    @State private var splitPaperID: UUID? = nil
    @State private var showTerminal = false
    @State private var selectedText = ""

    /// Paper tabs only (no library)
    private var openPaperIDs: [UUID] {
        openTabs.compactMap { if case .paper(let id) = $0 { return id } else { return nil } }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar + split button
            HStack(spacing: 0) {
                TabBar(
                    tabs: $openTabs,
                    selectedTab: $selectedTab,
                    allPapers: allPapers
                )

                Divider().frame(height: 20)

                // Split toggle
                if case .paper = selectedTab {
                    Menu {
                        if splitPaperID != nil {
                            Button("Fermer le split") { splitPaperID = nil }
                            Divider()
                        }
                        ForEach(openPaperIDs, id: \.self) { id in
                            if let paper = allPapers.first(where: { $0.id == id }) {
                                Button(paper.title) { splitPaperID = id }
                            }
                        }
                    } label: {
                        Image(systemName: splitPaperID != nil ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .help("Split view")
                }
            }
            .frame(height: 32)
            .background(.bar)

            Divider()

            // Content + resizable shared terminal
            HSplitView {
                // Main content — keep all views alive
                ZStack {
                    LibraryView(paperToOpen: $paperToOpen)
                        .opacity(selectedTab == .library ? 1 : 0)
                        .allowsHitTesting(selectedTab == .library)

                    ForEach(openPaperIDs, id: \.self) { paperId in
                        if let paper = allPapers.first(where: { $0.id == paperId }) {
                            Group {
                                let isActive = selectedTab == .paper(paperId)
                                if let splitID = splitPaperID,
                                   splitID != paperId,
                                   isActive {
                                    if let splitPaper = allPapers.first(where: { $0.id == splitID }) {
                                        HSplitView {
                                            PDFReaderView(paperID: paper.persistentModelID, isSplitMode: true, isActive: isActive, showTerminal: $showTerminal, selectedText: $selectedText)
                                            PDFReaderView(paperID: splitPaper.persistentModelID, isSplitMode: true, isActive: isActive, showTerminal: $showTerminal, selectedText: $selectedText)
                                        }
                                    }
                                } else {
                                    PDFReaderView(paperID: paper.persistentModelID, isActive: isActive, showTerminal: $showTerminal, selectedText: $selectedText)
                                }
                            }
                            .opacity(selectedTab == .paper(paperId) ? 1 : 0)
                            .allowsHitTesting(selectedTab == .paper(paperId))
                        }
                    }
                }

                // Shared terminal — always mounted, hidden when not needed
                TerminalPanel(document: nil, selectedText: selectedText)
                    .frame(
                        minWidth: showTerminal && selectedTab != .library ? 250 : 0,
                        idealWidth: showTerminal && selectedTab != .library ? 400 : 0,
                        maxWidth: showTerminal && selectedTab != .library ? .infinity : 0
                    )
                    .opacity(showTerminal && selectedTab != .library ? 1 : 0)
            }
        }
        .onChange(of: paperToOpen) {
            guard let id = paperToOpen else { return }
            let tab = TabItem.paper(id)
            if !openTabs.contains(tab) {
                openTabs.append(tab)
            }
            selectedTab = tab
            paperToOpen = nil
        }
    }
}

// MARK: - Tab Bar

struct TabBar: View {
    @Binding var tabs: [TabItem]
    @Binding var selectedTab: TabItem
    let allPapers: [Paper]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        title: title(for: tab),
                        onSelect: { selectedTab = tab },
                        onClose: tab != .library ? { closeTab(tab) } : nil
                    )
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }

    private func title(for tab: TabItem) -> String {
        switch tab {
        case .library: return "Bibliothèque"
        case .paper(let id):
            return allPapers.first(where: { $0.id == id })?.title ?? "Article"
        }
    }

    private func closeTab(_ tab: TabItem) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = index > 0 ? tabs[index - 1] : (tabs.first ?? .library)
        }
    }
}

struct TabButton: View {
    let tab: TabItem
    let isSelected: Bool
    let title: String
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tab == .library ? "books.vertical" : "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 150)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isSelected ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @Binding var paperToOpen: UUID?
    @State private var sidebarSelection: SidebarSelection? = .allPapers
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    @State private var inspectedPaperID: UUID?
    @Query private var allPapers: [Paper]

    private var inspectedPaper: Paper? {
        guard let id = inspectedPaperID else { return nil }
        return allPapers.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            PaperTableView(
                sidebarSelection: sidebarSelection ?? .allPapers,
                inspectedPaperID: $inspectedPaperID,
                onOpenPaper: { paper in
                    paperToOpen = paper.id
                }
            )
        }
        .inspector(isPresented: $showInspector) {
            if let paper = inspectedPaper {
                PaperInfoPanel(paper: paper)
            } else {
                ContentUnavailableView(
                    "Aucun article sélectionné",
                    systemImage: "info.circle",
                    description: Text("Sélectionnez un article pour voir ses infos")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showInspector.toggle() }) {
                    Image(systemName: "info.circle")
                }
                .help("Panneau info (⌘I)")
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .onChange(of: inspectedPaperID) {
            if inspectedPaperID != nil && !showInspector {
                showInspector = true
            }
        }
    }
}

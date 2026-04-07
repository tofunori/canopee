import SwiftUI
import SwiftData

// MARK: - Library View

struct LibraryView: View {
    @Binding var paperToOpen: UUID?
    @Binding var isImportingPDF: Bool
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
                isImporting: $isImportingPDF,
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
        .onChange(of: inspectedPaperID) {
            if inspectedPaperID != nil && !showInspector {
                showInspector = true
            }
        }
    }
}

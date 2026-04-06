import Foundation
import SwiftUI

/// Owns main-window tab list, selection, and split-PDF state so `MainWindow` stays thinner.
@MainActor
final class MainWindowTabController: ObservableObject {
    @Published var openTabs: [TabItem] = [.library]
    @Published var selectedTab: TabItem = .library
    @Published var splitPaperID: UUID?

    var openPaperIDs: [UUID] {
        openTabs.compactMap { if case .paper(let id) = $0 { return id } else { return nil } }
    }

    var openEditorPaths: [String] {
        openTabs.compactMap { if case .editor(let path) = $0 { return path } else { return nil } }
    }

    var openPDFPaths: [String] {
        openTabs.compactMap { if case .pdfFile(let path) = $0 { return path } else { return nil } }
    }

    func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    func makePersistSnapshot(showTerminal: Bool) -> MainWindowWorkspaceState {
        var savedTabs = openTabs
            .filter { $0 != .editorWorkspace }
            .compactMap(MainWindowWorkspaceState.SavedTab.init)
        if !savedTabs.contains(.library) {
            savedTabs.insert(.library, at: 0)
        }
        savedTabs = deduplicated(savedTabs)

        let selectedSavedTab = MainWindowWorkspaceState.SavedTab(selectedTab) ?? savedTabs.last ?? .library
        return MainWindowWorkspaceState(
            openTabs: savedTabs,
            selectedTab: selectedSavedTab,
            showTerminal: showTerminal,
            splitPaperID: splitPaperID
        )
    }

    func applyRestoredSnapshot(_ snapshot: MainWindowWorkspaceState) {
        var restoredTabs = snapshot.openTabs
            .compactMap(\.tabItem)
            .filter { $0 != .editorWorkspace }
        if !restoredTabs.contains(.library) {
            restoredTabs.insert(.library, at: 0)
        }
        restoredTabs = deduplicated(restoredTabs)
        if restoredTabs.isEmpty {
            restoredTabs = [.library]
        }

        openTabs = restoredTabs

        if let restoredSelected = snapshot.selectedTab.tabItem {
            if restoredSelected != .editorWorkspace && !openTabs.contains(restoredSelected) {
                openTabs.append(restoredSelected)
            }
            selectedTab = restoredSelected
        } else {
            selectedTab = openTabs.last ?? .library
        }

        if let splitID = snapshot.splitPaperID, openTabs.contains(.paper(splitID)) {
            splitPaperID = splitID
        } else {
            splitPaperID = nil
        }
    }

    func openPDFFile(_ url: URL) {
        let tab = TabItem.pdfFile(url.path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        selectedTab = tab
    }

    func openEditorTab(path: String, select: Bool = true) {
        let tab = TabItem.editor(path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        if select {
            selectedTab = tab
        }
    }

    func closeTab(_ tab: TabItem) {
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = index > 0 ? openTabs[index - 1] : (openTabs.first ?? .library)
        }
    }
}

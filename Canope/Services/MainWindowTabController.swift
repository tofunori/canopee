import Foundation
import SwiftUI
import OSLog

/// Owns main-window tab list, selection, and split-PDF state so `MainWindow` stays thinner.
@MainActor
final class MainWindowTabController: ObservableObject {
    @Published var openTabs: [TabItem] = [.library]
    @Published var selectedTab: TabItem = .library {
        didSet {
            guard self.selectedTab != oldValue else { return }
            Self.logger.info("Selected main tab: \(Self.describe(tab: self.selectedTab), privacy: .public)")
        }
    }
    @Published var splitPaperID: UUID? {
        didSet {
            guard self.splitPaperID != oldValue else { return }
            let value = self.splitPaperID?.uuidString ?? "nil"
            Self.logger.debug("Updated split paper id: \(value, privacy: .public)")
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.canope.app",
        category: "WindowTabs"
    )

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

        Self.logger.info(
            "Restored workspace tabs=\(self.openTabs.count, privacy: .public) selected=\(Self.describe(tab: self.selectedTab), privacy: .public)"
        )
    }

    func openPDFFile(_ url: URL) {
        let tab = TabItem.pdfFile(url.path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        selectedTab = tab
        Self.logger.info("Opened standalone PDF tab: \(url.lastPathComponent, privacy: .public)")
    }

    func openEditorTab(path: String, select: Bool = true) {
        let tab = TabItem.editor(path)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        if select {
            selectedTab = tab
        }
        Self.logger.info("Opened editor tab: \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public) select=\(select, privacy: .public)")
    }

    func closeTab(_ tab: TabItem) {
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = index > 0 ? openTabs[index - 1] : (openTabs.first ?? .library)
        }
        Self.logger.info("Closed tab: \(Self.describe(tab: tab), privacy: .public)")
    }

    private static func describe(tab: TabItem) -> String {
        switch tab {
        case .library:
            return "library"
        case .paper(let id):
            return "paper:\(id.uuidString)"
        case .editorWorkspace:
            return "editorWorkspace"
        case .editor(let path):
            return "editor:\(URL(fileURLWithPath: path).lastPathComponent)"
        case .pdfFile(let path):
            return "pdf:\(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }
}

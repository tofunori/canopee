import SwiftUI

enum NativeChatProviderKind: Equatable, Hashable {
    case claude
    case codex
}

enum TerminalTabKind: Equatable {
    case terminal
    case nativeChat(NativeChatProviderKind)
}

struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String = "Terminal"
    var optionAsMetaKey: Bool = false
    var kind: TerminalTabKind = .terminal
}

enum TerminalSessionPane {
    case top
    case bottom
}

@MainActor
final class TerminalSessionStore {
    private var topTerminalViews: [UUID: FocusAwareLocalProcessTerminalView] = [:]
    private var bottomTerminalViews: [UUID: FocusAwareLocalProcessTerminalView] = [:]

    func terminalView(for tabID: UUID, in pane: TerminalSessionPane) -> FocusAwareLocalProcessTerminalView? {
        storage(for: pane)[tabID]
    }

    func register(_ terminalView: FocusAwareLocalProcessTerminalView, for tabID: UUID, in pane: TerminalSessionPane) {
        var views = storage(for: pane)
        views[tabID] = terminalView
        setStorage(views, for: pane)
    }

    func removeTerminalView(for tabID: UUID, in pane: TerminalSessionPane) -> FocusAwareLocalProcessTerminalView? {
        var views = storage(for: pane)
        let removed = views.removeValue(forKey: tabID)
        setStorage(views, for: pane)
        return removed
    }

    func terminalViews(in pane: TerminalSessionPane) -> [FocusAwareLocalProcessTerminalView] {
        Array(storage(for: pane).values)
    }

    func clearTerminalViews(in pane: TerminalSessionPane) {
        setStorage([:], for: pane)
    }

    func promoteBottomSessionsToTop() {
        topTerminalViews = bottomTerminalViews
        bottomTerminalViews = [:]
    }

    private func storage(for pane: TerminalSessionPane) -> [UUID: FocusAwareLocalProcessTerminalView] {
        switch pane {
        case .top:
            return topTerminalViews
        case .bottom:
            return bottomTerminalViews
        }
    }

    private func setStorage(_ storage: [UUID: FocusAwareLocalProcessTerminalView], for pane: TerminalSessionPane) {
        switch pane {
        case .top:
            topTerminalViews = storage
        case .bottom:
            bottomTerminalViews = storage
        }
    }
}

@MainActor
final class TerminalWorkspaceState: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selectedTabID: UUID?
    @Published var isSplit: Bool
    @Published var splitTabs: [TerminalTab]
    @Published var focusedPane: TerminalPanel.PaneID
    @Published var splitFraction: CGFloat
    @Published var claudeChatProviders: [UUID: ClaudeHeadlessProvider] = [:]
    @Published var codexChatProviders: [UUID: CodexAppServerProvider] = [:]
    private let terminalSessions = TerminalSessionStore()

    init() {
        let initialTab = TerminalTab()
        self.tabs = [initialTab]
        self.selectedTabID = initialTab.id
        self.isSplit = false
        self.splitTabs = [TerminalTab()]
        self.focusedPane = .top
        self.splitFraction = 0.5
    }

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func claudeChatProvider(for tabID: UUID, workingDirectory: URL?) -> ClaudeHeadlessProvider {
        if let existing = claudeChatProviders[tabID] {
            if let wd = workingDirectory {
                existing.updateWorkingDirectory(wd)
            }
            return existing
        }
        let provider = ClaudeHeadlessProvider(workingDirectory: workingDirectory)
        claudeChatProviders[tabID] = provider
        return provider
    }

    func codexChatProvider(for tabID: UUID, workingDirectory: URL?) -> CodexAppServerProvider {
        if let existing = codexChatProviders[tabID] {
            if let wd = workingDirectory {
                existing.updateWorkingDirectory(wd)
            }
            return existing
        }
        let provider = CodexAppServerProvider(workingDirectory: workingDirectory)
        codexChatProviders[tabID] = provider
        return provider
    }

    func removeTab(id: UUID) {
        claudeChatProviders[id]?.stop()
        claudeChatProviders.removeValue(forKey: id)
        codexChatProviders[id]?.stop()
        codexChatProviders.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
        }
    }

    func terminalView(for tabID: UUID, in pane: TerminalSessionPane) -> FocusAwareLocalProcessTerminalView? {
        terminalSessions.terminalView(for: tabID, in: pane)
    }

    func registerTerminalView(_ terminalView: FocusAwareLocalProcessTerminalView, for tabID: UUID, in pane: TerminalSessionPane) {
        terminalSessions.register(terminalView, for: tabID, in: pane)
    }

    func removeTerminalView(for tabID: UUID, in pane: TerminalSessionPane) -> FocusAwareLocalProcessTerminalView? {
        terminalSessions.removeTerminalView(for: tabID, in: pane)
    }

    func terminalViews(in pane: TerminalSessionPane) -> [FocusAwareLocalProcessTerminalView] {
        terminalSessions.terminalViews(in: pane)
    }

    func clearTerminalViews(in pane: TerminalSessionPane) {
        terminalSessions.clearTerminalViews(in: pane)
    }

    func promoteSplitTerminalViewsToTop() {
        terminalSessions.promoteBottomSessionsToTop()
    }
}

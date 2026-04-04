import Foundation

@MainActor
final class WorkspaceSessionStore {
    static let shared = WorkspaceSessionStore()

    private enum Keys {
        static let mainWindowState = "canope.last-main-window-workspace.v1"
        static let latexWorkspaceState = "canope.last-latex-workspace.v2"
        static let codeWorkspaceStates = "canope.last-code-workspace.v1"
    }

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func saveMainWindowState(_ state: MainWindowWorkspaceState) {
        save(state, forKey: Keys.mainWindowState)
    }

    func loadMainWindowState() -> MainWindowWorkspaceState? {
        load(MainWindowWorkspaceState.self, forKey: Keys.mainWindowState)
    }

    func saveLaTeXWorkspaceState(_ state: LaTeXEditorWorkspaceState) {
        save(state, forKey: Keys.latexWorkspaceState)
    }

    func loadLaTeXWorkspaceState() -> LaTeXEditorWorkspaceState? {
        load(LaTeXEditorWorkspaceState.self, forKey: Keys.latexWorkspaceState)
    }

    func saveCodeDocumentWorkspaceState(_ state: CodeDocumentWorkspaceState, for path: String) {
        var allStates = loadCodeDocumentWorkspaceStates()
        allStates[path] = state
        save(allStates, forKey: Keys.codeWorkspaceStates)
    }

    func loadCodeDocumentWorkspaceState(for path: String) -> CodeDocumentWorkspaceState? {
        loadCodeDocumentWorkspaceStates()[path]
    }

    private func loadCodeDocumentWorkspaceStates() -> [String: CodeDocumentWorkspaceState] {
        load([String: CodeDocumentWorkspaceState].self, forKey: Keys.codeWorkspaceStates) ?? [:]
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

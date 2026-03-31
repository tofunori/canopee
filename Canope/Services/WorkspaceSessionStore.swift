import Foundation
import PDFKit

struct MainWindowWorkspaceState: Codable, Equatable {
    enum SavedTab: Codable, Hashable {
        case library
        case paper(UUID)
        case editor(String)
        case pdfFile(String)

        private enum CodingKeys: String, CodingKey {
            case kind
            case uuid
            case path
        }

        private enum Kind: String, Codable {
            case library
            case paper
            case editor
            case pdfFile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)
            switch kind {
            case .library:
                self = .library
            case .paper:
                self = .paper(try container.decode(UUID.self, forKey: .uuid))
            case .editor:
                self = .editor(try container.decode(String.self, forKey: .path))
            case .pdfFile:
                self = .pdfFile(try container.decode(String.self, forKey: .path))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .library:
                try container.encode(Kind.library, forKey: .kind)
            case .paper(let id):
                try container.encode(Kind.paper, forKey: .kind)
                try container.encode(id, forKey: .uuid)
            case .editor(let path):
                try container.encode(Kind.editor, forKey: .kind)
                try container.encode(path, forKey: .path)
            case .pdfFile(let path):
                try container.encode(Kind.pdfFile, forKey: .kind)
                try container.encode(path, forKey: .path)
            }
        }

        init?(_ tab: TabItem) {
            switch tab {
            case .library:
                self = .library
            case .paper(let id):
                self = .paper(id)
            case .editor(let path):
                guard !path.isEmpty else { return nil }
                self = .editor(path)
            case .pdfFile(let path):
                self = .pdfFile(path)
            }
        }

        var tabItem: TabItem? {
            switch self {
            case .library:
                return .library
            case .paper(let id):
                return .paper(id)
            case .editor(let path):
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return .editor(path)
            case .pdfFile(let path):
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return .pdfFile(path)
            }
        }
    }

    var openTabs: [SavedTab]
    var selectedTab: SavedTab
    var showTerminal: Bool
    var splitPaperID: UUID?
}

struct LaTeXEditorWorkspaceState: Codable, Equatable {
    var showSidebar: Bool
    var selectedSidebarSection: String
    var showPDFPreview: Bool
    var showErrors: Bool
    var splitLayout: String
    var editorFontSize: Double
    var editorTheme: Int
    var referencePaperIDs: [UUID]
    var selectedReferencePaperID: UUID?
    var layoutBeforeReference: String?
}

@MainActor
final class LaTeXWorkspaceUIState: ObservableObject {
    @Published var showSidebar = true
    @Published var selectedSidebarSection = "files"
    @Published var showPDFPreview = false
    @Published var showErrors = false
    @Published var splitLayout = "editorOnly"
    @Published var editorFontSize: Double = 14
    @Published var editorTheme = 0
    @Published var referencePaperIDs: [UUID] = []
    @Published var selectedReferencePaperID: UUID?
    @Published var layoutBeforeReference: String?
    @Published var referencePDFs: [UUID: PDFDocument] = [:]
}

@MainActor
final class WorkspaceSessionStore {
    static let shared = WorkspaceSessionStore()

    private enum Keys {
        static let mainWindowState = "canope.last-main-window-workspace.v1"
        static let latexWorkspaceState = "canope.last-latex-workspace.v2"
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

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

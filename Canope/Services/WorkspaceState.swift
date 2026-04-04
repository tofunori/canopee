import Foundation

enum LaTeXPanelArrangement: String, Codable, CaseIterable, Equatable {
    case editorPDFTerminal
    case terminalEditorPDF
    case pdfEditorTerminal

    var title: String {
        switch self {
        case .editorPDFTerminal:
            return "TeX | PDF | Terminal"
        case .terminalEditorPDF:
            return "Terminal | TeX | PDF"
        case .pdfEditorTerminal:
            return "PDF | TeX | Terminal"
        }
    }
}

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
    var sidebarWidth: Double
    var showEditorPane: Bool
    var showPDFPreview: Bool
    var showErrors: Bool
    var splitLayout: String
    var panelArrangement: LaTeXPanelArrangement
    var threePaneLeadingWidth: Double?
    var threePaneTrailingWidth: Double?
    var editorFontSize: Double
    var editorTheme: Int
    var referencePaperIDs: [UUID]
    var selectedReferencePaperID: UUID?
    var layoutBeforeReference: String?

    private enum CodingKeys: String, CodingKey {
        case showSidebar
        case selectedSidebarSection
        case sidebarWidth
        case showEditorPane
        case showPDFPreview
        case showErrors
        case splitLayout
        case panelArrangement
        case threePaneLeadingWidth
        case threePaneTrailingWidth
        case editorFontSize
        case editorTheme
        case referencePaperIDs
        case selectedReferencePaperID
        case layoutBeforeReference
    }

    init(
        showSidebar: Bool,
        selectedSidebarSection: String,
        sidebarWidth: Double,
        showEditorPane: Bool,
        showPDFPreview: Bool,
        showErrors: Bool,
        splitLayout: String,
        panelArrangement: LaTeXPanelArrangement,
        threePaneLeadingWidth: Double?,
        threePaneTrailingWidth: Double?,
        editorFontSize: Double,
        editorTheme: Int,
        referencePaperIDs: [UUID],
        selectedReferencePaperID: UUID?,
        layoutBeforeReference: String?
    ) {
        self.showSidebar = showSidebar
        self.selectedSidebarSection = selectedSidebarSection
        self.sidebarWidth = sidebarWidth
        self.showEditorPane = showEditorPane
        self.showPDFPreview = showPDFPreview
        self.showErrors = showErrors
        self.splitLayout = splitLayout
        self.panelArrangement = panelArrangement
        self.threePaneLeadingWidth = threePaneLeadingWidth
        self.threePaneTrailingWidth = threePaneTrailingWidth
        self.editorFontSize = editorFontSize
        self.editorTheme = editorTheme
        self.referencePaperIDs = referencePaperIDs
        self.selectedReferencePaperID = selectedReferencePaperID
        self.layoutBeforeReference = layoutBeforeReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showSidebar = try container.decode(Bool.self, forKey: .showSidebar)
        selectedSidebarSection = try container.decode(String.self, forKey: .selectedSidebarSection)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 220
        showEditorPane = try container.decodeIfPresent(Bool.self, forKey: .showEditorPane) ?? true
        showPDFPreview = try container.decode(Bool.self, forKey: .showPDFPreview)
        showErrors = try container.decode(Bool.self, forKey: .showErrors)
        splitLayout = try container.decode(String.self, forKey: .splitLayout)
        panelArrangement = try container.decodeIfPresent(LaTeXPanelArrangement.self, forKey: .panelArrangement) ?? .editorPDFTerminal
        threePaneLeadingWidth = try container.decodeIfPresent(Double.self, forKey: .threePaneLeadingWidth)
        threePaneTrailingWidth = try container.decodeIfPresent(Double.self, forKey: .threePaneTrailingWidth)
        editorFontSize = try container.decode(Double.self, forKey: .editorFontSize)
        editorTheme = try container.decode(Int.self, forKey: .editorTheme)
        referencePaperIDs = try container.decode([UUID].self, forKey: .referencePaperIDs)
        selectedReferencePaperID = try container.decodeIfPresent(UUID.self, forKey: .selectedReferencePaperID)
        layoutBeforeReference = try container.decodeIfPresent(String.self, forKey: .layoutBeforeReference)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showSidebar, forKey: .showSidebar)
        try container.encode(selectedSidebarSection, forKey: .selectedSidebarSection)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(showEditorPane, forKey: .showEditorPane)
        try container.encode(showPDFPreview, forKey: .showPDFPreview)
        try container.encode(showErrors, forKey: .showErrors)
        try container.encode(splitLayout, forKey: .splitLayout)
        try container.encode(panelArrangement, forKey: .panelArrangement)
        try container.encodeIfPresent(threePaneLeadingWidth, forKey: .threePaneLeadingWidth)
        try container.encodeIfPresent(threePaneTrailingWidth, forKey: .threePaneTrailingWidth)
        try container.encode(editorFontSize, forKey: .editorFontSize)
        try container.encode(editorTheme, forKey: .editorTheme)
        try container.encode(referencePaperIDs, forKey: .referencePaperIDs)
        try container.encodeIfPresent(selectedReferencePaperID, forKey: .selectedReferencePaperID)
        try container.encodeIfPresent(layoutBeforeReference, forKey: .layoutBeforeReference)
    }
}

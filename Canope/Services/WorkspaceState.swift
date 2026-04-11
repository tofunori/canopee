import Foundation

enum MarkdownEditorDisplayMode: String, Codable, CaseIterable, Equatable {
    case source
    case livePreview

    var title: String {
        switch self {
        case .source:
            return AppStrings.source
        case .livePreview:
            return AppStrings.preview
        }
    }
}

enum PanelArrangement: String, Codable, CaseIterable, Equatable {
    // Raw values match the old LaTeXPanelArrangement for backward compat
    case editorContentTerminal = "editorPDFTerminal"
    case terminalEditorContent = "terminalEditorPDF"
    case contentEditorTerminal = "pdfEditorTerminal"

    func title(contentLabel: String) -> String {
        switch self {
        case .editorContentTerminal:
            return "TeX | \(contentLabel) | Terminal"
        case .terminalEditorContent:
            return "Terminal | TeX | \(contentLabel)"
        case .contentEditorTerminal:
            return "\(contentLabel) | TeX | Terminal"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Accept old CodePanelArrangement raw values
        switch raw {
        case "editorOutputTerminal":
            self = .editorContentTerminal
        case "terminalEditorOutput":
            self = .terminalEditorContent
        case "outputEditorTerminal":
            self = .contentEditorTerminal
        default:
            guard let value = PanelArrangement(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown PanelArrangement: \(raw)")
            }
            self = value
        }
    }
}

typealias LaTeXPanelArrangement = PanelArrangement

struct MainWindowWorkspaceState: Codable, Equatable {
    enum SavedTab: Codable, Hashable {
        case library
        case paper(UUID)
        case editorWorkspace
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
            case editorWorkspace
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
            case .editorWorkspace:
                self = .editorWorkspace
            case .editor:
                let path = try container.decode(String.self, forKey: .path)
                self = path.isEmpty ? .editorWorkspace : .editor(path)
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
            case .editorWorkspace:
                try container.encode(Kind.editorWorkspace, forKey: .kind)
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
            case .editorWorkspace:
                self = .editorWorkspace
            case .editor(let path):
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
            case .editorWorkspace:
                return .editorWorkspace
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
    var selectedSidebarSection: LaTeXEditorSidebarSection
    var sidebarWidth: Double
    var showEditorPane: Bool
    var showPDFPreview: Bool
    var showErrors: Bool
    var splitLayout: LaTeXEditorSplitLayout
    var panelArrangement: PanelArrangement
    var threePaneLeadingWidth: Double?
    var threePaneTrailingWidth: Double?
    var editorFontSize: Double
    var editorTheme: Int
    var markdownEditorMode: MarkdownEditorDisplayMode
    var isCompiledPDFTabVisible: Bool
    var referencePaperIDs: [UUID]
    var selectedReferencePaperID: UUID?
    var layoutBeforeReference: LaTeXEditorSplitLayout?
    var workspaceRootPath: String?

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
        case markdownEditorMode
        case isCompiledPDFTabVisible
        case referencePaperIDs
        case selectedReferencePaperID
        case layoutBeforeReference
        case workspaceRootPath
    }

    init(
        showSidebar: Bool,
        selectedSidebarSection: LaTeXEditorSidebarSection,
        sidebarWidth: Double,
        showEditorPane: Bool,
        showPDFPreview: Bool,
        showErrors: Bool,
        splitLayout: LaTeXEditorSplitLayout,
        panelArrangement: PanelArrangement,
        threePaneLeadingWidth: Double?,
        threePaneTrailingWidth: Double?,
        editorFontSize: Double,
        editorTheme: Int,
        markdownEditorMode: MarkdownEditorDisplayMode,
        isCompiledPDFTabVisible: Bool,
        referencePaperIDs: [UUID],
        selectedReferencePaperID: UUID?,
        layoutBeforeReference: LaTeXEditorSplitLayout?,
        workspaceRootPath: String? = nil
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
        self.markdownEditorMode = markdownEditorMode
        self.isCompiledPDFTabVisible = isCompiledPDFTabVisible
        self.referencePaperIDs = referencePaperIDs
        self.selectedReferencePaperID = selectedReferencePaperID
        self.layoutBeforeReference = layoutBeforeReference
        self.workspaceRootPath = workspaceRootPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showSidebar = try container.decode(Bool.self, forKey: .showSidebar)
        selectedSidebarSection = try container.decodeIfPresent(LaTeXEditorSidebarSection.self, forKey: .selectedSidebarSection)
            ?? .files
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 220
        showEditorPane = try container.decodeIfPresent(Bool.self, forKey: .showEditorPane) ?? true
        showPDFPreview = try container.decode(Bool.self, forKey: .showPDFPreview)
        showErrors = try container.decode(Bool.self, forKey: .showErrors)
        splitLayout = try container.decodeIfPresent(LaTeXEditorSplitLayout.self, forKey: .splitLayout)
            ?? .editorOnly
        panelArrangement = try container.decodeIfPresent(PanelArrangement.self, forKey: .panelArrangement) ?? .terminalEditorContent
        threePaneLeadingWidth = try container.decodeIfPresent(Double.self, forKey: .threePaneLeadingWidth)
        threePaneTrailingWidth = try container.decodeIfPresent(Double.self, forKey: .threePaneTrailingWidth)
        editorFontSize = try container.decode(Double.self, forKey: .editorFontSize)
        editorTheme = try container.decode(Int.self, forKey: .editorTheme)
        markdownEditorMode = try container.decodeIfPresent(MarkdownEditorDisplayMode.self, forKey: .markdownEditorMode) ?? .livePreview
        isCompiledPDFTabVisible = try container.decodeIfPresent(Bool.self, forKey: .isCompiledPDFTabVisible) ?? true
        referencePaperIDs = try container.decode([UUID].self, forKey: .referencePaperIDs)
        selectedReferencePaperID = try container.decodeIfPresent(UUID.self, forKey: .selectedReferencePaperID)
        layoutBeforeReference = try container.decodeIfPresent(LaTeXEditorSplitLayout.self, forKey: .layoutBeforeReference)
        workspaceRootPath = try container.decodeIfPresent(String.self, forKey: .workspaceRootPath)
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
        try container.encode(markdownEditorMode, forKey: .markdownEditorMode)
        try container.encode(isCompiledPDFTabVisible, forKey: .isCompiledPDFTabVisible)
        try container.encode(referencePaperIDs, forKey: .referencePaperIDs)
        try container.encodeIfPresent(selectedReferencePaperID, forKey: .selectedReferencePaperID)
        try container.encodeIfPresent(layoutBeforeReference, forKey: .layoutBeforeReference)
        try container.encodeIfPresent(workspaceRootPath, forKey: .workspaceRootPath)
    }
}

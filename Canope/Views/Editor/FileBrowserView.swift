import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileItem]?

    var displayIcon: String {
        if isDirectory { return "" }
        switch url.pathExtension.lowercased() {
        case "tex": return ""
        case "bib": return ""
        case "pdf": return ""
        case "png", "jpg", "jpeg", "eps", "svg": return ""
        case "md", "txt": return ""
        case "sty", "cls": return ""
        case "log", "aux", "out": return ""
        default: return ""
        }
    }

    var color: Color {
        if isDirectory { return Color(red: 0.55, green: 0.7, blue: 0.9) } // soft blue
        switch url.pathExtension.lowercased() {
        case "tex": return Color(red: 0.6, green: 0.85, blue: 0.6) // soft green
        case "bib": return Color(red: 0.85, green: 0.75, blue: 0.55) // warm tan
        case "pdf": return Color(red: 0.85, green: 0.6, blue: 0.6) // muted rose
        case "png", "jpg", "jpeg", "eps", "svg": return Color(red: 0.8, green: 0.65, blue: 0.8) // soft lavender
        case "md", "txt": return Color(white: 0.7) // soft gray
        case "sty", "cls": return Color(red: 0.7, green: 0.6, blue: 0.8) // muted purple
        case "log", "aux", "out": return Color(white: 0.35)
        default: return Color(white: 0.5)
        }
    }
}

struct FileBrowserView: View {
    private enum NewFileKind {
        case latex
        case markdown

        var defaultFileName: String {
            switch self {
            case .latex:
                return "untitled.tex"
            case .markdown:
                return "notes.md"
            }
        }

        var contentType: UTType {
            switch self {
            case .latex:
                return UTType(filenameExtension: "tex") ?? .plainText
            case .markdown:
                return UTType(filenameExtension: "md") ?? .plainText
            }
        }

        var panelTitle: String {
            switch self {
            case .latex:
                return "Nouveau fichier LaTeX"
            case .markdown:
                return "Nouveau fichier Markdown"
            }
        }

        var panelMessage: String {
            switch self {
            case .latex:
                return "Crée un nouveau fichier .tex"
            case .markdown:
                return "Crée un nouveau fichier .md"
            }
        }

        var template: String {
            switch self {
            case .latex:
                return """
                \\documentclass{article}

                \\begin{document}

                \\end{document}
                """
            case .markdown:
                return ""
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let initialRootURL: URL
    let showsCreateFileMenu: Bool
    let onOpenFile: (URL) -> Void
    @State private var currentDir: URL
    @State private var items: [FileItem] = []
    @State private var expandedDirs: Set<URL> = []
    @State private var childDirectoryCache: [URL: [FileItem]] = [:]
    @State private var selectedIndex: Int = 0
    @State private var hoveredItemURL: URL?
    @State private var fileCreationError: String?
    @FocusState private var isFocused: Bool

    private let bgColor = Color(nsColor: NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1))

    init(rootURL: URL, showsCreateFileMenu: Bool = true, onOpenFile: @escaping (URL) -> Void) {
        self.initialRootURL = rootURL
        self.showsCreateFileMenu = showsCreateFileMenu
        self.onOpenFile = onOpenFile
        self._currentDir = State(initialValue: rootURL)
    }

    // Flat list of visible items for keyboard navigation
    private var flatItems: [FileItem] {
        var result: [FileItem] = []
        func flatten(_ items: [FileItem]) {
            for item in items {
                result.append(item)
                if item.isDirectory,
                   expandedDirs.contains(item.url),
                   let children = childItems(for: item.url) {
                    flatten(children)
                }
            }
        }
        flatten(items)
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with current path
            HStack(spacing: 4) {
                Text(" \(currentDir.lastPathComponent)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Spacer()
                if showsCreateFileMenu {
                    Menu {
                        Button {
                            createFile(.latex)
                        } label: {
                            Label("Nouveau fichier LaTeX", systemImage: "doc.badge.plus")
                        }

                        Button {
                            createFile(.markdown)
                        } label: {
                            Label("Nouveau fichier Markdown", systemImage: "text.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Créer un nouveau fichier .tex ou .md")
                }

                Button(action: refresh) {
                    Text("↻")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(bgColor.opacity(0.8))

            AppChromeDivider(role: .inset)

            // File list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // ".." to go up
                        let canGoUp = currentDir.path != "/"
                        if canGoUp {
                            Button(action: goUp) {
                                HStack(spacing: 0) {
                                    Spacer().frame(width: 4)
                                    Text(" ..")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.yellow)
                                    Spacer()
                                }
                                .frame(height: 19)
                                .frame(maxWidth: .infinity)
                                .background(selectedIndex == -1 ? Color.white.opacity(0.08) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id("parent")
                        }

                        // Only top-level items — renderItem handles recursion
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            renderItem(item, depth: 0, index: flatIndex(for: item))
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .background(bgColor)
                .focused($isFocused)
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    scrollTo(proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    scrollTo(proxy)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    collapseOrGoUp()
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    expandOrEnter()
                    return .handled
                }
                .onKeyPress(.return) {
                    activateSelected()
                    return .handled
                }
            }
        }
        .onAppear {
            refresh()
            isFocused = true
        }
        .onChange(of: currentDir) {
            refresh()
            selectedIndex = 0
        }
        .alert("Impossible de créer le fichier", isPresented: Binding(
            get: { fileCreationError != nil },
            set: { if !$0 { fileCreationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fileCreationError ?? "")
        }
    }

    private func itemDepth(_ item: FileItem) -> Int {
        // Calculate depth based on URL relative to currentDir
        let base = currentDir.pathComponents.count
        let itemComponents = item.url.deletingLastPathComponent().pathComponents.count
        return max(0, itemComponents - base)
    }

    @ViewBuilder
    private func renderItem(_ item: FileItem, depth: Int, index: Int) -> some View {
        let isExpanded = expandedDirs.contains(item.url)
        let isSelected = selectedIndex == index
        let isHovered = hoveredItemURL == item.url
        let indent = CGFloat(depth) * 14

        Button(action: {
            if selectedIndex == index {
                // Second click — open
                if item.isDirectory {
                    expandedDirs.removeAll()
                    currentDir = item.url
                } else {
                    onOpenFile(item.url)
                }
            } else {
                // First click — select only
                selectedIndex = index
                if item.isDirectory {
                    AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                        if isExpanded { expandedDirs.remove(item.url) }
                        else {
                            loadChildrenIfNeeded(for: item.url)
                            expandedDirs.insert(item.url)
                        }
                    }
                }
            }
        }) {
            HStack(spacing: 0) {
                Spacer().frame(width: 4 + indent)

                if item.isDirectory {
                    Text(isExpanded ? "▾" : "▸")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, alignment: .center)
                } else {
                    Spacer().frame(width: 10)
                }

                Text("\(item.isDirectory ? " " : "\(item.displayIcon) ")\(item.name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(item.color)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .frame(height: 19)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? AppChromePalette.selectedAccentFill
                : isHovered ? AppChromePalette.hoverFill
                : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItemURL = hovering ? item.url : nil
        }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: hoveredItemURL)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)

        if item.isDirectory && isExpanded, let children = childItems(for: item.url) {
            ForEach(children) { child in
                AnyView(renderItem(child, depth: depth + 1, index: flatIndex(for: child)))
            }
        }
    }

    private func flatIndex(for item: FileItem) -> Int {
        flatItems.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    // MARK: - Navigation

    private func goUp() {
        let parent = currentDir.deletingLastPathComponent()
        expandedDirs.removeAll()
        childDirectoryCache.removeAll()
        currentDir = parent
    }

    private func moveSelection(_ delta: Int) {
        let visible = flatItems
        let newIndex = selectedIndex + delta
        if newIndex < -1 { return }
        if newIndex >= visible.count { return }
        selectedIndex = newIndex
    }

    private func scrollTo(_ proxy: ScrollViewProxy) {
        let visible = flatItems
        if selectedIndex == -1 {
            proxy.scrollTo("parent")
        } else if selectedIndex >= 0 && selectedIndex < visible.count {
            proxy.scrollTo(visible[selectedIndex].id)
        }
    }

    private func collapseOrGoUp() {
        let visible = flatItems
        if selectedIndex >= 0 && selectedIndex < visible.count {
            let item = visible[selectedIndex]
            if item.isDirectory && expandedDirs.contains(item.url) {
                expandedDirs.remove(item.url)
            } else {
                goUp()
            }
        } else {
            goUp()
        }
    }

    private func expandOrEnter() {
        let visible = flatItems
        if selectedIndex >= 0 && selectedIndex < visible.count {
            let item = visible[selectedIndex]
            if item.isDirectory {
                if !expandedDirs.contains(item.url) {
                    loadChildrenIfNeeded(for: item.url)
                    expandedDirs.insert(item.url)
                } else {
                    // Already expanded, move into first child
                    moveSelection(1)
                }
            }
        }
    }

    private func activateSelected() {
        if selectedIndex == -1 {
            goUp()
            return
        }
        let visible = flatItems
        guard selectedIndex >= 0 && selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        if item.isDirectory {
            // Double-enter navigates into directory
            expandedDirs.removeAll()
            currentDir = item.url
        } else {
            onOpenFile(item.url)
        }
    }

    private func refresh() {
        childDirectoryCache.removeAll()
        items = scanDirectory(currentDir)
    }

    private var creationTargetDirectory: URL {
        guard selectedIndex >= 0 && selectedIndex < flatItems.count else { return currentDir }
        let item = flatItems[selectedIndex]
        return item.isDirectory ? item.url : currentDir
    }

    private func createFile(_ kind: NewFileKind) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = creationTargetDirectory
        panel.nameFieldStringValue = kind.defaultFileName
        panel.allowedContentTypes = [kind.contentType]
        panel.isExtensionHidden = false
        panel.title = kind.panelTitle
        panel.message = kind.panelMessage
        panel.prompt = "Créer"

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        do {
            try kind.template.write(to: fileURL, atomically: true, encoding: .utf8)
            revealCreatedFile(at: fileURL)
            onOpenFile(fileURL)
        } catch {
            fileCreationError = error.localizedDescription
        }
    }

    private func revealCreatedFile(at fileURL: URL) {
        let targetDirectory = fileURL.deletingLastPathComponent()

        if targetDirectory == currentDir {
            refresh()
        } else {
            items = scanDirectory(currentDir)
            childDirectoryCache[targetDirectory] = scanDirectory(targetDirectory)
            expandedDirs.insert(targetDirectory)
        }

        if let newIndex = flatItems.firstIndex(where: { $0.url == fileURL }) {
            selectedIndex = newIndex
        }
    }

    private func childItems(for directory: URL) -> [FileItem]? {
        childDirectoryCache[directory]
    }

    private func loadChildrenIfNeeded(for directory: URL) {
        guard childDirectoryCache[directory] == nil else { return }
        childDirectoryCache[directory] = scanDirectory(directory)
    }

    private func scanDirectory(_ url: URL) -> [FileItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let validExtensions: Set<String> = ["tex", "bib", "sty", "cls", "pdf", "png", "jpg", "jpeg", "eps", "svg", "txt", "md"]

        return contents
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDir = values?.isDirectory ?? false
                let isSymbolicLink = values?.isSymbolicLink ?? false
                if isSymbolicLink { return false }
                return isDir || validExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { a, b in
                let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if aDir != bDir { return aDir }
                return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
            }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    children: nil
                )
            }
    }
}

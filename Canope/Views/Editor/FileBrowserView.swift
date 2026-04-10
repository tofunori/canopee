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
        case "py", "r": return ""
        case "html", "htm": return ""
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
        case "py": return Color(red: 0.93, green: 0.67, blue: 0.38)
        case "r": return Color(red: 0.72, green: 0.58, blue: 0.88)
        case "html", "htm": return Color(red: 0.58, green: 0.78, blue: 0.92)
        case "md", "txt": return Color(white: 0.7) // soft gray
        case "sty", "cls": return Color(red: 0.7, green: 0.6, blue: 0.8) // muted purple
        case "log", "aux", "out": return Color(white: 0.35)
        default: return Color(white: 0.5)
        }
    }
}

struct FileBrowserView: View {
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
                            Label(AppStrings.newLatexFile, systemImage: "doc.badge.plus")
                        }

                        Button {
                            createFile(.markdown)
                        } label: {
                            Label(AppStrings.newMarkdownFile, systemImage: "text.badge.plus")
                        }

                        Button {
                            createFile(.python)
                        } label: {
                            Label(AppStrings.newPythonScript, systemImage: "play.rectangle")
                        }

                        Button {
                            createFile(.r)
                        } label: {
                            Label(AppStrings.newRScript, systemImage: "chart.line.uptrend.xyaxis")
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
                    .help(AppStrings.createEditableFile)
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
        .onChange(of: initialRootURL) {
            expandedDirs.removeAll()
            childDirectoryCache.removeAll()
            selectedIndex = 0
            currentDir = initialRootURL
        }
        .onChange(of: currentDir) {
            refresh()
            selectedIndex = 0
        }
        .alert(AppStrings.couldNotCreateFile, isPresented: Binding(
            get: { fileCreationError != nil },
            set: { if !$0 { fileCreationError = nil } }
        )) {
            Button(AppStrings.ok, role: .cancel) {}
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
        FileBrowserTreeRowView(
            item: item,
            depth: depth,
            index: index,
            selectedIndex: $selectedIndex,
            hoveredItemURL: $hoveredItemURL,
            expandedDirs: $expandedDirs,
            reduceMotion: reduceMotion,
            childItems: { childItems(for: $0) },
            flatIndex: { flatIndex(for: $0) },
            openItem: { selectedItem in
                if selectedItem.isDirectory {
                    expandedDirs.removeAll()
                    currentDir = selectedItem.url
                } else {
                    onOpenFile(selectedItem.url)
                }
            },
            loadChildrenIfNeeded: loadChildrenIfNeeded(for:)
        )
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
        guard !AppRuntime.isRunningTests else {
            items = []
            return
        }
        items = scanDirectory(currentDir)
    }

    private var creationTargetDirectory: URL {
        guard selectedIndex >= 0 && selectedIndex < flatItems.count else { return currentDir }
        let item = flatItems[selectedIndex]
        return item.isDirectory ? item.url : currentDir
    }

    private func createFile(_ kind: NewEditorFileKind) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = creationTargetDirectory
        panel.nameFieldStringValue = kind.defaultFileName
        panel.allowedContentTypes = [kind.contentType]
        panel.isExtensionHidden = false
        panel.title = kind.title
        panel.message = kind.message
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
            options: []
        ) else { return [] }

        return contents
            .filter { url in
                let name = url.lastPathComponent
                if name.hasPrefix(".") && name != ".canope" {
                    return false
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDir = values?.isDirectory ?? false
                let isSymbolicLink = values?.isSymbolicLink ?? false
                if isSymbolicLink { return false }
                return isDir || EditorFileSupport.browseableExtensions.contains(url.pathExtension.lowercased())
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

private struct FileBrowserTreeRowView: View {
    let item: FileItem
    let depth: Int
    let index: Int
    @Binding var selectedIndex: Int
    @Binding var hoveredItemURL: URL?
    @Binding var expandedDirs: Set<URL>
    let reduceMotion: Bool
    let childItems: (URL) -> [FileItem]?
    let flatIndex: (FileItem) -> Int
    let openItem: (FileItem) -> Void
    let loadChildrenIfNeeded: (URL) -> Void

    private var isExpanded: Bool { expandedDirs.contains(item.url) }
    private var isSelected: Bool { selectedIndex == index }
    private var isHovered: Bool { hoveredItemURL == item.url }
    private var indent: CGFloat { CGFloat(depth) * 14 }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: handleTap) {
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

            if item.isDirectory && isExpanded, let children = childItems(item.url) {
                ForEach(children) { child in
                    FileBrowserTreeRowView(
                        item: child,
                        depth: depth + 1,
                        index: flatIndex(child),
                        selectedIndex: $selectedIndex,
                        hoveredItemURL: $hoveredItemURL,
                        expandedDirs: $expandedDirs,
                        reduceMotion: reduceMotion,
                        childItems: childItems,
                        flatIndex: flatIndex,
                        openItem: openItem,
                        loadChildrenIfNeeded: loadChildrenIfNeeded
                    )
                }
            }
        }
    }

    private func handleTap() {
        if selectedIndex == index {
            openItem(item)
            return
        }

        selectedIndex = index
        guard item.isDirectory else { return }

        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            if isExpanded {
                expandedDirs.remove(item.url)
            } else {
                loadChildrenIfNeeded(item.url)
                expandedDirs.insert(item.url)
            }
        }
    }
}

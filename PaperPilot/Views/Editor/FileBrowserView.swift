import SwiftUI

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileItem]?

    var icon: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "tex": return "doc.text"
        case "bib": return "book.closed"
        case "sty", "cls": return "gearshape"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "eps", "svg": return "photo"
        case "log", "aux", "out": return "doc"
        default: return "doc.text"
        }
    }

    var iconColor: Color {
        if isDirectory { return .blue }
        switch url.pathExtension.lowercased() {
        case "tex": return .green
        case "bib": return .orange
        case "sty", "cls": return .purple
        case "pdf": return .red
        case "png", "jpg", "jpeg", "eps", "svg": return .pink
        default: return .secondary
        }
    }
}

struct FileBrowserView: View {
    let rootURL: URL
    let onOpenFile: (URL) -> Void
    @State private var items: [FileItem] = []
    @State private var expandedDirs: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.blue)
                Text(rootURL.lastPathComponent)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            List {
                ForEach(items) { item in
                    fileRow(item)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 150, idealWidth: 200, maxWidth: 300)
        .onAppear { refresh() }
    }

    @ViewBuilder
    private func fileRow(_ item: FileItem) -> some View {
        if item.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedDirs.contains(item.url) },
                set: { if $0 { expandedDirs.insert(item.url) } else { expandedDirs.remove(item.url) } }
            )) {
                if let children = item.children {
                    ForEach(children) { child in
                        AnyView(fileRow(child))
                    }
                }
            } label: {
                Label(item.name, systemImage: item.icon)
                    .foregroundStyle(item.iconColor)
                    .font(.caption)
            }
        } else {
            Button(action: { onOpenFile(item.url) }) {
                Label(item.name, systemImage: item.icon)
                    .foregroundStyle(item.iconColor)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private func refresh() {
        items = scanDirectory(rootURL)
    }

    private func scanDirectory(_ url: URL) -> [FileItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let validExtensions: Set<String> = ["tex", "bib", "sty", "cls", "pdf", "png", "jpg", "jpeg", "eps", "svg", "txt", "md"]

        return contents
            .filter { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
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
                    children: isDir ? scanDirectory(url) : nil
                )
            }
    }
}

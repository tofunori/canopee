import SwiftUI
import SwiftTerm
import PDFKit

// MARK: - Terminal Tab

struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String = "Terminal"
}

// MARK: - Terminal Panel with Tabs

struct TerminalPanel: View {
    let document: PDFDocument?
    let selectedText: String
    @State private var tabs: [TerminalTab] = [TerminalTab()]
    @State private var selectedTabID: UUID? = nil
    @State private var terminalViews: [UUID: LocalProcessTerminalView] = [:]

    private var currentTabID: UUID {
        selectedTabID ?? tabs.first!.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            terminalTabButton(tab)
                        }
                    }
                }

                Spacer()

                // New tab button
                Button(action: addTab) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Nouveau terminal")

                // Theme picker
                Menu {
                    ForEach(0..<Self.themes.count, id: \.self) { i in
                        Button {
                            applyTheme(i)
                        } label: {
                            HStack {
                                if i == currentTheme {
                                    Image(systemName: "checkmark")
                                }
                                Text(Self.themes[i].name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Thème du terminal")
                .padding(.trailing, 6)
            }
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Selection preview
            if !selectedText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(selectedText)
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("synced")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.05))
                Divider()
            }

            // Terminal views (ZStack to keep all alive)
            ZStack {
                ForEach(tabs) { tab in
                    TerminalViewWrapper(
                        tabID: tab.id,
                        terminalViews: $terminalViews
                    )
                    .opacity(tab.id == currentTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == currentTabID)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 600)
        .onAppear {
            selectedTabID = tabs.first?.id
        }
    }

    // MARK: - Tab Button

    @ViewBuilder
    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.green)
            Text(tab.title)
                .font(.caption2)
                .lineLimit(1)

            if tabs.count > 1 {
                Button(action: { closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tab.id == currentTabID ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if tab.id == currentTabID {
                Rectangle().fill(Color.green).frame(height: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedTabID = tab.id }
    }

    // MARK: - Themes

    private static let themes: [(name: String, bg: NSColor, fg: NSColor, cursor: NSColor)] = [
        ("Sombre", NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1), .white, .green),
        ("Dracula", NSColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1), NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1), NSColor(red: 0.94, green: 0.47, blue: 0.60, alpha: 1)),
        ("Monokai", NSColor(red: 0.15, green: 0.16, blue: 0.13, alpha: 1), NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1), NSColor(red: 0.65, green: 0.89, blue: 0.18, alpha: 1)),
        ("Solarized Dark", NSColor(red: 0.0, green: 0.17, blue: 0.21, alpha: 1), NSColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1), NSColor(red: 0.71, green: 0.54, blue: 0.0, alpha: 1)),
        ("Nord", NSColor(red: 0.18, green: 0.20, blue: 0.25, alpha: 1), NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1), NSColor(red: 0.53, green: 0.75, blue: 0.82, alpha: 1)),
        ("Clair", NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1), NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1), .blue),
        ("Gruvbox", NSColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1), NSColor(red: 0.92, green: 0.86, blue: 0.70, alpha: 1), NSColor(red: 0.98, green: 0.74, blue: 0.18, alpha: 1)),
        ("Tokyo Night", NSColor(red: 0.10, green: 0.11, blue: 0.18, alpha: 1), NSColor(red: 0.66, green: 0.70, blue: 0.84, alpha: 1), NSColor(red: 0.48, green: 0.51, blue: 0.93, alpha: 1)),
    ]

    @State private var currentTheme = 0

    // MARK: - Tab Management

    private func addTab() {
        let tab = TerminalTab()
        tabs.append(tab)
        selectedTabID = tab.id
    }

    private func applyTheme(_ index: Int) {
        currentTheme = index
        let theme = Self.themes[index]
        for (_, tv) in terminalViews {
            tv.nativeBackgroundColor = theme.bg
            tv.nativeForegroundColor = theme.fg
            tv.caretColor = theme.cursor
        }
    }

    private func closeTab(_ tab: TerminalTab) {
        guard tabs.count > 1 else { return }
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
            terminalViews.removeValue(forKey: tab.id)
            if selectedTabID == tab.id {
                selectedTabID = tabs[max(0, index - 1)].id
            }
        }
    }
}

// MARK: - SwiftTerm NSViewRepresentable

struct TerminalViewWrapper: NSViewRepresentable {
    let tabID: UUID
    @Binding var terminalViews: [UUID: LocalProcessTerminalView]

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.optionAsMetaKey = false

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("CANOPEE_SELECTION=/tmp/canopee_selection.txt")
        env.append("CANOPEE_PAPER=/tmp/canopee_paper.txt")
        tv.startProcess(executable: shell, args: ["-l"], environment: env, execName: shell)

        DispatchQueue.main.async {
            self.terminalViews[tabID] = tv
        }

        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {}
}

import SwiftUI
@preconcurrency import SwiftTerm
import PDFKit
import MetalKit

private let preferredTerminalCursorStyle: CursorStyle = .blinkBar

private func makeTerminalFont(size: CGFloat) -> NSFont {
    NSFont(name: "Menlo", size: size)
        ?? NSFont.userFixedPitchFont(ofSize: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

// MARK: - Terminal Tab

struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String = "Terminal"
}

// MARK: - Terminal Panel with Tabs (SwiftTerm + Metal GPU)

struct TerminalPanel: View {
    let document: PDFDocument?
    let isVisible: Bool
    @State private var tabs: [TerminalTab] = [TerminalTab()]
    @State private var selectedTabID: UUID? = nil
    @State private var terminalViews: [UUID: LocalProcessTerminalView] = [:]
    @State private var currentTheme = 0
    @State private var currentFontSize: CGFloat = 14
    @State private var isSplit = false
    @State private var splitTerminalViews: [UUID: LocalProcessTerminalView] = [:]
    @State private var splitTabs: [TerminalTab] = [TerminalTab()]
    @State private var focusedPane: PaneID = .top

    enum PaneID { case top, bottom }

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

                // New tab
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
                                if i == currentTheme { Image(systemName: "checkmark") }
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

                // Font size
                Menu {
                    ForEach([12, 13, 14, 15, 16, 17, 18, 20, 24], id: \.self) { size in
                        Button {
                            applyFontSize(CGFloat(size))
                        } label: {
                            HStack {
                                if Int(currentFontSize) == size { Image(systemName: "checkmark") }
                                Text("\(size) pt")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Taille de la police")
                .padding(.trailing, 6)
            }
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Terminal views with optional split
            VSplitView {
                // Top pane
                VStack(spacing: 0) {
                    if isSplit {
                        paneHeader(.top)
                    }
                    ZStack {
                        ForEach(tabs) { tab in
                            TerminalViewWrapper(
                                tabID: tab.id,
                                terminalViews: $terminalViews,
                                isActive: tab.id == currentTabID,
                                fontSize: currentFontSize,
                                theme: Self.themes[currentTheme]
                            )
                            .opacity(tab.id == currentTabID ? 1 : 0)
                            .allowsHitTesting(tab.id == currentTabID)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { focusedPane = .top }
                }

                // Bottom pane
                VStack(spacing: 0) {
                    if isSplit {
                        paneHeader(.bottom)
                    }
                    ZStack {
                        ForEach(splitTabs) { tab in
                            TerminalViewWrapper(
                                tabID: tab.id,
                                terminalViews: $splitTerminalViews,
                                isActive: isSplit,
                                fontSize: currentFontSize,
                                theme: Self.themes[currentTheme]
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { focusedPane = .bottom }
                }
                .frame(minHeight: isSplit ? 100 : 0, maxHeight: isSplit ? .infinity : 0)
                .opacity(isSplit ? 1 : 0)
            }
        }
        .frame(minWidth: 200, maxWidth: .infinity)
        .onAppear {
            selectedTabID = tabs.first?.id
            isSplit = false
        }
        .onChange(of: isVisible) {
            guard isVisible else { return }
            DispatchQueue.main.async {
                focusVisibleTerminal()
            }
        }
        .onChange(of: selectedTabID) {
            guard isVisible else { return }
            DispatchQueue.main.async {
                focusVisibleTerminal()
            }
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

    // MARK: - Themes (Kaku-inspired)

    static let themes: [(name: String, bg: NSColor, fg: NSColor, cursor: NSColor)] = [
        ("Kaku Dark", NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1), NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1), NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1)),
        ("Sombre", NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1), .white, .green),
        ("Dracula", NSColor(red: 0.16, green: 0.16, blue: 0.21, alpha: 1), NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1), NSColor(red: 0.94, green: 0.47, blue: 0.60, alpha: 1)),
        ("Monokai", NSColor(red: 0.15, green: 0.16, blue: 0.13, alpha: 1), NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1), NSColor(red: 0.65, green: 0.89, blue: 0.18, alpha: 1)),
        ("Nord", NSColor(red: 0.18, green: 0.20, blue: 0.25, alpha: 1), NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1), NSColor(red: 0.53, green: 0.75, blue: 0.82, alpha: 1)),
        ("Tokyo Night", NSColor(red: 0.10, green: 0.11, blue: 0.18, alpha: 1), NSColor(red: 0.66, green: 0.70, blue: 0.84, alpha: 1), NSColor(red: 0.48, green: 0.51, blue: 0.93, alpha: 1)),
        ("Gruvbox", NSColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1), NSColor(red: 0.92, green: 0.86, blue: 0.70, alpha: 1), NSColor(red: 0.98, green: 0.74, blue: 0.18, alpha: 1)),
        ("Clair", NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1), NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1), .blue),
    ]

    // MARK: - Actions

    private func applyTheme(_ index: Int) {
        currentTheme = index
        let theme = Self.themes[index]
        for (_, tv) in terminalViews {
            tv.nativeBackgroundColor = theme.bg
            tv.nativeForegroundColor = theme.fg
            tv.caretColor = theme.cursor
        }
    }

    private func applyFontSize(_ size: CGFloat) {
        currentFontSize = size
        for (_, tv) in terminalViews {
            tv.font = makeTerminalFont(size: size)
        }
    }

    @ViewBuilder
    private func paneHeader(_ pane: PaneID) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(focusedPane == pane ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(pane == .top ? "Haut" : "Bas")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { closePane(pane) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Fermer ce split")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(focusedPane == pane ? Color.accentColor.opacity(0.08) : Color.clear)
        .onTapGesture { focusedPane = pane }
    }

    private func closePane(_ pane: PaneID) {
        if pane == .bottom {
            isSplit = false
        } else if pane == .top && isSplit {
            // Close top: move bottom to top
            tabs = splitTabs
            terminalViews = splitTerminalViews
            splitTabs = [TerminalTab()]
            splitTerminalViews = [:]
            selectedTabID = tabs.first?.id
            isSplit = false
        }
        focusedPane = .top
    }

    private func addTab() {
        let tab = TerminalTab()
        tabs.append(tab)
        selectedTabID = tab.id
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

    private func focusVisibleTerminal() {
        if focusedPane == .bottom,
           isSplit,
           let bottomTabID = splitTabs.first?.id,
           let bottomTerminal = splitTerminalViews[bottomTabID] as? FocusAwareLocalProcessTerminalView {
            bottomTerminal.activateInputFocus()
            return
        }

        if let topTerminal = terminalViews[currentTabID] as? FocusAwareLocalProcessTerminalView {
            topTerminal.activateInputFocus()
        }
    }
}

// MARK: - SwiftTerm + Metal NSViewRepresentable

struct TerminalViewWrapper: NSViewRepresentable {
    let tabID: UUID
    @Binding var terminalViews: [UUID: LocalProcessTerminalView]
    let isActive: Bool
    let fontSize: CGFloat
    let theme: (name: String, bg: NSColor, fg: NSColor, cursor: NSColor)

    func makeNSView(context: Context) -> FocusAwareLocalProcessTerminalView {
        let tv = FocusAwareLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.font = makeTerminalFont(size: fontSize)
        tv.getTerminal().setCursorStyle(preferredTerminalCursorStyle)
        tv.optionAsMetaKey = false
        tv.nativeBackgroundColor = theme.bg
        tv.nativeForegroundColor = theme.fg
        tv.caretColor = theme.cursor
        tv.shouldCaptureFocusFromClicks = isActive

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("CANOPE_SELECTION=/tmp/canope_selection.txt")
        env.append("CANOPE_PAPER=/tmp/canope_paper.txt")
        tv.startProcess(executable: shell, args: ["-l"], environment: env, execName: shell)
        tv.schedulePreferredCursorWarmup()
        ChildProcessRegistry.shared.track(terminalView: tv)

        enableMetalWhenReady(for: tv)

        DispatchQueue.main.async {
            self.terminalViews[tabID] = tv
        }

        return tv
    }

    func updateNSView(_ nsView: FocusAwareLocalProcessTerminalView, context: Context) {
        nsView.shouldCaptureFocusFromClicks = isActive
    }

    static func dismantleNSView(_ nsView: FocusAwareLocalProcessTerminalView, coordinator: ()) {
        nsView.prepareForRemoval()
        ChildProcessRegistry.shared.untrack(terminalView: nsView)
    }

    private func enableMetalWhenReady(for tv: FocusAwareLocalProcessTerminalView, remainingAttempts: Int = 40) {
        guard remainingAttempts > 0 else { return }
        guard tv.window != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                enableMetalWhenReady(for: tv, remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        do {
            try tv.setUseMetal(true)
            if tv.isUsingMetalRenderer {
                tv.metalBufferingMode = .perRowPersistent
                tv.getTerminal().setCursorStyle(preferredTerminalCursorStyle)
                tv.schedulePreferredCursorWarmup()
                // Ensure MTKView forwards events to terminal
                for subview in tv.subviews {
                    if let mtkView = subview as? MTKView {
                        mtkView.nextResponder = tv
                    }
                }
                tv.activateInputFocus()
                print("[Canope] Metal GPU rendering active ✓")
            }
        } catch {
            print("[Canope] Metal not available, using CoreGraphics: \(error)")
        }
    }
}

/// Transparent view that forwards all mouse/scroll events to a target view
final class EventForwardingView: NSView {
    weak var target: NSView?

    init(frame: NSRect, target: NSView) {
        self.target = target
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        target?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        target?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        target?.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        target?.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        target?.rightMouseDown(with: event)
    }
}

@MainActor
final class FocusAwareLocalProcessTerminalView: LocalProcessTerminalView, ChildProcessTerminable {
    var shouldCaptureFocusFromClicks = true
    private var clickMonitor: Any?
    private var scrollMonitor: Any?

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        source.options.cursorStyle = preferredTerminalCursorStyle
        super.cursorStyleChanged(source: source, newStyle: preferredTerminalCursorStyle)
    }

    func terminateTrackedProcess() {
        terminate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitors()
        } else {
            installClickMonitorIfNeeded()
            installScrollMonitor()
            DispatchQueue.main.async { [weak self] in
                self?.activateInputFocus()
                self?.applyPreferredCursorAppearance()
                self?.schedulePreferredCursorWarmup()
            }
        }
    }

    func activateInputFocus() {
        guard let window else { return }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        applyPreferredCursorAppearance()
    }

    private func applyPreferredCursorAppearance() {
        let terminal = getTerminal()
        terminal.setCursorStyle(preferredTerminalCursorStyle)
        terminal.showCursor()
        needsDisplay = true
    }

    func schedulePreferredCursorWarmup() {
        let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.7]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyPreferredCursorAppearance()
            }
        }
    }

    func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point), event.deltaY != 0 else { return event }

            let terminal = self.getTerminal()
            // If app has enabled mouse reporting, send scroll as button events
            if terminal.mouseMode != .off {
                let cols = terminal.cols
                let rows = terminal.rows
                let cellW = self.bounds.width / CGFloat(max(1, cols))
                let cellH = self.bounds.height / CGFloat(max(1, rows))
                let col = max(0, Int(point.x / cellW))
                let row = max(0, Int((self.frame.height - point.y) / cellH))

                // SGR: button 64 = scroll up, 65 = scroll down
                let button = event.deltaY > 0 ? 64 : 65
                let seq = "\u{1b}[<\(button);\(col + 1);\(row + 1)M"
                self.send(txt: seq)
                return nil // consume the event
            }

            return event // let SwiftTerm handle buffer scroll
        }
    }

    func prepareForRemoval() {
        removeEventMonitors()
        terminate()
    }

    private func installClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard shouldCaptureFocusFromClicks, let window = self.window else { return event }
            guard event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
            return event
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private func removeScrollMonitor() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    private func removeEventMonitors() {
        removeClickMonitor()
        removeScrollMonitor()
    }
}

import SwiftUI
@preconcurrency import SwiftTerm
import PDFKit
import MetalKit

extension Notification.Name {
    static let canopeSendPromptToTerminal = Notification.Name("canopeSendPromptToTerminal")
    static let canopeTerminalAddTab = Notification.Name("canopeTerminalAddTab")
    static let canopeTerminalApplyTheme = Notification.Name("canopeTerminalApplyTheme")
    static let canopeTerminalApplyFontSize = Notification.Name("canopeTerminalApplyFontSize")
}

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
    var optionAsMetaKey: Bool = false
}

@MainActor
final class TerminalWorkspaceState: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selectedTabID: UUID?
    @Published var terminalViews: [UUID: LocalProcessTerminalView]
    @Published var currentTheme: Int
    @Published var currentFontSize: CGFloat
    @Published var isSplit: Bool
    @Published var splitTerminalViews: [UUID: LocalProcessTerminalView]
    @Published var splitTabs: [TerminalTab]
    @Published var focusedPane: TerminalPanel.PaneID

    init() {
        let initialTab = TerminalTab()
        self.tabs = [initialTab]
        self.selectedTabID = initialTab.id
        self.terminalViews = [:]
        self.currentTheme = 0
        self.currentFontSize = 14
        self.isSplit = false
        self.splitTerminalViews = [:]
        self.splitTabs = [TerminalTab()]
        self.focusedPane = .top
    }
}

// MARK: - Terminal Panel with Tabs (SwiftTerm + Metal GPU)

struct TerminalPanel: View {
    @ObservedObject var workspaceState: TerminalWorkspaceState
    let document: PDFDocument?
    let isVisible: Bool
    let topInset: CGFloat
    let showsInlineControls: Bool
    let startupWorkingDirectory: URL?

    enum PaneID { case top, bottom }

    init(
        workspaceState: TerminalWorkspaceState,
        document: PDFDocument?,
        isVisible: Bool,
        topInset: CGFloat,
        showsInlineControls: Bool,
        startupWorkingDirectory: URL? = nil
    ) {
        self.workspaceState = workspaceState
        self.document = document
        self.isVisible = isVisible
        self.topInset = topInset
        self.showsInlineControls = showsInlineControls
        self.startupWorkingDirectory = startupWorkingDirectory
    }

    private var currentTabID: UUID {
        workspaceState.selectedTabID ?? workspaceState.tabs.first!.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if topInset > 0 {
                Color.clear
                    .frame(height: topInset)
                    .background(.bar)
                Divider()
            }

            // Tab bar
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspaceState.tabs) { tab in
                            terminalTabButton(tab)
                        }
                    }
                }

                if showsInlineControls {
                    Spacer()

                    Button(action: toggleOptionAsMetaForFocusedPane) {
                        Text("⌥")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(focusedPaneUsesOptionAsMeta ? .blue : .secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(focusedPaneUsesOptionAsMeta ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Utiliser Option comme Meta pour cet onglet de terminal")

                    Button(action: addTab) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Nouveau terminal")

                    Menu {
                        ForEach(0..<Self.themes.count, id: \.self) { i in
                            Button {
                                applyTheme(i)
                            } label: {
                                HStack {
                                    if i == workspaceState.currentTheme { Image(systemName: "checkmark") }
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

                    Menu {
                        ForEach(Self.fontSizes, id: \.self) { size in
                            Button {
                                applyFontSize(CGFloat(size))
                            } label: {
                                HStack {
                                    if Int(workspaceState.currentFontSize) == size { Image(systemName: "checkmark") }
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
            }
            .frame(height: EditorChromeMetrics.tabBarHeight)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Terminal views with optional split
            VSplitView {
                // Top pane
                VStack(spacing: 0) {
                    if workspaceState.isSplit {
                        paneHeader(.top)
                    }
                    ZStack {
                        ForEach(workspaceState.tabs) { tab in
                            TerminalViewWrapper(
                                tabID: tab.id,
                                terminalViews: $workspaceState.terminalViews,
                                isActive: tab.id == currentTabID,
                                optionAsMetaKey: tab.optionAsMetaKey,
                                fontSize: workspaceState.currentFontSize,
                                theme: Self.themes[workspaceState.currentTheme],
                                startupWorkingDirectory: startupWorkingDirectory
                            )
                            .opacity(tab.id == currentTabID ? 1 : 0)
                            .allowsHitTesting(tab.id == currentTabID)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { workspaceState.focusedPane = .top }
                }

                // Bottom pane
                VStack(spacing: 0) {
                    if workspaceState.isSplit {
                        paneHeader(.bottom)
                    }
                    ZStack {
                        ForEach(workspaceState.splitTabs) { tab in
                            TerminalViewWrapper(
                                tabID: tab.id,
                                terminalViews: $workspaceState.splitTerminalViews,
                                isActive: workspaceState.isSplit,
                                optionAsMetaKey: tab.optionAsMetaKey,
                                fontSize: workspaceState.currentFontSize,
                                theme: Self.themes[workspaceState.currentTheme],
                                startupWorkingDirectory: startupWorkingDirectory
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { workspaceState.focusedPane = .bottom }
                }
                .frame(minHeight: workspaceState.isSplit ? 100 : 0, maxHeight: workspaceState.isSplit ? .infinity : 0)
                .opacity(workspaceState.isSplit ? 1 : 0)
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity)
        .onAppear {
            if workspaceState.tabs.isEmpty {
                let tab = TerminalTab()
                workspaceState.tabs = [tab]
                workspaceState.selectedTabID = tab.id
            } else if workspaceState.selectedTabID == nil {
                workspaceState.selectedTabID = workspaceState.tabs.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .canopeSendPromptToTerminal)) { notification in
            guard isVisible else { return }
            guard let prompt = notification.userInfo?["prompt"] as? String else { return }
            sendPromptToFocusedTerminal(prompt)
        }
        .onReceive(NotificationCenter.default.publisher(for: .canopeTerminalAddTab)) { _ in
            guard isVisible else { return }
            addTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .canopeTerminalApplyTheme)) { notification in
            guard isVisible else { return }
            guard let index = notification.userInfo?["themeIndex"] as? Int,
                  Self.themes.indices.contains(index) else { return }
            applyTheme(index)
        }
        .onReceive(NotificationCenter.default.publisher(for: .canopeTerminalApplyFontSize)) { notification in
            guard isVisible else { return }
            guard let size = notification.userInfo?["fontSize"] as? CGFloat else { return }
            applyFontSize(size)
        }
        .onChange(of: isVisible) {
            guard isVisible else { return }
            DispatchQueue.main.async {
                focusVisibleTerminal()
            }
        }
        .onChange(of: workspaceState.selectedTabID) {
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
            if workspaceState.tabs.count > 1 {
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
        .onTapGesture { workspaceState.selectedTabID = tab.id }
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
    static let fontSizes = [12, 13, 14, 15, 16, 17, 18, 20, 24]

    private var focusedPaneUsesOptionAsMeta: Bool {
        switch workspaceState.focusedPane {
        case .top:
            guard let selectedID = workspaceState.selectedTabID,
                  let tab = workspaceState.tabs.first(where: { $0.id == selectedID }) else {
                return false
            }
            return tab.optionAsMetaKey
        case .bottom:
            return workspaceState.splitTabs.first?.optionAsMetaKey ?? false
        }
    }

    // MARK: - Actions

    private func applyTheme(_ index: Int) {
        workspaceState.currentTheme = index
        let theme = Self.themes[index]
        for (_, tv) in workspaceState.terminalViews {
            tv.nativeBackgroundColor = theme.bg
            tv.nativeForegroundColor = theme.fg
            tv.caretColor = theme.cursor
        }
        for (_, tv) in workspaceState.splitTerminalViews {
            tv.nativeBackgroundColor = theme.bg
            tv.nativeForegroundColor = theme.fg
            tv.caretColor = theme.cursor
        }
    }

    private func applyFontSize(_ size: CGFloat) {
        workspaceState.currentFontSize = size
        for (_, tv) in workspaceState.terminalViews {
            tv.font = makeTerminalFont(size: size)
        }
        for (_, tv) in workspaceState.splitTerminalViews {
            tv.font = makeTerminalFont(size: size)
        }
    }

    @ViewBuilder
    private func paneHeader(_ pane: PaneID) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(workspaceState.focusedPane == pane ? Color.green : Color.gray.opacity(0.3))
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
        .background(workspaceState.focusedPane == pane ? Color.accentColor.opacity(0.08) : Color.clear)
        .onTapGesture { workspaceState.focusedPane = pane }
    }

    private func closePane(_ pane: PaneID) {
        if pane == .bottom {
            for terminal in workspaceState.splitTerminalViews.values {
                if let terminal = terminal as? FocusAwareLocalProcessTerminalView {
                    ChildProcessRegistry.shared.untrack(terminalView: terminal)
                    terminal.prepareForRemoval()
                }
            }
            workspaceState.splitTerminalViews = [:]
            workspaceState.splitTabs = [TerminalTab()]
            workspaceState.isSplit = false
        } else if pane == .top && workspaceState.isSplit {
            // Close top: move bottom to top
            for terminal in workspaceState.terminalViews.values {
                if let terminal = terminal as? FocusAwareLocalProcessTerminalView {
                    ChildProcessRegistry.shared.untrack(terminalView: terminal)
                    terminal.prepareForRemoval()
                }
            }
            workspaceState.tabs = workspaceState.splitTabs
            workspaceState.terminalViews = workspaceState.splitTerminalViews
            workspaceState.splitTabs = [TerminalTab()]
            workspaceState.splitTerminalViews = [:]
            workspaceState.selectedTabID = workspaceState.tabs.first?.id
            workspaceState.isSplit = false
        }
        workspaceState.focusedPane = .top
    }

    private func addTab() {
        let tab = TerminalTab()
        workspaceState.tabs.append(tab)
        workspaceState.selectedTabID = tab.id
    }

    private func toggleOptionAsMetaForFocusedPane() {
        switch workspaceState.focusedPane {
        case .top:
            guard let selectedID = workspaceState.selectedTabID,
                  let index = workspaceState.tabs.firstIndex(where: { $0.id == selectedID }) else {
                return
            }
            var tabs = workspaceState.tabs
            tabs[index].optionAsMetaKey.toggle()
            workspaceState.tabs = tabs
        case .bottom:
            guard let index = workspaceState.splitTabs.indices.first else { return }
            var tabs = workspaceState.splitTabs
            tabs[index].optionAsMetaKey.toggle()
            workspaceState.splitTabs = tabs
        }
    }

    private func closeTab(_ tab: TerminalTab) {
        guard workspaceState.tabs.count > 1 else { return }
        if let index = workspaceState.tabs.firstIndex(where: { $0.id == tab.id }) {
            workspaceState.tabs.remove(at: index)
            if let terminal = workspaceState.terminalViews.removeValue(forKey: tab.id) {
                if let terminal = terminal as? FocusAwareLocalProcessTerminalView {
                    ChildProcessRegistry.shared.untrack(terminalView: terminal)
                    terminal.prepareForRemoval()
                }
            }
            if workspaceState.selectedTabID == tab.id {
                workspaceState.selectedTabID = workspaceState.tabs[max(0, index - 1)].id
            }
        }
    }

    private func focusVisibleTerminal() {
        if workspaceState.focusedPane == .bottom,
           workspaceState.isSplit,
           let bottomTabID = workspaceState.splitTabs.first?.id,
           let bottomTerminal = workspaceState.splitTerminalViews[bottomTabID] as? FocusAwareLocalProcessTerminalView {
            bottomTerminal.activateInputFocus()
            return
        }

        if let topTerminal = workspaceState.terminalViews[currentTabID] as? FocusAwareLocalProcessTerminalView {
            topTerminal.activateInputFocus()
        }
    }

    private func sendPromptToFocusedTerminal(_ prompt: String) {
        let payload = prompt.hasSuffix("\n") ? prompt : prompt + "\n"

        if workspaceState.focusedPane == .bottom,
           workspaceState.isSplit,
           let bottomTabID = workspaceState.splitTabs.first?.id,
           let bottomTerminal = workspaceState.splitTerminalViews[bottomTabID] as? FocusAwareLocalProcessTerminalView {
            bottomTerminal.activateInputFocus()
            bottomTerminal.send(txt: payload)
            return
        }

        if let topTerminal = workspaceState.terminalViews[currentTabID] as? FocusAwareLocalProcessTerminalView {
            topTerminal.activateInputFocus()
            topTerminal.send(txt: payload)
        }
    }
}

// MARK: - SwiftTerm + Metal NSViewRepresentable

struct TerminalViewWrapper: NSViewRepresentable {
    let tabID: UUID
    @Binding var terminalViews: [UUID: LocalProcessTerminalView]
    let isActive: Bool
    let optionAsMetaKey: Bool
    let fontSize: CGFloat
    let theme: (name: String, bg: NSColor, fg: NSColor, cursor: NSColor)
    let startupWorkingDirectory: URL?

    func makeNSView(context: Context) -> FocusAwareLocalProcessTerminalView {
        if let existing = terminalViews[tabID] as? FocusAwareLocalProcessTerminalView {
            existing.font = makeTerminalFont(size: fontSize)
            existing.nativeBackgroundColor = theme.bg
            existing.nativeForegroundColor = theme.fg
            existing.caretColor = theme.cursor
            existing.shouldCaptureFocusFromClicks = isActive
            existing.optionAsMetaKey = optionAsMetaKey
            existing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            existing.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return existing
        }

        let tv = FocusAwareLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.font = makeTerminalFont(size: fontSize)
        tv.getTerminal().setCursorStyle(preferredTerminalCursorStyle)
        tv.optionAsMetaKey = optionAsMetaKey
        tv.nativeBackgroundColor = theme.bg
        tv.nativeForegroundColor = theme.fg
        tv.caretColor = theme.cursor
        tv.shouldCaptureFocusFromClicks = isActive

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        ClaudeIDEBridgeService.shared.startIfNeeded()
        env = ClaudeCLIWrapperService.shared.apply(to: env, shellPath: shell)
        env.append(contentsOf: CanopeContextFiles.terminalEnvironment)
        tv.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: shell,
            currentDirectory: startupWorkingDirectory?.path
        )
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
        nsView.font = makeTerminalFont(size: fontSize)
        nsView.nativeBackgroundColor = theme.bg
        nsView.nativeForegroundColor = theme.fg
        nsView.caretColor = theme.cursor
        nsView.optionAsMetaKey = optionAsMetaKey
    }

    static func dismantleNSView(_ nsView: FocusAwareLocalProcessTerminalView, coordinator: ()) {
        nsView.detachFromSwiftUIHierarchy()
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
    private var keyMonitor: Any?

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
            installKeyMonitorIfNeeded()
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

    func detachFromSwiftUIHierarchy() {
        removeEventMonitors()
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

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard event.window === window, window.firstResponder === self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.option),
                  !flags.contains(.command),
                  !flags.contains(.control) else {
                return event
            }

            if self.optionAsMetaKey,
               let rawCharacter = event.charactersIgnoringModifiers,
               !rawCharacter.isEmpty {
                self.send(txt: "\u{1b}\(rawCharacter)")
                return nil
            }

            let terminal = self.getTerminal()
            if !self.optionAsMetaKey,
               !terminal.keyboardEnhancementFlags.isEmpty,
               let composedCharacter = event.characters,
               let rawCharacter = event.charactersIgnoringModifiers,
               !composedCharacter.isEmpty,
               composedCharacter != rawCharacter {
                self.send(txt: composedCharacter)
                return nil
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

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func removeEventMonitors() {
        removeClickMonitor()
        removeScrollMonitor()
        removeKeyMonitor()
    }
}

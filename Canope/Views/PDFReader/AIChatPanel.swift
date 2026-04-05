import SwiftUI
@preconcurrency import SwiftTerm
import PDFKit
import MetalKit

extension Notification.Name {
    static let canopeSendPromptToTerminal = Notification.Name("canopeSendPromptToTerminal")
    static let canopeTerminalAddTab = Notification.Name("canopeTerminalAddTab")
}

private let defaultTerminalCursorStyle: CursorStyle = .blinkBar

private func makeTerminalFont(familyName: String, size: CGFloat) -> NSFont {
    let candidates: [String]
    switch familyName.lowercased() {
    case "sf mono", "sfmono", "sf mono regular":
        candidates = ["SF Mono", "SFMono-Regular", "SF Mono Regular", "Menlo"]
    case "menlo":
        candidates = ["Menlo"]
    case "monaco":
        candidates = ["Monaco", "Menlo"]
    default:
        candidates = [familyName, "SF Mono", "SFMono-Regular", "Menlo"]
    }

    for name in candidates {
        if let font = NSFont(name: name, size: size) {
            return font
        }
    }

    return NSFont.userFixedPitchFont(ofSize: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

private enum TerminalAppearanceCoding {
    static let defaultsKey = "canope.terminalAppearance.v1"
}

enum TerminalCursorShape: String, Codable, CaseIterable, Equatable, Identifiable {
    case bar
    case block
    case underline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bar:
            return "Barre"
        case .block:
            return "Bloc"
        case .underline:
            return "Souligné"
        }
    }
}

enum TerminalCursorStyleOption: String, Codable, CaseIterable, Equatable, Identifiable {
    case blinkBar
    case steadyBar
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline

    var id: String { rawValue }

    var title: String {
        switch self.shape {
        case .bar:
            return isBlinking ? "Barre clignotante" : "Barre fixe"
        case .block:
            return isBlinking ? "Bloc clignotant" : "Bloc fixe"
        case .underline:
            return isBlinking ? "Souligné clignotant" : "Souligné fixe"
        }
    }

    var shape: TerminalCursorShape {
        switch self {
        case .blinkBar, .steadyBar:
            return .bar
        case .blinkBlock, .steadyBlock:
            return .block
        case .blinkUnderline, .steadyUnderline:
            return .underline
        }
    }

    var isBlinking: Bool {
        switch self {
        case .blinkBar, .blinkBlock, .blinkUnderline:
            return true
        case .steadyBar, .steadyBlock, .steadyUnderline:
            return false
        }
    }

    func withShape(_ shape: TerminalCursorShape) -> TerminalCursorStyleOption {
        switch (shape, isBlinking) {
        case (.bar, true):
            return .blinkBar
        case (.bar, false):
            return .steadyBar
        case (.block, true):
            return .blinkBlock
        case (.block, false):
            return .steadyBlock
        case (.underline, true):
            return .blinkUnderline
        case (.underline, false):
            return .steadyUnderline
        }
    }

    func withBlinking(_ blinking: Bool) -> TerminalCursorStyleOption {
        switch (shape, blinking) {
        case (.bar, true):
            return .blinkBar
        case (.bar, false):
            return .steadyBar
        case (.block, true):
            return .blinkBlock
        case (.block, false):
            return .steadyBlock
        case (.underline, true):
            return .blinkUnderline
        case (.underline, false):
            return .steadyUnderline
        }
    }

    var swiftTermValue: CursorStyle {
        CursorStyle.from(string: rawValue) ?? defaultTerminalCursorStyle
    }
}

struct TerminalThemePreset: Identifiable, Equatable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let cursorText: NSColor
    let selectionBackground: NSColor
    let ansiColors: [NSColor]

    static let ghosttyDefaultDark = TerminalThemePreset(
        id: "ghostty-default-dark",
        name: "Ghostty Default Dark",
        background: NSColor(hex: "#282c34", fallback: NSColor(calibratedWhite: 0.16, alpha: 1)),
        foreground: NSColor(hex: "#ffffff", fallback: .white),
        cursor: NSColor(hex: "#ffffff", fallback: .white),
        cursorText: NSColor(hex: "#282c34", fallback: NSColor(calibratedWhite: 0.16, alpha: 1)),
        selectionBackground: NSColor(hex: "#3e4451", fallback: NSColor(calibratedWhite: 0.28, alpha: 1)),
        ansiColors: [
            "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
            "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            "#666666", "#d54e53", "#b9ca4a", "#e7c547",
            "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"
        ].map { NSColor(hex: $0, fallback: .white) }
    )

    static let builtinTangoLight = TerminalThemePreset(
        id: "builtin-tango-light",
        name: "Builtin Tango Light",
        background: NSColor(hex: "#ffffff", fallback: .white),
        foreground: NSColor(hex: "#2e3434", fallback: NSColor(calibratedWhite: 0.18, alpha: 1)),
        cursor: NSColor(hex: "#2e3434", fallback: NSColor(calibratedWhite: 0.18, alpha: 1)),
        cursorText: NSColor(hex: "#ffffff", fallback: .white),
        selectionBackground: NSColor(hex: "#accef7", fallback: NSColor.systemBlue.withAlphaComponent(0.25)),
        ansiColors: [
            "#2e3436", "#cc0000", "#4e9a06", "#c4a000",
            "#3465a4", "#75507b", "#06989a", "#d3d7cf",
            "#555753", "#ef2929", "#8ae234", "#fce94f",
            "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"
        ].map { NSColor(hex: $0, fallback: .black) }
    )

    static let canopeClassic = TerminalThemePreset(
        id: "canope-classic",
        name: "Canope Classic",
        background: NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1),
        foreground: NSColor(red: 0.929, green: 0.925, blue: 0.933, alpha: 1),
        cursor: NSColor(red: 0.635, green: 0.467, blue: 1.0, alpha: 1),
        cursorText: NSColor(red: 0.082, green: 0.078, blue: 0.106, alpha: 1),
        selectionBackground: NSColor(red: 0.184, green: 0.176, blue: 0.235, alpha: 1),
        ansiColors: [
            "#16131b", "#df6b79", "#8ed48b", "#f0d48a",
            "#82b1ff", "#c792ea", "#80cbc4", "#eceff4",
            "#4c566a", "#ff7a90", "#9ce59e", "#ffe39a",
            "#97c3ff", "#d6a4ff", "#9be0db", "#ffffff"
        ].map { NSColor(hex: $0, fallback: .white) }
    )

    static let all: [TerminalThemePreset] = [
        .ghosttyDefaultDark,
        .builtinTangoLight,
        .canopeClassic
    ]

    static func preset(id: String) -> TerminalThemePreset {
        all.first(where: { $0.id == id }) ?? .ghosttyDefaultDark
    }
}

struct TerminalAppearanceState: Codable, Equatable {
    var fontFamily: String = "SF Mono"
    var fontSize: Double = 14
    var cursorStyle: TerminalCursorStyleOption = .blinkBar
    var useBrightColors: Bool = true
    var darkThemePresetID: String = TerminalThemePreset.ghosttyDefaultDark.id
    var lightThemePresetID: String = TerminalThemePreset.builtinTangoLight.id
    var useSeparateLightTheme: Bool = false
    var dividerColorDark: String = "#3f3f46"
    var dividerColorLight: String = "#d4d4d8"
    var inactivePaneOpacity: Double = 0.8
    var activePaneOpacity: Double = 1.0
    var dividerThickness: Double = 3
    var terminalPadding: Double = 4
    var scrollbackLines: Int = 10_000

    func resolvedThemePreset(for colorScheme: ColorScheme) -> TerminalThemePreset {
        if colorScheme == .light && useSeparateLightTheme {
            return .preset(id: lightThemePresetID)
        }
        return .preset(id: darkThemePresetID)
    }

    func resolvedThemePresetID(for colorScheme: ColorScheme) -> String {
        resolvedThemePreset(for: colorScheme).id
    }

    func resolvedDividerColor(for colorScheme: ColorScheme) -> NSColor {
        let hex = colorScheme == .light && useSeparateLightTheme ? dividerColorLight : dividerColorDark
        let fallback = colorScheme == .light ? NSColor(calibratedWhite: 0.84, alpha: 1) : NSColor(calibratedWhite: 0.25, alpha: 1)
        return NSColor(hex: hex, fallback: fallback)
    }
}

@MainActor
final class TerminalAppearanceStore: ObservableObject {
    static let shared = TerminalAppearanceStore()

    @Published var appearance: TerminalAppearanceState {
        didSet {
            persist()
        }
    }

    @Published var isPresentingSettings = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: TerminalAppearanceCoding.defaultsKey),
           let decoded = try? JSONDecoder().decode(TerminalAppearanceState.self, from: data) {
            appearance = decoded
        } else {
            appearance = TerminalAppearanceState()
        }
    }

    func presentSettings() {
        isPresentingSettings = true
    }

    func binding<Value>(for keyPath: WritableKeyPath<TerminalAppearanceState, Value>) -> Binding<Value> {
        Binding(
            get: { self.appearance[keyPath: keyPath] },
            set: { newValue in
                var updated = self.appearance
                updated[keyPath: keyPath] = newValue
                self.appearance = updated
            }
        )
    }

    private let defaults: UserDefaults

    private func persist() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: TerminalAppearanceCoding.defaultsKey)
    }
}

@MainActor
protocol TerminalAppearanceApplying: AnyObject {
    var font: NSFont { get set }
    var nativeBackgroundColor: NSColor { get set }
    var nativeForegroundColor: NSColor { get set }
    var selectedTextBackgroundColor: NSColor { get set }
    var caretColor: NSColor { get set }
    var caretTextColor: NSColor? { get set }
    var useBrightColors: Bool { get set }

    func installColors(_ colors: [SwiftTerm.Color])
    func setAnsi256PaletteStrategy(_ strategy: Ansi256PaletteStrategy)
    func setTerminalBaseColors(background: SwiftTerm.Color, foreground: SwiftTerm.Color)
    func setScrollbackLines(_ lines: Int?)
    func applyCursorStyle(_ style: CursorStyle)
    func schedulePreferredCursorWarmup()
}

enum TerminalAppearanceApplicator {
    @MainActor
    static func apply(
        appearance: TerminalAppearanceState,
        colorScheme: ColorScheme,
        to target: TerminalAppearanceApplying
    ) {
        let theme = appearance.resolvedThemePreset(for: colorScheme)
        let font = makeTerminalFont(familyName: appearance.fontFamily, size: CGFloat(appearance.fontSize))
        let terminalBackground = theme.background.swiftTermColor
        let terminalForeground = theme.foreground.swiftTermColor

        target.font = font
        target.nativeBackgroundColor = theme.background
        target.nativeForegroundColor = theme.foreground
        target.selectedTextBackgroundColor = theme.selectionBackground
        target.caretColor = theme.cursor
        target.caretTextColor = theme.cursorText
        target.useBrightColors = appearance.useBrightColors
        target.setAnsi256PaletteStrategy(.base16Lab)
        target.setTerminalBaseColors(background: terminalBackground, foreground: terminalForeground)
        target.installColors(theme.ansiColors.map(\.swiftTermColor))
        target.setScrollbackLines(appearance.scrollbackLines)
        target.applyCursorStyle(appearance.cursorStyle.swiftTermValue)
        target.schedulePreferredCursorWarmup()
    }
}

extension NSColor {
    convenience init(hex: String, fallback: NSColor) {
        let normalized = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard normalized.count == 6,
              let value = Int(normalized, radix: 16) else {
            let base = fallback.usingColorSpace(.deviceRGB) ?? fallback
            self.init(
                srgbRed: base.redComponent,
                green: base.greenComponent,
                blue: base.blueComponent,
                alpha: base.alphaComponent
            )
            return
        }

        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.deviceRGB) ?? self
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    var swiftTermColor: SwiftTerm.Color {
        let color = usingColorSpace(.deviceRGB) ?? self
        return SwiftTerm.Color(
            red: UInt16(round(color.redComponent * 65535)),
            green: UInt16(round(color.greenComponent * 65535)),
            blue: UInt16(round(color.blueComponent * 65535))
        )
    }
}

// MARK: - Terminal Tab

enum TerminalTabKind: Equatable {
    case terminal
    case claudeChat
}

struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String = "Terminal"
    var optionAsMetaKey: Bool = false
    var kind: TerminalTabKind = .terminal
}

@MainActor
final class TerminalWorkspaceState: ObservableObject {
    @Published var tabs: [TerminalTab]
    @Published var selectedTabID: UUID?
    @Published var terminalViews: [UUID: LocalProcessTerminalView]
    @Published var isSplit: Bool
    @Published var splitTerminalViews: [UUID: LocalProcessTerminalView]
    @Published var splitTabs: [TerminalTab]
    @Published var focusedPane: TerminalPanel.PaneID
    @Published var splitFraction: CGFloat
    @Published var chatProviders: [UUID: ClaudeHeadlessProvider] = [:]

    init() {
        let initialTab = TerminalTab()
        self.tabs = [initialTab]
        self.selectedTabID = initialTab.id
        self.terminalViews = [:]
        self.isSplit = false
        self.splitTerminalViews = [:]
        self.splitTabs = [TerminalTab()]
        self.focusedPane = .top
        self.splitFraction = 0.5
    }

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func chatProvider(for tabID: UUID, workingDirectory: URL?) -> ClaudeHeadlessProvider {
        if let existing = chatProviders[tabID] { return existing }
        let provider = ClaudeHeadlessProvider(workingDirectory: workingDirectory)
        chatProviders[tabID] = provider
        return provider
    }

    func removeTab(id: UUID) {
        chatProviders[id]?.stop()
        chatProviders.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }
        if selectedTabID == id {
            selectedTabID = tabs.last?.id
        }
    }
}

// MARK: - Terminal Panel with Tabs (SwiftTerm + Metal GPU)

struct TerminalPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appearanceStore = TerminalAppearanceStore.shared
    @ObservedObject var workspaceState: TerminalWorkspaceState
    let document: PDFDocument?
    let isVisible: Bool
    let topInset: CGFloat
    let showsInlineControls: Bool
    let startupWorkingDirectory: URL?
    @State private var splitDragStartFraction: CGFloat?

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

    private var appearance: TerminalAppearanceState {
        appearanceStore.appearance
    }

    private var resolvedTheme: TerminalThemePreset {
        appearance.resolvedThemePreset(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            if topInset > 0 {
                Color.clear
                    .frame(height: topInset)
                    .background(AppChromePalette.surfaceBar)
                AppChromeDivider(role: .shell)
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

                Spacer()

                Button(action: addClaudeChatTab) {
                    Image(systemName: "sparkle")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Nouveau chat Claude")

                if showsInlineControls {
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

                    Button(action: appearanceStore.presentSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Réglages du terminal")
                }

                Spacer()
                    .frame(width: 6)
            }
            .frame(height: AppChromeMetrics.tabBarHeight)
            .background(AppChromePalette.surfaceSubbar)

            AppChromeDivider(role: .panel)

            Group {
                if workspaceState.selectedTab?.kind == .claudeChat {
                    chatPaneContent
                } else if workspaceState.isSplit {
                    splitTerminalContent
                } else {
                    paneContainer(.top) {
                        topTerminalPane
                    }
                }
            }
            .background(Color(nsColor: resolvedTheme.background))
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
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: workspaceState.isSplit)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: appearance)
    }

    // MARK: - Tab Button

    @ViewBuilder
    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        let iconName = tab.kind == .claudeChat ? "sparkle" : "terminal"
        let indicatorColor = tab.kind == .claudeChat ? Color.orange : AppChromePalette.tabIndicator(for: .terminal)

        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundStyle(indicatorColor)
            Text(tab.title)
                .font(.system(size: 10, weight: tab.id == currentTabID ? .semibold : .regular))
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
        .background(AppChromePalette.tabFill(isSelected: tab.id == currentTabID, isHovered: false, role: .terminal))
        .overlay(alignment: .bottom) {
            if tab.id == currentTabID {
                Rectangle()
                    .fill(indicatorColor)
                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { workspaceState.selectedTabID = tab.id }
    }

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

    @ViewBuilder
    private func paneHeader(_ pane: PaneID) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(workspaceState.focusedPane == pane ? AppChromePalette.tabIndicator(for: .terminal) : Color.gray.opacity(0.3))
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
        .background(AppChromePalette.tabFill(isSelected: workspaceState.focusedPane == pane, isHovered: false, role: .terminal))
        .onTapGesture { workspaceState.focusedPane = pane }
    }

    private var terminalPadding: CGFloat {
        CGFloat(max(0, appearance.terminalPadding))
    }

    private func paneOpacity(_ pane: PaneID) -> Double {
        guard workspaceState.isSplit else { return 1 }
        return workspaceState.focusedPane == pane ? appearance.activePaneOpacity : appearance.inactivePaneOpacity
    }

    @ViewBuilder
    private var topTerminalPane: some View {
        ZStack {
            ForEach(workspaceState.tabs) { tab in
                TerminalViewWrapper(
                    tabID: tab.id,
                    terminalViews: $workspaceState.terminalViews,
                    isActive: tab.id == currentTabID,
                    optionAsMetaKey: tab.optionAsMetaKey,
                    appearance: appearance,
                    colorScheme: colorScheme,
                    startupWorkingDirectory: startupWorkingDirectory
                )
                .opacity(tab.id == currentTabID ? 1 : 0)
                .allowsHitTesting(tab.id == currentTabID)
            }
        }
    }

    @ViewBuilder
    private var bottomTerminalPane: some View {
        ZStack {
            ForEach(workspaceState.splitTabs) { tab in
                TerminalViewWrapper(
                    tabID: tab.id,
                    terminalViews: $workspaceState.splitTerminalViews,
                    isActive: workspaceState.isSplit,
                    optionAsMetaKey: tab.optionAsMetaKey,
                    appearance: appearance,
                    colorScheme: colorScheme,
                    startupWorkingDirectory: startupWorkingDirectory
                )
            }
        }
    }

    private func paneContainer<Content: View>(_ pane: PaneID, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if workspaceState.isSplit {
                paneHeader(pane)
            }
            content()
                .padding(terminalPadding)
                .background(Color(nsColor: resolvedTheme.background))
        }
        .opacity(paneOpacity(pane))
        .contentShape(Rectangle())
        .onTapGesture { workspaceState.focusedPane = pane }
    }

    private var splitTerminalContent: some View {
        GeometryReader { geometry in
            let dividerHeight = max(CGFloat(appearance.dividerThickness), 1)
            let minimumPaneHeight: CGFloat = 110
            let availableHeight = max(geometry.size.height - dividerHeight, minimumPaneHeight * 2)
            let topHeight = min(
                max(availableHeight * workspaceState.splitFraction, minimumPaneHeight),
                availableHeight - minimumPaneHeight
            )
            let bottomHeight = max(minimumPaneHeight, availableHeight - topHeight)

            VStack(spacing: 0) {
                paneContainer(.top) {
                    topTerminalPane
                }
                .frame(height: topHeight)

                Rectangle()
                    .fill(Color.clear)
                    .frame(height: max(dividerHeight + 6, 12))
                    .contentShape(Rectangle())
                    .overlay {
                        Rectangle()
                            .fill(Color(nsColor: appearance.resolvedDividerColor(for: colorScheme)))
                            .frame(height: dividerHeight)
                    }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let startingFraction = splitDragStartFraction ?? workspaceState.splitFraction
                                if splitDragStartFraction == nil {
                                    splitDragStartFraction = workspaceState.splitFraction
                                }
                                let delta = value.translation.height / max(availableHeight, 1)
                                workspaceState.splitFraction = min(max(startingFraction + delta, 0.22), 0.78)
                            }
                            .onEnded { _ in
                                splitDragStartFraction = nil
                            }
                    )

                paneContainer(.bottom) {
                    bottomTerminalPane
                }
                .frame(height: bottomHeight)
            }
        }
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
        workspaceState.splitFraction = 0.5
    }

    private func addTab() {
        let tab = TerminalTab()
        workspaceState.tabs.append(tab)
        workspaceState.selectedTabID = tab.id
    }

    private func addClaudeChatTab() {
        let tab = TerminalTab(title: "Claude", kind: .claudeChat)
        workspaceState.tabs.append(tab)
        workspaceState.selectedTabID = tab.id
    }

    @ViewBuilder
    private var chatPaneContent: some View {
        if let tabID = workspaceState.selectedTabID {
            let provider = workspaceState.chatProvider(
                for: tabID,
                workingDirectory: startupWorkingDirectory
            )
            AIChatView(provider: provider)
        }
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
            // Clean up chat provider if it's a chat tab
            workspaceState.chatProviders[tab.id]?.stop()
            workspaceState.chatProviders.removeValue(forKey: tab.id)

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
    let appearance: TerminalAppearanceState
    let colorScheme: ColorScheme
    let startupWorkingDirectory: URL?

    func makeNSView(context: Context) -> FocusAwareLocalProcessTerminalView {
        if let existing = terminalViews[tabID] as? FocusAwareLocalProcessTerminalView {
            existing.shouldCaptureFocusFromClicks = isActive
            existing.optionAsMetaKey = optionAsMetaKey
            existing.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            existing.setContentHuggingPriority(.defaultLow, for: .horizontal)
            TerminalAppearanceApplicator.apply(appearance: appearance, colorScheme: colorScheme, to: existing)
            return existing
        }

        let tv = FocusAwareLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.optionAsMetaKey = optionAsMetaKey
        tv.shouldCaptureFocusFromClicks = isActive
        TerminalAppearanceApplicator.apply(appearance: appearance, colorScheme: colorScheme, to: tv)

        if !AppRuntime.isRunningTests {
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
        }

        enableMetalWhenReady(for: tv)

        DispatchQueue.main.async {
            self.terminalViews[tabID] = tv
        }

        return tv
    }

    func updateNSView(_ nsView: FocusAwareLocalProcessTerminalView, context: Context) {
        nsView.shouldCaptureFocusFromClicks = isActive
        nsView.optionAsMetaKey = optionAsMetaKey
        TerminalAppearanceApplicator.apply(appearance: appearance, colorScheme: colorScheme, to: nsView)
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
                tv.applyCursorStyle(appearance.cursorStyle.swiftTermValue)
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
    private var preferredCursorStyle: CursorStyle = defaultTerminalCursorStyle
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private weak var focusClickGesture: NSClickGestureRecognizer?
    private var mouseWheelAccumulator: CGFloat = 0
    private var alternateWheelAccumulator: CGFloat = 0

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        source.options.cursorStyle = preferredCursorStyle
        super.cursorStyleChanged(source: source, newStyle: preferredCursorStyle)
    }

    func terminateTrackedProcess() {
        terminate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitors()
        } else {
            installFocusClickGestureIfNeeded()
            installClickMonitorIfNeeded()
            installKeyMonitorIfNeeded()
            installScrollMonitorIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.activateInputFocus()
                self?.applyPreferredCursorAppearance()
                self?.schedulePreferredCursorWarmup()
            }
        }
    }

    @objc private func handleFocusClickGesture(_ recognizer: NSClickGestureRecognizer) {
        guard shouldCaptureFocusFromClicks else { return }
        guard recognizer.state == .ended else { return }
        activateInputFocus()
    }

    private func installFocusClickGestureIfNeeded() {
        guard focusClickGesture == nil else { return }
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleFocusClickGesture(_:)))
        recognizer.buttonMask = 0x1
        recognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(recognizer)
        focusClickGesture = recognizer
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
        terminal.setCursorStyle(preferredCursorStyle)
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

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func removeEventMonitors() {
        removeClickMonitor()
        removeKeyMonitor()
        removeScrollMonitor()
    }

    private func installScrollMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window else { return event }
            guard event.window === window else { return event }
            guard event.scrollingDeltaY != 0 else { return event }

            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            let terminal = self.getTerminal()

            // Mouse mode active: prefer SGR mouse wheel events for the TUI app
            // (Claude Code, vim, tmux, etc.). Only consume the event once we
            // actually emitted a scroll action; otherwise leave room for
            // alternate-screen fallbacks or native handling.
            if terminal.mouseMode != .off {
                if self.sendMouseWheelEvent(event, terminal: terminal) {
                    return nil
                }

                if !self.canScroll {
                    if self.sendAlternateBufferScrollFallback(event, terminal: terminal) {
                        return nil
                    }
                }

                return event
            }

            // Alternate buffer without native scrollback (e.g. Claude Code/Codex
            // full-screen views): try paging first, then cursor-key fallback.
            if !self.canScroll {
                if self.sendAlternateBufferScrollFallback(event, terminal: terminal) {
                    return nil
                }
                return event
            }

            return event
        }
    }

    private func removeScrollMonitor() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    private func resetWheelAccumulatorsForDirectionChange(deltaY: CGFloat) {
        if mouseWheelAccumulator != 0, deltaY.sign != mouseWheelAccumulator.sign {
            mouseWheelAccumulator = 0
        }
        if alternateWheelAccumulator != 0, deltaY.sign != alternateWheelAccumulator.sign {
            alternateWheelAccumulator = 0
        }
    }

    @discardableResult
    private func sendMouseWheelEvent(_ event: NSEvent, terminal: Terminal) -> Bool {
        let flags = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        let safeWidth = max(bounds.width, 1)
        let safeHeight = max(bounds.height, 1)
        let cellWidth = safeWidth / CGFloat(max(terminal.cols, 1))
        let cellHeight = safeHeight / CGFloat(max(terminal.rows, 1))

        let clampedX = min(max(point.x, 0), safeWidth - 1)
        let clampedY = min(max(point.y, 0), safeHeight - 1)
        let column = min(max(Int(clampedX / max(cellWidth, 1)), 0), max(terminal.cols - 1, 0))
        let rowFromTop = min(max(Int((safeHeight - clampedY) / max(cellHeight, 1)), 0), max(terminal.rows - 1, 0))
        let pixelX = Int(clampedX)
        let pixelY = Int(safeHeight - clampedY)

        let deltaY = event.scrollingDeltaY
        resetWheelAccumulatorsForDirectionChange(deltaY: deltaY)

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        mouseWheelAccumulator += deltaY
        let steps = min(max(Int(abs(mouseWheelAccumulator) / threshold), 0), 3)
        guard steps > 0 else { return false }
        mouseWheelAccumulator -= CGFloat(steps) * threshold * (mouseWheelAccumulator >= 0 ? 1 : -1)

        let button = deltaY > 0 ? 4 : 5
        let buttonFlags = terminal.encodeButton(
            button: button,
            release: false,
            shift: flags.contains(.shift),
            meta: flags.contains(.option),
            control: flags.contains(.control)
        )

        for _ in 0..<steps {
            terminal.sendEvent(
                buttonFlags: buttonFlags,
                x: column,
                y: rowFromTop,
                pixelX: pixelX,
                pixelY: pixelY
            )
        }
        return true
    }

    @discardableResult
    private func sendAlternateBufferScrollFallback(_ event: NSEvent, terminal: Terminal) -> Bool {
        let deltaY = event.scrollingDeltaY
        resetWheelAccumulatorsForDirectionChange(deltaY: deltaY)

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
        alternateWheelAccumulator += deltaY
        let steps = min(max(Int(abs(alternateWheelAccumulator) / threshold), 0), 2)
        guard steps > 0 else { return false }
        alternateWheelAccumulator -= CGFloat(steps) * threshold * (alternateWheelAccumulator >= 0 ? 1 : -1)

        let sequence = deltaY > 0 ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown
        for _ in 0..<steps {
            send(data: sequence[...])
        }
        return true
    }

}

@MainActor
extension FocusAwareLocalProcessTerminalView: TerminalAppearanceApplying {
    func setAnsi256PaletteStrategy(_ strategy: Ansi256PaletteStrategy) {
        getTerminal().ansi256PaletteStrategy = strategy
    }

    func setTerminalBaseColors(background: SwiftTerm.Color, foreground: SwiftTerm.Color) {
        let terminal = getTerminal()
        terminal.backgroundColor = background
        terminal.foregroundColor = foreground
    }

    func setScrollbackLines(_ lines: Int?) {
        changeScrollback(lines)
    }

    func applyCursorStyle(_ style: CursorStyle) {
        preferredCursorStyle = style
        let terminal = getTerminal()
        terminal.options.cursorStyle = style
        terminal.setCursorStyle(style)
        applyPreferredCursorAppearance()
    }
}

struct TerminalAppearanceSheet: View {
    @ObservedObject var store: TerminalAppearanceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var cursorShapeBinding: Binding<TerminalCursorShape> {
        Binding(
            get: { store.appearance.cursorStyle.shape },
            set: { newShape in
                var updated = store.appearance
                updated.cursorStyle = updated.cursorStyle.withShape(newShape)
                store.appearance = updated
            }
        )
    }

    private var cursorBlinkBinding: Binding<Bool> {
        Binding(
            get: { store.appearance.cursorStyle.isBlinking },
            set: { isBlinking in
                var updated = store.appearance
                updated.cursorStyle = updated.cursorStyle.withBlinking(isBlinking)
                store.appearance = updated
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Réglages du terminal")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Preset Ghostty, séparation plus lisible et apparence commune pour tous les terminaux.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Réinitialiser") {
                    store.appearance = TerminalAppearanceState()
                }
                Button("Fermer") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(AppChromePalette.surfaceBar)

            AppChromeDivider(role: .shell)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TerminalThemePreview(appearance: store.appearance, colorScheme: colorScheme)

                    GroupBox("Typography") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Famille") {
                                TextField("SF Mono", text: store.binding(for: \.fontFamily))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Taille") {
                                    Text("\(Int(store.appearance.fontSize)) pt")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: store.binding(for: \.fontSize),
                                    in: 10...24,
                                    step: 1
                                )
                            }
                        }
                    }

                    GroupBox("Cursor") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Forme", selection: cursorShapeBinding) {
                                ForEach(TerminalCursorShape.allCases) { shape in
                                    Text(shape.title).tag(shape)
                                }
                            }
                            .pickerStyle(.segmented)

                            Toggle("Curseur clignotant", isOn: cursorBlinkBinding)

                            Text(store.appearance.cursorStyle.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Pane Styling") {
                        VStack(alignment: .leading, spacing: 12) {
                            sliderRow(
                                title: "Opacité panneau inactif",
                                value: store.binding(for: \.inactivePaneOpacity),
                                range: 0.35...1,
                                step: 0.05,
                                suffix: String(format: "%.2f", store.appearance.inactivePaneOpacity)
                            )
                            sliderRow(
                                title: "Opacité panneau actif",
                                value: store.binding(for: \.activePaneOpacity),
                                range: 0.75...1,
                                step: 0.05,
                                suffix: String(format: "%.2f", store.appearance.activePaneOpacity)
                            )
                            sliderRow(
                                title: "Épaisseur du séparateur",
                                value: store.binding(for: \.dividerThickness),
                                range: 1...8,
                                step: 1,
                                suffix: "\(Int(store.appearance.dividerThickness)) px"
                            )
                            sliderRow(
                                title: "Padding terminal",
                                value: store.binding(for: \.terminalPadding),
                                range: 0...12,
                                step: 1,
                                suffix: "\(Int(store.appearance.terminalPadding)) px"
                            )
                        }
                    }

                    GroupBox("Themes") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Thème sombre", selection: store.binding(for: \.darkThemePresetID)) {
                                ForEach(TerminalThemePreset.all) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("Utiliser un thème séparé en clair", isOn: store.binding(for: \.useSeparateLightTheme))

                            Picker("Thème clair", selection: store.binding(for: \.lightThemePresetID)) {
                                ForEach(TerminalThemePreset.all) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(!store.appearance.useSeparateLightTheme)

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Divider sombre")
                                        .font(.system(size: 11, weight: .medium))
                                    TextField("#3f3f46", text: store.binding(for: \.dividerColorDark))
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Divider clair")
                                        .font(.system(size: 11, weight: .medium))
                                    TextField("#d4d4d8", text: store.binding(for: \.dividerColorLight))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }

                    GroupBox("Advanced") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Utiliser les bright colors ANSI", isOn: store.binding(for: \.useBrightColors))

                            HStack {
                                Text("Scrollback")
                                Spacer()
                                Stepper(
                                    "\(store.appearance.scrollbackLines) lignes",
                                    value: store.binding(for: \.scrollbackLines),
                                    in: 1000...50000,
                                    step: 1000
                                )
                                .frame(maxWidth: 220, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 620, minHeight: 720)
            .background(AppChromePalette.surfaceSubbar)
        }
    }

    @ViewBuilder
    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(suffix)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

struct TerminalThemePreview: View {
    let appearance: TerminalAppearanceState
    let colorScheme: ColorScheme

    private var theme: TerminalThemePreset {
        appearance.resolvedThemePreset(for: colorScheme)
    }

    private var dividerColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: appearance.resolvedDividerColor(for: colorScheme))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                previewPane(title: "Actif", opacity: appearance.activePaneOpacity)

                Rectangle()
                    .fill(dividerColor)
                    .frame(height: max(CGFloat(appearance.dividerThickness), 1))

                previewPane(title: "Inactif", opacity: appearance.inactivePaneOpacity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func previewPane(title: String, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(title == "Actif" ? AppChromePalette.tabIndicator(for: .terminal) : Color.gray.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: theme.foreground).opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("tofunori@canope % latexmk main.tex")
                Text("Terminal preset: \(theme.name)")
                Text("Cursor: \(appearance.cursorStyle.title)")
                    .foregroundStyle(Color(nsColor: theme.ansiColors[4]))
            }
            .font(.custom(appearance.fontFamily, size: appearance.fontSize))
            .foregroundStyle(Color(nsColor: theme.foreground))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(Array(theme.ansiColors.enumerated()), id: \.offset) { index, color in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(height: 14)
                        .overlay(alignment: .center) {
                            Text("\(index)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(index < 8 ? Color.black.opacity(0.65) : Color.white.opacity(0.75))
                        }
                }
            }
        }
        .padding(CGFloat(max(0, appearance.terminalPadding)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.background))
        .opacity(opacity)
    }
}

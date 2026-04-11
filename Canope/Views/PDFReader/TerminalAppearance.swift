import SwiftUI
@preconcurrency import SwiftTerm

let defaultTerminalCursorStyle: CursorStyle = .blinkBar

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
            return "Bar"
        case .block:
            return "Block"
        case .underline:
            return "Underline"
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
            return isBlinking ? "Blinking bar" : "Steady bar"
        case .block:
            return isBlinking ? "Blinking block" : "Steady block"
        case .underline:
            return isBlinking ? "Blinking underline" : "Steady underline"
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
                    Text(AppStrings.settingsTerminal)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Ghostty preset, clearer dividers, and a shared appearance for every terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") {
                    store.appearance = TerminalAppearanceState()
                }
                Button("Close") {
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
                            LabeledContent("Family") {
                                TextField("SF Mono", text: store.binding(for: \.fontFamily))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Size") {
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
                            Picker("Shape", selection: cursorShapeBinding) {
                                ForEach(TerminalCursorShape.allCases) { shape in
                                    Text(shape.title).tag(shape)
                                }
                            }
                            .pickerStyle(.segmented)

                            Toggle("Blinking cursor", isOn: cursorBlinkBinding)

                            Text(store.appearance.cursorStyle.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Pane Styling") {
                        VStack(alignment: .leading, spacing: 12) {
                            sliderRow(
                                title: "Inactive pane opacity",
                                value: store.binding(for: \.inactivePaneOpacity),
                                range: 0.35...1,
                                step: 0.05,
                                suffix: String(format: "%.2f", store.appearance.inactivePaneOpacity)
                            )
                            sliderRow(
                                title: "Active pane opacity",
                                value: store.binding(for: \.activePaneOpacity),
                                range: 0.75...1,
                                step: 0.05,
                                suffix: String(format: "%.2f", store.appearance.activePaneOpacity)
                            )
                            sliderRow(
                                title: "Divider thickness",
                                value: store.binding(for: \.dividerThickness),
                                range: 1...8,
                                step: 1,
                                suffix: "\(Int(store.appearance.dividerThickness)) px"
                            )
                            sliderRow(
                                title: "Terminal padding",
                                value: store.binding(for: \.terminalPadding),
                                range: 0...12,
                                step: 1,
                                suffix: "\(Int(store.appearance.terminalPadding)) px"
                            )
                        }
                    }

                    GroupBox("Themes") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Dark theme", selection: store.binding(for: \.darkThemePresetID)) {
                                ForEach(TerminalThemePreset.all) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("Use a separate light theme", isOn: store.binding(for: \.useSeparateLightTheme))

                            Picker("Light theme", selection: store.binding(for: \.lightThemePresetID)) {
                                ForEach(TerminalThemePreset.all) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(!store.appearance.useSeparateLightTheme)

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Dark divider")
                                        .font(.system(size: 11, weight: .medium))
                                    TextField("#3f3f46", text: store.binding(for: \.dividerColorDark))
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Light divider")
                                        .font(.system(size: 11, weight: .medium))
                                    TextField("#d4d4d8", text: store.binding(for: \.dividerColorLight))
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }

                    GroupBox("Advanced") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Use ANSI bright colors", isOn: store.binding(for: \.useBrightColors))

                            HStack {
                                Text("Scrollback")
                                Spacer()
                                Stepper(
                                    "\(store.appearance.scrollbackLines) lines",
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

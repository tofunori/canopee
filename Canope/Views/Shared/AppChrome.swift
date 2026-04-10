import SwiftUI
import Foundation

enum AppChromeMetrics {
    static let topBarHeight: CGFloat = 26
    static let topButtonSize: CGFloat = 24
    static let sectionTabBarHeight: CGFloat = 22
    static let sectionTabOuterCornerRadius: CGFloat = 11
    static let sectionTabInnerCornerRadius: CGFloat = 8
    static let sectionTabHorizontalPadding: CGFloat = 8
    static let toolbarHeight: CGFloat = 32
    static let tabBarHeight: CGFloat = 26
    static let clusterHeight: CGFloat = 24
    static let clusterCornerRadius: CGFloat = 8
    static let toolbarButtonSize: CGFloat = 24
    static let toolbarButtonCornerRadius: CGFloat = 6
    static let toolbarCompactIconSize: CGFloat = 14
    static let tabCornerRadius: CGFloat = 6
    static let tabIndicatorHeight: CGFloat = 2
    static let dividerThickness: CGFloat = 1
    static let statusCapsuleHeight: CGFloat = 18
    static let hoverHintDelay: TimeInterval = 0.02
    static let codexHeaderHeight: CGFloat = 24
    static let codexPromptCornerRadius: CGFloat = 20
    static let codexPromptInnerCornerRadius: CGFloat = 14
    static let codexPromptMinHeight: CGFloat = 96
    static let codexEventCornerRadius: CGFloat = 12
    static let codexUserBubbleCornerRadius: CGFloat = 16
    static let codexFooterChipHeight: CGFloat = 22
}

enum AppChromeTabRole {
    case section
    case document
    case terminal
    case reference
}

enum AppChromeTabFillToken: Equatable {
    case idle
    case hovered
    case selected
}

enum AppChromePalette {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
                return bestMatch == .darkAqua ? dark : light
            }
        )
    }

    static let dividerStrong = adaptive(
        light: NSColor(hex: "#d4d4d8", fallback: .separatorColor),
        dark: NSColor(hex: "#3f3f46", fallback: NSColor(calibratedWhite: 0.25, alpha: 1))
    )
    static let dividerSoft = adaptive(
        light: NSColor(hex: "#e4e4e7", fallback: .separatorColor),
        dark: NSColor(hex: "#27272a", fallback: NSColor(calibratedWhite: 0.15, alpha: 1))
    )
    static let dividerInset = adaptive(
        light: NSColor(hex: "#ededf0", fallback: .separatorColor),
        dark: NSColor(hex: "#1f2023", fallback: NSColor(calibratedWhite: 0.11, alpha: 1))
    )
    static let surfaceBar = adaptive(
        light: NSColor(hex: "#f8f8f9", fallback: .windowBackgroundColor),
        dark: NSColor(hex: "#111214", fallback: NSColor(calibratedWhite: 0.07, alpha: 1))
    )
    static let surfaceSubbar = adaptive(
        light: NSColor(hex: "#f1f1f3", fallback: .controlBackgroundColor),
        dark: NSColor(hex: "#16181b", fallback: NSColor(calibratedWhite: 0.09, alpha: 1))
    )
    static let clusterFill = adaptive(
        light: NSColor(hex: "#ffffff", fallback: .white).withAlphaComponent(0.9),
        dark: NSColor(hex: "#1c1f23", fallback: NSColor(calibratedWhite: 0.12, alpha: 1)).withAlphaComponent(0.92)
    )
    static let clusterStroke = adaptive(
        light: NSColor(hex: "#e5e7eb", fallback: .separatorColor),
        dark: NSColor(hex: "#31343a", fallback: NSColor(calibratedWhite: 0.2, alpha: 1))
    )
    static let hoverFill = adaptive(
        light: NSColor(hex: "#eceef2", fallback: .quaternaryLabelColor),
        dark: NSColor(hex: "#23262b", fallback: NSColor(calibratedWhite: 0.16, alpha: 1))
    )
    static let tabHoverFill = adaptive(
        light: NSColor(hex: "#eceef2", fallback: .quaternaryLabelColor),
        dark: NSColor(hex: "#202329", fallback: NSColor(calibratedWhite: 0.15, alpha: 1))
    )
    static let tabSelectedFill = adaptive(
        light: NSColor(hex: "#e5e7eb", fallback: .selectedContentBackgroundColor),
        dark: NSColor(hex: "#262a31", fallback: NSColor(calibratedWhite: 0.18, alpha: 1))
    )
    static let selectedAccentFill = adaptive(
        light: NSColor(hex: "#e2e8f0", fallback: .selectedContentBackgroundColor),
        dark: NSColor(hex: "#272b32", fallback: NSColor(calibratedWhite: 0.19, alpha: 1))
    )
    static let selectedAccentStroke = adaptive(
        light: NSColor(hex: "#cbd5e1", fallback: .separatorColor),
        dark: NSColor(hex: "#3b4250", fallback: NSColor(calibratedWhite: 0.25, alpha: 1))
    )
    static let selectedAccent = adaptive(
        light: NSColor(hex: "#475569", fallback: .labelColor),
        dark: NSColor(hex: "#cbd5e1", fallback: NSColor(calibratedWhite: 0.85, alpha: 1))
    )
    static let subtleUnderline = adaptive(
        light: NSColor(hex: "#9ca3af", fallback: .secondaryLabelColor),
        dark: NSColor(hex: "#71717a", fallback: NSColor(calibratedWhite: 0.45, alpha: 1))
    )
    static let handleFill = adaptive(
        light: NSColor(hex: "#cbd5e1", fallback: .separatorColor).withAlphaComponent(0.7),
        dark: NSColor(hex: "#3f3f46", fallback: NSColor(calibratedWhite: 0.25, alpha: 1))
    )
    static let handleHoverFill = adaptive(
        light: NSColor(hex: "#94a3b8", fallback: .secondaryLabelColor),
        dark: NSColor(hex: "#71717a", fallback: NSColor(calibratedWhite: 0.45, alpha: 1))
    )
    static let success = adaptive(
        light: NSColor(hex: "#15803d", fallback: .systemGreen),
        dark: NSColor(hex: "#86efac", fallback: .systemGreen)
    )
    static let info = adaptive(
        light: NSColor(hex: "#2563eb", fallback: .systemBlue),
        dark: NSColor(hex: "#93c5fd", fallback: .systemBlue)
    )
    static let danger = adaptive(
        light: NSColor(hex: "#dc2626", fallback: .systemRed),
        dark: NSColor(hex: "#fca5a5", fallback: .systemRed)
    )
    static let neutral = Color.secondary
    static let codexCanvas = adaptive(
        light: NSColor(hex: "#fafafa", fallback: .windowBackgroundColor),
        dark: NSColor(hex: "#121113", fallback: NSColor(calibratedWhite: 0.07, alpha: 1))
    )
    static let codexHeaderFill = adaptive(
        light: NSColor(hex: "#f4f4f5", fallback: .controlBackgroundColor),
        dark: NSColor(hex: "#151418", fallback: NSColor(calibratedWhite: 0.09, alpha: 1))
    )
    static let codexPromptShell = adaptive(
        light: NSColor(hex: "#f4f1f1", fallback: .controlBackgroundColor),
        dark: NSColor(hex: "#232022", fallback: NSColor(calibratedWhite: 0.14, alpha: 1))
    )
    static let codexPromptInner = adaptive(
        light: NSColor(hex: "#ffffff", fallback: .textBackgroundColor),
        dark: NSColor(hex: "#2b282b", fallback: NSColor(calibratedWhite: 0.17, alpha: 1))
    )
    static let codexPromptStroke = adaptive(
        light: NSColor(hex: "#d9d4d7", fallback: .separatorColor),
        dark: NSColor(hex: "#3a3539", fallback: NSColor(calibratedWhite: 0.24, alpha: 1))
    )
    static let codexPromptDivider = adaptive(
        light: NSColor(hex: "#d6d1d4", fallback: .separatorColor),
        dark: NSColor(hex: "#3f3a3f", fallback: NSColor(calibratedWhite: 0.25, alpha: 1))
    )
    static let codexRequestFill = adaptive(
        light: NSColor(hex: "#ece7ea", fallback: .selectedContentBackgroundColor),
        dark: NSColor(hex: "#2a262b", fallback: NSColor(calibratedWhite: 0.17, alpha: 1))
    )
    static let codexRequestStroke = adaptive(
        light: NSColor(hex: "#d9d4d7", fallback: .separatorColor),
        dark: NSColor(hex: "#39343a", fallback: NSColor(calibratedWhite: 0.24, alpha: 1))
    )
    static let codexEventFill = adaptive(
        light: NSColor(hex: "#f6f5f7", fallback: .controlBackgroundColor),
        dark: NSColor(hex: "#1a181c", fallback: NSColor(calibratedWhite: 0.1, alpha: 1))
    )
    static let codexMutedText = adaptive(
        light: NSColor(hex: "#71717a", fallback: .secondaryLabelColor),
        dark: NSColor(hex: "#a1a1aa", fallback: NSColor(calibratedWhite: 0.65, alpha: 1))
    )
    static let codexIDEContext = adaptive(
        light: NSColor(hex: "#b7791f", fallback: .systemOrange),
        dark: NSColor(hex: "#f3d36b", fallback: .systemYellow)
    )
    static let codexSendFill = adaptive(
        light: NSColor(hex: "#d6d1d4", fallback: .tertiaryLabelColor),
        dark: NSColor(hex: "#b9b4b8", fallback: NSColor(calibratedWhite: 0.72, alpha: 1))
    )
    static let codexSendGlyph = adaptive(
        light: NSColor(hex: "#2a262b", fallback: .windowBackgroundColor),
        dark: NSColor(hex: "#2a262b", fallback: .black)
    )

    static func divider(for role: AppChromeDividerRole) -> Color {
        switch role {
        case .shell:
            return dividerStrong
        case .panel:
            return dividerSoft
        case .inset:
            return dividerInset
        }
    }

    static func tabFillToken(isSelected: Bool, isHovered: Bool) -> AppChromeTabFillToken {
        if isSelected { return .selected }
        if isHovered { return .hovered }
        return .idle
    }

    static func tabFill(isSelected: Bool, isHovered: Bool, role: AppChromeTabRole) -> Color {
        switch tabFillToken(isSelected: isSelected, isHovered: isHovered) {
        case .idle:
            return .clear
        case .hovered:
            return role == .section ? tabHoverFill : hoverFill
        case .selected:
            return role == .section ? tabSelectedFill : selectedAccentFill
        }
    }

    static func tabIndicator(for role: AppChromeTabRole) -> Color {
        switch role {
        case .section:
            return subtleUnderline
        case .terminal:
            return success
        case .document, .reference:
            return selectedAccent
        }
    }
}

enum ToolbarZone {
    case leading
    case primary
    case trailing
}

enum AppChromeDividerRole {
    case shell
    case panel
    case inset
}

enum ToolbarStatusState: Equatable {
    case idle
    case compiling
    case rendering
    case running
    case saved
    case completed
    case exported
    case previewReady
    case errors(Int)

    var isVisible: Bool {
        self != .idle
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "circle.fill"
        case .compiling:
            return "hourglass"
        case .rendering:
            return "doc.richtext"
        case .running:
            return "play.circle.fill"
        case .saved:
            return "checkmark.circle.fill"
        case .completed:
            return "checkmark.circle"
        case .exported:
            return "square.and.arrow.up.circle.fill"
        case .previewReady:
            return "doc.richtext.fill"
        case .errors:
            return "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .idle:
            return ""
        case .compiling:
            return "Compilation…"
        case .rendering:
            return "Rendu…"
        case .running:
            return "Exécution…"
        case .saved:
            return "Enregistré"
        case .completed:
            return "Exécuté"
        case .exported:
            return "Annotations exportées"
        case .previewReady:
            return "PDF prêt"
        case .errors(let count):
            return "\(count) erreur\(count > 1 ? "s" : "")"
        }
    }

    var tint: Color {
        switch self {
        case .idle:
            return AppChromePalette.neutral
        case .compiling:
            return AppChromePalette.info
        case .rendering:
            return AppChromePalette.info
        case .running:
            return AppChromePalette.info
        case .saved:
            return AppChromePalette.success
        case .completed:
            return AppChromePalette.success
        case .exported:
            return AppChromePalette.success
        case .previewReady:
            return AppChromePalette.success
        case .errors:
            return AppChromePalette.danger
        }
    }

    var isEmphasized: Bool {
        switch self {
        case .compiling, .rendering, .running, .errors:
            return true
        case .idle, .saved, .completed, .exported, .previewReady:
            return false
        }
    }

    var textTint: Color {
        switch self {
        case .saved, .completed, .exported, .previewReady:
            return .secondary
        default:
            return tint
        }
    }
}

enum AppChromeMotion {
    static func hover(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    static func selection(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.9, blendDuration: 0.12)
    }

    static func panel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func perform(_ animation: Animation?, updates: () -> Void) {
        if let animation {
            withAnimation(animation, updates)
        } else {
            updates()
        }
    }

    static func performSelection(reduceMotion: Bool, updates: () -> Void) {
        perform(selection(reduceMotion: reduceMotion), updates: updates)
    }

    static func performPanel(reduceMotion: Bool, updates: () -> Void) {
        perform(panel(reduceMotion: reduceMotion), updates: updates)
    }
}

struct AppChromeToolbarCluster<Content: View>: View {
    let zone: ToolbarZone
    var title: String?
    var collapsible: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = true

    var body: some View {
        HStack(spacing: 6) {
            if let title, !title.isEmpty {
                if collapsible {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                        HStack(spacing: 3) {
                            Text(title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(titleTint)
                                .lineLimit(1)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(titleTint)
                        .lineLimit(1)
                }
            }

            if !collapsible || isExpanded {
                content()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AppChromeMetrics.clusterHeight)
        .background(
            RoundedRectangle(cornerRadius: AppChromeMetrics.clusterCornerRadius, style: .continuous)
                .fill(AppChromePalette.clusterFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppChromeMetrics.clusterCornerRadius, style: .continuous)
                .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
        )
    }

    private var titleTint: Color {
        switch zone {
        case .leading:
            return .secondary
        case .primary:
            return .secondary
        case .trailing:
            return .secondary.opacity(0.85)
        }
    }
}

struct AppChromeDivider: View {
    let role: AppChromeDividerRole
    var axis: Axis = .horizontal
    var inset: CGFloat = 0

    var body: some View {
        Group {
            switch axis {
            case .horizontal:
                Rectangle()
                    .fill(AppChromePalette.divider(for: role))
                    .frame(height: AppChromeMetrics.dividerThickness)
                    .padding(.horizontal, inset)
            case .vertical:
                Rectangle()
                    .fill(AppChromePalette.divider(for: role))
                    .frame(width: AppChromeMetrics.dividerThickness)
                    .padding(.vertical, inset)
            }
        }
        .accessibilityHidden(true)
    }
}

struct AppChromeStatusCapsule: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: ToolbarStatusState

    var body: some View {
        if status.isVisible {
            HStack(spacing: 5) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(status.tint)
                Text(status.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(status.textTint)
            }
            .padding(.horizontal, status.isEmphasized ? 7 : 2)
            .frame(height: AppChromeMetrics.statusCapsuleHeight)
            .background(status.isEmphasized ? status.tint.opacity(0.12) : .clear)
            .overlay {
                if status.isEmphasized {
                    Capsule()
                        .stroke(status.tint.opacity(0.22), lineWidth: 1)
                }
            }
            .clipShape(Capsule())
            .transition(.opacity)
            .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: status)
        }
    }
}

struct AppChromeHoverHintBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppChromePalette.clusterStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .fixedSize(horizontal: true, vertical: false)
            .allowsHitTesting(false)
    }
}

private struct AppChromeQuickHelpModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    @State private var isPresented = false
    @State private var revealWorkItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    AppChromeHoverHintBubble(text: text)
                        .offset(y: 34)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .onHover { hovering in
                revealWorkItem?.cancel()
                revealWorkItem = nil

                guard !text.isEmpty else {
                    isPresented = false
                    return
                }

                if hovering {
                    let workItem = DispatchWorkItem {
                        AppChromeMotion.perform(AppChromeMotion.hover(reduceMotion: reduceMotion)) {
                            isPresented = true
                        }
                        revealWorkItem = nil
                    }
                    revealWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + AppChromeMetrics.hoverHintDelay, execute: workItem)
                } else {
                    AppChromeMotion.perform(AppChromeMotion.hover(reduceMotion: reduceMotion)) {
                        isPresented = false
                    }
                }
            }
    }
}

extension View {
    @ViewBuilder
    func appChromeSystemHelp(_ text: String?) -> some View {
        self
    }

    @ViewBuilder
    func appChromeQuickHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            modifier(AppChromeQuickHelpModifier(text: text))
        } else {
            self
        }
    }
}

@ViewBuilder
func AppChromeAnnotationExportMenuItems(
    activeMarkdownFileName: String?,
    companionFileName: String,
    onExportToActiveMarkdown: (() -> Void)?,
    onExportToCompanion: @escaping () -> Void,
    onChooseDestination: @escaping () -> Void
) -> some View {
    if let activeMarkdownFileName, let onExportToActiveMarkdown {
        Button(action: onExportToActiveMarkdown) {
            Label("Markdown actif (\(activeMarkdownFileName))", systemImage: "text.document")
        }
    }

    Button(action: onExportToCompanion) {
        Label("Fichier compagnon (\(companionFileName))", systemImage: "doc.plaintext")
    }

    Divider()

    Button(action: onChooseDestination) {
        Label("Choisir un fichier Markdown…", systemImage: "folder")
    }
}

struct AppChromeResizeHandle: View {
    let width: CGFloat
    let onHoverChanged: ((Bool) -> Void)?
    let dragGesture: AnyGesture<DragGesture.Value>
    var axis: Axis = .vertical
    var lineThickness: CGFloat = AppChromeMetrics.dividerThickness
    var lineColor: Color = AppChromePalette.handleFill
    var hoverLineColor: Color = AppChromePalette.handleHoverFill

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(isHovered ? hoverLineColor : lineColor)
                    .frame(
                        width: axis == .vertical ? lineThickness : nil,
                        height: axis == .horizontal ? lineThickness : nil
                    )
            }
            .onHover { hovering in
                isHovered = hovering
                onHoverChanged?(hovering)
            }
            .gesture(dragGesture)
            .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
    }
}

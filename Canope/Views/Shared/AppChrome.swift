import SwiftUI
import Foundation

enum AppChromeMetrics {
    static let topBarHeight: CGFloat = 26
    static let topButtonSize: CGFloat = 24
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
    static let hoverHintDelay: TimeInterval = 0.08
}

enum AppChromePalette {
    static let dividerStrong = Color.white.opacity(0.07)
    static let dividerSoft = Color.white.opacity(0.04)
    static let dividerInset = Color.white.opacity(0.03)
    static let surfaceBar = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let surfaceSubbar = Color(nsColor: .controlBackgroundColor).opacity(0.48)
    static let clusterFill = Color.white.opacity(0.04)
    static let clusterStroke = Color.white.opacity(0.05)
    static let hoverFill = Color.white.opacity(0.08)
    static let tabHoverFill = Color.white.opacity(0.03)
    static let tabSelectedFill = Color.white.opacity(0.06)
    static let selectedAccentFill = Color.accentColor.opacity(0.14)
    static let selectedAccentStroke = Color.accentColor.opacity(0.32)
    static let selectedAccent = Color.accentColor
    static let subtleUnderline = Color.white.opacity(0.3)
    static let handleFill = Color.white.opacity(0.035)
    static let handleHoverFill = Color.white.opacity(0.12)
    static let success = Color.green
    static let info = Color.blue
    static let danger = Color.red
    static let neutral = Color.secondary

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
    case saved
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
        case .saved:
            return "checkmark.circle.fill"
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
        case .saved:
            return "Enregistré"
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
        case .saved:
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
        case .compiling, .rendering, .errors:
            return true
        case .idle, .saved, .exported, .previewReady:
            return false
        }
    }

    var textTint: Color {
        switch self {
        case .saved, .exported, .previewReady:
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(titleTint)
                    .lineLimit(1)
            }

            content()
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
            .lineLimit(2)
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
            .fixedSize(horizontal: false, vertical: true)
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
            .overlay(alignment: .top) {
                if isPresented {
                    AppChromeHoverHintBubble(text: text)
                        .offset(y: -34)
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
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(isHovered ? AppChromePalette.handleHoverFill : AppChromePalette.handleFill)
                    .frame(width: AppChromeMetrics.dividerThickness)
            }
            .onHover { hovering in
                isHovered = hovering
                onHoverChanged?(hovering)
            }
            .gesture(dragGesture)
            .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
    }
}

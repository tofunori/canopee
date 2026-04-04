import SwiftUI

struct EditorDocumentToolbarClusterView: View {
    let title: String
    let showsLatexActions: Bool
    let isCompiling: Bool
    let compiledPDFAvailable: Bool
    let activeMarkdownExportFileName: String?
    let companionExportFileName: String
    let canAnnotateCurrentDocument: Bool
    let showErrors: Bool
    let hasCompilationErrors: Bool
    let primaryActionHelpText: String
    let outputLogHelpText: String
    let shortcutIdentity: String
    let onRunPrimaryAction: () -> Void
    let onSave: () -> Void
    let onExportToActiveMarkdown: (() -> Void)?
    let onExportToCompanionMarkdown: () -> Void
    let onChooseExportDestination: () -> Void
    let onBeginAnnotation: () -> Void
    let onReflow: () -> Void
    let onToggleErrors: () -> Void

    var body: some View {
        AppChromeToolbarCluster(zone: .primary, title: title) {
            Button(action: onRunPrimaryAction) {
                if isCompiling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.plain)
            .appChromeSystemHelp(primaryActionHelpText)
            .appChromeQuickHelp(primaryActionHelpText)
            .keyboardShortcut("b", modifiers: .command)
            .disabled(isCompiling)

            Button(action: onSave) {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .appChromeSystemHelp("Sauvegarder (⌘S)")
            .appChromeQuickHelp("Sauvegarder (⌘S)")
            .keyboardShortcut("s", modifiers: .command)

            if compiledPDFAvailable {
                Menu {
                    AppChromeAnnotationExportMenuItems(
                        activeMarkdownFileName: activeMarkdownExportFileName,
                        companionFileName: companionExportFileName,
                        onExportToActiveMarkdown: onExportToActiveMarkdown,
                        onExportToCompanion: onExportToCompanionMarkdown,
                        onChooseDestination: onChooseExportDestination
                    )
                } label: {
                    ReferencePDFToolbarIconLabel(
                        systemName: "square.and.arrow.up.on.square",
                        isActive: false,
                        helpText: "Exporter les annotations du PDF en Markdown"
                    )
                }
                .buttonStyle(.plain)
                .appChromeSystemHelp("Exporter les annotations du PDF en Markdown")
                .appChromeQuickHelp("Exporter les annotations du PDF en Markdown")
            }

            if showsLatexActions {
                Button(action: onBeginAnnotation) {
                    Image(systemName: "highlighter")
                }
                .buttonStyle(.plain)
                .appChromeSystemHelp("Annoter la sélection (⇧⌘A)")
                .appChromeQuickHelp("Annoter la sélection (⇧⌘A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!canAnnotateCurrentDocument)

                Button(action: onReflow) {
                    Image(systemName: "text.justify.leading")
                }
                .buttonStyle(.plain)
                .appChromeSystemHelp("Reflow paragraphes (⌘⇧W)")
                .appChromeQuickHelp("Reflow paragraphes (⌘⇧W)")
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            Button(action: onToggleErrors) {
                Image(systemName: "doc.text.below.ecg")
                    .foregroundStyle(showErrors ? .green : hasCompilationErrors ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .appChromeSystemHelp(outputLogHelpText)
            .appChromeQuickHelp(outputLogHelpText)
        }
        .id("document-toolbar-shortcuts:\(shortcutIdentity)")
    }
}

struct ActiveReferenceToolbarSections: View {
    @ObservedObject var referenceState: ReferencePDFUIState
    let annotationCount: Int
    let isAnnotationSidebarVisible: Bool
    let activeMarkdownFileName: String?
    let companionExportFileName: String
    let onChangeSelectedColor: (NSColor) -> Void
    let onFitToWidth: () -> Void
    let onRefresh: () -> Void
    let onSave: () -> Void
    let onExportToActiveMarkdown: (() -> Void)?
    let onExportToCompanionMarkdown: () -> Void
    let onExportToChosenMarkdownFile: () -> Void
    let onDeleteSelected: () -> Void
    let onDeleteAll: () -> Void
    let onToggleAnnotations: () -> Void

    var body: some View {
        Group {
            ReferencePDFToolCluster(title: "Outils", state: referenceState)

            ReferencePDFActionsCluster(
                title: "Actions",
                state: referenceState,
                annotationCount: annotationCount,
                isAnnotationSidebarVisible: isAnnotationSidebarVisible,
                activeMarkdownFileName: activeMarkdownFileName,
                companionExportFileName: companionExportFileName,
                onChangeSelectedColor: onChangeSelectedColor,
                onFitToWidth: onFitToWidth,
                onRefresh: onRefresh,
                onSave: onSave,
                onExportToActiveMarkdown: onExportToActiveMarkdown,
                onExportToCompanionMarkdown: onExportToCompanionMarkdown,
                onExportToChosenMarkdownFile: onExportToChosenMarkdownFile,
                onDeleteSelected: onDeleteSelected,
                onDeleteAll: onDeleteAll,
                onToggleAnnotations: onToggleAnnotations
            )
        }
    }
}

struct ActiveReferenceToolbarView: View {
    let referenceState: ReferencePDFUIState?
    let annotationCount: Int
    let isAnnotationSidebarVisible: Bool
    let activeMarkdownFileName: String?
    let companionExportFileName: String
    let onChangeSelectedColor: (NSColor) -> Void
    let onFitToWidth: () -> Void
    let onRefresh: () -> Void
    let onSave: () -> Void
    let onExportToActiveMarkdown: (() -> Void)?
    let onExportToCompanionMarkdown: () -> Void
    let onExportToChosenMarkdownFile: () -> Void
    let onDeleteSelected: () -> Void
    let onDeleteAll: () -> Void
    let onToggleAnnotations: () -> Void

    var body: some View {
        Group {
            if let referenceState {
                ActiveReferenceToolbarSections(
                    referenceState: referenceState,
                    annotationCount: annotationCount,
                    isAnnotationSidebarVisible: isAnnotationSidebarVisible,
                    activeMarkdownFileName: activeMarkdownFileName,
                    companionExportFileName: companionExportFileName,
                    onChangeSelectedColor: onChangeSelectedColor,
                    onFitToWidth: onFitToWidth,
                    onRefresh: onRefresh,
                    onSave: onSave,
                    onExportToActiveMarkdown: onExportToActiveMarkdown,
                    onExportToCompanionMarkdown: onExportToCompanionMarkdown,
                    onExportToChosenMarkdownFile: onExportToChosenMarkdownFile,
                    onDeleteSelected: onDeleteSelected,
                    onDeleteAll: onDeleteAll,
                    onToggleAnnotations: onToggleAnnotations
                )
            }
        }
    }
}

struct ReferencePDFToolbarIconButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemName: String
    var symbolVariant: SymbolVariants = .none
    let isActive: Bool
    var activeTint: Color = .accentColor
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolVariant(symbolVariant)
                .foregroundStyle(iconTint)
                .frame(width: AppChromeMetrics.toolbarCompactIconSize, height: AppChromeMetrics.toolbarCompactIconSize)
                .frame(width: AppChromeMetrics.toolbarButtonSize, height: AppChromeMetrics.toolbarButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous)
                        .fill(backgroundTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous)
                        .stroke(borderTint, lineWidth: borderTint == .clear ? 0 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .appChromeQuickHelp(help)
        .onHover { isHovered = $0 }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isActive)
    }

    private var iconTint: Color {
        if isActive { return activeTint }
        if isHovered { return .primary }
        return .secondary
    }

    private var backgroundTint: Color {
        if isActive { return activeTint.opacity(0.18) }
        if isHovered { return AppChromePalette.hoverFill }
        return .clear
    }

    private var borderTint: Color {
        if isActive { return activeTint.opacity(0.32) }
        if isHovered { return AppChromePalette.clusterStroke }
        return .clear
    }
}

struct ReferencePDFToolbarIconLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemName: String
    let isActive: Bool
    var helpText: String? = nil

    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(isActive ? AppChromePalette.selectedAccent : (isHovered ? Color.primary : Color.secondary))
            .frame(width: AppChromeMetrics.toolbarCompactIconSize, height: AppChromeMetrics.toolbarCompactIconSize)
            .frame(width: AppChromeMetrics.toolbarButtonSize, height: AppChromeMetrics.toolbarButtonSize)
            .background(
                RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous)
                    .fill(isActive ? AppChromePalette.selectedAccentFill : (isHovered ? AppChromePalette.hoverFill : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous)
                    .stroke(isActive ? AppChromePalette.selectedAccentStroke : (isHovered ? AppChromePalette.clusterStroke : .clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius, style: .continuous))
            .appChromeSystemHelp(helpText)
            .appChromeQuickHelp(helpText)
            .onHover { isHovered = $0 }
            .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
            .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isActive)
    }
}

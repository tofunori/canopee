import SwiftUI
import PDFKit
import AppKit

struct AnnotationToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var currentTool: AnnotationTool
    @Binding var currentColor: NSColor
    let status: ToolbarStatusState
    let selectedAnnotation: PDFAnnotation?
    @Binding var showTerminal: Bool
    @Binding var showAnnotations: Bool
    var onSave: () -> Void
    let activeMarkdownExportFileName: String?
    let companionExportFileName: String
    var onExportToActiveMarkdown: (() -> Void)?
    var onExportToCompanionMarkdown: () -> Void
    var onExportToChosenMarkdownFile: () -> Void
    var onDeleteSelected: () -> Void
    var onDeleteAll: () -> Void
    var onChangeColor: (NSColor) -> Void
    @State private var showDeleteAllConfirm = false
    @State private var favoriteColors: [NSColor] = AnnotationColor.loadFavorites()
    @State private var customColor: Color = .yellow
    @State private var editingSlotIndex: Int? = nil
    @State private var showColorPicker = false

    var body: some View {
        HStack(spacing: 8) {
            AppChromeToolbarCluster(zone: .primary, title: "Outils") {
                ForEach(Array(AnnotationTool.allCases), id: \.id) { tool in
                    toolButton(tool)
                }
            }

            AppChromeToolbarCluster(zone: .primary, title: "Couleurs") {
                ForEach(0..<5, id: \.self) { index in
                    ColorSlotButton(
                        color: favoriteColors[index],
                        isSelected: colorsMatch(currentColor, favoriteColors[index]),
                        onSelect: {
                            currentColor = favoriteColors[index]
                            if selectedAnnotation != nil {
                                onChangeColor(favoriteColors[index])
                            }
                        },
                        onCustomize: {
                            editingSlotIndex = index
                            customColor = Color(nsColor: favoriteColors[index])
                            showColorPicker = true
                        }
                    )
                }

                ToolbarIconButton(
                    systemName: "plus.circle",
                    helpText: "Couleur personnalisée",
                    action: {
                        editingSlotIndex = nil
                        customColor = Color(nsColor: currentColor)
                        showColorPicker = true
                    }
                )
            }

            if selectedAnnotation != nil {
                AppChromeToolbarCluster(zone: .primary, title: "Sélection") {
                    ToolbarIconButton(
                        systemName: "trash",
                        foregroundStyle: AppChromePalette.danger,
                        helpText: "Supprimer l'annotation (⌫)",
                        action: onDeleteSelected
                    )

                    Text("Sélectionné")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AppChromeStatusCapsule(status: status)

            Spacer()

            AppChromeToolbarCluster(zone: .trailing, title: "Actions") {
                ToolbarIconButton(
                    systemName: "trash.slash",
                    foregroundStyle: AppChromePalette.danger,
                    helpText: "Effacer toutes les annotations",
                    action: { showDeleteAllConfirm = true }
                )
                .confirmationDialog(
                    "Effacer toutes les annotations?",
                    isPresented: $showDeleteAllConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Tout effacer", role: .destructive, action: onDeleteAll)
                    Button("Annuler", role: .cancel) {}
                }

                AppChromeDivider(role: .inset, axis: .vertical, inset: 4)

                ToolbarIconButton(
                    systemName: "square.and.arrow.down",
                    helpText: "Enregistrer (⌘S)",
                    action: onSave
                )
                .keyboardShortcut("s", modifiers: .command)

                Menu {
                    AppChromeAnnotationExportMenuItems(
                        activeMarkdownFileName: activeMarkdownExportFileName,
                        companionFileName: companionExportFileName,
                        onExportToActiveMarkdown: onExportToActiveMarkdown,
                        onExportToCompanion: onExportToCompanionMarkdown,
                        onChooseDestination: onExportToChosenMarkdownFile
                    )
                } label: {
                    ToolbarIconLabel(
                        systemName: "square.and.arrow.up.on.square",
                        helpText: "Exporter les annotations en Markdown"
                    )
                }
                .buttonStyle(.plain)
                .help("Exporter les annotations en Markdown")
            }

            AppChromeToolbarCluster(zone: .trailing, title: "Vue") {
                ToolbarIconButton(
                    systemName: showTerminal ? "terminal.fill" : "terminal",
                    isSelected: showTerminal,
                    foregroundStyle: showTerminal ? AppChromePalette.success : .secondary,
                    selectedFillTint: AppChromePalette.success,
                    helpText: "Terminal",
                    action: {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            showTerminal.toggle()
                        }
                    }
                )

                ToolbarIconButton(
                    systemName: "sidebar.right",
                    symbolVariant: showAnnotations ? .none : .slash,
                    isSelected: showAnnotations,
                    foregroundStyle: showAnnotations ? AppChromePalette.info : .secondary,
                    selectedFillTint: AppChromePalette.info,
                    helpText: "Annotations",
                    action: {
                        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                            showAnnotations.toggle()
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
        .popover(isPresented: $showColorPicker) {
            ColorPickerPopover(
                selectedColor: $customColor,
                slotIndex: editingSlotIndex,
                onApply: { color in
                    let nsColor = AnnotationColor.normalized(NSColor(color))
                    currentColor = nsColor

                    // If editing a slot, save it as a favorite
                    if let index = editingSlotIndex {
                        favoriteColors[index] = nsColor
                        AnnotationColor.saveFavorites(favoriteColors)
                    }

                    // If an annotation is selected, change its color
                    if selectedAnnotation != nil {
                        onChangeColor(nsColor)
                    }

                    showColorPicker = false
                },
                onCancel: {
                    showColorPicker = false
                }
            )
        }
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        ToolbarIconButton(
            systemName: tool.icon,
            isSelected: currentTool == tool,
            helpText: tool.displayName,
            action: {
                AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                    currentTool = tool
                }
            }
        )
    }

    /// Compare two NSColors (approximate, ignoring tiny floating point diffs)
    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        let ac = AnnotationColor.normalized(a)
        let bc = AnnotationColor.normalized(b)
        return abs(ac.redComponent - bc.redComponent) < 0.01
            && abs(ac.greenComponent - bc.greenComponent) < 0.01
            && abs(ac.blueComponent - bc.blueComponent) < 0.01
            && abs(ac.alphaComponent - bc.alphaComponent) < 0.01
    }
}

// MARK: - Color Slot Button

struct ColorSlotButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: NSColor
    let isSelected: Bool
    let onSelect: () -> Void
    let onCustomize: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 18, height: 18)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.primary, lineWidth: 2)
                    }
                }
                .frame(width: AppChromeMetrics.toolbarButtonSize, height: AppChromeMetrics.toolbarButtonSize)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Changer cette couleur…") {
                onCustomize()
            }
        }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }

    private var backgroundFill: Color {
        if isSelected {
            return AppChromePalette.selectedAccentFill
        }
        if isHovered {
            return AppChromePalette.hoverFill
        }
        return .clear
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemName: String
    var symbolVariant: SymbolVariants = .none
    var isSelected = false
    var foregroundStyle: Color = .primary
    var selectedFillTint: Color? = nil
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolVariant(symbolVariant)
                .imageScale(.small)
                .frame(width: AppChromeMetrics.toolbarButtonSize, height: AppChromeMetrics.toolbarButtonSize)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .appChromeQuickHelp(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }

    private var backgroundFill: Color {
        if isSelected {
            return (selectedFillTint ?? AppChromePalette.selectedAccent).opacity(0.18)
        }
        if isHovered {
            return AppChromePalette.hoverFill
        }
        return .clear
    }
}

struct ToolbarIconLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemName: String
    var symbolVariant: SymbolVariants = .none
    let helpText: String
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .symbolVariant(symbolVariant)
            .imageScale(.small)
            .frame(width: AppChromeMetrics.toolbarButtonSize, height: AppChromeMetrics.toolbarButtonSize)
            .background(backgroundFill)
            .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.toolbarButtonCornerRadius))
            .foregroundStyle(.primary)
            .appChromeQuickHelp(helpText)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
    }

    private var backgroundFill: Color {
        isHovered ? AppChromePalette.hoverFill : .clear
    }
}

// MARK: - Color Picker Popover

struct ColorPickerPopover: View {
    @Binding var selectedColor: Color
    let slotIndex: Int?
    let onApply: (Color) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(slotIndex != nil ? "Changer la couleur du slot \(slotIndex! + 1)" : "Couleur personnalisée")
                .font(.headline)

            Circle()
                .fill(selectedColor)
                .frame(width: 42, height: 42)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }

            ColorPicker("Couleur", selection: $selectedColor, supportsOpacity: true)
                .frame(width: 220)

            // Quick presets
            HStack(spacing: 8) {
                ForEach(quickPresets, id: \.self) { preset in
                    Button(action: { selectedColor = preset }) {
                        Circle()
                            .fill(preset)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Appliquer") {
                    onApply(selectedColor)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private var quickPresets: [Color] {
        [.yellow, .orange, .red, .pink, .purple, .blue, .cyan, .green, .mint]
    }
}

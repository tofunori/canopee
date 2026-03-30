import SwiftUI
import PDFKit
import AppKit

struct AnnotationToolbar: View {
    @Binding var currentTool: AnnotationTool
    @Binding var currentColor: NSColor
    let selectedAnnotation: PDFAnnotation?
    @Binding var showTerminal: Bool
    @Binding var showAnnotations: Bool
    var onSave: () -> Void
    var onDeleteSelected: () -> Void
    var onDeleteAll: () -> Void
    var onChangeColor: (NSColor) -> Void
    @State private var showDeleteAllConfirm = false
    @State private var favoriteColors: [NSColor] = AnnotationColor.loadFavorites()
    @State private var customColor: Color = .yellow
    @State private var editingSlotIndex: Int? = nil
    @State private var showColorPicker = false

    var body: some View {
        HStack(spacing: 6) {
            // Tool buttons
            ForEach(Array(AnnotationTool.allCases), id: \.id) { tool in
                toolButton(tool)
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // 5 favorite color slots
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

            // Custom color picker button
            ToolbarIconButton(
                systemName: "plus.circle",
                helpText: "Couleur personnalisée",
                action: {
                    editingSlotIndex = nil
                    customColor = Color(nsColor: currentColor)
                    showColorPicker = true
                }
            )

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // Selection-dependent actions
            if selectedAnnotation != nil {
                ToolbarIconButton(
                    systemName: "trash",
                    foregroundStyle: .red,
                    helpText: "Supprimer l'annotation (⌫)",
                    action: onDeleteSelected
                )

                Text("Sélectionné")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Delete all
            ToolbarIconButton(
                systemName: "trash.slash",
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

            // Save button
            ToolbarIconButton(
                systemName: "square.and.arrow.down",
                helpText: "Enregistrer (⌘S)",
                action: onSave
            )
            .keyboardShortcut("s", modifiers: .command)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            // Terminal toggle
            ToolbarIconButton(
                systemName: showTerminal ? "terminal.fill" : "terminal",
                isSelected: showTerminal,
                foregroundStyle: showTerminal ? .green : .secondary,
                helpText: "Terminal",
                action: { showTerminal.toggle() }
            )

            // Annotations sidebar toggle
            ToolbarIconButton(
                systemName: "sidebar.right",
                symbolVariant: showAnnotations ? .none : .slash,
                isSelected: showAnnotations,
                helpText: "Annotations",
                action: { showAnnotations.toggle() }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
            action: { currentTool = tool }
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
                .frame(width: 30, height: 30)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
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
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.primary.opacity(0.14)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let systemName: String
    var symbolVariant: SymbolVariants = .none
    var isSelected = false
    var foregroundStyle: Color = .primary
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolVariant(symbolVariant)
                .imageScale(.medium)
                .frame(width: 34, height: 34)
                .background(backgroundFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.2)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
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

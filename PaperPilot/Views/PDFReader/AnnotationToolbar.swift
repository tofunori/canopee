import SwiftUI
import PDFKit
import AppKit

struct AnnotationToolbar: View {
    @Binding var currentTool: AnnotationTool
    @Binding var currentColor: NSColor
    let selectedAnnotation: PDFAnnotation?
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
        HStack(spacing: 4) {
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
            Button(action: {
                editingSlotIndex = nil
                showColorPicker = true
            }) {
                Image(systemName: "plus.circle")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Couleur personnalisée")

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // Selection-dependent actions
            if selectedAnnotation != nil {
                Button(action: onDeleteSelected) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Supprimer l'annotation (⌫)")

                Text("Sélectionné")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Delete all
            Button(action: { showDeleteAllConfirm = true }) {
                Image(systemName: "trash.slash")
            }
            .buttonStyle(.plain)
            .help("Effacer toutes les annotations")
            .confirmationDialog(
                "Effacer toutes les annotations?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Tout effacer", role: .destructive, action: onDeleteAll)
                Button("Annuler", role: .cancel) {}
            }

            // Save button
            Button(action: onSave) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Enregistrer (⌘S)")
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .popover(isPresented: $showColorPicker) {
            ColorPickerPopover(
                selectedColor: $customColor,
                slotIndex: editingSlotIndex,
                onApply: { color in
                    let nsColor = NSColor(color)
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
        Button(action: { currentTool = tool }) {
            Image(systemName: tool.icon)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(currentTool == tool ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(tool.displayName)
    }

    /// Compare two NSColors (approximate, ignoring tiny floating point diffs)
    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.deviceRGB),
              let bc = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(ac.redComponent - bc.redComponent) < 0.01
            && abs(ac.greenComponent - bc.greenComponent) < 0.01
            && abs(ac.blueComponent - bc.blueComponent) < 0.01
    }
}

// MARK: - Color Slot Button

struct ColorSlotButton: View {
    let color: NSColor
    let isSelected: Bool
    let onSelect: () -> Void
    let onCustomize: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 16, height: 16)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.primary, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Changer cette couleur…") {
                onCustomize()
            }
        }
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

            ColorPicker("Couleur", selection: $selectedColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 200)

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

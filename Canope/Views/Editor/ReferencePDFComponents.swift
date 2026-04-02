import SwiftUI
import PDFKit

struct ReferencePDFAnnotationPane: View {
    let document: PDFDocument
    let fileURL: URL
    let fitToWidthTrigger: Bool
    @ObservedObject var state: ReferencePDFUIState
    let onDocumentChanged: () -> Void
    let onMarkupAppearanceNeedsRefresh: () -> Void
    let onSaveNote: () -> Void
    let onCancelNote: () -> Void
    let onAutoSave: () -> Void

    var body: some View {
        PDFKitView(
            document: document,
            currentTool: $state.currentTool,
            currentColor: $state.currentColor,
            selectedAnnotation: $state.selectedAnnotation,
            selectedText: $state.selectedText,
            restoredPageIndex: state.requestedRestorePageIndex,
            onDocumentChanged: {
                onDocumentChanged()
            },
            onCurrentPageChanged: { pageIndex in
                state.lastKnownPageIndex = pageIndex
            },
            onMarkupAppearanceNeedsRefresh: {
                onMarkupAppearanceNeedsRefresh()
            },
            clearSelectionAction: $state.clearSelectionAction,
            undoAction: Binding(
                get: { state.undoAction },
                set: { state.setPDFViewUndoAction($0) }
            )
        )
        .id(state.pdfViewRefreshToken)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        .onChange(of: state.selectedAnnotation) {
            guard let annotation = state.selectedAnnotation, annotation.type == "Text" else { return }
            state.editingNoteText = annotation.contents ?? ""
            state.isEditingNote = true
        }
        .onChange(of: fitToWidthTrigger) {
            state.requestedRestorePageIndex = state.lastKnownPageIndex
            state.pdfViewRefreshToken = UUID()
        }
        .onDisappear {
            if state.hasUnsavedChanges {
                onAutoSave()
            }
        }
        .sheet(isPresented: $state.isEditingNote) {
            NoteEditorSheet(
                text: $state.editingNoteText,
                onSave: onSaveNote,
                onCancel: onCancelNote
            )
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.key == KeyEquivalent("z") && press.modifiers.contains(.command) {
            state.undoAction?()
            return .handled
        }

        if press.key == .escape {
            if !state.selectedText.isEmpty {
                state.clearSelectionAction?()
            } else if state.selectedAnnotation != nil {
                state.selectedAnnotation = nil
            } else {
                state.currentTool = .pointer
            }
            return .handled
        }

        return .ignored
    }
}

struct ReferencePDFToolCluster: View {
    @ObservedObject var state: ReferencePDFUIState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(AnnotationTool.allCases), id: \.id) { tool in
                ReferencePDFToolbarIconButton(
                    systemName: tool.icon,
                    isActive: state.currentTool == tool,
                    help: tool.displayName,
                    action: {
                        state.currentTool = tool
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct ReferencePDFActionsCluster: View {
    @ObservedObject var state: ReferencePDFUIState
    let annotationCount: Int
    let isAnnotationSidebarVisible: Bool
    let onChangeSelectedColor: (NSColor) -> Void
    let onFitToWidth: () -> Void
    let onRefresh: () -> Void
    let onSave: () -> Void
    let onDeleteSelected: () -> Void
    let onDeleteAll: () -> Void
    let onToggleAnnotations: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AnnotationColor.all, id: \.name) { item in
                    Button {
                        onChangeSelectedColor(item.color)
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: annotationColorSwatchImage(item.color))
                                .renderingMode(.original)

                            Text(item.name)

                            if colorsMatch(item.color, state.currentColor) {
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                ReferencePDFToolbarIconLabel(systemName: "paintpalette", isActive: false)
            }
            .buttonStyle(.plain)
            .help("Couleur d'annotation")

            Divider()
                .frame(height: 12)

            ReferencePDFToolbarIconButton(
                systemName: "arrow.left.and.right.square",
                isActive: false,
                help: "Ajuster à la largeur",
                action: onFitToWidth
            )

            ReferencePDFToolbarIconButton(
                systemName: "arrow.clockwise",
                isActive: false,
                help: "Actualiser le PDF de référence",
                action: onRefresh
            )

            ReferencePDFToolbarIconButton(
                systemName: "square.and.arrow.down",
                isActive: state.hasUnsavedChanges,
                help: "Enregistrer les annotations du PDF",
                action: onSave
            )

            ReferencePDFToolbarIconButton(
                systemName: "trash",
                isActive: state.selectedAnnotation != nil,
                activeTint: .red,
                help: "Supprimer l'annotation sélectionnée",
                action: onDeleteSelected
            )
            .disabled(state.selectedAnnotation == nil)

            ReferencePDFToolbarIconButton(
                systemName: "trash.slash",
                isActive: false,
                help: "Effacer toutes les annotations du PDF",
                action: onDeleteAll
            )
            .disabled(annotationCount == 0)

            ReferencePDFToolbarIconButton(
                systemName: "sidebar.right",
                symbolVariant: isAnnotationSidebarVisible ? .none : .slash,
                isActive: isAnnotationSidebarVisible,
                help: "Afficher les annotations PDF",
                action: onToggleAnnotations
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
    let ac = AnnotationColor.normalized(a)
    let bc = AnnotationColor.normalized(b)
    return abs(ac.redComponent - bc.redComponent) < 0.01 &&
           abs(ac.greenComponent - bc.greenComponent) < 0.01 &&
           abs(ac.blueComponent - bc.blueComponent) < 0.01 &&
           abs(ac.alphaComponent - bc.alphaComponent) < 0.01
}

func annotationColorSwatchImage(_ color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    AnnotationColor.normalized(color).setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
    image.unlockFocus()
    return image
}

struct ReferencePDFToolbarIconButton: View {
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
                .frame(width: 16, height: 16)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(backgroundTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(borderTint, lineWidth: borderTint == .clear ? 0 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var iconTint: Color {
        if isActive { return activeTint }
        if isHovered { return .primary }
        return .secondary
    }

    private var backgroundTint: Color {
        if isActive { return activeTint.opacity(0.18) }
        if isHovered { return Color.white.opacity(0.08) }
        return .clear
    }

    private var borderTint: Color {
        if isActive { return activeTint.opacity(0.32) }
        if isHovered { return Color.white.opacity(0.10) }
        return .clear
    }
}

struct ReferencePDFToolbarIconLabel: View {
    let systemName: String
    let isActive: Bool

    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(isActive ? Color.accentColor : (isHovered ? Color.primary : Color.secondary))
            .frame(width: 16, height: 16)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : (isHovered ? Color.white.opacity(0.08) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.32) : (isHovered ? Color.white.opacity(0.10) : .clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

import SwiftUI
import PDFKit

struct ReferencePDFAnnotationPane: View {
    let document: PDFDocument
    let fileURL: URL
    let fitToWidthTrigger: Bool
    let isBridgeCommandTargetActive: Bool
    @ObservedObject var state: ReferencePDFUIState
    let onDocumentChanged: () -> Void
    let onMarkupAppearanceNeedsRefresh: () -> Void
    let onSaveNote: () -> Void
    let onCancelNote: () -> Void
    let onAutoSave: () -> Void

    var body: some View {
        PDFKitView(
            document: document,
            fileURL: fileURL,
            currentTool: $state.currentTool,
            currentColor: $state.currentColor,
            selectedAnnotation: $state.selectedAnnotation,
            selectedText: $state.selectedText,
            restoredPageIndex: state.requestedRestorePageIndex,
            searchState: state.searchState,
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
            ),
            fitToWidthAction: $state.fitToWidthAction,
            applyBridgeAnnotation: Binding(
                get: { state.applyBridgeAnnotationAction },
                set: { state.setPDFViewApplyBridgeAnnotation($0) }
            ),
            onUserInteraction: {
                BridgeCommandRouter.shared.setPreferredHandler(id: bridgeCommandTargetID)
            }
        )
        .id(state.pdfViewRefreshToken)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        .onAppear {
            refreshBridgeCommandTarget()
        }
        .onChange(of: state.selectedAnnotation) {
            guard let annotation = state.selectedAnnotation, annotation.type == "Text" else { return }
            state.editingNoteText = annotation.contents ?? ""
            state.isEditingNote = true
        }
        .onChange(of: fitToWidthTrigger) {
            state.fitToWidthAction?()
        }
        .onChange(of: isBridgeCommandTargetActive) {
            refreshBridgeCommandTarget()
        }
        .onChange(of: state.bridgeCommandRegistrationToken) {
            refreshBridgeCommandTarget()
        }
        .onDisappear {
            BridgeCommandRouter.shared.removeActiveHandler(id: bridgeCommandTargetID)
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

    private var bridgeCommandTargetID: String {
        "reference-pdf:\(fileURL.path)"
    }

    private func refreshBridgeCommandTarget() {
        guard isBridgeCommandTargetActive else {
            BridgeCommandRouter.shared.removeActiveHandler(id: bridgeCommandTargetID)
            return
        }

        BridgeCommandRouter.shared.setActiveHandler(id: bridgeCommandTargetID) { command in
            _ = BridgeCommandWatcher.handleCommand(
                command,
                document: document,
                applyBridgeAnnotation: state.applyBridgeAnnotationAction
            )
        }
        BridgeCommandRouter.shared.setPreferredHandler(id: bridgeCommandTargetID)
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
    let title: String
    @ObservedObject var state: ReferencePDFUIState

    var body: some View {
        AppChromeToolbarCluster(zone: .primary, title: title) {
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
        }
    }
}

struct ReferencePDFActionsCluster: View {
    @State private var showDeleteAllConfirm = false
    let title: String
    @ObservedObject var state: ReferencePDFUIState
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
        AppChromeToolbarCluster(zone: .primary, title: title) {
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
                    ReferencePDFToolbarIconLabel(systemName: "eyedropper.halffull", isActive: false)
                }
                .buttonStyle(.plain)
                .help("Couleur d'annotation")

                AppChromeDivider(role: .inset, axis: .vertical, inset: 4)

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

                Menu {
                    AppChromeAnnotationExportMenuItems(
                        activeMarkdownFileName: activeMarkdownFileName,
                        companionFileName: companionExportFileName,
                        onExportToActiveMarkdown: onExportToActiveMarkdown,
                        onExportToCompanion: onExportToCompanionMarkdown,
                        onChooseDestination: onExportToChosenMarkdownFile
                    )
                } label: {
                    ReferencePDFToolbarIconLabel(
                        systemName: "square.and.arrow.up.on.square",
                        isActive: false,
                        helpText: "Exporter les annotations en Markdown"
                    )
                }
                .buttonStyle(.plain)
                .help("Exporter les annotations en Markdown")

                AppChromeDivider(role: .inset, axis: .vertical, inset: 4)

                if state.selectedAnnotation != nil {
                    ReferencePDFToolbarIconButton(
                        systemName: "trash",
                        isActive: true,
                        activeTint: AppChromePalette.danger,
                        help: "Supprimer l'annotation sélectionnée",
                        action: onDeleteSelected
                    )
                }

                ReferencePDFToolbarIconButton(
                    systemName: "trash.slash",
                    isActive: false,
                    help: "Effacer toutes les annotations du PDF",
                    action: { showDeleteAllConfirm = true }
                )
                .confirmationDialog(
                    "Effacer toutes les annotations du PDF?",
                    isPresented: $showDeleteAllConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Tout effacer", role: .destructive, action: onDeleteAll)
                    Button("Annuler", role: .cancel) {}
                }
                .disabled(annotationCount == 0)

                AppChromeDivider(role: .inset, axis: .vertical, inset: 4)

                ReferencePDFToolbarIconButton(
                    systemName: "sidebar.right",
                    symbolVariant: isAnnotationSidebarVisible ? .none : .slash,
                    isActive: isAnnotationSidebarVisible,
                    activeTint: AppChromePalette.info,
                    help: "Afficher les annotations PDF",
                    action: onToggleAnnotations
                )
            }
        }
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

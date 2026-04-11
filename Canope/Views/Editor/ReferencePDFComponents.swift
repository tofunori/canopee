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
        AppChromeToolbarCluster(zone: .primary, title: title, collapsible: true) {
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

struct ReferencePDFColorCluster: View {
    @ObservedObject var state: ReferencePDFUIState
    let onChangeSelectedColor: (NSColor) -> Void

    @State private var favoriteColors: [NSColor] = AnnotationColor.loadFavorites()
    @State private var customColor: Color = .yellow
    @State private var editingSlotIndex: Int? = nil
    @State private var showColorPicker = false

    var body: some View {
        Group {
            if isVisible {
                AppChromeToolbarCluster(zone: .primary, title: AppStrings.colors, collapsible: true) {
                    HStack(spacing: 6) {
                        ForEach(Array(favoriteColors.indices), id: \.self) { index in
                            ColorSlotButton(
                                color: favoriteColors[index],
                                isSelected: colorsMatch(state.currentColor, favoriteColors[index]),
                                onSelect: {
                                    applyColor(favoriteColors[index])
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
                            helpText: AppStrings.customColor,
                            action: {
                                editingSlotIndex = nil
                                customColor = Color(nsColor: state.currentColor)
                                showColorPicker = true
                            }
                        )
                    }
                }
                .popover(isPresented: $showColorPicker) {
                    ColorPickerPopover(
                        selectedColor: $customColor,
                        slotIndex: editingSlotIndex,
                        onApply: { color in
                            let nsColor = AnnotationColor.normalized(NSColor(color))
                            if let index = editingSlotIndex, favoriteColors.indices.contains(index) {
                                favoriteColors[index] = nsColor
                                AnnotationColor.saveFavorites(favoriteColors)
                            }
                            applyColor(nsColor)
                            showColorPicker = false
                        },
                        onCancel: {
                            showColorPicker = false
                        }
                    )
                }
            }
        }
    }

    private var isVisible: Bool {
        state.currentTool != .pointer || state.selectedAnnotation != nil
    }

    private func applyColor(_ color: NSColor) {
        let normalizedColor = AnnotationColor.normalized(color)
        state.currentColor = normalizedColor
        if state.selectedAnnotation != nil {
            onChangeSelectedColor(normalizedColor)
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
        AppChromeToolbarCluster(zone: .primary, title: title, collapsible: true) {
            HStack(spacing: 6) {
                ReferencePDFToolbarIconButton(
                    systemName: "arrow.left.and.right.square",
                    isActive: false,
                    help: "Ajuster à la largeur",
                    action: onFitToWidth
                )

                ReferencePDFToolbarIconButton(
                    systemName: "arrow.clockwise",
                    isActive: false,
                    help: "Refresh reference PDF",
                    action: onRefresh
                )

                ReferencePDFToolbarIconButton(
                    systemName: "square.and.arrow.down",
                    isActive: state.hasUnsavedChanges,
                    help: "Save PDF annotations",
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
                        helpText: AppStrings.exportAnnotationsMarkdown
                    )
                }
                .buttonStyle(.plain)
                .help(AppStrings.exportAnnotationsMarkdown)

                AppChromeDivider(role: .inset, axis: .vertical, inset: 4)

                if state.selectedAnnotation != nil {
                    ReferencePDFToolbarIconButton(
                        systemName: "trash",
                        isActive: true,
                        activeTint: AppChromePalette.danger,
                        help: "Delete selected annotation",
                        action: onDeleteSelected
                    )
                }

                ReferencePDFToolbarIconButton(
                    systemName: "trash.slash",
                    isActive: false,
                    help: "Delete all PDF annotations",
                    action: { showDeleteAllConfirm = true }
                )
                .confirmationDialog(
                    "Delete all PDF annotations?",
                    isPresented: $showDeleteAllConfirm,
                    titleVisibility: .visible
                ) {
                    Button(AppStrings.deleteAll, role: .destructive, action: onDeleteAll)
                    Button(AppStrings.cancel, role: .cancel) {}
                }
                .disabled(annotationCount == 0)

                AppChromeDivider(role: .inset, axis: .vertical, inset: 4)

                ReferencePDFToolbarIconButton(
                    systemName: "sidebar.right",
                    symbolVariant: isAnnotationSidebarVisible ? .none : .slash,
                    isActive: isAnnotationSidebarVisible,
                    activeTint: AppChromePalette.info,
                    help: "Show PDF annotations",
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

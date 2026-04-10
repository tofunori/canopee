import SwiftUI
import PDFKit

extension UnifiedEditorView {
    /// The PDF document for the currently selected pane tab
    var displayedPDF: PDFDocument? {
        switch selectedPdfTab {
        case .compiled: return compiledPDF
        case .reference(let id): return workspaceState.referencePDFs[id]
        }
    }

    var activeReferencePDFID: UUID? {
        if case .reference(let id) = selectedPdfTab { return id }
        return nil
    }

    var activeReferencePDFDocument: PDFDocument? {
        guard let id = activeReferencePDFID else { return nil }
        return workspaceState.referencePDFs[id]
    }

    var activeReferencePDFState: ReferencePDFUIState? {
        guard let id = activeReferencePDFID else { return nil }
        return workspaceState.referencePDFUIStates[id]
    }

    var isShowingReference: Bool {
        if case .reference = selectedPdfTab { return true }
        return false
    }

    var activeReferenceAnnotationCount: Int {
        guard let document = activeReferencePDFDocument else { return 0 }
        return (0..<document.pageCount).reduce(0) { count, pageIndex in
            guard let page = document.page(at: pageIndex) else { return count }
            return count + page.annotations.filter { annotation in
                annotation.type != "Link" && annotation.type != "Widget"
            }.count
        }
    }

    var activeErrorCount: Int {
        errors.filter { !$0.isWarning }.count
    }

    func paperFor(_ id: UUID) -> Paper? {
        allPapers.first { $0.id == id }
    }

    var pdfPane: some View {
        VStack(spacing: 0) {
            if pdfPaneTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(pdfPaneTabs, id: \.self) { tab in
                            pdfTabButton(tab)
                        }
                    }
                }
                .frame(height: AppChromeMetrics.tabBarHeight)
                .background(AppChromePalette.surfaceSubbar)
                AppChromeDivider(role: .panel)
            }

            ZStack {
                Group {
                    if let pdf = compiledPDF {
                        PDFPreviewView(
                            document: pdf,
                            syncTarget: documentMode == .latex && selectedPdfTab == .compiled ? syncTarget : nil,
                            onInverseSync: documentMode == .latex ? { result in inverseSyncResult = result } : nil,
                            allowsInverseSync: documentMode == .latex,
                            restoredPageIndex: documentState.compiledPDFRequestedRestorePageIndex,
                            fitToWidthTrigger: selectedPdfTab == .compiled ? fitToWidthTrigger : false,
                            searchState: compiledPDFSearchState,
                            onCurrentPageChanged: { pageIndex in
                                documentState.compiledPDFLastKnownPageIndex = pageIndex
                            }
                        )
                    } else {
                        ContentUnavailableView(
                            documentMode.emptyPreviewTitle,
                            systemImage: "doc.text",
                            description: Text(documentMode.emptyPreviewDescription)
                        )
                    }
                }
                .opacity(selectedPdfTab == .compiled ? 1 : 0)
                .allowsHitTesting(selectedPdfTab == .compiled)

                ForEach(pdfPaneTabs.compactMap { tab -> UUID? in
                    if case .reference(let id) = tab { return id } else { return nil }
                }, id: \.self) { id in
                    Group {
                        if let pdf = workspaceState.referencePDFs[id],
                           let state = workspaceState.referencePDFUIStates[id],
                           let paper = paperFor(id) {
                            ReferencePDFAnnotationPane(
                                document: pdf,
                                fileURL: paper.fileURL,
                                fitToWidthTrigger: selectedPdfTab == .reference(id) ? fitToWidthTrigger : false,
                                isBridgeCommandTargetActive: selectedPdfTab == .reference(id),
                                state: state,
                                onDocumentChanged: {
                                    referencePDFDocumentDidChange(id: id)
                                },
                                onMarkupAppearanceNeedsRefresh: {
                                    reloadReferencePDFDocument(id: id)
                                },
                                onSaveNote: {
                                    saveReferenceAnnotationNote(for: id)
                                },
                                onCancelNote: {
                                    cancelReferenceAnnotationNoteEdit(for: id)
                                },
                                onAutoSave: {
                                    saveReferencePDF(id: id)
                                }
                            )
                        } else {
                            ContentUnavailableView(
                                "PDF introuvable",
                                systemImage: "exclamationmark.triangle",
                                description: Text("Le fichier PDF n'a pas pu être chargé")
                            )
                        }
                    }
                    .opacity(selectedPdfTab == .reference(id) ? 1 : 0)
                    .allowsHitTesting(selectedPdfTab == .reference(id))
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 320, maxWidth: .infinity)
    }

    @ViewBuilder
    func pdfTabButton(_ tab: LaTeXEditorPdfPaneTab) -> some View {
        let isSelected = tab == selectedPdfTab
        HStack(spacing: 4) {
            Button {
                AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                    selectPdfTab(tab)
                }
            } label: {
                HStack(spacing: 4) {
                    switch tab {
                    case .compiled:
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                        Text(documentMode.compiledTabTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    case .reference(let id):
                        Image(systemName: "book")
                            .font(.system(size: 9))
                        Text(paperFor(id)?.authorsShort ?? "Article")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if case .reference = tab {
                Button {
                    closePdfTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(AppChromePalette.tabFill(isSelected: isSelected, isHovered: false, role: .reference))
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(AppChromePalette.tabIndicator(for: .reference))
                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
                    .matchedGeometryEffect(id: "pdf-tab-indicator", in: pdfTabIndicatorNamespace)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }
}

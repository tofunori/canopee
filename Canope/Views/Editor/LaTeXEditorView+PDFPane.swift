import SwiftUI
import PDFKit

// MARK: - PDF Pane

extension LaTeXEditorView {
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

    func paperFor(_ id: UUID) -> Paper? {
        allPapers.first { $0.id == id }
    }

    var pdfPane: some View {
        VStack(spacing: 0) {
            // Tab bar (only shown when more than just compiled)
            if pdfPaneTabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(pdfPaneTabs, id: \.self) { tab in
                            pdfTabButton(tab)
                        }
                    }
                }
                .frame(height: EditorChromeMetrics.tabBarHeight)
                .background(.bar)
                Divider()
            }

            // PDF content — each tab keeps its own PDFView to preserve scroll position
            ZStack {
                // Compiled PDF tab
                Group {
                    if let pdf = compiledPDF {
                        PDFPreviewView(
                            document: pdf,
                            syncTarget: selectedPdfTab == .compiled ? syncTarget : nil,
                            onInverseSync: { result in inverseSyncResult = result },
                            fitToWidthTrigger: selectedPdfTab == .compiled ? fitToWidthTrigger : false
                        )
                    } else {
                        ContentUnavailableView(
                            "Pas encore compilé",
                            systemImage: "doc.text",
                            description: Text("⌘B pour compiler")
                        )
                    }
                }
                .opacity(selectedPdfTab == .compiled ? 1 : 0)
                .allowsHitTesting(selectedPdfTab == .compiled)

                // Reference PDF tabs
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
    func pdfTabButton(_ tab: PdfPaneTab) -> some View {
        let isSelected = tab == selectedPdfTab
        HStack(spacing: 4) {
            switch tab {
            case .compiled:
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text("PDF compilé")
                    .font(.system(size: 11))
                    .lineLimit(1)
            case .reference(let id):
                Image(systemName: "book")
                    .font(.system(size: 9))
                Text(paperFor(id)?.authorsShort ?? "Article")
                    .font(.system(size: 11))
                    .lineLimit(1)
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            // Only switch tab if this tab still exists (not just closed by ✕)
            if pdfPaneTabs.contains(tab) {
                switch tab {
                case .compiled:
                    workspaceState.selectedReferencePaperID = nil
                case .reference(let id):
                    workspaceState.selectedReferencePaperID = id
                }
            }
        }
    }
}

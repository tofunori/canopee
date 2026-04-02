import SwiftUI
import PDFKit

// MARK: - Reference PDF Management

extension LaTeXEditorView {
    func openReference(_ paper: Paper) {
        let tab = PdfPaneTab.reference(paper.id)
        if pdfPaneTabs.contains(tab) {
            workspaceState.selectedReferencePaperID = paper.id
            return
        }
        guard let pdf = PDFDocument(url: paper.fileURL) else { return }
        AnnotationService.normalizeDocumentAnnotations(in: pdf)
        workspaceState.referencePDFs[paper.id] = pdf
        if workspaceState.referencePDFUIStates[paper.id] == nil {
            workspaceState.referencePDFUIStates[paper.id] = ReferencePDFUIState()
        }
        workspaceState.referencePaperIDs.append(paper.id)
        workspaceState.selectedReferencePaperID = paper.id
        if splitLayout == .editorOnly {
            layoutBeforeReference = .editorOnly
            splitLayout = .horizontal
            showPDFPreview = true
        }
    }

    func closePdfTab(_ tab: PdfPaneTab) {
        guard case .reference(let id) = tab else { return }
        saveReferencePDF(id: id)
        workspaceState.referencePaperIDs.removeAll { $0 == id }
        workspaceState.referencePDFs.removeValue(forKey: id)
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates.removeValue(forKey: id)
        if selectedPdfTab == tab {
            workspaceState.selectedReferencePaperID = nil
        }
        // Restore layout only if no more references AND user hasn't changed layout since
        if pdfPaneTabs == [.compiled],
           let previous = layoutBeforeReference,
           compiledPDF == nil {
            splitLayout = previous
            showPDFPreview = previous != .editorOnly
            layoutBeforeReference = nil
        }
    }

    func fitToWidth() {
        fitToWidthTrigger.toggle()
    }

    func refreshCurrentReference() {
        guard let id = activeReferencePDFID else { return }
        reloadReferencePDFDocument(id: id)
    }

    func referencePDFDocumentDidChange(id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.hasUnsavedChanges = true
        state.annotationRefreshToken = UUID()
        scheduleReferencePDFAutoSave(for: id, delay: preferredReferencePDFAutoSaveDelay(for: state))
    }

    func preferredReferencePDFAutoSaveDelay(for state: ReferencePDFUIState) -> TimeInterval {
        if state.selectedAnnotation?.isTextBoxAnnotation == true || state.currentTool == .textBox {
            return 0.9
        }
        return 0.25
    }

    func scheduleReferencePDFAutoSave(for id: UUID, delay: TimeInterval) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak state] in
            state?.pendingSaveWorkItem = nil
            saveReferencePDF(id: id)
        }

        state.pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func saveCurrentReferencePDF() {
        guard let id = activeReferencePDFID else { return }
        saveReferencePDF(id: id)
    }

    func saveReferencePDF(id: UUID) {
        guard let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }

        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem = nil

        if AnnotationService.save(document: document, to: paper.fileURL) {
            workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges = false
        }
    }

    func reloadReferencePDFDocument(id: UUID) {
        guard let paper = paperFor(id) else { return }
        let state = workspaceState.referencePDFUIStates[id]
        state?.selectedAnnotation = nil
        state?.requestedRestorePageIndex = state?.lastKnownPageIndex

        guard let data = try? Data(contentsOf: paper.fileURL),
              let refreshedDocument = PDFDocument(data: data) else {
            if let loadedDocument = PDFDocument(url: paper.fileURL) {
                AnnotationService.normalizeDocumentAnnotations(in: loadedDocument)
                workspaceState.referencePDFs[id] = loadedDocument
            }
            state?.annotationRefreshToken = UUID()
            state?.pdfViewRefreshToken = UUID()
            return
        }

        AnnotationService.normalizeDocumentAnnotations(in: refreshedDocument)
        workspaceState.referencePDFs[id] = refreshedDocument
        state?.annotationRefreshToken = UUID()
        state?.pdfViewRefreshToken = UUID()
    }

    func deleteSelectedReferenceAnnotation() {
        guard let id = activeReferencePDFID,
              let annotation = activeReferencePDFState?.selectedAnnotation else { return }
        deleteReferenceAnnotation(annotation, in: id)
    }

    func deleteReferenceAnnotation(_ annotation: PDFAnnotation, in id: UUID) {
        guard let page = annotation.page else { return }
        let state = workspaceState.referencePDFUIStates[id]
        let wasSelected = state?.selectedAnnotation === annotation

        state?.pushUndoAction { [weak state] in
            page.addAnnotation(annotation)
            if wasSelected {
                state?.selectedAnnotation = annotation
            }
            state?.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        if wasSelected {
            state?.selectedAnnotation = nil
        }
        page.removeAnnotation(annotation)
        state?.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    func deleteAllReferenceAnnotations() {
        guard let id = activeReferencePDFID,
              let document = activeReferencePDFDocument else { return }

        var removedAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.type != "Link" && annotation.type != "Widget" {
                removedAnnotations.append((page: page, annotation: annotation))
                page.removeAnnotation(annotation)
            }
        }

        workspaceState.referencePDFUIStates[id]?.pushUndoAction {
            for (page, annotation) in removedAnnotations {
                page.addAnnotation(annotation)
            }
            workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        activeReferencePDFState?.selectedAnnotation = nil
        workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    func changeSelectedReferenceAnnotationColor(_ color: NSColor) {
        guard let id = activeReferencePDFID,
              let state = activeReferencePDFState else { return }

        guard let annotation = state.selectedAnnotation else { return }
        let previousCurrentColor = state.currentColor
        let previousAnnotationColor = annotation.color

        state.pushUndoAction { [weak state] in
            guard let state else { return }
            state.currentColor = previousCurrentColor
            if annotation.isTextBoxAnnotation {
                annotation.setTextBoxFillColor(previousAnnotationColor)
            } else {
                annotation.color = previousAnnotationColor
            }
            state.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        state.currentColor = color
        if annotation.isTextBoxAnnotation {
            annotation.setTextBoxFillColor(AnnotationColor.annotationColor(color, for: "FreeText"))
        } else {
            annotation.color = AnnotationColor.annotationColor(color, for: annotation.type ?? "")
        }

        workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    func beginEditingReferenceAnnotationNote(_ annotation: PDFAnnotation, in id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.selectedAnnotation = annotation
        state.editingNoteText = annotation.contents ?? ""
        state.isEditingNote = true
    }

    func saveReferenceAnnotationNote(for id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id],
              let annotation = state.selectedAnnotation else { return }
        let previousContents = annotation.contents ?? ""
        let newContents = state.editingNoteText

        state.pushUndoAction { [weak state] in
            guard let state else { return }
            annotation.contents = previousContents
            state.selectedAnnotation = annotation
            state.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        annotation.contents = newContents
        state.isEditingNote = false
        state.annotationRefreshToken = UUID()
        referencePDFDocumentDidChange(id: id)
    }

    func cancelReferenceAnnotationNoteEdit(for id: UUID) {
        workspaceState.referencePDFUIStates[id]?.isEditingNote = false
    }
}

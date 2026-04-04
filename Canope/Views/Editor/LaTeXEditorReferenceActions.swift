import AppKit
import SwiftUI
import PDFKit

extension UnifiedEditorView {
    func openReference(_ paper: Paper) {
        let tab = LaTeXEditorPdfPaneTab.reference(paper.id)
        if pdfPaneTabs.contains(tab) {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = paper.id
            }
            writeReferencePaperContext(for: paper.id)
            return
        }
        guard let pdf = PDFDocument(url: paper.fileURL) else { return }
        AnnotationService.normalizeDocumentAnnotations(in: pdf)
        workspaceState.referencePDFs[paper.id] = pdf
        if workspaceState.referencePDFUIStates[paper.id] == nil {
            workspaceState.referencePDFUIStates[paper.id] = ReferencePDFUIState()
        }
        workspaceState.referencePaperIDs.append(paper.id)
        AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
            workspaceState.selectedReferencePaperID = paper.id
        }
        writeReferencePaperContext(for: paper.id)
        if splitLayout == .editorOnly {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                layoutBeforeReference = .editorOnly
                splitLayout = .horizontal
                showPDFPreview = true
            }
        }
    }

    func selectPdfTab(_ tab: LaTeXEditorPdfPaneTab) {
        switch tab {
        case .compiled:
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = nil
            }
            invalidateReferencePaperContextWrites()
        case .reference(let id):
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = id
            }
            writeReferencePaperContext(for: id)
        }
    }

    func closePdfTab(_ tab: LaTeXEditorPdfPaneTab) {
        guard case .reference(let id) = tab else { return }
        let pendingSave = workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges == true
        let documentToSave = workspaceState.referencePDFs[id]
        let fileURLToSave = paperFor(id)?.fileURL
        let remainingReferenceIDs = workspaceState.referencePaperIDs.filter { $0 != id }

        workspaceState.referencePaperIDs.removeAll { $0 == id }
        workspaceState.referencePDFs.removeValue(forKey: id)
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates.removeValue(forKey: id)
        if selectedPdfTab == tab || workspaceState.selectedReferencePaperID == id {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion) {
                workspaceState.selectedReferencePaperID = remainingReferenceIDs.first
            }
            if let nextID = remainingReferenceIDs.first {
                writeReferencePaperContext(for: nextID)
            } else {
                invalidateReferencePaperContextWrites()
            }
        }
        if pdfPaneTabs == [.compiled],
           let previous = layoutBeforeReference,
           compiledPDF == nil {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                splitLayout = previous
                showPDFPreview = previous != .editorOnly
                layoutBeforeReference = nil
            }
        }

        guard pendingSave,
              let documentToSave,
              let fileURLToSave else { return }

        DispatchQueue.main.async {
            _ = AnnotationService.save(document: documentToSave, to: fileURLToSave)
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
        if activeReferencePDFID == id {
            writeReferencePaperContext(for: id)
        }
    }

    func writeReferencePaperContext(for id: UUID) {
        guard let paper = paperFor(id) else { return }
        let title = paper.title
        let authors = paper.authors
        let year = paper.year.map(String.init) ?? "unknown"
        let journal = paper.journal ?? "unknown"
        let doi = paper.doi ?? "unknown"
        let fileURL = paper.fileURL
        let writeID = UUID()

        referenceContextWriteID = writeID

        DispatchQueue.global(qos: .utility).async {
            guard let snapshotDocument = PDFDocument(url: fileURL) else { return }

            var fullText = """
            ========================================
            CURRENTLY OPEN PAPER IN CANOPÉE
            ========================================
            Title: \(title)
            Authors: \(authors)
            Year: \(year)
            Journal: \(journal)
            DOI: \(doi)
            Pages: \(snapshotDocument.pageCount)
            ========================================

            """

            for index in 0..<snapshotDocument.pageCount {
                if let page = snapshotDocument.page(at: index), let text = page.string {
                    fullText += "--- Page \(index + 1) ---\n\(text)\n\n"
                }
            }

            let shouldWrite = DispatchQueue.main.sync {
                referenceContextWriteID == writeID && activeReferencePDFID == id
            }
            guard shouldWrite else { return }

            CanopeContextFiles.writePaper(fullText)
            CanopeContextFiles.writeIDESelectionState(
                ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: fileURL)
            )
            CanopeContextFiles.clearLegacySelectionMirror()
        }
    }

    func invalidateReferencePaperContextWrites() {
        referenceContextWriteID = UUID()
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
        changeReferenceAnnotationColor(annotation, to: color, in: id)
    }

    func changeReferenceAnnotationColor(_ annotation: PDFAnnotation, to color: NSColor, in id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }

        let previousCurrentColor = state.currentColor
        let previousAnnotationColor = annotation.isTextBoxAnnotation ? annotation.textBoxFillColor : annotation.color

        state.pushUndoAction { [weak state] in
            guard let state else { return }
            state.currentColor = previousCurrentColor
            AnnotationService.applyColor(previousAnnotationColor, to: annotation)
            state.selectedAnnotation = annotation
            state.annotationRefreshToken = UUID()
            referencePDFDocumentDidChange(id: id)
        }

        state.currentColor = color
        state.selectedAnnotation = annotation
        AnnotationService.applyColor(color, to: annotation)
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

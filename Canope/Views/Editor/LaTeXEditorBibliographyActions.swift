import Foundation

extension UnifiedEditorView {
    var availableReferencePapers: [Paper] {
        var seen = Set<UUID>()
        let orderedIDs = (workspaceState.referencePaperIDs + openPaperIDs).filter { seen.insert($0).inserted }
        return orderedIDs.compactMap(paperFor)
    }

    var selectedCitationPaper: Paper? {
        if let id = workspaceState.selectedReferencePaperID,
           let paper = paperFor(id) {
            return paper
        }
        if let firstID = workspaceState.referencePaperIDs.first,
           let paper = paperFor(firstID) {
            return paper
        }
        return nil
    }

    var canInsertCitationIntoCurrentEditor: Bool {
        fileURL.pathExtension.lowercased() == "tex"
    }

    func syncBibliographyCommandRouter() {
        guard isActive else {
            BibliographyCommandRouter.shared.clearActions()
            return
        }

        guard selectedCitationPaper != nil else {
            BibliographyCommandRouter.shared.setEditorActions(
                copyCiteKey: nil,
                copyBibTeX: nil,
                appendToBibliography: nil,
                insertCitation: nil
            )
            return
        }

        BibliographyCommandRouter.shared.setEditorActions(
            copyCiteKey: { copySelectedReferenceCiteKey() },
            copyBibTeX: { copySelectedReferenceBibTeX() },
            appendToBibliography: { appendSelectedReferenceToBibliography() },
            insertCitation: canInsertCitationIntoCurrentEditor ? { insertCitationFromSelectedReference() } : nil
        )
    }

    func copySelectedReferenceCiteKey() {
        guard let record = selectedCitationRecord(assignMissingKeys: true) else { return }
        ClipboardCitationService.copy(record.citeKey)
        syncBibliographyCommandRouter()
    }

    func copySelectedReferenceBibTeX() {
        guard let record = selectedCitationRecord(assignMissingKeys: true) else { return }
        ClipboardCitationService.copy(BibTeXSerializer.serialize(record))
        syncBibliographyCommandRouter()
    }

    func appendSelectedReferenceToBibliography() {
        guard let paper = selectedCitationPaper else { return }
        _ = BibliographyExportService.appendToProjectBibliography(
            papers: [paper],
            allPapers: allPapers,
            projectRoot: projectRoot
        )
        syncBibliographyCommandRouter()
    }

    func insertCitationFromSelectedReference() {
        guard canInsertCitationIntoCurrentEditor,
              let record = selectedCitationRecord(assignMissingKeys: true) else { return }
        let citation = ClipboardCitationService.latexCitation(for: [record.citeKey])
        NotificationCenter.default.post(
            name: .editorInsertText,
            object: nil,
            userInfo: [
                "text": citation,
                "filePath": fileURL.path
            ]
        )
        syncBibliographyCommandRouter()
    }

    private func selectedCitationRecord(assignMissingKeys: Bool) -> BibliographicRecord? {
        guard let paper = selectedCitationPaper else { return nil }
        return BibliographyExportService.records(
            for: [paper],
            allPapers: allPapers,
            assignMissingKeys: assignMissingKeys
        ).first
    }
}

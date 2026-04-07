import Foundation

@MainActor
final class BibliographyCommandRouter: ObservableObject {
    static let shared = BibliographyCommandRouter()

    @Published private(set) var canCopyCiteKey = false
    @Published private(set) var canCopyBibTeX = false
    @Published private(set) var canExportBibTeX = false
    @Published private(set) var canAppendToBibliography = false
    @Published private(set) var canInsertCitation = false

    private var copyCiteKeyAction: (() -> Void)?
    private var copyBibTeXAction: (() -> Void)?
    private var exportBibTeXAction: (() -> Void)?
    private var appendToBibliographyAction: (() -> Void)?
    private var insertCitationAction: (() -> Void)?

    func setLibraryActions(
        copyCiteKey: (() -> Void)?,
        copyBibTeX: (() -> Void)?,
        exportBibTeX: (() -> Void)?,
        appendToBibliography: (() -> Void)?
    ) {
        copyCiteKeyAction = copyCiteKey
        copyBibTeXAction = copyBibTeX
        exportBibTeXAction = exportBibTeX
        appendToBibliographyAction = appendToBibliography
        canCopyCiteKey = copyCiteKey != nil
        canCopyBibTeX = copyBibTeX != nil
        canExportBibTeX = exportBibTeX != nil
        canAppendToBibliography = appendToBibliography != nil
        canInsertCitation = false
        insertCitationAction = nil
    }

    func setEditorActions(
        copyCiteKey: (() -> Void)?,
        copyBibTeX: (() -> Void)?,
        appendToBibliography: (() -> Void)?,
        insertCitation: (() -> Void)?
    ) {
        copyCiteKeyAction = copyCiteKey
        copyBibTeXAction = copyBibTeX
        exportBibTeXAction = nil
        appendToBibliographyAction = appendToBibliography
        insertCitationAction = insertCitation
        canCopyCiteKey = copyCiteKey != nil
        canCopyBibTeX = copyBibTeX != nil
        canExportBibTeX = false
        canAppendToBibliography = appendToBibliography != nil
        canInsertCitation = insertCitation != nil
    }

    func clearActions() {
        copyCiteKeyAction = nil
        copyBibTeXAction = nil
        exportBibTeXAction = nil
        appendToBibliographyAction = nil
        insertCitationAction = nil
        canCopyCiteKey = false
        canCopyBibTeX = false
        canExportBibTeX = false
        canAppendToBibliography = false
        canInsertCitation = false
    }

    func copyCiteKey() {
        copyCiteKeyAction?()
    }

    func copyBibTeX() {
        copyBibTeXAction?()
    }

    func exportBibTeX() {
        exportBibTeXAction?()
    }

    func appendToBibliography() {
        appendToBibliographyAction?()
    }

    func insertCitation() {
        insertCitationAction?()
    }
}

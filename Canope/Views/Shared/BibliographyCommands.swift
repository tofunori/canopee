import SwiftUI

struct BibliographyCommands: Commands {
    @ObservedObject var router: BibliographyCommandRouter

    var body: some Commands {
        CommandMenu("Bibliography") {
            Button("Copy Cite Key") {
                router.copyCiteKey()
            }
            .disabled(!router.canCopyCiteKey)

            Button("Copy BibTeX") {
                router.copyBibTeX()
            }
            .disabled(!router.canCopyBibTeX)

            Button("Insert Citation") {
                router.insertCitation()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!router.canInsertCitation)

            Divider()

            Button("Export Selection as BibTeX") {
                router.exportBibTeX()
            }
            .disabled(!router.canExportBibTeX)

            Button("Append to references.bib") {
                router.appendToBibliography()
            }
            .disabled(!router.canAppendToBibliography)
        }
    }
}

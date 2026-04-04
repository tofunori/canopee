import AppKit
import PDFKit
import UniformTypeIdentifiers

extension UnifiedEditorView {
    var activeMarkdownExportFileName: String? {
        documentMode == .markdown ? fileURL.lastPathComponent : nil
    }

    var activeReferenceCompanionExportFileName: String {
        guard let id = activeReferencePDFID,
              let paper = paperFor(id) else {
            return PDFAnnotationMarkdownExporter.companionURL(for: previewPDFURL).lastPathComponent
        }

        return companionExportFileName(for: .reference(pdfURL: paper.fileURL))
    }

    var compiledPDFCompanionExportFileName: String {
        companionExportFileName(for: .compiled(documentURL: fileURL, pdfURL: previewPDFURL))
    }

    var exportCompiledAnnotationsToActiveMarkdownAction: (() -> Void)? {
        guard documentMode == .markdown else { return nil }
        return { exportCompiledPDFAnnotationsToActiveMarkdown() }
    }

    var exportActiveReferenceAnnotationsToActiveMarkdownAction: (() -> Void)? {
        guard documentMode == .markdown else { return nil }
        return { exportActiveReferencePDFAnnotationsToActiveMarkdown() }
    }

    func exportCompiledPDFAnnotationsToActiveMarkdown() {
        guard let document = compiledPDF,
              let target = activeMarkdownExportTarget else { return }
        exportPDFAnnotationsToMarkdown(
            document: document,
            source: .compiled(documentURL: fileURL, pdfURL: previewPDFURL),
            target: target
        )
    }

    func exportCompiledPDFAnnotationsToCompanionMarkdown() {
        guard let document = compiledPDF else { return }
        exportPDFAnnotationsToMarkdown(
            document: document,
            source: .compiled(documentURL: fileURL, pdfURL: previewPDFURL),
            target: .companionFile(PDFAnnotationMarkdownExporter.companionURL(for: fileURL))
        )
    }

    func chooseCompiledPDFAnnotationsMarkdownDestination() {
        guard let document = compiledPDF else { return }
        chooseMarkdownExportDestination(
            document: document,
            source: .compiled(documentURL: fileURL, pdfURL: previewPDFURL)
        )
    }

    func exportActiveReferencePDFAnnotationsToActiveMarkdown() {
        guard let id = activeReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id),
              let target = activeMarkdownExportTarget else { return }

        exportPDFAnnotationsToMarkdown(
            document: document,
            source: .reference(pdfURL: paper.fileURL),
            target: target
        )
    }

    func exportActiveReferencePDFAnnotationsToCompanionMarkdown() {
        guard let id = activeReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }

        exportPDFAnnotationsToMarkdown(
            document: document,
            source: .reference(pdfURL: paper.fileURL),
            target: .companionFile(PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL))
        )
    }

    func chooseActiveReferencePDFAnnotationsMarkdownDestination() {
        guard let id = activeReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }

        chooseMarkdownExportDestination(
            document: document,
            source: .reference(pdfURL: paper.fileURL)
        )
    }

    func exportPDFAnnotationsToMarkdown(
        document: PDFDocument,
        source: PDFAnnotationMarkdownExportSource,
        target: PDFAnnotationExportTarget? = nil
    ) {
        do {
            let resolvedTarget = target ?? defaultExportTarget(for: source)
            let isWritingBackIntoActiveMarkdown = documentMode == .markdown && resolvedTarget.url == fileURL
            let existingMarkdown: String? = {
                if isWritingBackIntoActiveMarkdown {
                    return text
                }
                return nil
            }()

            let result = try PDFAnnotationMarkdownExporter.export(
                document: document,
                source: source,
                target: resolvedTarget,
                existingMarkdown: existingMarkdown
            )

            if isWritingBackIntoActiveMarkdown {
                text = result.updatedMarkdown
                savedText = result.updatedMarkdown
                lastModified = modificationDate()
            }

            setToolbarStatus(.exported, autoClearAfter: 1.6)
        } catch {
            annotationExportError = error.localizedDescription
        }
    }

    var activeMarkdownExportTarget: PDFAnnotationExportTarget? {
        documentMode == .markdown ? .activeMarkdown(fileURL) : nil
    }

    func defaultExportTarget(for source: PDFAnnotationMarkdownExportSource) -> PDFAnnotationExportTarget {
        if documentMode == .markdown {
            return .activeMarkdown(fileURL)
        }

        switch source {
        case .compiled(let documentURL, _):
            return .companionFile(PDFAnnotationMarkdownExporter.companionURL(for: documentURL))
        case .reference(let pdfURL):
            return .companionFile(PDFAnnotationMarkdownExporter.companionURL(for: pdfURL))
        }
    }

    func companionExportFileName(for source: PDFAnnotationMarkdownExportSource) -> String {
        source.fallbackCompanionURL.lastPathComponent
    }

    func chooseMarkdownExportDestination(
        document: PDFDocument,
        source: PDFAnnotationMarkdownExportSource
    ) {
        guard let targetURL = presentMarkdownExportPanel(suggestedURL: source.fallbackCompanionURL) else { return }
        exportPDFAnnotationsToMarkdown(
            document: document,
            source: source,
            target: .companionFile(targetURL)
        )
    }

    func presentMarkdownExportPanel(suggestedURL: URL) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.isExtensionHidden = false
        panel.title = "Exporter les annotations"
        panel.message = "Choisis un fichier Markdown à mettre à jour avec ces annotations."
        panel.prompt = "Exporter"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

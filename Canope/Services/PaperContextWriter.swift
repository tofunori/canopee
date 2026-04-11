import Foundation
import Combine
@preconcurrency import PDFKit

struct PaperContextMetadata: Equatable, Sendable {
    let fileURL: URL
    let title: String
    let authors: String
    let year: String
    let journal: String
    let doi: String
}

struct PaperContextDocumentContent: Equatable, Sendable {
    let pageCount: Int
    let extractedText: String
}

@MainActor
final class PaperContextWriter: ObservableObject {
    struct Sink: Sendable {
        let writeSelectionState: @Sendable (ClaudeIDESelectionState) -> Void
        let clearLegacySelectionMirror: @Sendable () -> Void
        let writePaper: @Sendable (String) -> Void

        static let live = Sink(
            writeSelectionState: { CanopeContextFiles.writeIDESelectionState($0) },
            clearLegacySelectionMirror: { CanopeContextFiles.clearLegacySelectionMirror() },
            writePaper: { CanopeContextFiles.writePaper($0) }
        )
    }

    final class DocumentBox: @unchecked Sendable {
        let document: PDFDocument

        init(document: PDFDocument) {
            self.document = document
        }
    }

    typealias DocumentLoader = @MainActor @Sendable (_ key: String, _ url: URL) async -> DocumentBox?
    typealias ContentExtractor = @Sendable (_ document: PDFDocument) -> PaperContextDocumentContent

    private let sink: Sink
    private let documentLoader: DocumentLoader
    private let contentExtractor: ContentExtractor
    private var activeWriteID = UUID()

    init(
        sink: Sink = .live,
        documentLoader: @escaping DocumentLoader = { key, url in
            guard let document = await PDFDocumentRepository.shared.loadDocument(forKey: key, from: url) else {
                return nil
            }
            return DocumentBox(document: document)
        },
        contentExtractor: @escaping ContentExtractor = PaperContextWriter.extractDocumentContent
    ) {
        self.sink = sink
        self.documentLoader = documentLoader
        self.contentExtractor = contentExtractor
    }

    func writeContext(
        metadata: PaperContextMetadata,
        document: PDFDocument?,
        documentKey: String
    ) {
        let writeID = UUID()
        activeWriteID = writeID

        sink.writeSelectionState(
            ClaudeIDESelectionState.makeSnapshot(selectedText: "", fileURL: metadata.fileURL)
        )
        sink.clearLegacySelectionMirror()

        if let currentDocument = document ?? PDFDocumentRepository.shared.cachedDocument(forKey: documentKey) {
            buildAndWriteContext(
                writeID: writeID,
                metadata: metadata,
                documentBox: DocumentBox(document: currentDocument)
            )
            return
        }

        Task { [documentLoader] in
            let loadedDocument = await documentLoader(documentKey, metadata.fileURL)
            self.finishLoadingAndWrite(
                writeID: writeID,
                metadata: metadata,
                documentBox: loadedDocument
            )
        }
    }

    func cancelPendingWrites() {
        activeWriteID = UUID()
    }

    private func finishLoadingAndWrite(
        writeID: UUID,
        metadata: PaperContextMetadata,
        documentBox: DocumentBox?
    ) {
        guard activeWriteID == writeID,
              let documentBox else { return }
        buildAndWriteContext(
            writeID: writeID,
            metadata: metadata,
            documentBox: documentBox
        )
    }

    private func buildAndWriteContext(
        writeID: UUID,
        metadata: PaperContextMetadata,
        documentBox: DocumentBox
    ) {
        Task { [weak self, contentExtractor] in
            let content = await Task.detached(priority: .utility) {
                contentExtractor(documentBox.document)
            }.value

            guard let self, self.activeWriteID == writeID else { return }
            self.sink.writePaper(Self.composeContextText(metadata: metadata, content: content))
        }
    }

    nonisolated static func composeContextText(
        metadata: PaperContextMetadata,
        content: PaperContextDocumentContent
    ) -> String {
        var fullText = """
        ========================================
        CURRENTLY OPEN PAPER IN CANOPÉE
        ========================================
        Title: \(metadata.title)
        Authors: \(metadata.authors)
        Year: \(metadata.year)
        Journal: \(metadata.journal)
        DOI: \(metadata.doi)
        Pages: \(content.pageCount)
        ========================================

        """

        if content.extractedText.isEmpty == false {
            fullText += content.extractedText
            if content.extractedText.hasSuffix("\n\n") == false {
                fullText += "\n\n"
            }
        }

        return fullText
    }

    nonisolated static func extractDocumentContent(_ document: PDFDocument) -> PaperContextDocumentContent {
        var extractedText = ""
        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex), let text = page.string {
                extractedText += "--- Page \(pageIndex + 1) ---\n\(text)\n\n"
            }
        }
        return PaperContextDocumentContent(
            pageCount: document.pageCount,
            extractedText: extractedText
        )
    }
}

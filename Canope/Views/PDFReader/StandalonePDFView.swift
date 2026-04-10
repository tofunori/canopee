import SwiftUI
import PDFKit

// MARK: - Standalone PDF Viewer (for files opened from file browser)

struct StandalonePDFView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var currentURL: URL?
        var loadTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        loadDocument(into: pdfView, coordinator: context.coordinator)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        loadDocument(into: pdfView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
    }

    private func loadDocument(into pdfView: PDFView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.currentURL = url
        let targetURL = url
        coordinator.loadTask = Task {
            let document = await PDFDocumentRepository.shared.loadDocument(
                forKey: "standalone:\(targetURL.path)",
                from: targetURL,
                normalizeAnnotations: false
            )
            guard !Task.isCancelled, coordinator.currentURL == targetURL else { return }
            pdfView.document = document
        }
    }
}

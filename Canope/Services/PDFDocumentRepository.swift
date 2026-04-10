import Foundation
@preconcurrency import PDFKit

@MainActor
final class PDFDocumentRepository {
    static let shared = PDFDocumentRepository()

    private final class CachedDocumentBox: NSObject, @unchecked Sendable {
        let document: PDFDocument

        init(document: PDFDocument) {
            self.document = document
        }
    }

    private let cache = NSCache<NSString, CachedDocumentBox>()

    private init() {
        cache.countLimit = 12
    }

    func cachedDocument(forKey key: String) -> PDFDocument? {
        cache.object(forKey: key as NSString)?.document
    }

    func store(_ document: PDFDocument, forKey key: String) {
        cache.setObject(CachedDocumentBox(document: document), forKey: key as NSString)
    }

    func removeDocument(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func loadDocument(
        forKey key: String,
        from url: URL,
        normalizeAnnotations: Bool = true,
        forceReload: Bool = false
    ) async -> PDFDocument? {
        if !forceReload, let cached = cachedDocument(forKey: key) {
            return cached
        }

        let box = await Task.detached(priority: .userInitiated) {
            Self.makeDocumentBox(from: url, normalizeAnnotations: normalizeAnnotations)
        }.value

        guard let box else { return nil }
        let document = box.document
        cache.setObject(box, forKey: key as NSString)
        return document
    }

    nonisolated private static func makeDocumentBox(from url: URL, normalizeAnnotations: Bool) -> CachedDocumentBox? {
        if let data = try? Data(contentsOf: url),
           let document = PDFDocument(data: data) {
            if normalizeAnnotations {
                AnnotationService.normalizeDocumentAnnotations(in: document)
            }
            return CachedDocumentBox(document: document)
        }

        guard let document = PDFDocument(url: url) else { return nil }
        if normalizeAnnotations {
            AnnotationService.normalizeDocumentAnnotations(in: document)
        }
        return CachedDocumentBox(document: document)
    }
}

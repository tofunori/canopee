import Foundation
import PDFKit

struct PDFFileManager {
    static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PaperPilot/PDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Import a PDF and extract metadata locally (no network, instant).
    static func importPDF(from sourceURL: URL) throws -> (fileName: String, metadata: PaperMetadata) {
        let fileName = "\(UUID().uuidString).pdf"
        let destination = storageDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        var metadata = MetadataExtractor.extractLocal(from: destination)
        if metadata.title == nil {
            metadata.title = sourceURL.deletingPathExtension().lastPathComponent
        }

        return (fileName, metadata)
    }

    /// Delete a PDF file from storage.
    static func deletePDF(fileName: String) {
        let url = storageDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
}

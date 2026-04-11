import Foundation
@preconcurrency import PDFKit

enum ChatAttachmentSupport {
    static func listFiles(at baseURL: URL, query: String, maxResults: Int = 40) -> [String] {
        let components = query.components(separatedBy: "/")
        var currentURL = baseURL
        var filterQuery = query

        if components.count > 1 {
            let dirPath = components.dropLast().joined(separator: "/")
            currentURL = baseURL.appendingPathComponent(dirPath)
            filterQuery = components.last ?? ""
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: currentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        let prefix = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""
        let skipNames = Set(["node_modules", ".git", "DerivedData", ".build", "Pods", ".DS_Store"])
        let skipExts = Set(["aux", "bbl", "bcf", "blg", "fdb_latexmk", "fls", "lof", "lot",
                            "out", "toc", "synctex.gz", "synctex", "run.xml", "log"])

        var dirs: [String] = []
        var files: [String] = []

        for entry in entries.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
            let name = entry.lastPathComponent
            if skipNames.contains(name) { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if !isDirectory,
               let ext = name.components(separatedBy: ".").last,
               skipExts.contains(ext) {
                continue
            }

            if !filterQuery.isEmpty && !name.lowercased().contains(filterQuery.lowercased()) {
                continue
            }

            let display = prefix + (isDirectory ? "\(name)/" : name)
            if isDirectory {
                dirs.append(display)
            } else {
                files.append(display)
            }
        }

        return Array((dirs + files).prefix(maxResults))
    }

    static func readTextAttachment(at url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf",
           let content = readPDFAttachmentText(at: url) {
            return """
            [Attached PDF: \(url.lastPathComponent)]

            \(content)
            """
        }

        return readTextFileWithFallbacks(at: url)
    }

    static func makeAttachment(from url: URL) -> AttachedFile? {
        guard url.isFileURL else { return nil }

        if isSupportedImageURL(url) {
            return AttachedFile(
                name: url.lastPathComponent,
                path: url.path,
                content: "[Attached image at: \(url.path)]",
                kind: .image
            )
        }

        guard let content = readTextAttachment(at: url) else { return nil }
        return AttachedFile(
            name: url.lastPathComponent,
            path: url.path,
            content: content,
            kind: .textFile
        )
    }

    static func readTextFileWithFallbacks(at url: URL) -> String? {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .unicode) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
            return content
        }
        return nil
    }

    static func readPDFAttachmentText(at url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }

        let content = PDFPageTextFormatter.formattedText(
            from: document,
            options: .chatAttachment
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return content.isEmpty ? nil : content
    }

    static func isSupportedImageURL(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"].contains(ext)
    }

    static func skippedAttachmentMessage(for names: [String]) -> String {
        let suffix = names.count == 1 ? (names.first ?? "") : names.joined(separator: ", ")
        return "Skipped attachments: \(suffix). Only images and text files are supported for now."
    }
}

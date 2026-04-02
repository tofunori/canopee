import SwiftUI
import PDFKit

// MARK: - File Operations & Compilation

extension LaTeXEditorView {
    func loadFile(useAsBaseline: Bool = true) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        latexAnnotations = LaTeXAnnotationStore.load(for: fileURL)
        reconcileAnnotations()
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    func saveFile() {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        savedText = text
        reconcileAnnotations()
        lastModified = modificationDate()
        compile()
    }

    func openFile(_ url: URL) {
        if url.pathExtension == "tex" {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
                savedText = content
                latexAnnotations = LaTeXAnnotationStore.load(for: url)
                reconcileAnnotations()
            }
        }
    }

    /// Reflow: join paragraph lines into single lines. Visual word wrap handles display.
    /// Preserves blank lines and LaTeX structural commands.
    func reflowParagraphs() {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var currentParagraph: [String] = []

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                result.append(currentParagraph.joined(separator: " "))
                currentParagraph = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                result.append("")
                continue
            }

            let isStructural = trimmed.hasPrefix("\\begin") || trimmed.hasPrefix("\\end") ||
                trimmed.hasPrefix("\\section") || trimmed.hasPrefix("\\subsection") ||
                trimmed.hasPrefix("\\title") || trimmed.hasPrefix("\\author") ||
                trimmed.hasPrefix("\\date") || trimmed.hasPrefix("\\documentclass") ||
                trimmed.hasPrefix("\\usepackage") || trimmed.hasPrefix("\\maketitle") ||
                trimmed.hasPrefix("\\item") || trimmed.hasPrefix("\\label") ||
                trimmed.hasPrefix("\\input") || trimmed.hasPrefix("\\include") ||
                trimmed.hasPrefix("\\newcommand") || trimmed.hasPrefix("\\renewcommand") ||
                trimmed.hasPrefix("\\tableofcontents") || trimmed.hasPrefix("\\bibliography") ||
                trimmed.hasPrefix("\\onehalfspacing") || trimmed.hasPrefix("\\setlength") ||
                trimmed.hasPrefix("%")

            if isStructural {
                flushParagraph()
                result.append(line)
            } else {
                currentParagraph.append(trimmed)
            }
        }
        flushParagraph()

        text = result.joined(separator: "\n")
        savedText = text
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        reconcileAnnotations()
        lastModified = modificationDate()
    }

    func loadExistingPDF() {
        let pdfURL = fileURL.deletingPathExtension().appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: pdfURL.path) {
            compiledPDF = PDFDocument(url: pdfURL)
        } else {
            compiledPDF = nil
        }
    }

    func reloadActiveFileState() {
        stopFileWatcher()
        pendingAnnotation = nil
        selectedEditorRange = nil
        syncTarget = nil
        inverseSyncResult = nil
        errors = []
        compileOutput = ""
        loadFile()
        loadExistingPDF()
        if isActive {
            startFileWatcher()
        }
        refreshSplitGrabAreas()
    }

    func refreshSplitGrabAreas() {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    MainWindow.thickenSplitViews(contentView)
                }
            }
        }
    }

    // MARK: - Compilation

    func compile() {
        guard !isCompiling else { return }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        isCompiling = true
        Task {
            let result = await LaTeXCompiler.compile(file: fileURL)
            await MainActor.run {
                errors = result.errors
                compileOutput = result.log
                showErrors = true
                if let pdfURL = result.pdfURL {
                    compiledPDF = PDFDocument(url: pdfURL)
                }
                isCompiling = false
            }
        }
    }

    // MARK: - File Watching

    func startFileWatcher() {
        guard pollTimer == nil else { return }
        lastModified = modificationDate()
        let watchedURL = fileURL
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let currentMod = Self.modificationDate(for: watchedURL)
            Task { @MainActor in
                guard isActive else { return }
                if let currentMod, currentMod != lastModified {
                    lastModified = currentMod
                    loadFile(useAsBaseline: false)
                }
            }
        }
    }

    func stopFileWatcher() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func modificationDate() -> Date? {
        Self.modificationDate(for: fileURL)
    }

    nonisolated static func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

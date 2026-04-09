import AppKit
import Foundation

extension UnifiedEditorView {
    func prepareEditorStateForDisplay() {
        guard !hasNoFile else {
            documentState.resetForPlaceholder()
            return
        }

        if !documentState.didInitialLoadFromDisk {
            loadFile()
        } else if shouldReloadEditorTextFromDisk() {
            loadFile()
        }

        if !documentMode.isRunnableCode {
            loadExistingPDF()
        }

        configureDocumentLayoutIfNeeded()
        if isActive {
            startFileWatcher()
        }
        if !documentMode.isRunnableCode {
            refreshSplitGrabAreas()
        }
    }

    func refreshEditorStateForActivation() {
        guard !hasNoFile else {
            documentState.resetForPlaceholder()
            return
        }

        if !documentState.didInitialLoadFromDisk || shouldReloadEditorTextFromDisk() {
            loadFile()
        }

        if !documentMode.isRunnableCode {
            loadExistingPDF()
        }
    }

    private func shouldReloadEditorTextFromDisk() -> Bool {
        guard !documentState.hasUnsavedEditorChanges else { return false }
        guard let currentMod = modificationDate() else { return false }
        return currentMod != lastModified
    }

    func setToolbarStatus(_ status: ToolbarStatusState, autoClearAfter delay: TimeInterval? = nil) {
        documentState.toolbarStatusClearWorkItem?.cancel()
        documentState.toolbarStatusClearWorkItem = nil
        AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
            toolbarStatus = status
        }

        guard let delay, status != .idle else { return }

        let workItem = DispatchWorkItem {
            AppChromeMotion.performPanel(reduceMotion: reduceMotion) {
                toolbarStatus = .idle
            }
            documentState.toolbarStatusClearWorkItem = nil
        }
        documentState.toolbarStatusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func loadFile(useAsBaseline: Bool = true) {
        guard !hasNoFile, let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        text = content
        if useAsBaseline {
            savedText = content
        }
        if !documentMode.isRunnableCode {
            latexAnnotations = documentMode == .latex ? LaTeXAnnotationStore.load(for: fileURL) : []
            reconcileAnnotations()
        }
        lastModified = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        documentState.markInitialLoadFromDisk()
    }

    func saveFile() {
        if documentMode.isRunnableCode {
            guard writeCurrentTextToDisk() else { return }
            setToolbarStatus(.saved, autoClearAfter: 1.4)
        } else if documentMode == .latex {
            compile()
        } else if documentMode == .markdown {
            guard writeCurrentTextToDisk() else { return }
            setToolbarStatus(.saved, autoClearAfter: 1.4)
        } else {
            renderMarkdownPreview()
        }
    }

    func createNewEditorFile(_ kind: NewEditorFileKind) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = projectRoot
        panel.nameFieldStringValue = kind.defaultFileName
        panel.allowedContentTypes = [kind.contentType]
        panel.isExtensionHidden = false
        panel.title = kind.title
        panel.message = kind.message
        panel.prompt = "Créer"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try kind.template.write(to: url, atomically: true, encoding: .utf8)
            setToolbarStatus(.saved, autoClearAfter: 1.4)
            onOpenInNewTab?(url)
        } catch {
            fileCreationError = error.localizedDescription
        }
    }

    func openFile(_ url: URL) {
        if EditorFileSupport.isEditorDocument(url) {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
                savedText = content
                latexAnnotations = EditorDocumentMode(fileURL: url) == .latex ? LaTeXAnnotationStore.load(for: url) : []
                reconcileAnnotations()
                documentState.markInitialLoadFromDisk()
            }
        }
    }

    func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choisir un dossier de travail"
        panel.prompt = "Ouvrir"
        panel.directoryURL = workspaceState.workspaceRoot ?? FileManager.default.homeDirectoryForCurrentUser
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.workspaceState.workspaceRoot = url
                if !self.showSidebar { self.showSidebar = true }
            }
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            workspaceState.workspaceRoot = url
            if !showSidebar { showSidebar = true }
        }
    }

    @discardableResult
    func writeCurrentTextToDisk() -> Bool {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
            if !documentMode.isRunnableCode {
                reconcileAnnotations()
            }
            lastModified = modificationDate()
            return true
        } catch {
            if documentMode.isRunnableCode {
                codeDocumentState.outputLog = error.localizedDescription
                codeDocumentState.showLogs = true
                setToolbarStatus(.errors(1))
            } else {
                errors = [
                    CompilationError(
                        line: 0,
                        message: error.localizedDescription,
                        file: fileURL.lastPathComponent,
                        isWarning: false
                    )
                ]
                compileOutput = error.localizedDescription
                showErrors = true
                setToolbarStatus(.errors(1))
            }
            return false
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

    func reconcileAnnotations() {
        guard documentMode == .latex else {
            resolvedLaTeXAnnotations = []
            return
        }
        resolvedLaTeXAnnotations = LaTeXAnnotationStore.resolve(latexAnnotations, in: text)
    }

    func persistAnnotations() {
        guard documentMode == .latex else { return }
        if latexAnnotations.isEmpty {
            try? LaTeXAnnotationStore.deleteSidecar(for: fileURL)
        } else {
            try? LaTeXAnnotationStore.save(latexAnnotations, for: fileURL)
        }
    }
}

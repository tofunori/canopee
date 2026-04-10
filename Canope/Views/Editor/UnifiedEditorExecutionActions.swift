import AppKit
import Foundation
import PDFKit

extension UnifiedEditorView {
    func loadExistingPDF(forceReload: Bool = true) {
        let previewExists = FileManager.default.fileExists(atPath: previewPDFURL.path)

        guard previewExists else {
            compiledPDF = nil
            documentState.compiledPDFLastKnownPageIndex = 0
            documentState.compiledPDFRequestedRestorePageIndex = nil
            return
        }

        let existingURL = compiledPDF?.documentURL?.standardizedFileURL
        if !forceReload, existingURL == previewPDFURL.standardizedFileURL {
            return
        }

        replaceCompiledPDF(with: PDFDocument(url: previewPDFURL))
    }

    func replaceCompiledPDF(with document: PDFDocument?) {
        documentState.compiledPDFRequestedRestorePageIndex = documentState.compiledPDFLastKnownPageIndex
        compiledPDF = document
    }

    func reloadActiveFileState() {
        stopFileWatcher()
        documentState.resetTransientNavigationState()
        errors = []
        compileOutput = ""
        setToolbarStatus(.idle)
        loadFile()
        loadExistingPDF()
        configureDocumentLayoutIfNeeded()
        if isActive {
            startFileWatcher()
        }
        refreshSplitGrabAreas()
    }

    /// For markdown files there is no compiled PDF, but we no longer force the
    /// layout to editorOnly — the user may have reference PDFs open, and
    /// aggressively switching layouts when changing tabs is disorienting.
    func configureDocumentLayoutIfNeeded() {
        // No-op: let the user control the layout via toolbar buttons.
    }

    func sendMarkdownCommand(_ command: MarkdownLiveEditor.Command) {
        guard documentMode == .markdown else { return }
        NotificationCenter.default.post(
            name: .markdownEditorCommand,
            object: nil,
            userInfo: [
                "filePath": fileURL.path,
                "command": command.rawValue,
            ]
        )
    }

    func refreshSplitGrabAreas() {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows {
                    guard let contentView = window.contentView else { continue }
                    SplitViewHelper.thickenSplitViews(contentView)
                }
            }
        }
    }

    func scrollEditorToLine(_ lineNumber: Int, selectingLine: Bool = true) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += (lines[i] as NSString).length + 1
        }
        let lineLength = (lines[lineNumber - 1] as NSString).length
        let range = NSRange(location: charOffset, length: lineLength)
        NotificationCenter.default.post(
            name: .syncTeXScrollToLine,
            object: nil,
            userInfo: [
                "range": range,
                "select": selectingLine,
            ]
        )
    }

    func scrollEditorToInverseSyncResult(_ result: SyncTeXInverseResult) {
        let lines = text.components(separatedBy: "\n")
        guard result.line > 0 && result.line <= lines.count else { return }

        let lineText = lines[result.line - 1]
        let lineNSString = lineText as NSString
        let column = resolvedInverseSyncColumn(in: lineText, result: result)
        let clampedColumn = min(max(column, 0), lineNSString.length)
        revealEditorLocationForLine(
            result.line,
            columnOffset: clampedColumn,
            highlightLength: inverseSyncHighlightLength(in: lineText, result: result)
        )
    }

    func resolvedInverseSyncColumn(in lineText: String, result: SyncTeXInverseResult) -> Int {
        let lineNSString = lineText as NSString
        if let column = result.column, column >= 0 {
            return min(column, lineNSString.length)
        }

        guard let context = result.context?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              context.isEmpty == false,
              let offset = result.offset,
              offset >= 0 else {
            return 0
        }

        if let fullContextRange = lineText.range(of: context, options: [.caseInsensitive]) {
            let utf16Range = NSRange(fullContextRange, in: lineText)
            return min(utf16Range.location + offset, lineNSString.length)
        }

        let anchor = syncHintAnchor(in: context, offset: offset)
        if anchor.isEmpty == false,
           let anchorRange = lineText.range(of: anchor, options: [.caseInsensitive]) {
            return NSRange(anchorRange, in: lineText).location
        }

        return 0
    }

    func syncHintAnchor(in context: String, offset: Int) -> String {
        let nsContext = context as NSString
        let length = nsContext.length
        guard length > 0 else { return "" }
        let clampedOffset = min(max(offset, 0), max(length - 1, 0))
        let wordSeparators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var start = clampedOffset
        var end = clampedOffset

        while start > 0 {
            let scalar = UnicodeScalar(nsContext.character(at: start - 1))
            if let scalar, wordSeparators.contains(scalar) { break }
            start -= 1
        }
        while end < length {
            let scalar = UnicodeScalar(nsContext.character(at: end))
            if let scalar, wordSeparators.contains(scalar) { break }
            end += 1
        }

        return nsContext.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    func inverseSyncHighlightLength(in lineText: String, result: SyncTeXInverseResult) -> Int {
        guard let context = result.context?
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              context.isEmpty == false,
              let offset = result.offset,
              offset >= 0 else {
            return 1
        }

        let anchor = syncHintAnchor(in: context, offset: offset)
        guard anchor.isEmpty == false,
              let anchorRange = lineText.range(of: anchor, options: [.caseInsensitive]) else {
            return 1
        }

        return max(1, NSRange(anchorRange, in: lineText).length)
    }

    func revealEditorLocation(for group: LaTeXEditorDiffGroup) {
        revealEditorLocationForLine(
            max(group.preferredRevealLine, 1),
            columnOffset: group.preferredRevealColumn,
            highlightLength: group.preferredRevealLength
        )
    }

    func revealEditorLocationForLine(
        _ lineNumber: Int,
        columnOffset: Int = 0,
        highlightLength: Int = 1
    ) {
        let lines = text.components(separatedBy: "\n")
        guard lineNumber > 0 && lineNumber <= lines.count else { return }
        var charOffset = 0
        for i in 0..<(lineNumber - 1) {
            charOffset += (lines[i] as NSString).length + 1
        }
        let lineNSString = lines[lineNumber - 1] as NSString
        let clampedColumnOffset = min(max(columnOffset, 0), lineNSString.length)
        NotificationCenter.default.post(
            name: .editorRevealLocation,
            object: nil,
            userInfo: [
                "location": charOffset + clampedColumnOffset,
                "length": max(1, highlightLength),
            ]
        )
    }

    func forwardSync(line: Int) {
        guard documentMode == .latex else { return }
        let pdfPath = previewPDFURL.path
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        let texFile = fileURL.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = SyncTeXService.forwardSync(line: line, texFile: texFile, pdfPath: pdfPath) {
                DispatchQueue.main.async {
                    syncTarget = result
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        syncTarget = nil
                    }
                }
            }
        }
    }

    func runPrimaryDocumentAction() {
        switch documentMode {
        case .latex:
            compile()
        case .markdown:
            renderMarkdownPreview()
        case .python, .r:
            break
        }
    }

    func compile() {
        guard documentMode == .latex, !isCompiling else { return }
        guard writeCurrentTextToDisk() else { return }
        isCompiling = true
        setToolbarStatus(documentMode.runningStatus)
        Task {
            let result = await LaTeXCompiler.compile(file: fileURL)
            await MainActor.run {
                errors = result.errors
                compileOutput = result.log
                showErrors = true
                if let pdfURL = result.pdfURL {
                    replaceCompiledPDF(with: PDFDocument(url: pdfURL))
                }
                isCompiling = false
                if activeErrorCount > 0 {
                    setToolbarStatus(.errors(activeErrorCount))
                } else {
                    setToolbarStatus(documentMode.successStatus, autoClearAfter: 1.6)
                }
            }
        }
    }

    func renderMarkdownPreview() {
        guard documentMode == .markdown, !isCompiling else { return }
        guard writeCurrentTextToDisk() else { return }
        isCompiling = true
        setToolbarStatus(documentMode.runningStatus)
        Task {
            let result = await MarkdownPreviewRenderer.render(file: fileURL)
            await MainActor.run {
                errors = result.errors
                compileOutput = result.log
                showErrors = !result.success || !result.errors.isEmpty
                if let pdfURL = result.pdfURL {
                    replaceCompiledPDF(with: PDFDocument(url: pdfURL))
                } else if !result.success {
                    compiledPDF = nil
                }
                isCompiling = false
                if activeErrorCount > 0 {
                    setToolbarStatus(.errors(activeErrorCount))
                } else {
                    setToolbarStatus(documentMode.successStatus, autoClearAfter: 1.6)
                }
            }
        }
    }

    func runScript() {
        guard documentMode.isRunnableCode, !codeDocumentState.isRunning else { return }
        guard writeCurrentTextToDisk() else { return }

        let commandName = documentMode == .python ? "python3 \(fileURL.lastPathComponent)" : "Rscript \(fileURL.lastPathComponent)"
        codeDocumentState.beginRun(commandDescription: commandName)
        setToolbarStatus(documentMode.runningStatus)

        Task {
            let result = await CodeRunService.run(file: fileURL, mode: documentMode)
            await MainActor.run {
                codeDocumentState.applyRunResult(result)
                if result.succeeded {
                    setToolbarStatus(result.artifacts.isEmpty ? .completed : .previewReady, autoClearAfter: 1.6)
                } else {
                    setToolbarStatus(.errors(1))
                }
                persistDocumentWorkspaceState()
            }
        }
    }

    func revealArtifactDirectoryInFinder() {
        if FileManager.default.fileExists(atPath: outputDirectoryURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([outputDirectoryURL])
        } else {
            NSWorkspace.shared.open(projectRoot)
        }
    }

    func refreshSelectedRun() {
        guard let selectedRun = codeDocumentState.selectedRun else { return }
        let refreshed = CodeRunService.refresh(selectedRun, sourceDocumentPath: fileURL.path)
        codeDocumentState.applyRefreshedRun(refreshed)
        setToolbarStatus(refreshed.artifacts.isEmpty ? .completed : .previewReady, autoClearAfter: 1.2)
        persistDocumentWorkspaceState()
    }

    func persistDocumentWorkspaceState() {
        onPersistWorkspaceState?()
    }

    private var codeActiveReferencePDFID: UUID? {
        if case .reference(let id) = selectedContentTab { return id }
        return nil
    }

    var codeActiveReferencePDFState: ReferencePDFUIState? {
        guard let id = codeActiveReferencePDFID else { return nil }
        return workspaceState.referencePDFUIStates[id]
    }

    private var codeActiveReferencePDFDocument: PDFDocument? {
        guard let id = codeActiveReferencePDFID else { return nil }
        return workspaceState.referencePDFs[id]
    }

    var codeActiveReferenceAnnotationCount: Int {
        guard let document = codeActiveReferencePDFDocument else { return 0 }
        return (0..<document.pageCount).reduce(0) { count, pageIndex in
            guard let page = document.page(at: pageIndex) else { return count }
            return count + page.annotations.filter { $0.type != "Link" && $0.type != "Widget" }.count
        }
    }

    func codeDeleteSelectedReferenceAnnotation() {
        guard let id = codeActiveReferencePDFID,
              let annotation = codeActiveReferencePDFState?.selectedAnnotation,
              let page = annotation.page else { return }
        let state = workspaceState.referencePDFUIStates[id]
        let wasSelected = state?.selectedAnnotation === annotation
        state?.pushUndoAction { [weak state] in
            page.addAnnotation(annotation)
            if wasSelected { state?.selectedAnnotation = annotation }
            state?.annotationRefreshToken = UUID()
            codeReferencePDFDocumentDidChange(id: id)
        }
        if wasSelected { state?.selectedAnnotation = nil }
        page.removeAnnotation(annotation)
        state?.annotationRefreshToken = UUID()
        codeReferencePDFDocumentDidChange(id: id)
    }

    func codeDeleteAllReferenceAnnotations() {
        guard let id = codeActiveReferencePDFID,
              let document = codeActiveReferencePDFDocument else { return }
        var removed: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for ann in page.annotations where ann.type != "Link" && ann.type != "Widget" {
                removed.append((page, ann))
                page.removeAnnotation(ann)
            }
        }
        workspaceState.referencePDFUIStates[id]?.pushUndoAction {
            for (page, ann) in removed { page.addAnnotation(ann) }
            workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
            codeReferencePDFDocumentDidChange(id: id)
        }
        codeActiveReferencePDFState?.selectedAnnotation = nil
        workspaceState.referencePDFUIStates[id]?.annotationRefreshToken = UUID()
        codeReferencePDFDocumentDidChange(id: id)
    }

    func codeChangeSelectedReferenceAnnotationColor(_ color: NSColor) {
        guard let id = codeActiveReferencePDFID,
              let state = codeActiveReferencePDFState,
              let annotation = state.selectedAnnotation else { return }
        let prevCurrent = state.currentColor
        let prevAnnotation = annotation.isTextBoxAnnotation ? annotation.textBoxFillColor : annotation.color
        state.pushUndoAction { [weak state] in
            guard let state else { return }
            state.currentColor = prevCurrent
            AnnotationService.applyColor(prevAnnotation, to: annotation)
            state.selectedAnnotation = annotation
            state.annotationRefreshToken = UUID()
            codeReferencePDFDocumentDidChange(id: id)
        }
        state.currentColor = color
        state.selectedAnnotation = annotation
        AnnotationService.applyColor(color, to: annotation)
        codeReferencePDFDocumentDidChange(id: id)
    }

    func codeSaveCurrentReferencePDF() {
        guard let id = codeActiveReferencePDFID else { return }
        codeSaveReferencePDF(id: id)
    }

    func codeRefreshCurrentReference() {
        guard let id = codeActiveReferencePDFID else { return }
        codeReloadReferencePDFDocument(id: id)
    }

    var codeActiveReferenceCompanionExportFileName: String {
        guard let id = codeActiveReferencePDFID,
              let paper = paperFor(id) else { return "annotations.md" }
        return PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL).lastPathComponent
    }

    func codeExportActiveReferencePDFAnnotationsToCompanionMarkdown() {
        guard let id = codeActiveReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        let companionURL = PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL)
        _ = try? PDFAnnotationMarkdownExporter.export(
            document: document,
            source: .reference(pdfURL: paper.fileURL),
            target: .companionFile(companionURL)
        )
    }

    func codeChooseActiveReferencePDFAnnotationsMarkdownDestination() {
        guard let id = codeActiveReferencePDFID,
              let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = PDFAnnotationMarkdownExporter.companionURL(for: paper.fileURL).lastPathComponent
        panel.directoryURL = paper.fileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = try? PDFAnnotationMarkdownExporter.export(
            document: document,
            source: .reference(pdfURL: paper.fileURL),
            target: .companionFile(url)
        )
    }

    private func codeReferencePDFDocumentDidChange(id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id] else { return }
        state.hasUnsavedChanges = true
        state.annotationRefreshToken = UUID()
        let delay: TimeInterval = (state.selectedAnnotation?.isTextBoxAnnotation == true || state.currentTool == .textBox) ? 0.9 : 0.25
        state.pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak state] in
            state?.pendingSaveWorkItem = nil
            codeSaveReferencePDF(id: id)
        }
        state.pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func codeSaveReferencePDF(id: UUID) {
        guard let document = workspaceState.referencePDFs[id],
              let paper = paperFor(id) else { return }
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem?.cancel()
        workspaceState.referencePDFUIStates[id]?.pendingSaveWorkItem = nil
        if AnnotationService.save(document: document, to: paper.fileURL) {
            workspaceState.referencePDFUIStates[id]?.hasUnsavedChanges = false
        }
    }

    private func codeReloadReferencePDFDocument(id: UUID) {
        guard let paper = paperFor(id) else { return }
        let state = workspaceState.referencePDFUIStates[id]
        state?.selectedAnnotation = nil
        state?.requestedRestorePageIndex = state?.lastKnownPageIndex
        guard let data = try? Data(contentsOf: paper.fileURL),
              let refreshed = PDFDocument(data: data) else {
            if let loaded = PDFDocument(url: paper.fileURL) {
                AnnotationService.normalizeDocumentAnnotations(in: loaded)
                workspaceState.referencePDFs[id] = loaded
            }
            state?.annotationRefreshToken = UUID()
            state?.pdfViewRefreshToken = UUID()
            return
        }
        AnnotationService.normalizeDocumentAnnotations(in: refreshed)
        workspaceState.referencePDFs[id] = refreshed
        state?.annotationRefreshToken = UUID()
        state?.pdfViewRefreshToken = UUID()
    }

    private func codeSaveReferenceAnnotationNote(for id: UUID) {
        guard let state = workspaceState.referencePDFUIStates[id],
              let annotation = state.selectedAnnotation else { return }
        annotation.contents = state.editingNoteText
        state.isEditingNote = false
        state.annotationRefreshToken = UUID()
        codeReferencePDFDocumentDidChange(id: id)
    }

    func startFileWatcher() {
        guard !hasNoFile, pollTimer == nil else { return }
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

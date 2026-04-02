import SwiftUI

// MARK: - LaTeX Annotations

extension LaTeXEditorView {
    func reconcileAnnotations() {
        resolvedLaTeXAnnotations = LaTeXAnnotationStore.resolve(latexAnnotations, in: text)
    }

    func persistAnnotations() {
        if latexAnnotations.isEmpty {
            try? LaTeXAnnotationStore.deleteSidecar(for: fileURL)
        } else {
            try? LaTeXAnnotationStore.save(latexAnnotations, for: fileURL)
        }
    }

    func beginAnnotationFromSelection() {
        guard let range = selectedEditorRange,
              canCreateAnnotationFromSelection,
              let draft = LaTeXAnnotationStore.makeDraft(from: range, in: text) else {
            return
        }

        if !showSidebar {
            showSidebar = true
        }
        selectedSidebarSection = .annotations
        pendingAnnotation = PendingAnnotation(draft: draft, existingAnnotationID: nil)
    }

    func savePendingAnnotation(note: String, sendToClaude: Bool = false) {
        guard var draft = pendingAnnotation?.draft else { return }
        draft.note = note

        let annotationToSend: LaTeXAnnotation
        if let existingAnnotationID = pendingAnnotation?.existingAnnotationID,
           let index = latexAnnotations.firstIndex(where: { $0.id == existingAnnotationID }) {
            latexAnnotations[index] = LaTeXAnnotationStore.update(latexAnnotations[index], note: note, in: text)
            annotationToSend = latexAnnotations[index]
        } else {
            let annotation = LaTeXAnnotationStore.createAnnotation(from: draft)
            latexAnnotations.append(annotation)
            annotationToSend = annotation
        }
        persistAnnotations()
        reconcileAnnotations()
        pendingAnnotation = nil

        if sendToClaude,
           let resolved = LaTeXAnnotationStore.resolve([annotationToSend], in: text).first {
            sendAnnotationToClaude(resolved)
        }
    }

    func deleteAnnotation(_ annotationID: UUID) {
        latexAnnotations.removeAll { $0.id == annotationID }
        persistAnnotations()
        reconcileAnnotations()
    }

    func sendAnnotationToClaude(_ resolved: ResolvedLaTeXAnnotation) {
        let prompt = annotationPrompt(for: resolved)
        sendPromptToClaudeTerminal(prompt, selectionContent: resolved.annotation.selectedText)
    }

    func sendAllAnnotationsToClaude() {
        let prompt = batchAnnotationPrompt(for: sidebarAnnotations)
        let selectionContent = sidebarAnnotations
            .map(\.annotation.selectedText)
            .joined(separator: "\n\n---\n\n")
        sendPromptToClaudeTerminal(prompt, selectionContent: selectionContent)
    }

    func sendPromptToClaudeTerminal(_ prompt: String, selectionContent: String) {
        CanopeContextFiles.writeAnnotationPrompt(prompt)
        CanopeContextFiles.writeIDESelectionState(
            ClaudeIDESelectionState.makeSnapshot(
                selectedText: selectionContent,
                fileURL: fileURL
            )
        )
        CanopeContextFiles.clearLegacySelectionMirror()
        showTerminal = true

        let userInfo = ["prompt": prompt]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .canopeSendPromptToTerminal, object: nil, userInfo: userInfo)
        }
    }

    func addTerminalTab() {
        NotificationCenter.default.post(name: .canopeTerminalAddTab, object: nil)
    }

    func applyTerminalTheme(_ index: Int) {
        let userInfo = ["themeIndex": index]
        NotificationCenter.default.post(name: .canopeTerminalApplyTheme, object: nil, userInfo: userInfo)
    }

    func applyTerminalFontSize(_ size: Int) {
        let userInfo = ["fontSize": CGFloat(size)]
        NotificationCenter.default.post(name: .canopeTerminalApplyFontSize, object: nil, userInfo: userInfo)
    }

    func annotationPrompt(for resolved: ResolvedLaTeXAnnotation) -> String {
        let annotation = resolved.annotation
        let status = resolved.isDetached ? "detached" : "anchored"

        return """
        <canope_annotation>
        file: \(fileURL.path)
        status: \(status)

        selected_text:
        \(annotation.selectedText)

        note:
        \(annotation.note)
        </canope_annotation>

        Aide-moi avec cette annotation LaTeX. Réponds d'abord sur ce passage précis en tenant compte de la note.
        """
    }

    func batchAnnotationPrompt(for annotations: [ResolvedLaTeXAnnotation]) -> String {
        let blocks = annotations.enumerated().map { index, resolved in
            let annotation = resolved.annotation
            let status = resolved.isDetached ? "detached" : "anchored"

            return """
            <annotation index="\(index + 1)">
            status: \(status)

            selected_text:
            \(annotation.selectedText)

            note:
            \(annotation.note)
            </annotation>
            """
        }
        .joined(separator: "\n\n")

        return """
        <canope_annotation_batch>
        file: \(fileURL.path)
        count: \(annotations.count)

        \(blocks)
        </canope_annotation_batch>

        Aide-moi avec ce lot d'annotations LaTeX. Traite-les une par une, puis propose au besoin une synthèse courte des problèmes principaux du texte.
        """
    }

    func beginEditingAnnotation(_ annotationID: UUID) {
        guard let resolved = resolvedLaTeXAnnotations.first(where: { $0.annotation.id == annotationID }) else {
            return
        }

        if let range = resolved.resolvedRange,
           let draft = LaTeXAnnotationStore.makeDraft(from: range, in: text, note: resolved.annotation.note) {
            pendingAnnotation = PendingAnnotation(draft: draft, existingAnnotationID: annotationID)
            return
        }

        pendingAnnotation = PendingAnnotation(
            draft: LaTeXAnnotationDraft(
                selectedText: resolved.annotation.selectedText,
                note: resolved.annotation.note,
                utf16Range: resolved.annotation.utf16Range,
                prefixContext: resolved.annotation.prefixContext,
                suffixContext: resolved.annotation.suffixContext
            ),
            existingAnnotationID: annotationID
        )
    }
}

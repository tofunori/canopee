import Foundation
import PDFKit
import SwiftUI

@MainActor
final class EditorDocumentUIState: ObservableObject {
    @Published var text = ""
    @Published var savedText = ""
    @Published var lastModified: Date?
    @Published var toolbarStatus: ToolbarStatusState = .idle
    @Published var compiledPDF: PDFDocument?
    @Published var errors: [CompilationError] = []
    @Published var compileOutput = ""
    @Published var isCompiling = false
    @Published var syncTarget: SyncTeXForwardResult?
    @Published var inverseSyncResult: SyncTeXInverseResult?
    @Published var compiledPDFLastKnownPageIndex = 0
    @Published var compiledPDFRequestedRestorePageIndex: Int?
    @Published var latexAnnotations: [LaTeXAnnotation] = []
    @Published var resolvedLaTeXAnnotations: [ResolvedLaTeXAnnotation] = []
    @Published var selectedEditorRange: NSRange?
    @Published var pendingAnnotation: LaTeXEditorPendingAnnotation?
    @Published var referenceContextWriteID = UUID()

    var toolbarStatusClearWorkItem: DispatchWorkItem?
    private(set) var didInitialLoadFromDisk = false

    var hasUnsavedEditorChanges: Bool {
        text != savedText
    }

    func markInitialLoadFromDisk() {
        didInitialLoadFromDisk = true
    }

    func resetForPlaceholder() {
        text = ""
        savedText = ""
        lastModified = nil
        toolbarStatus = .idle
        compiledPDF = nil
        errors = []
        compileOutput = ""
        isCompiling = false
        syncTarget = nil
        inverseSyncResult = nil
        compiledPDFLastKnownPageIndex = 0
        compiledPDFRequestedRestorePageIndex = nil
        latexAnnotations = []
        resolvedLaTeXAnnotations = []
        selectedEditorRange = nil
        pendingAnnotation = nil
        referenceContextWriteID = UUID()
        toolbarStatusClearWorkItem?.cancel()
        toolbarStatusClearWorkItem = nil
        didInitialLoadFromDisk = false
    }

    func resetTransientNavigationState() {
        pendingAnnotation = nil
        selectedEditorRange = nil
        syncTarget = nil
        inverseSyncResult = nil
    }
}

@MainActor
final class EditorDocumentStateStore: ObservableObject {
    private var states: [String: EditorDocumentUIState] = [:]

    func ensureState(for fileURL: URL) {
        guard states[fileURL.path] == nil else { return }
        states[fileURL.path] = EditorDocumentUIState()
    }

    func stateOrCreate(for fileURL: URL) -> EditorDocumentUIState {
        if let existing = states[fileURL.path] {
            return existing
        }
        let state = EditorDocumentUIState()
        states[fileURL.path] = state
        return state
    }

    func removeState(for fileURL: URL) {
        states.removeValue(forKey: fileURL.path)
    }

    func removeMissingStates(keepingPaths paths: [String]) {
        let keep = Set(paths)
        for path in Array(states.keys) where !keep.contains(path) {
            states.removeValue(forKey: path)
        }
    }
}

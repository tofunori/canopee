import Foundation
import SwiftUI

struct CodeRunRecord: Identifiable, Codable, Equatable {
    let runID: UUID
    let executedAt: Date
    let commandDescription: String
    let exitCode: Int32
    let timedOut: Bool
    let artifactDirectory: URL
    let artifacts: [ArtifactDescriptor]
    let logURL: URL

    var id: UUID { runID }

    var succeeded: Bool {
        exitCode == 0 && !timedOut
    }
}

struct CodeRunResult {
    let runID: UUID
    let executedAt: Date
    let commandDescription: String
    let exitCode: Int32
    let timedOut: Bool
    let outputLog: String
    let artifactDirectory: URL
    let logURL: URL
    let artifacts: [ArtifactDescriptor]

    var succeeded: Bool {
        exitCode == 0 && !timedOut
    }

    var record: CodeRunRecord {
        CodeRunRecord(
            runID: runID,
            executedAt: executedAt,
            commandDescription: commandDescription,
            exitCode: exitCode,
            timedOut: timedOut,
            artifactDirectory: artifactDirectory,
            artifacts: artifacts,
            logURL: logURL
        )
    }
}

struct CodeDocumentWorkspaceState: Codable, Equatable {
    var showLogs: Bool
    var selectedRunID: UUID?
    var lastArtifactPath: String?
    var outputLayout: CodeOutputLayoutState
    var secondaryArtifactPath: String?
    var primaryManualPreviewPath: String?
    var secondaryManualPreviewPath: String?

    init(
        showLogs: Bool,
        selectedRunID: UUID?,
        lastArtifactPath: String?,
        outputLayout: CodeOutputLayoutState = CodeOutputLayoutState(),
        secondaryArtifactPath: String? = nil,
        primaryManualPreviewPath: String? = nil,
        secondaryManualPreviewPath: String? = nil
    ) {
        self.showLogs = showLogs
        self.selectedRunID = selectedRunID
        self.lastArtifactPath = lastArtifactPath
        self.outputLayout = outputLayout
        self.secondaryArtifactPath = secondaryArtifactPath
        self.primaryManualPreviewPath = primaryManualPreviewPath
        self.secondaryManualPreviewPath = secondaryManualPreviewPath
    }

    private enum CodingKeys: String, CodingKey {
        case showLogs
        case selectedRunID
        case lastArtifactPath
        case outputLayout
        case secondaryArtifactPath
        case primaryManualPreviewPath
        case secondaryManualPreviewPath
        case showOutputPane
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showLogs = try container.decodeIfPresent(Bool.self, forKey: .showLogs) ?? false
        selectedRunID = try container.decodeIfPresent(UUID.self, forKey: .selectedRunID)
        lastArtifactPath = try container.decodeIfPresent(String.self, forKey: .lastArtifactPath)
        secondaryArtifactPath = try container.decodeIfPresent(String.self, forKey: .secondaryArtifactPath)
        primaryManualPreviewPath = try container.decodeIfPresent(String.self, forKey: .primaryManualPreviewPath)
        secondaryManualPreviewPath = try container.decodeIfPresent(String.self, forKey: .secondaryManualPreviewPath)
        if let decodedLayout = try container.decodeIfPresent(CodeOutputLayoutState.self, forKey: .outputLayout) {
            outputLayout = decodedLayout
        } else {
            outputLayout = CodeOutputLayoutState(
                isOutputVisible: try container.decodeIfPresent(Bool.self, forKey: .showOutputPane) ?? true
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showLogs, forKey: .showLogs)
        try container.encodeIfPresent(selectedRunID, forKey: .selectedRunID)
        try container.encodeIfPresent(lastArtifactPath, forKey: .lastArtifactPath)
        try container.encode(outputLayout, forKey: .outputLayout)
        try container.encodeIfPresent(secondaryArtifactPath, forKey: .secondaryArtifactPath)
        try container.encodeIfPresent(primaryManualPreviewPath, forKey: .primaryManualPreviewPath)
        try container.encodeIfPresent(secondaryManualPreviewPath, forKey: .secondaryManualPreviewPath)
    }
}

@MainActor
final class CodeDocumentUIState: ObservableObject {
    @Published var showLogs: Bool
    @Published var runHistory: [CodeRunRecord]
    @Published var selectedRunID: UUID?
    @Published var selectedArtifactPath: String?
    @Published var manualPreviewArtifact: ArtifactDescriptor?
    @Published var outputLayout: CodeOutputLayoutState
    @Published var secondaryArtifactPath: String?
    @Published var secondaryManualPreviewArtifact: ArtifactDescriptor?
    @Published var isRunning = false
    @Published var outputLog = ""
    @Published var lastRunID: UUID?
    @Published var lastCommandDescription = ""

    private let fileURL: URL

    init(snapshot: CodeDocumentWorkspaceState?, fileURL: URL) {
        let loadedHistory = CodeRunService.loadRunHistory(for: fileURL)
        let restoredSelectedRunID = snapshot?.selectedRunID ?? loadedHistory.first?.runID

        self.fileURL = fileURL
        self.showLogs = snapshot?.showLogs ?? false
        self.runHistory = loadedHistory
        self.selectedRunID = restoredSelectedRunID
        self.selectedArtifactPath = snapshot?.lastArtifactPath
        self.outputLayout = snapshot?.outputLayout ?? CodeOutputLayoutState()
        self.secondaryArtifactPath = snapshot?.secondaryArtifactPath
        self.manualPreviewArtifact = Self.restoreManualArtifact(from: snapshot?.primaryManualPreviewPath, sourceDocumentPath: fileURL.path)
        self.secondaryManualPreviewArtifact = Self.restoreManualArtifact(from: snapshot?.secondaryManualPreviewPath, sourceDocumentPath: fileURL.path)

        if let selectedRunID, !runHistory.contains(where: { $0.runID == selectedRunID }) {
            self.selectedRunID = runHistory.first?.runID
        }

        if self.selectedArtifactPath == nil {
            self.selectedArtifactPath = selectedRun?.artifacts.first?.url.path
        }

        refreshOutputLogFromSelectedRun()
        sanitizeArtifactSelection()
        sanitizeSecondaryArtifactSelection()
    }

    var selectedRun: CodeRunRecord? {
        guard let selectedRunID else { return runHistory.first }
        return runHistory.first(where: { $0.runID == selectedRunID }) ?? runHistory.first
    }

    var activeArtifacts: [ArtifactDescriptor] {
        if let manualPreviewArtifact {
            return [manualPreviewArtifact]
        }
        return selectedRun?.artifacts ?? []
    }

    var activeArtifact: ArtifactDescriptor? {
        if let manualPreviewArtifact {
            return manualPreviewArtifact
        }
        if let selectedArtifactPath,
           let match = activeArtifacts.first(where: { $0.url.path == selectedArtifactPath }) {
            return match
        }
        return activeArtifacts.first
    }

    var availableSecondaryArtifacts: [ArtifactDescriptor] {
        guard manualPreviewArtifact == nil else { return [] }
        let primaryPath = activeArtifact?.url.path
        return (selectedRun?.artifacts ?? []).filter { $0.url.path != primaryPath }
    }

    var secondaryActiveArtifact: ArtifactDescriptor? {
        if let secondaryManualPreviewArtifact {
            return secondaryManualPreviewArtifact
        }
        if let secondaryArtifactPath,
           let match = availableSecondaryArtifacts.first(where: { $0.url.path == secondaryArtifactPath }) {
            return match
        }
        return availableSecondaryArtifacts.first
    }

    var canSelectPreviousRun: Bool {
        guard manualPreviewArtifact == nil,
              let selectedRun,
              let index = runHistory.firstIndex(where: { $0.runID == selectedRun.runID }) else {
            return false
        }
        return index + 1 < runHistory.count
    }

    var canSelectNextRun: Bool {
        guard manualPreviewArtifact == nil,
              let selectedRun,
              let index = runHistory.firstIndex(where: { $0.runID == selectedRun.runID }) else {
            return false
        }
        return index > 0
    }

    var persistedState: CodeDocumentWorkspaceState {
        CodeDocumentWorkspaceState(
            showLogs: showLogs,
            selectedRunID: selectedRun?.runID,
            lastArtifactPath: manualPreviewArtifact == nil ? activeArtifact?.url.path : selectedRun?.artifacts.first?.url.path,
            outputLayout: outputLayout,
            secondaryArtifactPath: secondaryManualPreviewArtifact == nil ? secondaryActiveArtifact?.url.path : nil,
            primaryManualPreviewPath: manualPreviewArtifact?.url.path,
            secondaryManualPreviewPath: secondaryManualPreviewArtifact?.url.path
        )
    }

    func applyRunResult(_ result: CodeRunResult) {
        lastRunID = result.runID
        lastCommandDescription = result.commandDescription
        outputLog = result.outputLog
        runHistory.removeAll { $0.runID == result.runID }
        runHistory.insert(result.record, at: 0)
        if runHistory.count > CodeRunService.maxStoredRuns {
            runHistory = Array(runHistory.prefix(CodeRunService.maxStoredRuns))
        }
        selectedRunID = result.runID
        selectedArtifactPath = result.artifacts.first?.url.path
        manualPreviewArtifact = nil
        secondaryManualPreviewArtifact = nil
        isRunning = false
        if !result.artifacts.isEmpty {
            updateOutputLayout { $0.isOutputVisible = true }
        }
        if !result.outputLog.isEmpty || !result.succeeded {
            showLogs = true
        }
        sanitizeArtifactSelection()
        sanitizeSecondaryArtifactSelection(preferNewestAlternative: true)
    }

    func beginRun(commandDescription: String) {
        lastCommandDescription = commandDescription
        isRunning = true
    }

    func applyRefreshedRun(_ record: CodeRunRecord) {
        guard let index = runHistory.firstIndex(where: { $0.runID == record.runID }) else { return }
        runHistory[index] = record
        runHistory.sort { $0.executedAt > $1.executedAt }
        if selectedRunID == record.runID {
            sanitizeArtifactSelection()
            sanitizeSecondaryArtifactSelection()
            refreshOutputLogFromSelectedRun()
        }
    }

    func setManualPreviewArtifact(_ artifact: ArtifactDescriptor) {
        manualPreviewArtifact = artifact
        updateOutputLayout { $0.isOutputVisible = true }
    }

    func returnToSelectedRun() {
        manualPreviewArtifact = nil
        sanitizeArtifactSelection()
        sanitizeSecondaryArtifactSelection()
        refreshOutputLogFromSelectedRun()
    }

    func setSecondaryManualPreviewArtifact(_ artifact: ArtifactDescriptor) {
        secondaryManualPreviewArtifact = artifact
        updateOutputLayout {
            $0.secondaryPaneVisible = true
            $0.isOutputVisible = true
        }
    }

    func clearSecondaryPreview() {
        secondaryManualPreviewArtifact = nil
        secondaryArtifactPath = nil
        sanitizeSecondaryArtifactSelection()
    }

    func selectPreviousRun() {
        guard let current = selectedRun,
              let index = runHistory.firstIndex(where: { $0.runID == current.runID }),
              index + 1 < runHistory.count else { return }
        manualPreviewArtifact = nil
        selectedRunID = runHistory[index + 1].runID
        sanitizeArtifactSelection()
        sanitizeSecondaryArtifactSelection()
        refreshOutputLogFromSelectedRun()
    }

    func selectNextRun() {
        guard let current = selectedRun,
              let index = runHistory.firstIndex(where: { $0.runID == current.runID }),
              index > 0 else { return }
        manualPreviewArtifact = nil
        selectedRunID = runHistory[index - 1].runID
        sanitizeArtifactSelection()
        sanitizeSecondaryArtifactSelection()
        refreshOutputLogFromSelectedRun()
    }

    func setSecondaryArtifactPath(_ path: String?) {
        secondaryManualPreviewArtifact = nil
        secondaryArtifactPath = path
        outputLayout.secondaryPaneVisible = true
        sanitizeSecondaryArtifactSelection()
    }

    private func sanitizeArtifactSelection() {
        guard manualPreviewArtifact == nil else { return }
        guard let selectedRun else {
            selectedArtifactPath = nil
            return
        }
        if let selectedArtifactPath,
           selectedRun.artifacts.contains(where: { $0.url.path == selectedArtifactPath }) {
            return
        }
        selectedArtifactPath = selectedRun.artifacts.first?.url.path
    }

    private func sanitizeSecondaryArtifactSelection(preferNewestAlternative: Bool = false) {
        guard outputLayout.secondaryPaneVisible else { return }
        if let secondaryManualPreviewArtifact {
            if FileManager.default.fileExists(atPath: secondaryManualPreviewArtifact.url.path) {
                return
            }
            self.secondaryManualPreviewArtifact = nil
        }
        let candidates = availableSecondaryArtifacts
        guard !candidates.isEmpty else {
            secondaryArtifactPath = nil
            return
        }
        if preferNewestAlternative {
            secondaryArtifactPath = candidates.first?.url.path
            return
        }
        if let secondaryArtifactPath,
           candidates.contains(where: { $0.url.path == secondaryArtifactPath }) {
            return
        }
        secondaryArtifactPath = candidates.first?.url.path
    }

    private func refreshOutputLogFromSelectedRun() {
        guard manualPreviewArtifact == nil, let selectedRun else {
            return
        }
        outputLog = (try? String(contentsOf: selectedRun.logURL, encoding: .utf8)) ?? ""
    }

    func updateOutputLayout(_ updates: (inout CodeOutputLayoutState) -> Void) {
        var next = outputLayout
        updates(&next)
        outputLayout = next
    }

    private static func restoreManualArtifact(from path: String?, sourceDocumentPath: String) -> ArtifactDescriptor? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ArtifactDescriptor.make(url: url, sourceDocumentPath: sourceDocumentPath, runID: nil)
    }
}

@MainActor
final class CodeDocumentStateStore: ObservableObject {
    private var states: [String: CodeDocumentUIState] = [:]

    func ensureState(for fileURL: URL) {
        guard states[fileURL.path] == nil else { return }
        let snapshot = WorkspaceSessionStore.shared.loadCodeDocumentWorkspaceState(for: fileURL.path)
        states[fileURL.path] = CodeDocumentUIState(snapshot: snapshot, fileURL: fileURL)
    }

    func state(for fileURL: URL) -> CodeDocumentUIState {
        ensureState(for: fileURL)
        return states[fileURL.path]!
    }

    func persistState(for fileURL: URL) {
        guard let state = states[fileURL.path] else { return }
        WorkspaceSessionStore.shared.saveCodeDocumentWorkspaceState(state.persistedState, for: fileURL.path)
    }

    func removeState(for fileURL: URL) {
        persistState(for: fileURL)
        states.removeValue(forKey: fileURL.path)
    }

    func removeMissingStates(keepingPaths paths: [String]) {
        let keep = Set(paths)
        for path in Array(states.keys) where !keep.contains(path) {
            WorkspaceSessionStore.shared.saveCodeDocumentWorkspaceState(states[path]!.persistedState, for: path)
            states.removeValue(forKey: path)
        }
    }
}

enum CodeRunService {
    static let maxStoredRuns = 20

    private static let supportedArtifactExtensions = EditorFileSupport.previewableArtifactExtensions
    private static let recordFileName = "run.json"
    private static let logFileName = "run.log"

    static func run(file: URL, mode: EditorDocumentMode, timeout: TimeInterval = 120) async -> CodeRunResult {
        let runID = UUID()
        let executedAt = Date()
        let artifactDirectory = runDirectoryURL(for: file, runID: runID, executedAt: executedAt)
        let basename = file.deletingPathExtension().lastPathComponent
        let currentDirectory = file.deletingLastPathComponent()

        return await Task.detached(priority: .userInitiated) {
            do {
                try prepareRunDirectory(artifactDirectory)

                let executable: String
                let args: [String]
                switch mode {
                case .python:
                    guard let pythonPath = ExecutableLocator.find(
                        "python3",
                        preferredPaths: ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
                    ) else {
                        return try makeFailureResult(
                            fileURL: file,
                            runID: runID,
                            executedAt: executedAt,
                            commandDescription: "python3 \(file.lastPathComponent)",
                            exitCode: 127,
                            outputLog: "python3 introuvable sur ce système.",
                            artifactDirectory: artifactDirectory
                        )
                    }
                    executable = pythonPath
                    args = [file.lastPathComponent]
                case .r:
                    guard let rscriptPath = ExecutableLocator.find(
                        "Rscript",
                        preferredPaths: ["/opt/homebrew/bin/Rscript", "/usr/local/bin/Rscript", "/usr/bin/Rscript"]
                    ) else {
                        return try makeFailureResult(
                            fileURL: file,
                            runID: runID,
                            executedAt: executedAt,
                            commandDescription: "Rscript \(file.lastPathComponent)",
                            exitCode: 127,
                            outputLog: "Rscript introuvable sur ce système.",
                            artifactDirectory: artifactDirectory
                        )
                    }
                    executable = rscriptPath
                    args = [file.lastPathComponent]
                case .latex, .markdown:
                    return try makeFailureResult(
                        fileURL: file,
                        runID: runID,
                        executedAt: executedAt,
                        commandDescription: file.lastPathComponent,
                        exitCode: 64,
                        outputLog: "Ce type de document n’est pas exécutable avec CodeRunService.",
                        artifactDirectory: artifactDirectory
                    )
                }

                var environment = ProcessInfo.processInfo.environment
                environment["CANOPE_ARTIFACT_DIR"] = artifactDirectory.path
                environment["CANOPE_ARTIFACT_BASENAME"] = basename
                if mode == .python, environment["MPLBACKEND"] == nil {
                    environment["MPLBACKEND"] = "Agg"
                }

                let execution = try ProcessRunner.run(
                    executable: executable,
                    args: args,
                    environment: environment,
                    currentDirectory: currentDirectory,
                    timeout: timeout
                )

                let commandDescription = "\(URL(fileURLWithPath: executable).lastPathComponent) \(file.lastPathComponent)"
                let logURL = try writeLog(execution.combinedOutput, in: artifactDirectory)
                let artifacts = discoverArtifacts(in: artifactDirectory, sourceDocumentPath: file.path, runID: runID)
                let result = CodeRunResult(
                    runID: runID,
                    executedAt: executedAt,
                    commandDescription: commandDescription,
                    exitCode: execution.exitCode,
                    timedOut: execution.timedOut,
                    outputLog: execution.combinedOutput,
                    artifactDirectory: artifactDirectory,
                    logURL: logURL,
                    artifacts: artifacts
                )
                try writeRunRecord(result.record, in: artifactDirectory)
                try pruneRunHistory(for: file, keeping: maxStoredRuns)
                return result
            } catch {
                let logURL = artifactDirectory.appendingPathComponent(logFileName, isDirectory: false)
                return CodeRunResult(
                    runID: runID,
                    executedAt: executedAt,
                    commandDescription: file.lastPathComponent,
                    exitCode: 1,
                    timedOut: false,
                    outputLog: error.localizedDescription,
                    artifactDirectory: artifactDirectory,
                    logURL: logURL,
                    artifacts: []
                )
            }
        }.value
    }

    static func artifactDirectoryURL(for fileURL: URL) -> URL {
        artifactRootDirectoryURL(for: fileURL)
    }

    static func artifactRootDirectoryURL(for fileURL: URL) -> URL {
        let projectDirectory = fileURL.deletingLastPathComponent()
        let stem = sanitizedStem(for: fileURL.deletingPathExtension().lastPathComponent)
        let suffix = shortHash(for: fileURL.path)
        return projectDirectory
            .appendingPathComponent(".canope", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("\(stem)-\(suffix)", isDirectory: true)
    }

    static func runsDirectoryURL(for fileURL: URL) -> URL {
        artifactRootDirectoryURL(for: fileURL).appendingPathComponent("runs", isDirectory: true)
    }

    static func runDirectoryURL(for fileURL: URL, runID: UUID, executedAt: Date) -> URL {
        runsDirectoryURL(for: fileURL).appendingPathComponent(runDirectoryName(for: runID, executedAt: executedAt), isDirectory: true)
    }

    static func loadRunHistory(for fileURL: URL) -> [CodeRunRecord] {
        let runsDirectory = runsDirectoryURL(for: fileURL)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .compactMap { runDirectory in
                guard let values = try? runDirectory.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else {
                    return nil
                }
                return loadRunRecord(from: runDirectory)
            }
            .sorted { $0.executedAt > $1.executedAt }
    }

    static func refresh(_ record: CodeRunRecord, sourceDocumentPath: String) -> CodeRunRecord {
        let artifacts = discoverArtifacts(in: record.artifactDirectory, sourceDocumentPath: sourceDocumentPath, runID: record.runID)
        let refreshed = CodeRunRecord(
            runID: record.runID,
            executedAt: record.executedAt,
            commandDescription: record.commandDescription,
            exitCode: record.exitCode,
            timedOut: record.timedOut,
            artifactDirectory: record.artifactDirectory,
            artifacts: artifacts,
            logURL: record.logURL
        )
        try? writeRunRecord(refreshed, in: record.artifactDirectory)
        return refreshed
    }

    static func discoverArtifacts(in directory: URL, sourceDocumentPath: String, runID: UUID?) -> [ArtifactDescriptor] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { supportedArtifactExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    return nil
                }
                return ArtifactDescriptor.make(url: url, sourceDocumentPath: sourceDocumentPath, runID: runID)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.displayName < rhs.displayName
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private static func makeFailureResult(
        fileURL: URL,
        runID: UUID,
        executedAt: Date,
        commandDescription: String,
        exitCode: Int32,
        outputLog: String,
        artifactDirectory: URL
    ) throws -> CodeRunResult {
        try prepareRunDirectory(artifactDirectory)
        let logURL = try writeLog(outputLog, in: artifactDirectory)
        let result = CodeRunResult(
            runID: runID,
            executedAt: executedAt,
            commandDescription: commandDescription,
            exitCode: exitCode,
            timedOut: false,
            outputLog: outputLog,
            artifactDirectory: artifactDirectory,
            logURL: logURL,
            artifacts: []
        )
        try writeRunRecord(result.record, in: artifactDirectory)
        try pruneRunHistory(for: fileURL, keeping: maxStoredRuns)
        return result
    }

    private static func prepareRunDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func writeRunRecord(_ record: CodeRunRecord, in directory: URL) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: directory.appendingPathComponent(recordFileName), options: .atomic)
    }

    private static func loadRunRecord(from directory: URL) -> CodeRunRecord? {
        let url = directory.appendingPathComponent(recordFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodeRunRecord.self, from: data)
    }

    private static func writeLog(_ log: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(logFileName)
        try log.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pruneRunHistory(for fileURL: URL, keeping limit: Int) throws {
        guard limit > 0 else { return }
        let history = loadRunHistory(for: fileURL)
        guard history.count > limit else { return }
        for record in history.dropFirst(limit) {
            try? FileManager.default.removeItem(at: record.artifactDirectory)
        }
    }

    private static func runDirectoryName(for runID: UUID, executedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = formatter.string(from: executedAt)
        return "\(prefix)-\(runID.uuidString.prefix(8))"
    }

    private static func sanitizedStem(for value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let raw = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let collapsed = raw.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "artifact" : trimmed
    }

    private static func shortHash(for value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

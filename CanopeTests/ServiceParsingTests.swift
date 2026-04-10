import AppKit
import PDFKit
import SwiftUI
@preconcurrency import SwiftTerm
import XCTest
@testable import Canope

final class ServiceParsingTests: XCTestCase {
    @MainActor
    private final class TerminalAppearanceTargetSpy: TerminalAppearanceApplying {
        var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        var nativeBackgroundColor: NSColor = .black
        var nativeForegroundColor: NSColor = .white
        var selectedTextBackgroundColor: NSColor = .clear
        var caretColor: NSColor = .white
        var caretTextColor: NSColor?
        var useBrightColors = true
        var installedColors: [SwiftTerm.Color] = []
        var paletteStrategy: Ansi256PaletteStrategy?
        var scrollbackLines: Int?
        var cursorStyle: CursorStyle?
        var baseBackground: SwiftTerm.Color?
        var baseForeground: SwiftTerm.Color?
        var scheduledCursorWarmupCount = 0

        func installColors(_ colors: [SwiftTerm.Color]) {
            installedColors = colors
        }

        func setAnsi256PaletteStrategy(_ strategy: Ansi256PaletteStrategy) {
            paletteStrategy = strategy
        }

        func setTerminalBaseColors(background: SwiftTerm.Color, foreground: SwiftTerm.Color) {
            baseBackground = background
            baseForeground = foreground
        }

        func setScrollbackLines(_ lines: Int?) {
            scrollbackLines = lines
        }

        func applyCursorStyle(_ style: CursorStyle) {
            cursorStyle = style
        }

        func schedulePreferredCursorWarmup() {
            scheduledCursorWarmupCount += 1
        }
    }

    private func assertColorsEqual(_ lhs: NSColor?, _ rhs: NSColor?, file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs, let rhs else {
            return XCTAssertEqual(lhs != nil, rhs != nil, file: file, line: line)
        }

        let normalizedLHS = AnnotationColor.normalized(lhs)
        let normalizedRHS = AnnotationColor.normalized(rhs)

        XCTAssertEqual(normalizedLHS.redComponent, normalizedRHS.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(normalizedLHS.greenComponent, normalizedRHS.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(normalizedLHS.blueComponent, normalizedRHS.blueComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(normalizedLHS.alphaComponent, normalizedRHS.alphaComponent, accuracy: 0.01, file: file, line: line)
    }

    private func seedCodeRun(
        for fileURL: URL,
        runID: UUID = UUID(),
        executedAt: Date,
        artifactNames: [String],
        log: String = "done"
    ) throws -> CodeRunRecord {
        let runDirectory = CodeRunService.runDirectoryURL(for: fileURL, runID: runID, executedAt: executedAt)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        for artifactName in artifactNames {
            let artifactURL = runDirectory.appendingPathComponent(artifactName)
            switch artifactURL.pathExtension.lowercased() {
            case "png":
                try Data([0x89, 0x50, 0x4e, 0x47]).write(to: artifactURL)
            default:
                try "<html><body>\(artifactName)</body></html>".write(to: artifactURL, atomically: true, encoding: .utf8)
            }
        }

        let logURL = runDirectory.appendingPathComponent("run.log")
        try log.write(to: logURL, atomically: true, encoding: .utf8)

        let record = CodeRunRecord(
            runID: runID,
            executedAt: executedAt,
            commandDescription: "python3 \(fileURL.lastPathComponent)",
            exitCode: 0,
            timedOut: false,
            artifactDirectory: runDirectory,
            artifacts: CodeRunService.discoverArtifacts(in: runDirectory, sourceDocumentPath: fileURL.path, runID: runID),
            logURL: logURL
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: runDirectory.appendingPathComponent("run.json"), options: .atomic)
        return record
    }

    func testParseLatexErrorsCapturesErrorsAndWarnings() {
        let log = """
        ! Undefined control sequence.
        l.42 \\badcommand
        LaTeX Warning: Label `sec:test' multiply defined.
        """

        let results = LaTeXCompiler.parseErrors(log: log, fileName: "sample.tex")

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.line, 42)
        XCTAssertEqual(results.first?.message, "Undefined control sequence.")
        XCTAssertEqual(results.first?.file, "sample.tex")
        XCTAssertEqual(results.first?.isWarning, false)
        XCTAssertEqual(results.last?.isWarning, true)
        XCTAssertTrue(results.last?.message.contains("Label `sec:test' multiply defined.") == true)
    }

    func testParseForwardSyncOutput() {
        let output = """
        This is SyncTeX command line utility, version 1.7
        Page:3
        h:120.5
        v:480.25
        W:40
        H:12
        """

        let result = SyncTeXService.parseForwardOutput(output)

        XCTAssertEqual(result?.page, 3)
        XCTAssertEqual(Double(result?.h ?? 0), 120.5, accuracy: 0.001)
        XCTAssertEqual(Double(result?.v ?? 0), 480.25, accuracy: 0.001)
        XCTAssertEqual(Double(result?.width ?? 0), 40, accuracy: 0.001)
        XCTAssertEqual(Double(result?.height ?? 0), 12, accuracy: 0.001)
    }

    func testParseInverseSyncOutput() {
        let output = """
        SyncTeX result begin
        Input:/tmp/project/main.tex
        Line:87
        Column:14
        Offset:6
        Context:contributions scientifiques
        SyncTeX result end
        """

        let result = SyncTeXService.parseInverseOutput(output)

        XCTAssertEqual(result?.file, "/tmp/project/main.tex")
        XCTAssertEqual(result?.line, 87)
        XCTAssertEqual(result?.column, 14)
        XCTAssertEqual(result?.offset, 6)
        XCTAssertEqual(result?.context, "contributions scientifiques")
    }

    func testParseInverseSyncOutputKeepsFirstMatchWhenMultipleRecordsAreReturned() {
        let output = """
        SyncTeX result begin
        Output:/tmp/project/main.pdf
        Input:/tmp/project/main.tex
        Line:87
        Column:-1
        SyncTeX result end
        SyncTeX result begin
        Output:/tmp/project/main.pdf
        Input:/tmp/project/other.tex
        Line:144
        Column:-1
        SyncTeX result end
        """

        let result = SyncTeXService.parseInverseOutput(output)

        XCTAssertEqual(result?.file, "/tmp/project/main.tex")
        XCTAssertEqual(result?.line, 87)
        XCTAssertEqual(result?.column, -1)
    }

    func testParseForwardSyncOutputKeepsFirstMatchWhenMultipleRecordsAreReturned() {
        let output = """
        SyncTeX result begin
        Page:2
        h:120.5
        v:480.25
        W:40
        H:12
        SyncTeX result end
        SyncTeX result begin
        Page:5
        h:42
        v:84
        W:20
        H:10
        SyncTeX result end
        """

        let result = SyncTeXService.parseForwardOutput(output)

        XCTAssertEqual(result?.page, 2)
        XCTAssertEqual(Double(result?.h ?? 0), 120.5, accuracy: 0.001)
        XCTAssertEqual(Double(result?.v ?? 0), 480.25, accuracy: 0.001)
        XCTAssertEqual(Double(result?.width ?? 0), 40, accuracy: 0.001)
        XCTAssertEqual(Double(result?.height ?? 0), 12, accuracy: 0.001)
    }

    func testProcessRunnerCapturesStdoutAndStderr() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            args: ["-c", "printf 'out'; printf 'err' 1>&2"],
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.combinedOutput, "out\nerr")
    }

    func testProcessRunnerTimesOutLongRunningCommand() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            args: ["-c", "sleep 2"],
            timeout: 0.2
        )

        XCTAssertTrue(result.timedOut)
    }

    func testExecutableLocatorFindsPreferredExecutable() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("fake-tool")
        let script = "#!/bin/sh\nexit 0\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let located = ExecutableLocator.find("fake-tool", preferredPaths: [scriptURL.path])

        XCTAssertEqual(located, scriptURL.path)
    }

    func testClaudeIDESelectionStateTracksZeroBasedLineAndCharacterOffsets() {
        let text = "alpha\nbeta\ngamma"
        let state = ClaudeIDESelectionState.make(
            text: text,
            fileURL: URL(fileURLWithPath: "/tmp/main.tex"),
            range: NSRange(location: 2, length: 7)
        )

        XCTAssertEqual(state?.filePath, "/tmp/main.tex")
        XCTAssertEqual(state?.text, "pha\nbet")
        XCTAssertEqual(state?.selection.start.line, 0)
        XCTAssertEqual(state?.selection.start.character, 2)
        XCTAssertEqual(state?.selection.end.line, 1)
        XCTAssertEqual(state?.selection.end.character, 3)
        XCTAssertEqual(state?.lineText, "alpha\nbeta")
        XCTAssertEqual(state?.selectionLineContext, "al[[pha\nbet]]a")
    }

    func testClaudeIDESelectionStatePreservesCollapsedSelectionsForCursorUpdates() {
        let text = "alpha\nbeta"
        let state = ClaudeIDESelectionState.make(
            text: text,
            fileURL: URL(fileURLWithPath: "/tmp/main.tex"),
            range: NSRange(location: 6, length: 0)
        )

        XCTAssertEqual(state?.text, "")
        XCTAssertEqual(state?.selection.start.line, 1)
        XCTAssertEqual(state?.selection.start.character, 0)
        XCTAssertEqual(state?.selection.end.line, 1)
        XCTAssertEqual(state?.selection.end.character, 0)
    }

    func testClaudeIDESelectionStateSnapshotUsesSelectionTextAsStandaloneBuffer() {
        let state = ClaudeIDESelectionState.makeSnapshot(
            selectedText: "alpha\nbeta",
            fileURL: URL(fileURLWithPath: "/tmp/paper.pdf")
        )

        XCTAssertEqual(state.filePath, "/tmp/paper.pdf")
        XCTAssertEqual(state.text, "alpha\nbeta")
        XCTAssertEqual(state.selection.start.line, 0)
        XCTAssertEqual(state.selection.start.character, 0)
        XCTAssertEqual(state.selection.end.line, 1)
        XCTAssertEqual(state.selection.end.character, 4)
    }

    func testDiffEngineBlocksPreserveRemovedLineSpan() {
        let blocks = DiffEngine.blocks(
            old: "alpha\nbeta\ngamma\ndelta",
            new: "alpha\ndelta"
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .removed)
        XCTAssertEqual(blocks.first?.oldLines, ["beta", "gamma"])
        XCTAssertEqual(blocks.first?.newLines, [])
        XCTAssertEqual(blocks.first?.startLine, 2)
        XCTAssertEqual(blocks.first?.endLine, 3)
        XCTAssertEqual(blocks.first?.oldLineRange, 1..<3)
        XCTAssertEqual(blocks.first?.newLineRange, 1..<1)
    }

    func testDiffEngineReplaceBlockPreservesTrailingNewline() {
        let blocks = DiffEngine.blocks(
            old: "alpha\nbeta\n",
            new: "alpha\ngamma\n"
        )
        guard let block = blocks.first else {
            return XCTFail("Expected a diff block")
        }

        let accepted = DiffEngine.replacingOldBlock(in: "alpha\nbeta\n", with: block)
        let rejected = DiffEngine.replacingNewBlock(in: "alpha\ngamma\n", with: block)

        XCTAssertEqual(accepted, "alpha\ngamma\n")
        XCTAssertEqual(rejected, "alpha\nbeta\n")
    }

    func testDiffEngineBlocksIgnorePhantomTrailingEmptyLine() {
        let blocks = DiffEngine.blocks(
            old: "alpha\n",
            new: "alpha\n"
        )

        XCTAssertTrue(blocks.isEmpty)
    }

    func testDiffEngineInlinePresentationTracksInsertionsAndDeletions() {
        let presentation = DiffEngine.inlinePresentation(
            old: "sexualite humaine",
            new: "sexualite tres humaine"
        )

        XCTAssertEqual(presentation.insertedRanges, [
            NSRange(location: 10, length: 5)
        ])
        XCTAssertTrue(presentation.deletedWidgets.isEmpty)
    }

    func testDiffEngineInlinePresentationKeepsDeletedWidgetAnchor() {
        let presentation = DiffEngine.inlinePresentation(
            old: "organismes vivants",
            new: "organismes"
        )

        XCTAssertTrue(presentation.insertedRanges.isEmpty)
        XCTAssertEqual(presentation.deletedWidgets, [
            .init(anchorOffset: 10, text: " vivants")
        ])
    }

    func testDiffEngineReviewBlocksCreateModifiedRowsForSingleLineChanges() {
        let reviewBlocks = DiffEngine.reviewBlocks(
            old: "alpha beta\n",
            new: "alpha gamma\n"
        )

        XCTAssertEqual(reviewBlocks.count, 1)
        XCTAssertEqual(reviewBlocks[0].block.kind, .modified)
        XCTAssertEqual(reviewBlocks[0].rows.count, 1)
        XCTAssertEqual(reviewBlocks[0].rows[0].kind, .modified)
        XCTAssertTrue(reviewBlocks[0].rows[0].oldSpans.contains { $0.kind == .delete && $0.text.contains("bet") })
        XCTAssertTrue(reviewBlocks[0].rows[0].newSpans.contains { $0.kind == .insert && $0.text.contains("gamm") })
        XCTAssertEqual(reviewBlocks[0].preferredRevealLine, 1)
    }

    func testDiffEngineReviewBlocksSplitRemovedAndAddedRowsWhenLineCountsDiffer() {
        let reviewBlocks = DiffEngine.reviewBlocks(
            old: "alpha\nbeta\ngamma\n",
            new: "alpha\nbeta modifiee\nnouvelle ligne\ngamma\n"
        )

        XCTAssertEqual(reviewBlocks.count, 1)
        XCTAssertEqual(reviewBlocks[0].block.kind, .modified)
        XCTAssertEqual(reviewBlocks[0].rows.map(\.kind), [.removed, .added, .added])
        XCTAssertEqual(reviewBlocks[0].rows.first?.oldSpans.first?.text, "beta")
        XCTAssertEqual(reviewBlocks[0].rows.dropFirst().first?.newSpans.first?.text, "beta modifiee")
        XCTAssertEqual(reviewBlocks[0].preferredRevealLine, 2)
    }

    func testDiffEngineReviewBlocksSplitPureAdditionsPerLine() {
        let reviewBlocks = DiffEngine.reviewBlocks(
            old: "alpha\n",
            new: "alpha\nbeta\ngamma\n"
        )

        XCTAssertEqual(reviewBlocks.count, 1)
        XCTAssertEqual(reviewBlocks[0].block.kind, .added)
        XCTAssertEqual(reviewBlocks[0].rows.map(\.kind), [.added, .added])
        XCTAssertEqual(reviewBlocks[0].rows.map(\.newLineOffset), [0, 1])
    }

    func testDiffEngineReviewBlocksSplitPureRemovalsPerLine() {
        let reviewBlocks = DiffEngine.reviewBlocks(
            old: "alpha\nbeta\ngamma\n",
            new: "alpha\n"
        )

        XCTAssertEqual(reviewBlocks.count, 1)
        XCTAssertEqual(reviewBlocks[0].block.kind, .removed)
        XCTAssertEqual(reviewBlocks[0].rows.map(\.kind), [.removed, .removed])
        XCTAssertEqual(reviewBlocks[0].rows.map(\.oldLineOffset), [0, 1])
    }

    func testClaudeCLIWrapperServicePrependsWrapperDirectoryToPATHOnce() {
        let environment = [
            "TERM=xterm-256color",
            "PATH=/usr/bin:/bin:/usr/bin",
        ]

        let updated = ClaudeCLIWrapperService.prependingToPATH("/tmp/canope-cli-bin", in: environment)
        let path = updated.first(where: { $0.hasPrefix("PATH=") })

        XCTAssertEqual(path, "PATH=/tmp/canope-cli-bin:/usr/bin:/bin")
        XCTAssertEqual(updated.filter { $0.hasPrefix("PATH=") }.count, 1)
    }

    func testClaudeCLIWrapperScriptInjectsIDEFlagsForInteractiveSessions() {
        let script = ClaudeCLIWrapperService.wrapperScript(realClaudePath: "/Users/tofunori/.local/bin/claude")

        XCTAssertTrue(script.contains("exec \"$REAL_CLAUDE\" --append-system-prompt \"$APPEND_SYSTEM_PROMPT\" --mcp-config \"$MCP_CONFIG\" --ide \"$@\""))
        XCTAssertTrue(script.contains("exec \"$REAL_CLAUDE\" --append-system-prompt \"$APPEND_SYSTEM_PROMPT\" --mcp-config \"$MCP_CONFIG\" \"$@\""))
        XCTAssertTrue(script.contains("auth|doctor|install|mcp|plugin|plugins|setup-token|update|upgrade|agents|auto-mode"))
        XCTAssertTrue(script.contains("--mcp-config=*"))
        XCTAssertTrue(script.contains("--append-system-prompt=*"))
        XCTAssertTrue(script.contains("/tmp/canopee_paper.txt"))
    }

    func testClaudeCLIWrapperScriptIncludesCanopeSessionPrompt() {
        let prompt = ClaudeCLIWrapperService.canopeSessionSystemPrompt()

        XCTAssertTrue(prompt.contains("sélection IDE"))
        XCTAssertTrue(prompt.contains("/tmp/canopee_paper.txt"))
        XCTAssertTrue(prompt.contains("pdf-selection"))
    }

    func testClaudeCLIWrapperZshBootstrapRCReappliesWrapperAfterUserZshrc() {
        let script = ClaudeCLIWrapperService.zshBootstrapRC(
            sourceDirectory: "/Users/tofunori",
            wrapperDirectory: "/tmp/canope-cli-bin",
            claudeWrapperPath: "/tmp/canope-cli-bin/claude",
            codexWrapperPath: "/tmp/canope-cli-bin/codex",
            opencodeWrapperPath: nil,
            mcpConfigPath: "/tmp/canope_claude_ide_mcp.json",
            alternateMcpConfigPath: "/tmp/canopee_claude_ide_mcp.json",
            bridgeURL: "http://127.0.0.1:8765/sse"
        )

        XCTAssertTrue(script.contains("source '/Users/tofunori/.zshrc'"))
        XCTAssertTrue(script.contains("export PATH='/tmp/canope-cli-bin':$PATH"))
        XCTAssertTrue(script.contains("alias claude='/tmp/canope-cli-bin/claude'"))
        XCTAssertTrue(script.contains("alias codex='/tmp/canope-cli-bin/codex'"))
        XCTAssertTrue(script.contains("export CANOPE_CLAUDE_IDE_MCP_CONFIG='/tmp/canope_claude_ide_mcp.json'"))
        XCTAssertTrue(script.contains("hash -r 2>/dev/null || rehash 2>/dev/null || true"))
    }

    func testClaudeCLIWrapperZshBootstrapRCInjectsOpencodeAliasOnlyWhenConfigured() {
        let withoutOpencode = ClaudeCLIWrapperService.zshBootstrapRC(
            sourceDirectory: "/Users/tofunori",
            wrapperDirectory: "/tmp/canope-cli-bin",
            claudeWrapperPath: "/tmp/canope-cli-bin/claude",
            codexWrapperPath: "/tmp/canope-cli-bin/codex",
            opencodeWrapperPath: nil,
            mcpConfigPath: "/tmp/canope_claude_ide_mcp.json",
            alternateMcpConfigPath: "/tmp/canopee_claude_ide_mcp.json",
            bridgeURL: "http://127.0.0.1:8765/sse"
        )
        let withOpencode = ClaudeCLIWrapperService.zshBootstrapRC(
            sourceDirectory: "/Users/tofunori",
            wrapperDirectory: "/tmp/canope-cli-bin",
            claudeWrapperPath: "/tmp/canope-cli-bin/claude",
            codexWrapperPath: "/tmp/canope-cli-bin/codex",
            opencodeWrapperPath: "/tmp/canope-cli-bin/opencode",
            mcpConfigPath: "/tmp/canope_claude_ide_mcp.json",
            alternateMcpConfigPath: "/tmp/canopee_claude_ide_mcp.json",
            bridgeURL: "http://127.0.0.1:8765/sse"
        )

        XCTAssertFalse(withoutOpencode.contains("alias opencode="))
        XCTAssertTrue(withOpencode.contains("alias opencode='/tmp/canope-cli-bin/opencode'"))
    }

    func testCodexWrapperScriptInjectsCanopeBridgeForInteractiveSessions() {
        let script = ClaudeCLIWrapperService.codexWrapperScript(realCodexPath: "/opt/homebrew/bin/codex")

        XCTAssertTrue(script.contains("REAL_CODEX='/opt/homebrew/bin/codex'"))
        XCTAssertTrue(script.contains("instructions=\\\"$DEVELOPER_INSTRUCTIONS\\\""))
        XCTAssertTrue(script.contains("developer_instructions=\\\"$DEVELOPER_INSTRUCTIONS\\\""))
        XCTAssertTrue(script.contains("mcp_servers.canope.type=\\\"stdio\\\""))
        XCTAssertTrue(script.contains("mcp_servers.canope.command=\\\"npx\\\""))
        XCTAssertTrue(script.contains("mcp_servers.canope.args=[\\\"-y\\\",\\\"mcp-remote\\\",\\\"$BRIDGE_URL\\\",\\\"--transport\\\",\\\"sse-only\\\"]"))
        XCTAssertTrue(script.contains("login|logout|mcp|completion|debug|app|app-server|help|features"))
        XCTAssertTrue(script.contains("mcp-remote"))
        XCTAssertTrue(script.contains("--transport"))
        XCTAssertTrue(script.contains("sse-only"))
    }

    func testCodexDeveloperInstructionsReferenceCurrentPaperTool() {
        let prompt = ClaudeCLIWrapperService.canopeCodexDeveloperInstructions()

        XCTAssertTrue(prompt.contains("getCurrentSelection"))
        XCTAssertTrue(prompt.contains("getCurrentPaper"))
        XCTAssertTrue(prompt.contains("no PDF is attached"))
    }

    func testClaudeCLIWrapperApplyKeepsWrapperVisibleInsideLoginZsh() throws {
        let environment = ClaudeCLIWrapperService.shared.apply(
            to: ["PATH=/usr/bin:/bin"],
            shellPath: "/bin/zsh"
        )
        let environmentDictionary = Dictionary(
            uniqueKeysWithValues: environment.compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        XCTAssertEqual(environmentDictionary["ZDOTDIR"], "/tmp/canope-zdotdir")

        let result = try ProcessRunner.run(
            executable: "/bin/zsh",
            args: ["-lic", "type claude"],
            environment: environmentDictionary,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("/tmp/canope-cli-bin/claude"))
    }

    func testClaudeCLIWrapperApplyKeepsCodexWrapperVisibleInsideLoginZsh() throws {
        let environment = ClaudeCLIWrapperService.shared.apply(
            to: ["PATH=/usr/bin:/bin"],
            shellPath: "/bin/zsh"
        )
        let environmentDictionary = Dictionary(
            uniqueKeysWithValues: environment.compactMap { entry -> (String, String)? in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
        )

        let result = try ProcessRunner.run(
            executable: "/bin/zsh",
            args: ["-lic", "type codex"],
            environment: environmentDictionary,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("/tmp/canope-cli-bin/codex"))
    }

    func testBridgeCommandWatcherNormalizedBridgeTextCollapsesPDFFormattingNoise() {
        let normalized = BridgeCommandWatcher.normalizedBridgeText("L’e\u{0301}volution-\nhumaine\u{00A0} \n")

        XCTAssertEqual(normalized, "l'evolutionhumaine")
    }

    func testBridgeCommandWatcherSearchVariantsIncludeWhitespaceAndPunctuationFallbacks() {
        let variants = BridgeCommandWatcher.searchVariants(for: "L’evolution-\n humaine")

        XCTAssertTrue(variants.contains("L’evolution-\n humaine"))
        XCTAssertTrue(variants.contains("L'evolution- humaine") || variants.contains("L'evolution-\n humaine"))
        XCTAssertTrue(variants.contains("L'evolution humaine") || variants.contains("L'evolution- humaine"))
        XCTAssertFalse(variants.isEmpty)
    }

    func testBridgeCommandWatcherMatchScorePrefersExactPageAndExactText() {
        let target = BridgeCommandWatcher.normalizedBridgeText("Les resultats principaux")
        let exactScore = BridgeCommandWatcher.bridgeMatchScore(
            originalText: "Les resultats principaux",
            candidateText: "Les resultats principaux",
            normalizedTarget: target,
            pageHint: 5,
            candidatePages: [5],
            variantIndex: 0
        )
        let weakerScore = BridgeCommandWatcher.bridgeMatchScore(
            originalText: "Les resultats principaux",
            candidateText: "Les resultats principaux",
            normalizedTarget: target,
            pageHint: 5,
            candidatePages: [2],
            variantIndex: 2
        )

        XCTAssertGreaterThan(exactScore, weakerScore)
    }

    @MainActor
    func testBridgeCommandRouterDispatchesToPreferredHandler() {
        let router = BridgeCommandRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        var receivedByFirst = false
        var receivedCommand: [String: Any]?

        router.setActiveHandler(id: "first") { _ in
            receivedByFirst = true
        }
        router.setActiveHandler(id: "preferred") { command in
            receivedCommand = command
        }
        router.setPreferredHandler(id: "preferred")

        let dispatched = router.dispatch(command: ["kind": "annotate", "text": "alpha"])

        XCTAssertTrue(dispatched)
        XCTAssertFalse(receivedByFirst)
        XCTAssertEqual(receivedCommand?["kind"] as? String, "annotate")
        XCTAssertEqual(receivedCommand?["text"] as? String, "alpha")
    }

    @MainActor
    func testBridgeCommandRouterFallsBackToSoleRegisteredHandler() {
        let router = BridgeCommandRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        var receivedCommand: [String: Any]?
        router.setActiveHandler(id: "only") { command in
            receivedCommand = command
        }

        let dispatched = router.dispatch(command: ["text": "beta"])

        XCTAssertTrue(dispatched)
        XCTAssertEqual(receivedCommand?["text"] as? String, "beta")
    }

    @MainActor
    func testBridgeCommandRouterRemovingPreferredHandlerClearsPreference() {
        let router = BridgeCommandRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        var receivedCount = 0
        router.setActiveHandler(id: "first") { _ in
            receivedCount += 1
        }
        router.setActiveHandler(id: "preferred") { _ in
            receivedCount += 1
        }
        router.setActiveHandler(id: "third") { _ in
            receivedCount += 1
        }
        router.setPreferredHandler(id: "preferred")
        router.removeActiveHandler(id: "preferred")

        let dispatched = router.dispatch(command: ["text": "gamma"])

        XCTAssertFalse(dispatched)
        XCTAssertEqual(receivedCount, 0)
    }

    func testAnnotationServiceApplyColorUpdatesStandardMarkupColor() {
        let annotation = PDFAnnotation(bounds: .init(x: 0, y: 0, width: 10, height: 10), forType: .highlight, withProperties: nil)
        let color = NSColor.systemBlue

        AnnotationService.applyColor(color, to: annotation)

        assertColorsEqual(annotation.color, AnnotationColor.annotationColor(color, for: annotation.type ?? ""))
    }

    func testAnnotationServiceApplyColorUpdatesTextBoxFillColor() {
        let annotation = PDFAnnotation(bounds: .init(x: 0, y: 0, width: 40, height: 20), forType: .freeText, withProperties: nil)
        let color = NSColor.systemPink

        AnnotationService.applyColor(color, to: annotation)

        assertColorsEqual(annotation.textBoxFillColor, AnnotationColor.annotationColor(color, for: "FreeText"))
    }

    func testTerminalAppearanceStateDefaultsMatchGhosttyBaseline() {
        let state = TerminalAppearanceState()

        XCTAssertEqual(state.fontFamily, "SF Mono")
        XCTAssertEqual(state.fontSize, 14)
        XCTAssertEqual(state.cursorStyle, .blinkBar)
        XCTAssertEqual(state.darkThemePresetID, TerminalThemePreset.ghosttyDefaultDark.id)
        XCTAssertEqual(state.lightThemePresetID, TerminalThemePreset.builtinTangoLight.id)
        XCTAssertEqual(state.dividerColorDark, "#3f3f46")
        XCTAssertEqual(state.dividerColorLight, "#d4d4d8")
        XCTAssertEqual(state.inactivePaneOpacity, 0.8)
        XCTAssertEqual(state.activePaneOpacity, 1)
        XCTAssertEqual(state.dividerThickness, 3)
        XCTAssertEqual(state.terminalPadding, 4)
    }

    func testTerminalAppearanceStateCodableRoundTrip() throws {
        let state = TerminalAppearanceState(
            fontFamily: "Menlo",
            fontSize: 15,
            cursorStyle: .steadyBlock,
            useBrightColors: false,
            darkThemePresetID: TerminalThemePreset.canopeClassic.id,
            lightThemePresetID: TerminalThemePreset.builtinTangoLight.id,
            useSeparateLightTheme: true,
            dividerColorDark: "#101010",
            dividerColorLight: "#efefef",
            inactivePaneOpacity: 0.65,
            activePaneOpacity: 0.95,
            dividerThickness: 5,
            terminalPadding: 6,
            scrollbackLines: 12000
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalAppearanceState.self, from: encoded)

        XCTAssertEqual(decoded, state)
    }

    func testTerminalAppearanceResolvedThemeUsesSeparateLightPresetWhenEnabled() {
        var state = TerminalAppearanceState()
        state.useSeparateLightTheme = true
        state.lightThemePresetID = TerminalThemePreset.builtinTangoLight.id
        state.darkThemePresetID = TerminalThemePreset.canopeClassic.id

        XCTAssertEqual(state.resolvedThemePresetID(for: .light), TerminalThemePreset.builtinTangoLight.id)
        XCTAssertEqual(state.resolvedThemePresetID(for: .dark), TerminalThemePreset.canopeClassic.id)
    }

    func testGhosttyPresetUsesExpectedAnsiColors() {
        let preset = TerminalThemePreset.ghosttyDefaultDark

        XCTAssertEqual(preset.ansiColors.count, 16)
        assertColorsEqual(preset.background, NSColor(hex: "#282c34", fallback: .black))
        assertColorsEqual(preset.selectionBackground, NSColor(hex: "#3e4451", fallback: .black))
        assertColorsEqual(preset.ansiColors[1], NSColor(hex: "#cc6666", fallback: .red))
        assertColorsEqual(preset.ansiColors[10], NSColor(hex: "#b9ca4a", fallback: .green))
        assertColorsEqual(preset.ansiColors[15], NSColor(hex: "#eaeaea", fallback: .white))
    }

    @MainActor
    func testTerminalAppearanceApplicatorConfiguresTerminalTarget() {
        let spy = TerminalAppearanceTargetSpy()
        var state = TerminalAppearanceState()
        state.fontFamily = "Menlo"
        state.fontSize = 15
        state.cursorStyle = .steadyUnderline
        state.useBrightColors = false
        state.scrollbackLines = 9000

        TerminalAppearanceApplicator.apply(appearance: state, colorScheme: .dark, to: spy)

        XCTAssertEqual(spy.font.pointSize, 15, accuracy: 0.1)
        XCTAssertEqual(spy.paletteStrategy, .base16Lab)
        XCTAssertFalse(spy.useBrightColors)
        XCTAssertEqual(spy.scrollbackLines, 9000)
        XCTAssertEqual(spy.cursorStyle, .steadyUnderline)
        XCTAssertEqual(spy.installedColors.count, 16)
        XCTAssertEqual(spy.scheduledCursorWarmupCount, 1)
        assertColorsEqual(spy.nativeBackgroundColor, TerminalThemePreset.ghosttyDefaultDark.background)
        assertColorsEqual(spy.caretColor, TerminalThemePreset.ghosttyDefaultDark.cursor)
    }

    func testAppChromePaletteTabFillTokensPrioritizeSelectionThenHover() {
        XCTAssertEqual(AppChromePalette.tabFillToken(isSelected: false, isHovered: false), .idle)
        XCTAssertEqual(AppChromePalette.tabFillToken(isSelected: false, isHovered: true), .hovered)
        XCTAssertEqual(AppChromePalette.tabFillToken(isSelected: true, isHovered: false), .selected)
        XCTAssertEqual(AppChromePalette.tabFillToken(isSelected: true, isHovered: true), .selected)
    }

    func testEditorDocumentModeRecognizesPythonAndR() {
        XCTAssertEqual(EditorDocumentMode(fileURL: URL(fileURLWithPath: "/tmp/test.py")), .python)
        XCTAssertEqual(EditorDocumentMode(fileURL: URL(fileURLWithPath: "/tmp/test.R")), .r)
        XCTAssertEqual(EditorDocumentMode(fileURL: URL(fileURLWithPath: "/tmp/test.md")), .markdown)
        XCTAssertEqual(EditorDocumentMode(fileURL: URL(fileURLWithPath: "/tmp/test.tex")), .latex)
    }

    func testMarkdownModeUsesDedicatedInlineEditor() {
        XCTAssertTrue(EditorDocumentMode(fileURL: URL(fileURLWithPath: "/tmp/test.md")).usesDedicatedInlineEditor)
        XCTAssertFalse(EditorDocumentMode(fileURL: URL(fileURLWithPath: "/tmp/test.tex")).usesDedicatedInlineEditor)
    }

    func testMarkdownFormatterParsesSharedBlockKinds() {
        let source = """
        # Title

        - first
        - second

        > quoted

        ```swift
        print("hi")
        ```
        """

        let blocks = MarkdownFormatter.parseBlocks(source)

        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .list(items: ["first", "second"], ordered: false))
        XCTAssertEqual(blocks[2], .blockquote(text: "quoted"))
        XCTAssertEqual(blocks[3], .code(language: "swift", content: #"print("hi")"#))
    }

    func testMarkdownSourceStylingPreservesCanonicalMarkdownText() {
        let source = "# Heading\n\nA **bold** [link](https://example.com) and `code`."
        let storage = NSTextStorage(string: source)

        MarkdownFormatter.styleSource(
            text: source,
            storage: storage,
            fontSize: 14,
            theme: .dark,
            displayMode: .livePreview
        )

        XCTAssertEqual(storage.string, source)
    }

    func testMarkdownSourceStylingAppliesHeadingLinkAndCodeAttributes() {
        let source = "# Heading\n\nA [link](https://example.com) with `code`."
        let storage = NSTextStorage(string: source)
        let theme = MarkdownTheme.dark

        MarkdownFormatter.styleSource(
            text: source,
            storage: storage,
            fontSize: 14,
            theme: theme,
            displayMode: .livePreview,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let nsSource = source as NSString
        let headingFont = storage.attribute(.font, at: nsSource.range(of: "Heading").location, effectiveRange: nil) as? NSFont
        let linkColor = storage.attribute(.foregroundColor, at: nsSource.range(of: "link").location, effectiveRange: nil) as? NSColor
        let codeBackground = storage.attribute(.backgroundColor, at: nsSource.range(of: "code").location, effectiveRange: nil) as? NSColor

        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, 14)
        assertColorsEqual(linkColor, theme.accentColor)
        assertColorsEqual(codeBackground, theme.codeBackgroundColor)
    }

    func testMarkdownPreviewRendererPreviewURLRemainsSeparateFromInlineEditor() {
        let markdownURL = URL(fileURLWithPath: "/tmp/notes.md")
        XCTAssertEqual(MarkdownPreviewRenderer.previewURL(for: markdownURL).path, "/tmp/notes.pdf")
    }

    func testMarkdownSourceModeLeavesHeadingAtBaseFontSize() {
        let source = "# Heading"
        let storage = NSTextStorage(string: source)

        MarkdownFormatter.styleSource(
            text: source,
            storage: storage,
            fontSize: 14,
            theme: .dark,
            displayMode: .source
        )

        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(headingFont?.pointSize ?? 0, 14, accuracy: 0.1)
    }

    func testMarkdownLivePreviewHidesInactiveHeadingMarker() {
        let source = "# Heading\n\nBody"
        let storage = NSTextStorage(string: source)

        MarkdownFormatter.styleSource(
            text: source,
            storage: storage,
            fontSize: 14,
            theme: .dark,
            displayMode: .livePreview,
            selectedRange: NSRange(location: source.count - 1, length: 0)
        )

        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let markerFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        assertColorsEqual(markerColor, .clear)
        XCTAssertLessThan(markerFont?.pointSize ?? 1, 1)
    }

    func testMarkdownLivePreviewShowsActiveHeadingMarker() {
        let source = "# Heading"
        let storage = NSTextStorage(string: source)

        MarkdownFormatter.styleSource(
            text: source,
            storage: storage,
            fontSize: 14,
            theme: .dark,
            displayMode: .livePreview,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertGreaterThan(AnnotationColor.normalized(markerColor ?? .clear).alphaComponent, 0.05)
    }

    func testLaTeXEditorWorkspaceStateRoundTripsMarkdownEditorMode() throws {
        let snapshot = LaTeXEditorWorkspaceState(
            showSidebar: true,
            selectedSidebarSection: .files,
            sidebarWidth: 220,
            showEditorPane: true,
            showPDFPreview: false,
            showErrors: false,
            splitLayout: .editorOnly,
            panelArrangement: .terminalEditorContent,
            threePaneLeadingWidth: nil,
            threePaneTrailingWidth: nil,
            editorFontSize: 14,
            editorTheme: 1,
            markdownEditorMode: .source,
            referencePaperIDs: [],
            selectedReferencePaperID: nil,
            layoutBeforeReference: nil,
            workspaceRootPath: "/tmp"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LaTeXEditorWorkspaceState.self, from: data)

        XCTAssertEqual(decoded.markdownEditorMode, .source)
        XCTAssertEqual(decoded.selectedSidebarSection, .files)
        XCTAssertEqual(decoded.splitLayout, .editorOnly)
        XCTAssertEqual(decoded.workspaceRootPath, "/tmp")
    }

    func testLaTeXEditorWorkspaceStateDecodesLegacyStringBackedLayoutState() throws {
        let data = Data(
            #"""
            {
              "showSidebar": true,
              "selectedSidebarSection": "annotations",
              "sidebarWidth": 220,
              "showEditorPane": true,
              "showPDFPreview": true,
              "showErrors": false,
              "splitLayout": "horizontal",
              "panelArrangement": "terminalEditorPDF",
              "editorFontSize": 14,
              "editorTheme": 1,
              "markdownEditorMode": "livePreview",
              "referencePaperIDs": [],
              "layoutBeforeReference": "editorOnly",
              "workspaceRootPath": "/tmp/project"
            }
            """#.utf8
        )

        let decoded = try JSONDecoder().decode(LaTeXEditorWorkspaceState.self, from: data)

        XCTAssertEqual(decoded.selectedSidebarSection, .annotations)
        XCTAssertEqual(decoded.splitLayout, .horizontal)
        XCTAssertEqual(decoded.panelArrangement, .terminalEditorContent)
        XCTAssertEqual(decoded.layoutBeforeReference, .editorOnly)
        XCTAssertEqual(decoded.workspaceRootPath, "/tmp/project")
    }

    @MainActor
    func testEditorDocumentStateStoreReusesStatePerPathAndDropsRemovedPaths() {
        let store = EditorDocumentStateStore()
        let firstURL = URL(fileURLWithPath: "/tmp/main.tex")
        let secondURL = URL(fileURLWithPath: "/tmp/notes.md")

        let firstState = store.stateOrCreate(for: firstURL)
        firstState.text = "bonjour"

        let reusedState = store.stateOrCreate(for: firstURL)
        XCTAssertTrue(firstState === reusedState)
        XCTAssertEqual(reusedState.text, "bonjour")

        _ = store.stateOrCreate(for: secondURL)
        store.removeMissingStates(keepingPaths: [firstURL.path])

        let recreatedSecondState = store.stateOrCreate(for: secondURL)
        XCTAssertFalse(recreatedSecondState === firstState)
        XCTAssertEqual(recreatedSecondState.text, "")
    }

    func testClaudeResumeStripsInjectedIDEContextFromUserMessage() {
        let raw = """
        [Canope IDE Context — current selection in "sample.pdf"]
        (no text currently selected)
        
        [Selected line context]
        foo[[bar]]
        [/Selected line context]
        [/Canope IDE Context]

        il est ou?
        """

        let cleaned = ClaudeHeadlessProvider.cleanedResumedUserMessage(raw)

        XCTAssertEqual(cleaned, "il est ou?")
    }

    func testClaudeBuildPromptWithIDEContextIncludesSelectedLineContextWhenAvailable() throws {
        let path = CanopeContextFiles.ideSelectionStatePaths[0]
        let payload: [String: Any] = [
            "filePath": "/tmp/main.tex",
            "text": "right=2.0cm]{",
            "lineText": "\\begin{adjustwidth}{0cm}{right=2.0cm]{",
            "selectionLineContext": "\\begin{adjustwidth}{0cm}{[[right=2.0cm]{",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let out = ClaudeHeadlessProvider.buildPromptWithIDEContext("met ca a 1cm")
        XCTAssertTrue(out.contains("[Selected line context]"))
        XCTAssertTrue(out.contains("\\begin{adjustwidth}{0cm}{[[right=2.0cm]{"))
        XCTAssertTrue(out.contains("met ca a 1cm"))
    }

    func testArtifactDescriptorMapsPreviewableKinds() {
        let basePath = "/tmp/example"
        XCTAssertEqual(ArtifactDescriptor.make(url: URL(fileURLWithPath: "\(basePath).pdf"), sourceDocumentPath: "/tmp/script.py", runID: nil)?.kind, .pdf)
        XCTAssertEqual(ArtifactDescriptor.make(url: URL(fileURLWithPath: "\(basePath).png"), sourceDocumentPath: "/tmp/script.py", runID: nil)?.kind, .image)
        XCTAssertEqual(ArtifactDescriptor.make(url: URL(fileURLWithPath: "\(basePath).svg"), sourceDocumentPath: "/tmp/script.py", runID: nil)?.kind, .html)
        XCTAssertNil(ArtifactDescriptor.make(url: URL(fileURLWithPath: "\(basePath).txt"), sourceDocumentPath: "/tmp/script.py", runID: nil))
    }

    func testCodeSyntaxThemeMonokaiProvidesExpectedKeywordColor() {
        assertColorsEqual(
            CodeSyntaxTheme.monokai.color(for: .keyword),
            NSColor(red: 102 / 255, green: 217 / 255, blue: 239 / 255, alpha: 1)
        )
    }

    func testMainWindowWorkspaceSavedTabRoundTripsEditorWorkspace() throws {
        let encoded = try JSONEncoder().encode(MainWindowWorkspaceState.SavedTab.editorWorkspace)
        let decoded = try JSONDecoder().decode(MainWindowWorkspaceState.SavedTab.self, from: encoded)

        XCTAssertEqual(decoded, .editorWorkspace)
        XCTAssertEqual(decoded.tabItem, .editorWorkspace)
    }

    func testMainWindowWorkspaceSavedTabDecodesLegacyEmptyEditorPathAsEditorWorkspace() throws {
        let data = Data(#"{"kind":"editor","path":""}"#.utf8)
        let decoded = try JSONDecoder().decode(MainWindowWorkspaceState.SavedTab.self, from: data)

        XCTAssertEqual(decoded, .editorWorkspace)
    }

    func testPreferredWorkspaceRootUsesLastOpenEditorPathBeforeRecents() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let root = LaTeXWorkspaceUIState.preferredWorkspaceRoot(
            openPaths: ["/tmp/alpha/main.tex", "/tmp/beta/notes.md"],
            recentPaths: ["/tmp/recent/paper.tex"],
            homeDirectory: home
        )

        XCTAssertEqual(root.path, "/tmp/beta")
    }

    func testPreferredWorkspaceRootFallsBackToRecentFileThenHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let fromRecent = LaTeXWorkspaceUIState.preferredWorkspaceRoot(
            openPaths: [],
            recentPaths: ["/tmp/recent/paper.tex"],
            homeDirectory: home
        )
        let fromHome = LaTeXWorkspaceUIState.preferredWorkspaceRoot(
            openPaths: [],
            recentPaths: [],
            homeDirectory: home
        )

        XCTAssertEqual(fromRecent.path, "/tmp/recent")
        XCTAssertEqual(fromHome.path, home.path)
    }

    func testCodeSyntaxHighlighterRecognizesPythonTokens() {
        let text = """
        @cache
        def build_plot(value=3):
            message = "hello"
            if value > 2:
                return value
        """

        let kinds = Set(CodeSyntaxHighlighter.tokens(for: text, language: .python).map(\.kind))

        XCTAssertTrue(kinds.contains(.decorator))
        XCTAssertTrue(kinds.contains(.function))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.keyword))
        XCTAssertTrue(kinds.contains(.number))
        XCTAssertTrue(kinds.contains(.oper))
    }

    func testCodeSyntaxHighlighterRecognizesRTokens() {
        let text = """
        build_plot <- function(value = 3) {
          label <- "hello"
          if (value > 2) {
            return(label)
          }
        }
        """

        let kinds = Set(CodeSyntaxHighlighter.tokens(for: text, language: .r).map(\.kind))

        XCTAssertTrue(kinds.contains(.function))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.keyword))
        XCTAssertTrue(kinds.contains(.number))
        XCTAssertTrue(kinds.contains(.oper))
    }

    func testCodeRunServiceDiscoversNewestArtifactsFirst() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let older = tempDirectory.appendingPathComponent("plot.png")
        let newer = tempDirectory.appendingPathComponent("plot.html")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: older)
        try "<html><body>ok</body></html>".write(to: newer, atomically: true, encoding: .utf8)

        let oldDate = Date(timeIntervalSinceNow: -120)
        let newDate = Date()
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newer.path)

        let artifacts = CodeRunService.discoverArtifacts(in: tempDirectory, sourceDocumentPath: "/tmp/script.py", runID: nil)

        XCTAssertEqual(artifacts.map(\.url.lastPathComponent), ["plot.html", "plot.png"])
    }

    func testCodeRunServiceRunsPythonScriptAndCapturesHtmlArtifact() async throws {
        guard ExecutableLocator.find("python3", preferredPaths: ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]) != nil else {
            throw XCTSkip("python3 non disponible sur ce système")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("analysis.py")
        try """
        from pathlib import Path
        import os

        artifact_dir = Path(os.environ["CANOPE_ARTIFACT_DIR"])
        artifact_dir.mkdir(parents=True, exist_ok=True)
        output = artifact_dir / "report.html"
        output.write_text("<html><body><h1>Hello</h1></body></html>", encoding="utf-8")
        print("done")
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = await CodeRunService.run(file: scriptURL, mode: .python, timeout: 10)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.artifacts.first?.kind, .html)
        XCTAssertEqual(result.artifacts.first?.displayName, "report.html")
        XCTAssertTrue(result.outputLog.contains("done"))
        XCTAssertEqual(CodeRunService.loadRunHistory(for: scriptURL).first?.runID, result.runID)
    }

    func testCodeRunServiceRunsRScriptAndCapturesHtmlArtifact() async throws {
        guard ExecutableLocator.find("Rscript", preferredPaths: ["/opt/homebrew/bin/Rscript", "/usr/local/bin/Rscript", "/usr/bin/Rscript"]) != nil else {
            throw XCTSkip("Rscript non disponible sur ce système")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("analysis.R")
        try """
        artifact_dir <- Sys.getenv("CANOPE_ARTIFACT_DIR")
        dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
        writeLines("<html><body><h1>Hello</h1></body></html>", file.path(artifact_dir, "report.html"))
        cat("done\\n")
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = await CodeRunService.run(file: scriptURL, mode: .r, timeout: 10)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.artifacts.first?.kind, .html)
        XCTAssertEqual(result.artifacts.first?.displayName, "report.html")
        XCTAssertTrue(result.outputLog.contains("done"))
    }

    func testCodeRunServicePrunesRunHistoryToTwentyRuns() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("analysis.py")
        try "print('ok')".write(to: scriptURL, atomically: true, encoding: .utf8)

        for index in 0..<22 {
            _ = try seedCodeRun(
                for: scriptURL,
                executedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                artifactNames: ["plot-\(index).html"]
            )
        }

        try CodeRunService.pruneRunHistory(for: scriptURL, keeping: 20)
        let history = CodeRunService.loadRunHistory(for: scriptURL)

        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.first?.artifacts.first?.displayName, "plot-21.html")
        XCTAssertEqual(history.last?.artifacts.first?.displayName, "plot-2.html")
    }

    @MainActor
    func testCodeDocumentUIStateNavigatesRunHistoryAndManualPreviewSeparately() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("analysis.py")
        try "print('ok')".write(to: scriptURL, atomically: true, encoding: .utf8)

        let older = try seedCodeRun(
            for: scriptURL,
            executedAt: Date(timeIntervalSince1970: 1_000),
            artifactNames: ["older.html"],
            log: "older"
        )
        let newer = try seedCodeRun(
            for: scriptURL,
            executedAt: Date(timeIntervalSince1970: 2_000),
            artifactNames: ["newer.html"],
            log: "newer"
        )

        let state = CodeDocumentUIState(snapshot: nil, fileURL: scriptURL)

        XCTAssertEqual(state.selectedRun?.runID, newer.runID)
        XCTAssertEqual(state.activeArtifact?.displayName, "newer.html")

        state.selectPreviousRun()
        XCTAssertEqual(state.selectedRun?.runID, older.runID)
        XCTAssertEqual(state.activeArtifact?.displayName, "older.html")

        let manualURL = tempDirectory.appendingPathComponent("manual.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: manualURL)
        let manualArtifact = try XCTUnwrap(
            ArtifactDescriptor.make(url: manualURL, sourceDocumentPath: scriptURL.path, runID: nil)
        )
        state.setManualPreviewArtifact(manualArtifact)

        XCTAssertEqual(state.activeArtifact?.url.path, manualURL.path)
        XCTAssertFalse(state.canSelectPreviousRun)

        state.returnToSelectedRun()
        XCTAssertEqual(state.selectedRun?.runID, older.runID)
        XCTAssertEqual(state.activeArtifact?.displayName, "older.html")
    }

    func testCodeDocumentWorkspaceStateDecodesLegacyOutputVisibility() throws {
        let payload = """
        {
          "showLogs": true,
          "selectedRunID": null,
          "lastArtifactPath": null,
          "showOutputPane": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CodeDocumentWorkspaceState.self, from: payload)

        XCTAssertTrue(decoded.showLogs)
        XCTAssertFalse(decoded.outputLayout.isOutputVisible)
        XCTAssertEqual(decoded.outputLayout.outputPlacement, .right)
        XCTAssertEqual(decoded.outputLayout.secondaryPaneAxis, .vertical)
    }

    @MainActor
    func testCodeDocumentUIStateKeepsSecondaryPreviewSeparateFromPrimary() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("analysis.py")
        try "print('ok')".write(to: scriptURL, atomically: true, encoding: .utf8)

        _ = try seedCodeRun(
            for: scriptURL,
            executedAt: Date(timeIntervalSince1970: 2_000),
            artifactNames: ["plot.png", "summary.html"],
            log: "done"
        )

        let state = CodeDocumentUIState(snapshot: nil, fileURL: scriptURL)
        state.updateOutputLayout { $0.secondaryPaneVisible = true }
        state.setSecondaryArtifactPath(state.availableSecondaryArtifacts.first?.url.path)

        XCTAssertNotNil(state.activeArtifact)
        XCTAssertNotNil(state.secondaryActiveArtifact)
        XCTAssertNotEqual(state.activeArtifact?.url.path, state.secondaryActiveArtifact?.url.path)

        let manualURL = tempDirectory.appendingPathComponent("manual.pdf")
        try Data().write(to: manualURL)
        let manualArtifact = try XCTUnwrap(
            ArtifactDescriptor.make(url: manualURL, sourceDocumentPath: scriptURL.path, runID: nil)
        )
        state.setSecondaryManualPreviewArtifact(manualArtifact)

        XCTAssertEqual(state.secondaryActiveArtifact?.url.path, manualURL.path)
        XCTAssertNotNil(state.activeArtifact)
        XCTAssertNotEqual(state.activeArtifact?.url.path, manualURL.path)
    }
}

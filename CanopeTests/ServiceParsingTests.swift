import XCTest
@testable import Canope

final class ServiceParsingTests: XCTestCase {
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
}

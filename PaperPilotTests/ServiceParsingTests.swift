import XCTest
@testable import PaperPilot

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
        SyncTeX result end
        """

        let result = SyncTeXService.parseInverseOutput(output)

        XCTAssertEqual(result?.file, "/tmp/project/main.tex")
        XCTAssertEqual(result?.line, 87)
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
}

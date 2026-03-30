import Foundation
import Darwin

struct ProcessExecutionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var combinedOutput: String {
        switch (stdout.isEmpty, stderr.isEmpty) {
        case (false, true):
            return stdout
        case (true, false):
            return stderr
        case (false, false):
            return "\(stdout)\n\(stderr)"
        case (true, true):
            return ""
        }
    }
}

enum ProcessRunnerError: LocalizedError {
    case failedToLaunch(String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message):
            return message
        }
    }
}

enum ExecutableLocator {
    static func find(_ name: String, preferredPaths: [String] = []) -> String? {
        let fm = FileManager.default
        let candidates = preferredPaths.map(expandTilde) + pathCandidates(for: name)

        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func pathCandidates(for name: String) -> [String] {
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let commonPaths = [
            "/Library/TeX/texbin",
            "/usr/local/texlive/2024/bin/universal-darwin",
            "/usr/local/texlive/2025/bin/universal-darwin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "~/.local/bin",
        ]

        let uniqueDirs = Array(NSOrderedSet(array: envPaths + commonPaths)) as? [String] ?? (envPaths + commonPaths)
        return uniqueDirs.map { expandTilde($0) + "/\(name)" }
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum ProcessRunner {
    static func run(
        executable: String,
        args: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.failedToLaunch(error.localizedDescription)
        }

        ChildProcessRegistry.shared.track(process: process)
        defer {
            ChildProcessRegistry.shared.untrack(process: process)
        }

        let stdoutSink = DataSink()
        let stderrSink = DataSink()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutSink.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrSink.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if let standardInput, let stdinPipe, let inputData = standardInput.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(inputData)
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let didTimeOut = terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut
        if didTimeOut {
            process.terminate()
            if terminationSemaphore.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 1)
            }
        }

        group.wait()

        let stdout = String(data: stdoutSink.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrSink.data, encoding: .utf8) ?? ""

        return ProcessExecutionResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: didTimeOut
        )
    }
}

private final class DataSink: @unchecked Sendable {
    var data = Data()
}

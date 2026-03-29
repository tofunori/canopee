import Foundation

struct ClaudeService {
    private static let claudePath = "/Users/tofunori/.local/bin/claude"

    /// Ask Claude a question with context from a scientific paper.
    /// Uses `claude --print` CLI (non-interactive mode).
    static func ask(prompt: String, context: String) async throws -> String {
        let input: String
        if context.isEmpty {
            input = prompt
        } else {
            input = """
            Context from a scientific paper:
            ---
            \(context.prefix(50000))
            ---

            \(prompt)
            """
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runClaude(input: input)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runClaude(input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--print"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Inherit environment so claude has access to API keys etc.
        process.environment = ProcessInfo.processInfo.environment

        try process.run()

        // Write prompt to stdin
        if let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Read stdout
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            // Check stderr for errors
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.failed(errorStr)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ClaudeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let msg): return "Claude error: \(msg)"
            }
        }
    }
}

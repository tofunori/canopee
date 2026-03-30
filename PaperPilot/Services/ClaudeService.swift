import Foundation

struct ClaudeService {
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
        guard let claudePath = ExecutableLocator.find(
            "claude",
            preferredPaths: ["~/.local/bin/claude", "/Users/tofunori/.local/bin/claude"]
        ) else {
            throw ClaudeError.failed("Claude CLI introuvable dans le PATH.")
        }

        let result = try ProcessRunner.run(
            executable: claudePath,
            args: ["--print"],
            standardInput: input,
            timeout: 120
        )

        let output = result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !output.isEmpty {
            return output
        }

        let errorOutput = result.combinedOutput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        throw ClaudeError.failed(errorOutput.isEmpty ? "Unknown error" : errorOutput)
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

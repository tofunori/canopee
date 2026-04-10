import Foundation

struct MarkdownPreviewRenderer {
    private static let pandocPreferredPaths = ["/opt/homebrew/bin/pandoc"]
    private static let xelatexPreferredPaths = ["/Library/TeX/texbin/xelatex"]

    static func render(file: URL) async -> CompilationResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runPandoc(file: file)
                continuation.resume(returning: result)
            }
        }
    }

    static func previewURL(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("pdf")
    }

    private static func runPandoc(file: URL) -> CompilationResult {
        guard let pandocPath = ExecutableLocator.find("pandoc", preferredPaths: pandocPreferredPaths) else {
            return failedResult(
                file: file,
                log: "pandoc not found.",
                message: "pandoc was not found. Install it before rendering a Markdown file."
            )
        }

        guard let xelatexPath = ExecutableLocator.find("xelatex", preferredPaths: xelatexPreferredPaths) else {
            return failedResult(
                file: file,
                log: "xelatex not found.",
                message: "xelatex was not found. Install MacTeX to render Markdown to PDF."
            )
        }

        let outputURL = previewURL(for: file)
        let resourcePath = file.deletingLastPathComponent().path
        let arguments = [
            file.lastPathComponent,
            "--from", "markdown",
            "--pdf-engine=\(xelatexPath)",
            "--resource-path", resourcePath,
            "-o", outputURL.lastPathComponent,
        ]

        var environment = ProcessInfo.processInfo.environment
        let toolPaths = [
            "/Library/TeX/texbin",
            "/usr/local/texlive/2024/bin/universal-darwin",
            "/usr/local/texlive/2025/bin/universal-darwin",
            "/opt/homebrew/bin",
        ]
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = toolPaths.joined(separator: ":") + ":" + currentPath

        let execution: ProcessExecutionResult
        do {
            execution = try ProcessRunner.run(
                executable: pandocPath,
                args: arguments,
                environment: environment,
                currentDirectory: file.deletingLastPathComponent(),
                timeout: 180
            )
        } catch {
            return failedResult(
                file: file,
                log: error.localizedDescription,
                message: "\(AppStrings.renderError): \(error.localizedDescription)"
            )
        }

        let log = execution.combinedOutput
        if execution.timedOut {
            return failedResult(
                file: file,
                log: log,
                message: "Markdown rendering exceeded the allowed time limit."
            )
        }

        let pdfExists = FileManager.default.fileExists(atPath: outputURL.path)
        if execution.exitCode == 0 && pdfExists {
            return CompilationResult(
                success: true,
                pdfURL: outputURL,
                errors: [],
                log: log
            )
        }

        let trimmedLog = log.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackMessage = trimmedLog.isEmpty ? "Pandoc could not generate the PDF." : trimmedLog
        return failedResult(file: file, log: log, message: fallbackMessage)
    }

    private static func failedResult(file: URL, log: String, message: String) -> CompilationResult {
        CompilationResult(
            success: false,
            pdfURL: nil,
            errors: [
                CompilationError(
                    line: 0,
                    message: message,
                    file: file.lastPathComponent,
                    isWarning: false
                )
            ],
            log: log
        )
    }
}

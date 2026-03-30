import Foundation

struct CompilationError: Identifiable {
    let id = UUID()
    let line: Int
    let message: String
    let file: String
    let isWarning: Bool
}

struct CompilationResult {
    let success: Bool
    let pdfURL: URL?
    let errors: [CompilationError]
    let log: String
}

struct LaTeXCompiler {

    /// Compile a .tex file using latexmk.
    static func compile(file: URL) async -> CompilationResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runLatexmk(file: file)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runLatexmk(file: URL) -> CompilationResult {
        // Try latexmk first, fall back to pdflatex
        let latexmkPath = ExecutableLocator.find("latexmk")
        let arguments: [String]
        let executablePath: String

        if let latexmk = latexmkPath {
            executablePath = latexmk
            arguments = ["-pdf", "-synctex=1", "-interaction=nonstopmode", "-halt-on-error", file.lastPathComponent]
        } else if let pdflatex = ExecutableLocator.find("pdflatex") {
            executablePath = pdflatex
            arguments = ["-synctex=1", "-interaction=nonstopmode", "-halt-on-error", file.lastPathComponent]
        } else {
            return CompilationResult(
                success: false,
                pdfURL: nil,
                errors: [CompilationError(line: 0, message: "latexmk et pdflatex introuvables. Installez MacTeX.", file: file.lastPathComponent, isWarning: false)],
                log: "No LaTeX compiler found"
            )
        }

        // Add common LaTeX paths
        var env = ProcessInfo.processInfo.environment
        let texPaths = ["/Library/TeX/texbin", "/usr/local/texlive/2024/bin/universal-darwin", "/usr/local/texlive/2025/bin/universal-darwin", "/opt/homebrew/bin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = texPaths.joined(separator: ":") + ":" + currentPath

        let execution: ProcessExecutionResult
        do {
            execution = try ProcessRunner.run(
                executable: executablePath,
                args: arguments,
                environment: env,
                currentDirectory: file.deletingLastPathComponent(),
                timeout: 180
            )
        } catch {
            return CompilationResult(
                success: false,
                pdfURL: nil,
                errors: [CompilationError(line: 0, message: "Erreur: \(error.localizedDescription)", file: file.lastPathComponent, isWarning: false)],
                log: error.localizedDescription
            )
        }

        let log = execution.combinedOutput
        let timedOutErrors = execution.timedOut ? [
            CompilationError(
                line: 0,
                message: "La compilation a dépassé le délai permis.",
                file: file.lastPathComponent,
                isWarning: false
            )
        ] : []

        let pdfName = file.deletingPathExtension().appendingPathExtension("pdf")
        let pdfExists = FileManager.default.fileExists(atPath: pdfName.path)
        let errors = timedOutErrors + parseErrors(log: log, fileName: file.lastPathComponent)

        return CompilationResult(
            success: execution.exitCode == 0 && pdfExists && !execution.timedOut,
            pdfURL: pdfExists ? pdfName : nil,
            errors: errors,
            log: log
        )
    }

    /// Parse LaTeX log for errors and warnings.
    static func parseErrors(log: String, fileName: String) -> [CompilationError] {
        var errors: [CompilationError] = []
        let lines = log.components(separatedBy: .newlines)

        for (i, line) in lines.enumerated() {
            // LaTeX errors: "! Error message"
            if line.hasPrefix("!") {
                let message = String(line.dropFirst(2))
                // Look for line number: "l.XX"
                var lineNum = 0
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1]
                    if let match = nextLine.range(of: #"l\.(\d+)"#, options: .regularExpression) {
                        let numStr = nextLine[match].dropFirst(2)
                        lineNum = Int(numStr) ?? 0
                    }
                }
                errors.append(CompilationError(line: lineNum, message: message, file: fileName, isWarning: false))
            }

            // LaTeX warnings
            if line.contains("LaTeX Warning:") || line.contains("Package Warning:") {
                let message = line.components(separatedBy: "Warning:").last?.trimmingCharacters(in: .whitespaces) ?? line
                errors.append(CompilationError(line: 0, message: message, file: fileName, isWarning: true))
            }
        }

        return errors
    }
}

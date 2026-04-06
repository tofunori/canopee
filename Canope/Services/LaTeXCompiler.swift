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
    /// Automatically resolves the root file (via `% !TEX root` or directory scan).
    static func compile(file: URL) async -> CompilationResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rootFile = resolveRootFile(from: file)
                let result = runLatexmk(file: rootFile)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Root file detection

    /// Resolve the root .tex file for compilation.
    /// Priority: 1) `% !TEX root` magic comment, 2) directory scan for \documentclass that includes this file.
    private static func resolveRootFile(from file: URL) -> URL {
        // If the file itself has \documentclass, it's already a root
        if fileContainsDocumentclass(file) { return file }

        // Method 1: magic comment in first 5 lines
        if let root = rootFromMagicComment(in: file) { return root }

        // Method 2: scan sibling .tex files for one with \documentclass that \input's this file
        if let root = rootFromDirectoryScan(for: file) { return root }

        return file
    }

    private static func rootFromMagicComment(in file: URL) -> URL? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines).prefix(5)
        for line in lines {
            // Match: % !TEX root = path/to/main.tex
            guard let range = line.range(of: #"(?i)%\s*!\s*TEX\s+root\s*[=:]\s*(.+)"#, options: .regularExpression) else { continue }
            let path = String(line[range])
                .replacingOccurrences(of: #"(?i)%\s*!\s*TEX\s+root\s*[=:]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let resolved = file.deletingLastPathComponent().appendingPathComponent(path).standardized
            if FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        }
        return nil
    }

    private static func rootFromDirectoryScan(for file: URL) -> URL? {
        let directory = file.deletingLastPathComponent()
        let baseName = file.deletingPathExtension().lastPathComponent
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let texFiles = contents.filter { $0.pathExtension == "tex" && $0 != file.standardizedFileURL }

        for candidate in texFiles {
            guard fileContainsDocumentclass(candidate),
                  let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            // Check if this file \input's, \include's, or \subfile's our file
            let pattern = #"\\(input|include|subfile|subimport)\s*(\{|(\[.*?\]\{))"# + NSRegularExpression.escapedPattern(for: baseName)
            if text.range(of: pattern, options: .regularExpression) != nil { return candidate }
        }
        return nil
    }

    private static func fileContainsDocumentclass(_ file: URL) -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return content.range(of: #"(?m)^\s*\\documentclass"#, options: .regularExpression) != nil
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

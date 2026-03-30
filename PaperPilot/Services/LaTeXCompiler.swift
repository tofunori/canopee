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
        let process = Process()
        // Try latexmk first, fall back to pdflatex
        let latexmkPath = findExecutable("latexmk")
        if let latexmk = latexmkPath {
            process.executableURL = URL(fileURLWithPath: latexmk)
            process.arguments = ["-pdf", "-synctex=1", "-interaction=nonstopmode", "-halt-on-error", file.lastPathComponent]
        } else if let pdflatex = findExecutable("pdflatex") {
            process.executableURL = URL(fileURLWithPath: pdflatex)
            process.arguments = ["-synctex=1", "-interaction=nonstopmode", "-halt-on-error", file.lastPathComponent]
        } else {
            return CompilationResult(
                success: false,
                pdfURL: nil,
                errors: [CompilationError(line: 0, message: "latexmk et pdflatex introuvables. Installez MacTeX.", file: file.lastPathComponent, isWarning: false)],
                log: "No LaTeX compiler found"
            )
        }

        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment

        // Add common LaTeX paths
        var env = process.environment ?? [:]
        let texPaths = ["/Library/TeX/texbin", "/usr/local/texlive/2024/bin/universal-darwin", "/usr/local/texlive/2025/bin/universal-darwin", "/opt/homebrew/bin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = texPaths.joined(separator: ":") + ":" + currentPath
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CompilationResult(
                success: false,
                pdfURL: nil,
                errors: [CompilationError(line: 0, message: "Erreur: \(error.localizedDescription)", file: file.lastPathComponent, isWarning: false)],
                log: error.localizedDescription
            )
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let log = String(data: outputData, encoding: .utf8) ?? ""

        let pdfName = file.deletingPathExtension().appendingPathExtension("pdf")
        let pdfExists = FileManager.default.fileExists(atPath: pdfName.path)
        let errors = parseErrors(log: log, fileName: file.lastPathComponent)

        return CompilationResult(
            success: process.terminationStatus == 0 && pdfExists,
            pdfURL: pdfExists ? pdfName : nil,
            errors: errors,
            log: log
        )
    }

    /// Parse LaTeX log for errors and warnings.
    private static func parseErrors(log: String, fileName: String) -> [CompilationError] {
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

    /// Find an executable in common paths.
    private static func findExecutable(_ name: String) -> String? {
        let paths = [
            "/Library/TeX/texbin/\(name)",
            "/usr/local/texlive/2024/bin/universal-darwin/\(name)",
            "/usr/local/texlive/2025/bin/universal-darwin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result, !result.isEmpty, FileManager.default.isExecutableFile(atPath: result) {
            return result
        }
        return nil
    }
}

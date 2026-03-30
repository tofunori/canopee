import Foundation
import CoreGraphics

struct SyncTeXForwardResult {
    let page: Int
    let h: CGFloat
    let v: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct SyncTeXInverseResult {
    let file: String
    let line: Int
}

struct SyncTeXService {
    /// Forward sync: source line → PDF page + position
    static func forwardSync(line: Int, texFile: String, pdfPath: String) -> SyncTeXForwardResult? {
        guard let synctexPath = ExecutableLocator.find("synctex", preferredPaths: ["/Library/TeX/texbin/synctex"]) else {
            return nil
        }

        let result: ProcessExecutionResult
        do {
            result = try ProcessRunner.run(
                executable: synctexPath,
                args: ["view", "-i", "\(line):0:\(texFile)", "-o", pdfPath],
                currentDirectory: URL(fileURLWithPath: pdfPath).deletingLastPathComponent(),
                timeout: 10
            )
        } catch {
            return nil
        }

        guard !result.timedOut, result.exitCode == 0 else { return nil }
        return parseForwardOutput(result.combinedOutput)
    }

    /// Inverse sync: PDF click position → source file + line
    static func inverseSync(page: Int, x: CGFloat, y: CGFloat, pdfPath: String) -> SyncTeXInverseResult? {
        guard let synctexPath = ExecutableLocator.find("synctex", preferredPaths: ["/Library/TeX/texbin/synctex"]) else {
            return nil
        }

        let result: ProcessExecutionResult
        do {
            result = try ProcessRunner.run(
                executable: synctexPath,
                args: ["edit", "-o", "\(page):\(x):\(y):\(pdfPath)"],
                currentDirectory: URL(fileURLWithPath: pdfPath).deletingLastPathComponent(),
                timeout: 10
            )
        } catch {
            return nil
        }

        guard !result.timedOut, result.exitCode == 0 else { return nil }
        return parseInverseOutput(result.combinedOutput)
    }

    static func parseForwardOutput(_ output: String) -> SyncTeXForwardResult? {
        var page = 0
        var h: CGFloat = 0
        var v: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0

        for outputLine in output.components(separatedBy: "\n") {
            let trimmed = outputLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Page:") { page = Int(trimmed.dropFirst(5)) ?? 0 }
            if trimmed.hasPrefix("h:") { h = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
            if trimmed.hasPrefix("v:") { v = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
            if trimmed.hasPrefix("W:") { width = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
            if trimmed.hasPrefix("H:") { height = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
        }

        guard page > 0 else { return nil }
        return SyncTeXForwardResult(page: page, h: h, v: v, width: width, height: height)
    }

    static func parseInverseOutput(_ output: String) -> SyncTeXInverseResult? {
        var inputFile = ""
        var line = 0

        for outputLine in output.components(separatedBy: "\n") {
            let trimmed = outputLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Input:") { inputFile = String(trimmed.dropFirst(6)) }
            if trimmed.hasPrefix("Line:") { line = Int(trimmed.dropFirst(5)) ?? 0 }
        }

        guard !inputFile.isEmpty, line > 0 else { return nil }
        return SyncTeXInverseResult(file: inputFile, line: line)
    }
}

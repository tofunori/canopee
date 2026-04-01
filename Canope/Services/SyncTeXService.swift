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
        var page: Int?
        var h: CGFloat?
        var v: CGFloat?
        var width: CGFloat?
        var height: CGFloat?

        for outputLine in output.components(separatedBy: "\n") {
            let trimmed = outputLine.trimmingCharacters(in: .whitespaces)
            if page == nil, trimmed.hasPrefix("Page:") {
                page = Int(trimmed.dropFirst(5))
            }
            if h == nil, trimmed.hasPrefix("h:") {
                h = CGFloat(Double(trimmed.dropFirst(2)) ?? 0)
            }
            if v == nil, trimmed.hasPrefix("v:") {
                v = CGFloat(Double(trimmed.dropFirst(2)) ?? 0)
            }
            if width == nil, trimmed.hasPrefix("W:") {
                width = CGFloat(Double(trimmed.dropFirst(2)) ?? 0)
            }
            if height == nil, trimmed.hasPrefix("H:") {
                height = CGFloat(Double(trimmed.dropFirst(2)) ?? 0)
            }

            if let page, let h, let v, let width, let height {
                return SyncTeXForwardResult(page: page, h: h, v: v, width: width, height: height)
            }
        }

        guard let page, let h, let v, let width, let height, page > 0 else { return nil }
        return SyncTeXForwardResult(page: page, h: h, v: v, width: width, height: height)
    }

    static func parseInverseOutput(_ output: String) -> SyncTeXInverseResult? {
        var inputFile: String?
        var line: Int?

        for outputLine in output.components(separatedBy: "\n") {
            let trimmed = outputLine.trimmingCharacters(in: .whitespaces)
            if inputFile == nil, trimmed.hasPrefix("Input:") {
                inputFile = String(trimmed.dropFirst(6))
            }
            if line == nil, trimmed.hasPrefix("Line:") {
                line = Int(trimmed.dropFirst(5))
            }

            if let inputFile, let line, !inputFile.isEmpty, line > 0 {
                return SyncTeXInverseResult(file: inputFile, line: line)
            }
        }

        guard let inputFile, let line, !inputFile.isEmpty, line > 0 else { return nil }
        return SyncTeXInverseResult(file: inputFile, line: line)
    }
}

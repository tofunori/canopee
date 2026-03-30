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

    private static let synctexPath = "/Library/TeX/texbin/synctex"

    /// Forward sync: source line → PDF page + position
    static func forwardSync(line: Int, texFile: String, pdfPath: String) -> SyncTeXForwardResult? {
        guard FileManager.default.isExecutableFile(atPath: synctexPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: synctexPath)
        process.arguments = ["view", "-i", "\(line):0:\(texFile)", "-o", pdfPath]
        process.currentDirectoryURL = URL(fileURLWithPath: pdfPath).deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var page = 0
        var h: CGFloat = 0
        var v: CGFloat = 0
        var W: CGFloat = 0
        var H: CGFloat = 0

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Page:") { page = Int(trimmed.dropFirst(5)) ?? 0 }
            if trimmed.hasPrefix("h:") { h = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
            if trimmed.hasPrefix("v:") { v = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
            if trimmed.hasPrefix("W:") { W = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
            if trimmed.hasPrefix("H:") { H = CGFloat(Double(trimmed.dropFirst(2)) ?? 0) }
        }

        guard page > 0 else { return nil }
        return SyncTeXForwardResult(page: page, h: h, v: v, width: W, height: H)
    }

    /// Inverse sync: PDF click position → source file + line
    static func inverseSync(page: Int, x: CGFloat, y: CGFloat, pdfPath: String) -> SyncTeXInverseResult? {
        guard FileManager.default.isExecutableFile(atPath: synctexPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: synctexPath)
        process.arguments = ["edit", "-o", "\(page):\(x):\(y):\(pdfPath)"]
        process.currentDirectoryURL = URL(fileURLWithPath: pdfPath).deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

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

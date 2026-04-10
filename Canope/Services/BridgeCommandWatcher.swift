import AppKit
import Foundation
import PDFKit

/// Watches for annotation commands written by the Python IDE bridge.
///
/// The bridge writes a JSON command to `/tmp/canope_bridge_commands.json`.
/// This watcher polls the file, posts a notification when a new command
/// is detected, and provides a static method to write back results.
final class BridgeCommandWatcher: @unchecked Sendable {
    static let shared = BridgeCommandWatcher()

    /// Posted on `.main` queue when a pending command is detected.
    /// `userInfo` contains the parsed command dictionary.
    static let commandNotification = Notification.Name("CanopeBridgeCommandReceived")

    private let lock = NSLock()
    private var monitors: [DirectoryEventMonitor] = []
    private var lastProcessedID: String?

    private init() {}

    func start() {
        guard monitors.isEmpty else { return }

        let directoryURLs = Set(
            CanopeContextFiles.bridgeCommandPaths.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent()
            }
        )

        monitors = directoryURLs.map { directoryURL in
            DirectoryEventMonitor(directoryURL: directoryURL) { [weak self] in
                self?.checkForCommand()
            }
        }

        monitors.forEach { $0.start() }
        checkForCommand()
    }

    func stop() {
        monitors.forEach { $0.stop() }
        monitors.removeAll()
    }

    // MARK: - Watch

    private func checkForCommand() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let pending = self.latestPendingCommand() else { return }

            self.lock.lock()
            let alreadyProcessed = (pending.id == self.lastProcessedID)
            if !alreadyProcessed {
                self.lastProcessedID = pending.id
            }
            self.lock.unlock()

            guard !alreadyProcessed else { return }

            DispatchQueue.main.async {
                let handled = BridgeCommandRouter.shared.dispatch(command: pending.command)
                if !handled {
                    BridgeCommandWatcher.writeResult(
                        id: pending.id,
                        status: "error",
                        message: "No active PDF target"
                    )
                }
            }
        }
    }

    private func latestPendingCommand() -> (id: String, command: [String: Any], modifiedAt: Date)? {
        CanopeContextFiles.bridgeCommandPaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commandID = command["id"] as? String,
                  let status = command["status"] as? String,
                  status == "pending"
            else {
                return nil
            }

            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            return (id: commandID, command: command, modifiedAt: modifiedAt)
        }
        .max { lhs, rhs in lhs.modifiedAt < rhs.modifiedAt }
    }

    // MARK: - Result Writing

    static func writeResult(id: String, status: String, message: String, matchedPages: [Int] = []) {
        let result: [String: Any] = [
            "id": id,
            "status": status,
            "message": message,
            "matchedPages": matchedPages,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) else { return }

        for path in CanopeContextFiles.bridgeCommandResultPaths {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @discardableResult
    static func handleCommand(
        _ info: [String: Any],
        document: PDFDocument?,
        applyBridgeAnnotation: ((_ selection: PDFSelection, _ type: PDFAnnotationSubtype, _ color: NSColor) -> Void)?
    ) -> Bool {
        guard let commandID = info["id"] as? String else { return false }
        guard let commandName = info["command"] as? String,
              let args = info["arguments"] as? [String: Any],
              let text = args["text"] as? String,
              let document
        else {
            writeResult(id: commandID, status: "error", message: "Invalid command or no PDF open")
            return false
        }

        guard let applyBridgeAnnotation else {
            writeResult(id: commandID, status: "error", message: "PDF view not ready")
            return false
        }

        let annotationType: PDFAnnotationSubtype = switch commandName {
        case "underlineText": .underline
        case "strikethroughText": .strikeOut
        default: .highlight
        }

        let color = bridgeColor(from: args["color"] as? String ?? "yellow")
        let pageHint = validatedPageHint(from: args["page"], in: document)

        guard let match = bestMatch(in: document, text: text, pageHint: pageHint) else {
            writeResult(
                id: commandID,
                status: "error",
                message: "Text not found: '\(String(text.prefix(80)))'"
            )
            return false
        }

        applyBridgeAnnotation(match, annotationType, color)
        let matchedPages = match.pages.map { document.index(for: $0) + 1 }
        writeResult(
            id: commandID,
            status: "completed",
            message: "Applied \(commandName) on page(s) \(matchedPages)",
            matchedPages: matchedPages
        )
        return true
    }

    static func validatedPageHint(from rawPage: Any?, in document: PDFDocument) -> Int? {
        guard let page = rawPage as? Int,
              page >= 1,
              page <= document.pageCount else {
            return nil
        }
        return page
    }

    static func bestMatch(in document: PDFDocument, text: String, pageHint: Int?) -> PDFSelection? {
        let variants = searchVariants(for: text)
        let targetNormalized = normalizedBridgeText(text)
        var candidatesByKey: [String: BridgeMatchCandidate] = [:]

        for (variantIndex, variant) in variants.enumerated() {
            let matches = document.findString(variant, withOptions: [.caseInsensitive])
            for selection in matches {
                guard let candidate = bridgeMatchCandidate(
                    for: selection,
                    in: document,
                    originalText: text,
                    normalizedTarget: targetNormalized,
                    pageHint: pageHint,
                    variantIndex: variantIndex
                ) else {
                    continue
                }

                let key = candidate.deduplicationKey
                if let existing = candidatesByKey[key], existing.score >= candidate.score {
                    continue
                }
                candidatesByKey[key] = candidate
            }
        }

        return candidatesByKey.values.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.deduplicationKey > rhs.deduplicationKey
            }
            return lhs.score < rhs.score
        })?.selection
    }

    static func searchVariants(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        var variants: [String] = [trimmed]
        let punctuationNormalized = trimmed
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{FB01}", with: "fi")
            .replacingOccurrences(of: "\u{FB02}", with: "fl")

        let collapsedWhitespace = punctuationNormalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")

        let dehyphenatedLineBreaks = punctuationNormalized
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "-\r\n", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")

        variants.append(punctuationNormalized)
        variants.append(collapsedWhitespace)
        variants.append(dehyphenatedLineBreaks)

        var seen: Set<String> = []
        return variants.compactMap { variant in
            let trimmedVariant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedVariant.isEmpty == false else { return nil }
            guard seen.insert(trimmedVariant).inserted else { return nil }
            return trimmedVariant
        }
    }

    static func normalizedBridgeText(_ text: String) -> String {
        let punctuationNormalized = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{FB01}", with: "fi")
            .replacingOccurrences(of: "\u{FB02}", with: "fl")
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "-\r\n", with: "")

        let collapsedWhitespace = punctuationNormalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsedWhitespace.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    static func bridgeMatchScore(
        originalText: String,
        candidateText: String,
        normalizedTarget: String,
        pageHint: Int?,
        candidatePages: [Int],
        variantIndex: Int
    ) -> Int {
        let trimmedOriginal = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = normalizedBridgeText(candidateText)

        var score = max(0, 240 - (variantIndex * 25))

        if trimmedCandidate == trimmedOriginal {
            score += 180
        }
        if normalizedCandidate == normalizedTarget {
            score += 160
        } else if normalizedCandidate.contains(normalizedTarget) || normalizedTarget.contains(normalizedCandidate) {
            score += 60
        }

        if let pageHint {
            if candidatePages.contains(pageHint) {
                score += 400
            } else {
                score -= 400
            }
        }

        score -= max(0, candidatePages.count - 1) * 25
        score -= abs(trimmedCandidate.count - trimmedOriginal.count)

        return score
    }

    private static func bridgeMatchCandidate(
        for selection: PDFSelection,
        in document: PDFDocument,
        originalText: String,
        normalizedTarget: String,
        pageHint: Int?,
        variantIndex: Int
    ) -> BridgeMatchCandidate? {
        guard let candidateText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              candidateText.isEmpty == false else {
            return nil
        }

        let pages = selection.pages.map { document.index(for: $0) + 1 }
        guard pageHint == nil || pages.contains(pageHint!) else {
            return nil
        }

        let score = bridgeMatchScore(
            originalText: originalText,
            candidateText: candidateText,
            normalizedTarget: normalizedTarget,
            pageHint: pageHint,
            candidatePages: pages,
            variantIndex: variantIndex
        )

        return BridgeMatchCandidate(
            selection: selection,
            normalizedText: normalizedBridgeText(candidateText),
            pages: pages,
            score: score
        )
    }

    private static func bridgeColor(from name: String) -> NSColor {
        switch name {
        case "green": return AnnotationColor.green
        case "red": return AnnotationColor.red
        case "blue": return AnnotationColor.blue
        case "orange": return .orange
        case "pink": return NSColor(red: 0.95, green: 0.5, blue: 0.7, alpha: 1.0)
        default: return AnnotationColor.yellow
        }
    }
}

struct BridgeMatchCandidate {
    let selection: PDFSelection
    let normalizedText: String
    let pages: [Int]
    let score: Int

    var deduplicationKey: String {
        let pageKey = pages.map(String.init).joined(separator: ",")
        return "\(pageKey)|\(normalizedText)"
    }
}

@MainActor
final class BridgeCommandRouter {
    static let shared = BridgeCommandRouter()

    typealias Handler = ([String: Any]) -> Void

    private var handlers: [String: Handler] = [:]
    private var preferredHandlerID: String?

    private init() {}

    func setActiveHandler(id: String, handler: @escaping Handler) {
        handlers[id] = handler
    }

    func setPreferredHandler(id: String) {
        guard handlers[id] != nil else { return }
        preferredHandlerID = id
    }

    func removeActiveHandler(id: String) {
        handlers.removeValue(forKey: id)
        if preferredHandlerID == id {
            preferredHandlerID = nil
        }
    }

    func dispatch(command: [String: Any]) -> Bool {
        if let preferredHandlerID,
           let preferredHandler = handlers[preferredHandlerID] {
            preferredHandler(command)
            return true
        }

        guard handlers.count == 1,
              let handler = handlers.values.first else {
            return false
        }

        handler(command)
        return true
    }

    func resetForTesting() {
        handlers.removeAll()
        preferredHandlerID = nil
    }
}

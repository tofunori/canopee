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
    private var timer: Timer?
    private var lastProcessedID: String?

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkForCommand()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Poll

    private func checkForCommand() {
        guard let pending = latestPendingCommand() else { return }

        lock.lock()
        let alreadyProcessed = (pending.id == lastProcessedID)
        if !alreadyProcessed {
            lastProcessedID = pending.id
        }
        lock.unlock()

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
        var selections = document.findString(text, withOptions: [.caseInsensitive])

        if let pageNum = args["page"] as? Int, pageNum >= 1, pageNum <= document.pageCount {
            selections = selections.filter { selection in
                selection.pages.contains { document.index(for: $0) == pageNum - 1 }
            }
        }

        guard let match = selections.first else {
            let normalized = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if normalized != text {
                var retrySelections = document.findString(normalized, withOptions: [.caseInsensitive])
                if let pageNum = args["page"] as? Int, pageNum >= 1, pageNum <= document.pageCount {
                    retrySelections = retrySelections.filter { selection in
                        selection.pages.contains { document.index(for: $0) == pageNum - 1 }
                    }
                }

                if let retryMatch = retrySelections.first {
                    applyBridgeAnnotation(retryMatch, annotationType, color)
                    let pages = retryMatch.pages.map { document.index(for: $0) + 1 }
                    writeResult(
                        id: commandID,
                        status: "completed",
                        message: "Applied \(commandName) on page(s) \(pages)",
                        matchedPages: pages
                    )
                    return true
                }
            }

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

@MainActor
final class BridgeCommandRouter {
    static let shared = BridgeCommandRouter()

    private var activeHandlerID: String?
    private var activeHandler: (([String: Any]) -> Void)?

    private init() {}

    func setActiveHandler(id: String, handler: @escaping ([String: Any]) -> Void) {
        activeHandlerID = id
        activeHandler = handler
    }

    func removeActiveHandler(id: String) {
        guard activeHandlerID == id else { return }
        activeHandlerID = nil
        activeHandler = nil
    }

    func dispatch(command: [String: Any]) -> Bool {
        guard let activeHandler else { return false }
        activeHandler(command)
        return true
    }
}

import Foundation

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
        let path = CanopeContextFiles.bridgeCommandPaths[0]
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandID = command["id"] as? String,
              let status = command["status"] as? String,
              status == "pending"
        else { return }

        lock.lock()
        let alreadyProcessed = (commandID == lastProcessedID)
        if !alreadyProcessed { lastProcessedID = commandID }
        lock.unlock()

        guard !alreadyProcessed else { return }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: BridgeCommandWatcher.commandNotification,
                object: nil,
                userInfo: command
            )
        }
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
}

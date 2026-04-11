import Foundation
import Combine

struct ChatSelectionInfo: Equatable {
    let fileName: String
    let lineCount: Int
}

@MainActor
final class ChatSelectionContextStore: ObservableObject {
    @Published private(set) var cachedSelection: ChatSelectionInfo?

    private var cachedSelectionModifiedAt: Date?
    private var selectionStateMonitor: DirectoryEventMonitor?

    func refreshSelectionCache(force: Bool = false, statePath: String) {
        let modifiedAt = Self.selectionStateModificationDate(at: statePath)
        guard force || modifiedAt != cachedSelectionModifiedAt else { return }
        cachedSelectionModifiedAt = modifiedAt
        cachedSelection = Self.readSelectionFromDisk(at: statePath)
    }

    func startMonitoring(selectionStatePath: String) {
        stopMonitoring()
        let stateURL = URL(fileURLWithPath: selectionStatePath)
        let directoryURL = stateURL.deletingLastPathComponent()
        selectionStateMonitor = DirectoryEventMonitor(directoryURL: directoryURL) { [weak self] in
            Task { @MainActor in
                self?.refreshSelectionCache(force: true, statePath: selectionStatePath)
            }
        }
        selectionStateMonitor?.start()
    }

    func stopMonitoring() {
        selectionStateMonitor?.stop()
        selectionStateMonitor = nil
    }

    private static func selectionStateModificationDate(at path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }

    private static func readSelectionFromDisk(at path: String) -> ChatSelectionInfo? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let filePath = json["filePath"] as? String ?? ""
        let fileName = (filePath as NSString).lastPathComponent
        let lines = text.components(separatedBy: .newlines).count

        return ChatSelectionInfo(fileName: fileName, lineCount: lines)
    }
}

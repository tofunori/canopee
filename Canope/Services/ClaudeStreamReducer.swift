import Foundation

enum ClaudeStreamEvent {
    case system([String: Any])
    case assistant([String: Any])
    case result([String: Any])
}

@MainActor
final class ClaudeStreamReducer {
    private var outputBuffer = ""
    private var pendingLines: [String] = []
    private var throttleTask: Task<Void, Never>?

    func reset() {
        throttleTask?.cancel()
        throttleTask = nil
        pendingLines.removeAll()
        outputBuffer = ""
    }

    func appendOutput(_ text: String, onEvent: @escaping (ClaudeStreamEvent) -> Void) {
        outputBuffer += text
        while let range = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<range.lowerBound])
            outputBuffer = String(outputBuffer[range.upperBound...])
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            pendingLines.append(line)
        }

        guard throttleTask == nil else { return }
        throttleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            let lines = self.pendingLines
            self.pendingLines.removeAll()
            self.throttleTask = nil
            for line in lines {
                guard let event = self.parseLine(line) else { continue }
                onEvent(event)
            }
        }
    }

    func flushPendingLines(onEvent: @escaping (ClaudeStreamEvent) -> Void) {
        if !outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingLines.append(outputBuffer)
        }
        outputBuffer = ""
        let lines = pendingLines
        pendingLines.removeAll()
        throttleTask?.cancel()
        throttleTask = nil
        for line in lines {
            guard let event = parseLine(line) else { continue }
            onEvent(event)
        }
    }

    private func parseLine(_ line: String) -> ClaudeStreamEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return nil }

        switch type {
        case "system":
            return .system(json)
        case "assistant":
            return .assistant(json)
        case "result":
            return .result(json)
        default:
            return nil
        }
    }
}

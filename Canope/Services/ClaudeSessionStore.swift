import Foundation

enum ClaudeSessionStore {
    struct SessionMetadata {
        let name: String
        let cwd: URL?
        let date: Date?
    }

    struct JSONLHeader {
        let cwd: URL?
        let title: String
    }

    static func listSessions(limit: Int = 15, matchingDirectory: URL? = nil) -> [ClaudeHeadlessProvider.SessionEntry] {
        let expectedPath = normalizedSessionPath(for: matchingDirectory)
        let metadataIndex = sessionMetadataIndex()

        let entries = sessionJSONLFiles().compactMap { url -> ClaudeHeadlessProvider.SessionEntry? in
            let sid = url.deletingPathExtension().lastPathComponent
            let metadata = metadataIndex[sid]
            let header = jsonlHeader(at: url)
            let cwdURL = metadata?.cwd ?? header?.cwd
            if let expectedPath, normalizedSessionPath(for: cwdURL) != expectedPath {
                return nil
            }

            let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let date = metadata?.date ?? fileDate
            let name = metadata?.name.isEmpty == false ? (metadata?.name ?? "") : (header?.title ?? "")
            let project = cwdURL?.lastPathComponent ?? ""
            return ClaudeHeadlessProvider.SessionEntry(id: sid, name: name, project: project, date: date, cwd: cwdURL)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        return Array(entries.prefix(limit))
    }

    static func sessionEntry(id: String, defaultDirectory: URL? = nil) -> ClaudeHeadlessProvider.SessionEntry? {
        let metadata = sessionMetadataIndex()[id]
        let header = findSessionJSONLURL(id: id).flatMap { jsonlHeader(at: $0) }
        let cwdURL = metadata?.cwd ?? header?.cwd ?? defaultDirectory
        let name = metadata?.name.isEmpty == false ? (metadata?.name ?? "") : (header?.title ?? "")
        let project = cwdURL?.lastPathComponent ?? ""
        return ClaudeHeadlessProvider.SessionEntry(id: id, name: name, project: project, date: metadata?.date, cwd: cwdURL)
    }

    static func renameSession(id: String, name: String, fallbackCwd: URL? = nil) {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = sessionEntry(id: id, defaultDirectory: fallbackCwd)
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String, sid == id
            else { continue }

            json["name"] = trimmedName
            if json["cwd"] == nil, let cwd = existing?.cwd?.path {
                json["cwd"] = cwd
            }
            if json["startedAt"] == nil, let startedAt = existing?.date?.timeIntervalSince1970 {
                json["startedAt"] = startedAt * 1000
            }
            guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? updated.write(to: file, options: .atomic)
            return
        }

        var json: [String: Any] = ["sessionId": id]
        if !trimmedName.isEmpty { json["name"] = trimmedName }
        if let cwd = existing?.cwd?.path ?? fallbackCwd?.path {
            json["cwd"] = cwd
        }
        if let startedAt = existing?.date?.timeIntervalSince1970 {
            json["startedAt"] = startedAt * 1000
        }
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? updated.write(to: sessionsDir.appendingPathComponent("\(id).json"), options: .atomic)
    }

    static func findSessionCwd(id: String) -> URL? {
        if let metadata = sessionMetadataIndex()[id], let cwd = metadata.cwd {
            return cwd
        }
        guard let jsonlURL = findSessionJSONLURL(id: id) else { return nil }
        return jsonlHeader(at: jsonlURL)?.cwd
    }

    static func compactSessionTitle(_ text: String, maxLength: Int = 90) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxLength else { return singleLine }
        return String(singleLine.prefix(maxLength - 1)) + "…"
    }

    private static func normalizedSessionPath(for url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func sessionMetadataIndex() -> [String: SessionMetadata] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }

        var result: [String: SessionMetadata] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String
            else { continue }

            let name = json["name"] as? String ?? ""
            let cwdString = json["cwd"] as? String ?? ""
            let cwd = cwdString.isEmpty ? nil : URL(fileURLWithPath: cwdString)
            let ts = json["startedAt"] as? Double ?? 0
            let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : nil
            result[sid] = SessionMetadata(name: name, cwd: cwd, date: date)
        }
        return result
    }

    private static func sessionJSONLFiles() -> [URL] {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return projectDirs.flatMap { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ))?
            .filter { $0.pathExtension == "jsonl" } ?? []
        }
    }

    private static func findSessionJSONLURL(id: String) -> URL? {
        sessionJSONLFiles().first { $0.deletingPathExtension().lastPathComponent == id }
    }

    private static func jsonlHeader(at url: URL) -> JSONLHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 64 * 1024)
        guard let data, !data.isEmpty else { return nil }

        let content = String(decoding: data, as: UTF8.self)
        var cwd: URL?
        var title = ""

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = rawLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if cwd == nil, let cwdString = json["cwd"] as? String, !cwdString.isEmpty {
                cwd = URL(fileURLWithPath: cwdString)
            }

            if title.isEmpty, let lastPrompt = json["lastPrompt"] as? String, !lastPrompt.isEmpty {
                title = compactSessionTitle(lastPrompt)
            }

            if title.isEmpty,
               json["type"] as? String == "user",
               let message = json["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    title = compactSessionTitle(text)
                } else if let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { block -> String? in
                        guard block["type"] as? String == "text" else { return nil }
                        return block["text"] as? String
                    }.joined(separator: "\n")
                    if !text.isEmpty { title = compactSessionTitle(text) }
                }
            }

            if cwd != nil, !title.isEmpty { break }
        }

        return JSONLHeader(cwd: cwd, title: title)
    }
}

import Foundation

enum RecentTeXFilesStore {
    private static let recentTeXKey = "recentTeXFiles"
    private static let maxRecent = 10

    static func addRecentTeXFile(_ path: String) {
        var recents = UserDefaults.standard.stringArray(forKey: recentTeXKey) ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > maxRecent { recents = Array(recents.prefix(maxRecent)) }
        UserDefaults.standard.set(recents, forKey: recentTeXKey)
    }

    static var recentTeXFiles: [String] {
        (UserDefaults.standard.stringArray(forKey: recentTeXKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

import Foundation

enum CodexCustomInstructionsStore {
    static let globalDefaultsKey = "Canope.CodexChatCustomInstructions.Global"
    static let sessionDefaultsKey = "Canope.CodexChatCustomInstructions.ByThread"

    static func loadGlobalText() -> String {
        UserDefaults.standard.string(forKey: globalDefaultsKey) ?? ""
    }

    static func saveGlobalText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: globalDefaultsKey)
        } else {
            UserDefaults.standard.set(normalized, forKey: globalDefaultsKey)
        }
    }

    static func loadSessionText(threadId: String) -> String {
        loadSessionStore()[threadId] ?? ""
    }

    static func saveSessionText(_ text: String, threadId: String) {
        var store = loadSessionStore()
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            store.removeValue(forKey: threadId)
        } else {
            store[threadId] = normalized
        }

        if store.isEmpty {
            UserDefaults.standard.removeObject(forKey: sessionDefaultsKey)
        } else {
            UserDefaults.standard.set(store, forKey: sessionDefaultsKey)
        }
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: globalDefaultsKey)
        UserDefaults.standard.removeObject(forKey: sessionDefaultsKey)
    }

    private static func loadSessionStore() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: sessionDefaultsKey) as? [String: String] ?? [:]
    }
}

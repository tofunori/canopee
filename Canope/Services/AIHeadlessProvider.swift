import Foundation
import Combine

// MARK: - AI Headless Provider Protocol

/// Abstracts the headless CLI process (Claude, Codex, etc.)
@MainActor
protocol AIHeadlessProvider: ObservableObject {
    var messages: [ChatMessage] { get set }
    var isProcessing: Bool { get set }
    var isConnected: Bool { get }
    var session: SessionInfo { get }
    var providerName: String { get }
    var providerIcon: String { get } // SF Symbol name

    func start()
    func stop()
    func sendMessage(_ text: String)
}

import SwiftUI
import SwiftData

@main
struct CanopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Canope") {
            MainWindow()
        }
        .modelContainer(for: [Paper.self, PaperCollection.self])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prefer classic key repeat over the macOS accent popup inside the app,
        // which makes terminal input behave like a real terminal.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
        ClaudeIDEBridgeService.shared.startIfNeeded()
        _ = ClaudeCLIWrapperService.shared.prepareWrapperIfNeeded()
        _ = ClaudeCLIWrapperService.shared.prepareCodexWrapperIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configureWindowFromNotification(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        Task { @MainActor in
            NSApp.windows.forEach { Self.configureWindow($0) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only terminate children launched by the app itself.
        ChildProcessRegistry.shared.terminateAllTrackedChildren()

        // Clean up temp files
        CanopeContextFiles.clearAll()
    }

    @objc
    private func configureWindowFromNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            Self.configureWindow(window)
        }
    }

    @MainActor
    private static func configureWindow(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

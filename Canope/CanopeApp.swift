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
        .defaultSize(width: 1100, height: 700)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prefer classic key repeat over the macOS accent popup inside the app,
        // which makes terminal input behave like a real terminal.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only terminate children launched by the app itself.
        ChildProcessRegistry.shared.terminateAllTrackedChildren()

        // Clean up temp files
        CanopeContextFiles.clearAll()
    }
}

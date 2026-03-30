import SwiftUI
import SwiftData

@main
struct CanopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Canopée") {
            MainWindow()
        }
        .modelContainer(for: [Paper.self, PaperCollection.self])
        .defaultSize(width: 1100, height: 700)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Only terminate children launched by the app itself.
        ChildProcessRegistry.shared.terminateAllTrackedChildren()

        // Clean up temp files
        try? FileManager.default.removeItem(atPath: "/tmp/canope_selection.txt")
        try? FileManager.default.removeItem(atPath: "/tmp/canope_paper.txt")
    }
}

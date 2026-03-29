import SwiftUI
import SwiftData

@main
struct PaperPilotApp: App {
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
        // Kill all child processes (terminal shells, claude, etc.)
        // SIGTERM gives them a chance to clean up
        let pgid = getpgrp()
        kill(-pgid, SIGTERM)

        // Clean up temp files
        try? FileManager.default.removeItem(atPath: "/tmp/canopee_selection.txt")
        try? FileManager.default.removeItem(atPath: "/tmp/canopee_paper.txt")
    }
}

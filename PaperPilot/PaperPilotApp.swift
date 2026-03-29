import SwiftUI
import SwiftData

@main
struct PaperPilotApp: App {
    var body: some Scene {
        WindowGroup("Canopée") {
            MainWindow()
        }
        .modelContainer(for: [Paper.self, PaperCollection.self])
        .defaultSize(width: 1100, height: 700)
    }
}

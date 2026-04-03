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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowChromeMonitors: [ObjectIdentifier: WindowChromeDoubleClickMonitor] = [:]

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

        NSApp.windows.forEach { configureWindow($0) }
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
        configureWindow(window)
    }

    @MainActor
    private func configureWindow(_ window: NSWindow) {
        Self.configureWindowAppearance(window)
        let key = ObjectIdentifier(window)
        if windowChromeMonitors[key] == nil {
            windowChromeMonitors[key] = WindowChromeDoubleClickMonitor(window: window)
        }
    }

    @MainActor
    private static func configureWindowAppearance(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

private final class WindowChromeDoubleClickMonitor {
    private weak var window: NSWindow?
    private var monitor: Any?

    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window,
              event.clickCount == 2,
              shouldHandleDoubleClick(event, in: window) else {
            return event
        }

        performPreferredDoubleClickAction(on: window)
        return nil
    }

    private func shouldHandleDoubleClick(_ event: NSEvent, in window: NSWindow) -> Bool {
        let clickPoint = event.locationInWindow
        guard clickPoint.y >= window.contentLayoutRect.maxY else {
            return false
        }

        return !isInsideStandardWindowControls(clickPoint, window: window)
    }

    private func isInsideStandardWindowControls(_ point: NSPoint, window: NSWindow) -> Bool {
        let protectedButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in protectedButtons {
            guard let button = window.standardWindowButton(type),
                  let container = button.superview else {
                continue
            }

            let frameInWindow = container.convert(button.frame, to: nil).insetBy(dx: -8, dy: -8)
            if frameInWindow.contains(point) {
                return true
            }
        }
        return false
    }

    private func performPreferredDoubleClickAction(on window: NSWindow) {
        if let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
            if action.contains("minimize") {
                window.performMiniaturize(nil)
                return
            }

            if action.contains("maximize") || action.contains("zoom") || action.contains("fill") {
                window.performZoom(nil)
                return
            }
        }

        if UserDefaults.standard.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
            window.performMiniaturize(nil)
        } else {
            window.performZoom(nil)
        }
    }
}

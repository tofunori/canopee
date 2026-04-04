import SwiftUI

struct MainWindowTitleBarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        MainWindowTitleBarDoubleClickAction.perform()
                    }
                )
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    MainWindowTitleBarDoubleClickAction.perform()
                }
        }
    }
}

private enum MainWindowTitleBarDoubleClickAction {
    @MainActor
    static func perform() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

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

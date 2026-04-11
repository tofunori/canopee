import SwiftUI

struct MainWindowDocumentTabsRow<TabContent: View>: View {
    let tabs: [TabItem]
    @ViewBuilder let tabContent: (TabItem) -> TabContent

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs, id: \.self) { tab in
                            tabContent(tab)
                        }
                    }
                }
                .frame(height: AppChromeMetrics.tabBarHeight)
                .background(AppChromePalette.surfaceSubbar)
            }

            AppChromeDivider(role: .shell)
        }
    }
}

struct MainWindowMountedContentHost<LibrarySurface: View, PaperSurfaces: View, EditorSurface: View, StandalonePDFSurfaces: View>: View {
    @ViewBuilder let librarySurface: () -> LibrarySurface
    @ViewBuilder let paperSurfaces: () -> PaperSurfaces
    @ViewBuilder let editorSurface: () -> EditorSurface
    @ViewBuilder let standalonePDFSurfaces: () -> StandalonePDFSurfaces

    var body: some View {
        ZStack(alignment: .topLeading) {
            librarySurface()
            paperSurfaces()
            editorSurface()
            standalonePDFSurfaces()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MainWindowExternalTerminalHost<TerminalContent: View>: View {
    let isVisible: Bool
    let animation: Animation?
    let animationTrigger: Bool
    @ViewBuilder let terminalContent: () -> TerminalContent

    var body: some View {
        terminalContent()
            .frame(
                minWidth: isVisible ? 180 : 0,
                idealWidth: isVisible ? 680 : 0,
                maxWidth: isVisible ? .infinity : 0
            )
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .opacity(isVisible ? 1 : 0)
            .animation(animation, value: animationTrigger)
    }
}

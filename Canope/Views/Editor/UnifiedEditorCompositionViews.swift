import SwiftUI

struct UnifiedEditorToolbarView<LeadingClusters: View, TrailingClusters: View>: View {
    @ViewBuilder let leadingClusters: () -> LeadingClusters
    @ViewBuilder let trailingClusters: () -> TrailingClusters

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    leadingClusters()
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                trailingClusters()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: AppChromeMetrics.toolbarHeight)
        .background(AppChromePalette.surfaceBar)
        .zIndex(30)
    }
}

struct UnifiedEditorWorkAreaPane<HorizontalThreePane: View, EmbeddedTerminal: View, ContentPane: View, EditorAndContentPane: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool
    let showTerminal: Bool
    let showEditorPane: Bool
    let isContentPaneVisible: Bool
    let contentAnimationTrigger: Bool
    @ViewBuilder let horizontalThreePaneLayout: () -> HorizontalThreePane
    @ViewBuilder let embeddedTerminalPane: () -> EmbeddedTerminal
    @ViewBuilder let contentPane: () -> ContentPane
    @ViewBuilder let editorAndContentPane: () -> EditorAndContentPane

    var body: some View {
        Group {
            if isActive && showTerminal && showEditorPane {
                horizontalThreePaneLayout()
            } else if isActive && showTerminal && !showEditorPane && isContentPaneVisible {
                HSplitView {
                    embeddedTerminalPane()
                    contentPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if isActive && showTerminal {
                embeddedTerminalPane()
            } else {
                editorAndContentPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showTerminal)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: contentAnimationTrigger)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: showEditorPane)
    }
}

struct UnifiedEditorContentTabsView<TabButton: View>: View {
    let tabs: [LaTeXEditorPdfPaneTab]
    @ViewBuilder let tabButton: (LaTeXEditorPdfPaneTab) -> TabButton

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    tabButton(tab)
                }
            }
        }
        .frame(height: AppChromeMetrics.tabBarHeight)
        .background(AppChromePalette.surfaceSubbar)
    }
}

import SwiftUI
import PDFKit

struct TerminalPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appearanceStore = TerminalAppearanceStore.shared
    @ObservedObject var workspaceState: TerminalWorkspaceState
    let document: PDFDocument?
    let isVisible: Bool
    let topInset: CGFloat
    let showsInlineControls: Bool
    let startupWorkingDirectory: URL?
    @State private var splitDragStartFraction: CGFloat?

    enum PaneID { case top, bottom }

    init(
        workspaceState: TerminalWorkspaceState,
        document: PDFDocument?,
        isVisible: Bool,
        topInset: CGFloat,
        showsInlineControls: Bool,
        startupWorkingDirectory: URL? = nil
    ) {
        self.workspaceState = workspaceState
        self.document = document
        self.isVisible = isVisible
        self.topInset = topInset
        self.showsInlineControls = showsInlineControls
        self.startupWorkingDirectory = startupWorkingDirectory
    }

    private var currentTabID: UUID {
        workspaceState.selectedTabID ?? workspaceState.tabs.first!.id
    }

    private var appearance: TerminalAppearanceState {
        appearanceStore.appearance
    }

    private var resolvedTheme: TerminalThemePreset {
        appearance.resolvedThemePreset(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            if topInset > 0 {
                Color.clear
                    .frame(height: topInset)
                    .background(AppChromePalette.surfaceBar)
                AppChromeDivider(role: .shell)
            }

            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspaceState.tabs) { tab in
                            terminalTabButton(tab)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Button(action: { addNativeChatTab(.claude) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 9))
                            Text("Claude")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(AppStrings.newClaudeChat)
                    .accessibilityLabel(AppStrings.newClaudeChat)

                    Button(action: { addNativeChatTab(.codex) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 9))
                            Text("Codex")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.cyan.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(AppStrings.newCodexChat)
                    .accessibilityLabel(AppStrings.newCodexChat)

                    if showsInlineControls {
                        Button(action: toggleOptionAsMetaForFocusedPane) {
                            Text("⌥")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(focusedPaneUsesOptionAsMeta ? .blue : .secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(focusedPaneUsesOptionAsMeta ? Color.accentColor.opacity(0.15) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(AppStrings.useOptionAsMeta)

                        Button(action: addTab) {
                            Image(systemName: "plus")
                                .font(.caption)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(AppStrings.newTerminal)

                        Button(action: appearanceStore.presentSettings) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(AppStrings.settingsTerminal)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer()
                    .frame(width: 6)
            }
            .frame(height: AppChromeMetrics.tabBarHeight)
            .background(AppChromePalette.surfaceSubbar)

            AppChromeDivider(role: .panel)

            Group {
                if case .nativeChat = workspaceState.selectedTab?.kind {
                    if isVisible {
                        chatPaneContent
                    }
                } else if workspaceState.isSplit {
                    splitTerminalContent
                } else {
                    paneContainer(.top) {
                        topTerminalPane
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: resolvedTheme.background))
        }
        .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if workspaceState.tabs.isEmpty {
                let tab = TerminalTab()
                workspaceState.tabs = [tab]
                workspaceState.selectedTabID = tab.id
            } else if workspaceState.selectedTabID == nil {
                workspaceState.selectedTabID = workspaceState.tabs.first?.id
            }
            prepareSelectedChatProviderIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .canopeSendPromptToTerminal)) { notification in
            guard isVisible else { return }
            guard let prompt = notification.userInfo?["prompt"] as? String else { return }
            if let selectedTab = workspaceState.selectedTab,
               case .nativeChat(let chatKind) = selectedTab.kind,
               let tabID = workspaceState.selectedTabID {
                switch chatKind {
                case .claude:
                    let provider = workspaceState.claudeChatProvider(for: tabID, workingDirectory: startupWorkingDirectory)
                    provider.sendMessage(prompt)
                case .codex:
                    let provider = workspaceState.codexChatProvider(for: tabID, workingDirectory: startupWorkingDirectory)
                    provider.sendMessage(prompt)
                }
            } else {
                sendPromptToFocusedTerminal(prompt)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .canopeTerminalAddTab)) { _ in
            guard isVisible else { return }
            addTab()
        }
        .onChange(of: isVisible) {
            guard isVisible else { return }
            DispatchQueue.main.async {
                focusVisibleTerminal()
            }
        }
        .onChange(of: workspaceState.selectedTabID) {
            prepareSelectedChatProviderIfNeeded()
            guard isVisible else { return }
            DispatchQueue.main.async {
                focusVisibleTerminal()
            }
        }
        .onChange(of: startupWorkingDirectory?.path) {
            prepareSelectedChatProviderIfNeeded()
        }
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: workspaceState.isSplit)
        .animation(AppChromeMotion.panel(reduceMotion: reduceMotion), value: appearance)
    }

    private func terminalTabIconAndColor(for tab: TerminalTab) -> (String, SwiftUI.Color) {
        switch tab.kind {
        case .terminal:
            return ("terminal", AppChromePalette.tabIndicator(for: .terminal))
        case .nativeChat(.claude):
            return ("sparkle", .orange)
        case .nativeChat(.codex):
            return ("chevron.left.forwardslash.chevron.right", .cyan)
        }
    }

    @ViewBuilder
    private func terminalTabButton(_ tab: TerminalTab) -> some View {
        let (iconName, indicatorColor) = terminalTabIconAndColor(for: tab)

        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundStyle(indicatorColor)
            Text(tab.title)
                .font(.system(size: 10, weight: tab.id == currentTabID ? .semibold : .regular))
                .lineLimit(1)
            if workspaceState.tabs.count > 1 {
                Button(action: { closeTab(tab) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppChromePalette.tabFill(isSelected: tab.id == currentTabID, isHovered: false, role: .terminal))
        .overlay(alignment: .bottom) {
            if tab.id == currentTabID {
                Rectangle()
                    .fill(indicatorColor)
                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { workspaceState.selectedTabID = tab.id }
    }

    private var focusedPaneUsesOptionAsMeta: Bool {
        switch workspaceState.focusedPane {
        case .top:
            guard let selectedID = workspaceState.selectedTabID,
                  let tab = workspaceState.tabs.first(where: { $0.id == selectedID }) else {
                return false
            }
            return tab.optionAsMetaKey
        case .bottom:
            return workspaceState.splitTabs.first?.optionAsMetaKey ?? false
        }
    }

    @ViewBuilder
    private func paneHeader(_ pane: PaneID) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(workspaceState.focusedPane == pane ? AppChromePalette.tabIndicator(for: .terminal) : Color.gray.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(pane == .top ? "Top" : "Bottom")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { closePane(pane) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close this split")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(AppChromePalette.tabFill(isSelected: workspaceState.focusedPane == pane, isHovered: false, role: .terminal))
        .onTapGesture { workspaceState.focusedPane = pane }
    }

    private var terminalPadding: CGFloat {
        CGFloat(max(0, appearance.terminalPadding))
    }

    private func paneOpacity(_ pane: PaneID) -> Double {
        guard workspaceState.isSplit else { return 1 }
        return workspaceState.focusedPane == pane ? appearance.activePaneOpacity : appearance.inactivePaneOpacity
    }

    @ViewBuilder
    private var topTerminalPane: some View {
        if let activeTab = workspaceState.tabs.first(where: { $0.id == currentTabID }) {
            TerminalViewWrapper(
                tabID: activeTab.id,
                workspaceState: workspaceState,
                pane: .top,
                isActive: true,
                optionAsMetaKey: activeTab.optionAsMetaKey,
                appearance: appearance,
                colorScheme: colorScheme,
                startupWorkingDirectory: startupWorkingDirectory
            )
        }
    }

    @ViewBuilder
    private var bottomTerminalPane: some View {
        if let activeTab = workspaceState.splitTabs.first {
            TerminalViewWrapper(
                tabID: activeTab.id,
                workspaceState: workspaceState,
                pane: .bottom,
                isActive: workspaceState.isSplit,
                optionAsMetaKey: activeTab.optionAsMetaKey,
                appearance: appearance,
                colorScheme: colorScheme,
                startupWorkingDirectory: startupWorkingDirectory
            )
        }
    }

    private func paneContainer<Content: View>(_ pane: PaneID, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if workspaceState.isSplit {
                paneHeader(pane)
            }
            content()
                .padding(terminalPadding)
                .background(Color(nsColor: resolvedTheme.background))
        }
        .opacity(paneOpacity(pane))
        .contentShape(Rectangle())
        .onTapGesture { workspaceState.focusedPane = pane }
    }

    private var splitTerminalContent: some View {
        GeometryReader { geometry in
            let dividerHeight = max(CGFloat(appearance.dividerThickness), 1)
            let minimumPaneHeight: CGFloat = 110
            let availableHeight = max(geometry.size.height - dividerHeight, minimumPaneHeight * 2)
            let topHeight = min(
                max(availableHeight * workspaceState.splitFraction, minimumPaneHeight),
                availableHeight - minimumPaneHeight
            )
            let bottomHeight = max(minimumPaneHeight, availableHeight - topHeight)

            VStack(spacing: 0) {
                paneContainer(.top) {
                    topTerminalPane
                }
                .frame(height: topHeight)

                Rectangle()
                    .fill(Color.clear)
                    .frame(height: max(dividerHeight + 6, 12))
                    .contentShape(Rectangle())
                    .overlay {
                        Rectangle()
                            .fill(Color(nsColor: appearance.resolvedDividerColor(for: colorScheme)))
                            .frame(height: dividerHeight)
                    }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let startingFraction = splitDragStartFraction ?? workspaceState.splitFraction
                                if splitDragStartFraction == nil {
                                    splitDragStartFraction = workspaceState.splitFraction
                                }
                                let delta = value.translation.height / max(availableHeight, 1)
                                workspaceState.splitFraction = min(max(startingFraction + delta, 0.22), 0.78)
                            }
                            .onEnded { _ in
                                splitDragStartFraction = nil
                            }
                    )

                paneContainer(.bottom) {
                    bottomTerminalPane
                }
                .frame(height: bottomHeight)
            }
        }
    }

    private func closePane(_ pane: PaneID) {
        if pane == .bottom {
            for terminal in workspaceState.terminalViews(in: .bottom) {
                ChildProcessRegistry.shared.untrack(terminalView: terminal)
                terminal.prepareForRemoval()
            }
            workspaceState.clearTerminalViews(in: .bottom)
            workspaceState.splitTabs = [TerminalTab()]
            workspaceState.isSplit = false
        } else if pane == .top && workspaceState.isSplit {
            for terminal in workspaceState.terminalViews(in: .top) {
                ChildProcessRegistry.shared.untrack(terminalView: terminal)
                terminal.prepareForRemoval()
            }
            workspaceState.tabs = workspaceState.splitTabs
            workspaceState.promoteSplitTerminalViewsToTop()
            workspaceState.splitTabs = [TerminalTab()]
            workspaceState.selectedTabID = workspaceState.tabs.first?.id
            workspaceState.isSplit = false
        }
        workspaceState.focusedPane = .top
        workspaceState.splitFraction = 0.5
    }

    private func addTab() {
        let tab = TerminalTab()
        workspaceState.tabs.append(tab)
        workspaceState.selectedTabID = tab.id
    }

    private func addNativeChatTab(_ chat: NativeChatProviderKind) {
        let title: String
        switch chat {
        case .claude: title = "Claude"
        case .codex: title = "Codex"
        }
        let tab = TerminalTab(title: title, kind: .nativeChat(chat))
        workspaceState.tabs.append(tab)
        workspaceState.selectedTabID = tab.id
    }

    @ViewBuilder
    private var chatPaneContent: some View {
        if let tab = workspaceState.selectedTab,
           case .nativeChat(let chatKind) = tab.kind {
            switch chatKind {
            case .claude:
                if let provider = workspaceState.claudeChatProviders[tab.id] {
                    AIChatView(provider: provider, fileRootURL: startupWorkingDirectory)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    chatProviderPlaceholder
                }
            case .codex:
                if let provider = workspaceState.codexChatProviders[tab.id] {
                    AIChatView(provider: provider, fileRootURL: startupWorkingDirectory)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    chatProviderPlaceholder
                }
            }
        }
    }

    private var chatProviderPlaceholder: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func prepareSelectedChatProviderIfNeeded() {
        guard isVisible,
              let tab = workspaceState.selectedTab,
              case .nativeChat(let chatKind) = tab.kind else { return }

        switch chatKind {
        case .claude:
            let provider = workspaceState.claudeChatProvider(for: tab.id, workingDirectory: startupWorkingDirectory)
            if let dir = startupWorkingDirectory {
                provider.updateWorkingDirectory(dir)
            }
        case .codex:
            let provider = workspaceState.codexChatProvider(for: tab.id, workingDirectory: startupWorkingDirectory)
            if let dir = startupWorkingDirectory {
                provider.updateWorkingDirectory(dir)
            }
        }
    }

    private func toggleOptionAsMetaForFocusedPane() {
        switch workspaceState.focusedPane {
        case .top:
            guard let selectedID = workspaceState.selectedTabID,
                  let index = workspaceState.tabs.firstIndex(where: { $0.id == selectedID }) else {
                return
            }
            var tabs = workspaceState.tabs
            tabs[index].optionAsMetaKey.toggle()
            workspaceState.tabs = tabs
        case .bottom:
            guard let index = workspaceState.splitTabs.indices.first else { return }
            var tabs = workspaceState.splitTabs
            tabs[index].optionAsMetaKey.toggle()
            workspaceState.splitTabs = tabs
        }
    }

    private func closeTab(_ tab: TerminalTab) {
        guard workspaceState.tabs.count > 1 else { return }
        if let index = workspaceState.tabs.firstIndex(where: { $0.id == tab.id }) {
            workspaceState.claudeChatProviders[tab.id]?.stop()
            workspaceState.claudeChatProviders.removeValue(forKey: tab.id)
            workspaceState.codexChatProviders[tab.id]?.stop()
            workspaceState.codexChatProviders.removeValue(forKey: tab.id)

            workspaceState.tabs.remove(at: index)
            if let terminal = workspaceState.removeTerminalView(for: tab.id, in: .top) {
                ChildProcessRegistry.shared.untrack(terminalView: terminal)
                terminal.prepareForRemoval()
            }
            if workspaceState.selectedTabID == tab.id {
                workspaceState.selectedTabID = workspaceState.tabs[max(0, index - 1)].id
            }
        }
    }

    private func focusVisibleTerminal() {
        if workspaceState.focusedPane == .bottom,
           workspaceState.isSplit,
           let bottomTabID = workspaceState.splitTabs.first?.id,
           let bottomTerminal = workspaceState.terminalView(for: bottomTabID, in: .bottom) {
            bottomTerminal.activateInputFocus()
            return
        }

        if let topTerminal = workspaceState.terminalView(for: currentTabID, in: .top) {
            topTerminal.activateInputFocus()
        }
    }

    private func sendPromptToFocusedTerminal(_ prompt: String) {
        let payload = prompt.hasSuffix("\n") ? prompt : prompt + "\n"

        if workspaceState.focusedPane == .bottom,
           workspaceState.isSplit,
           let bottomTabID = workspaceState.splitTabs.first?.id,
           let bottomTerminal = workspaceState.terminalView(for: bottomTabID, in: .bottom) {
            bottomTerminal.activateInputFocus()
            bottomTerminal.send(txt: payload)
            return
        }

        if let topTerminal = workspaceState.terminalView(for: currentTabID, in: .top) {
            topTerminal.activateInputFocus()
            topTerminal.send(txt: payload)
        }
    }
}

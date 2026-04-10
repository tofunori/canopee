import SwiftUI

// MARK: - Tab Bar

struct TabBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var tabs: [TabItem]
    @Binding var selectedTab: TabItem
    let allPapers: [Paper]
    var onOpenTeX: () -> Void = {}
    @Namespace private var sectionTabIndicatorNamespace

    /// The active editor tab (current selection if it's an editor, otherwise the last opened one)
    private var editorTab: TabItem? {
        if case .editor(let p) = selectedTab, !p.isEmpty { return selectedTab }
        return tabs.last { if case .editor(let p) = $0 { return !p.isEmpty } else { return false } }
    }

    /// Whether the selected tab is an editor tab
    private var isEditorSelected: Bool {
        switch selectedTab {
        case .editorWorkspace, .editor:
            return true
        default:
            return false
        }
    }

    /// All open editor tabs (excluding the empty placeholder)
    private var editorTabs: [TabItem] {
        tabs.filter { if case .editor(let p) = $0 { return !p.isEmpty } else { return false } }
    }

    /// Document tabs: papers + standalone PDFs (scrollable, bottom row)
    private var documentTabs: [TabItem] {
        tabs.filter {
            if case .paper = $0 { return true }
            if case .pdfFile = $0 { return true }
            return false
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            SectionTab(
                icon: "books.vertical",
                label: AppStrings.library,
                isSelected: selectedTab == .library,
                indicatorNamespace: sectionTabIndicatorNamespace
            ) { selectedTab = .library }

            SectionTab(
                icon: "chevron.left.forwardslash.chevron.right",
                label: editorTabs.count > 1 ? AppStrings.editor : (editorTab.map { title(for: $0) } ?? AppStrings.editor),
                isSelected: isEditorSelected,
                indicatorNamespace: sectionTabIndicatorNamespace
            ) {
                if let tab = editorTab {
                    selectedTab = tab
                } else {
                    selectedTab = .editorWorkspace
                }
            }
        }
        .frame(height: AppChromeMetrics.sectionTabBarHeight)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func title(for tab: TabItem) -> String {
        switch tab {
        case .library: return AppStrings.library
        case .paper(let id):
            return allPapers.first(where: { $0.id == id })?.title ?? "Paper"
        case .editorWorkspace:
            return AppStrings.editor
        case .editor(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .pdfFile(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func closeTab(_ tab: TabItem) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = index > 0 ? tabs[index - 1] : (tabs.first ?? .library)
        }
    }
}

// MARK: - Section Tab (top row)

struct SectionTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: String
    var iconColor: Color? = nil
    let label: String
    let isSelected: Bool
    let indicatorNamespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion, updates: action)
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(iconColor ?? (isSelected ? .primary : .secondary))
                Text(label)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, AppChromeMetrics.sectionTabHorizontalPadding)
            .frame(minHeight: AppChromeMetrics.sectionTabBarHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppChromeMetrics.sectionTabInnerCornerRadius, style: .continuous)
                        .fill(AppChromePalette.tabSelectedFill.opacity(0.82))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppChromeMetrics.sectionTabInnerCornerRadius, style: .continuous)
                                .stroke(AppChromePalette.clusterStroke.opacity(0.45), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "section-tab-surface", in: indicatorNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: AppChromeMetrics.sectionTabInnerCornerRadius, style: .continuous)
                        .fill(AppChromePalette.tabHoverFill.opacity(0.26))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppChromeMetrics.sectionTabInnerCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }
}

// MARK: - Document Tab (bottom row — papers / PDFs)

struct TabButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: TabItem
    let isSelected: Bool
    let indicatorNamespace: Namespace.ID
    let title: String
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovered = false

    private var tabIcon: String {
        switch tab {
        case .library: return "books.vertical"
        case .paper: return "doc.text"
        case .editorWorkspace: return "chevron.left.forwardslash.chevron.right"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .pdfFile: return "doc.richtext"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tabIcon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 160)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isSelected || isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(AppChromePalette.tabFill(isSelected: isSelected, isHovered: isHovered, role: .document))
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(AppChromePalette.tabIndicator(for: .document))
                    .frame(height: AppChromeMetrics.tabIndicatorHeight)
                    .matchedGeometryEffect(id: "document-tab-indicator", in: indicatorNamespace)
            }
        }
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: AppChromeMetrics.tabCornerRadius, style: .continuous))
        .onTapGesture {
            AppChromeMotion.performSelection(reduceMotion: reduceMotion, updates: onSelect)
        }
        .onHover { isHovered = $0 }
        .animation(AppChromeMotion.hover(reduceMotion: reduceMotion), value: isHovered)
        .animation(AppChromeMotion.selection(reduceMotion: reduceMotion), value: isSelected)
    }
}

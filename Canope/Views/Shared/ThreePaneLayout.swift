import SwiftUI

// MARK: - Configuration

struct ThreePaneSlotSizing {
    let minWidth: CGFloat
}

struct ThreePaneLayoutConfig {
    let leading: ThreePaneSlotSizing
    let middle: ThreePaneSlotSizing
    let trailing: ThreePaneSlotSizing
    let dividerWidth: CGFloat

    /// Resolve pane widths. When no stored widths exist, distribute equally.
    func resolvedWidths(
        leadingStored: CGFloat?,
        trailingStored: CGFloat?,
        totalContentWidth: CGFloat
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        // Collapsed panes (minWidth == 0) always get 0 width
        let leftCollapsed = leading.minWidth == 0
        let rightCollapsed = trailing.minWidth == 0
        let midCollapsed = middle.minWidth == 0

        let minimumTotal = leading.minWidth + middle.minWidth + trailing.minWidth
        let availableWidth = max(totalContentWidth, minimumTotal)

        // Default to equal split among visible panes
        let visibleCount = [!leftCollapsed, !midCollapsed, !rightCollapsed].filter { $0 }.count
        let equalShare = visibleCount > 0 ? availableWidth / CGFloat(visibleCount) : 0
        let seededLeft = leftCollapsed ? 0 : (leadingStored ?? equalShare)
        let seededRight = rightCollapsed ? 0 : (trailingStored ?? equalShare)

        // Clamp left
        let leftMax = leftCollapsed ? 0 : max(leading.minWidth, availableWidth - middle.minWidth - trailing.minWidth)
        let left = min(max(seededLeft, leading.minWidth), leftMax)

        // Clamp right given left
        let rightMax = rightCollapsed ? 0 : max(trailing.minWidth, availableWidth - left - middle.minWidth)
        let right = min(max(seededRight, trailing.minWidth), rightMax)

        // Middle gets the rest
        let mid = midCollapsed ? 0 : max(middle.minWidth, availableWidth - left - right)

        return (left, mid, right)
    }
}

// MARK: - Factory methods

extension ThreePaneLayoutConfig {
    static func latex(arrangement: PanelArrangement, contentVisible: Bool = true) -> ThreePaneLayoutConfig {
        let editor  = ThreePaneSlotSizing(minWidth: 160)
        let pdf     = ThreePaneSlotSizing(minWidth: contentVisible ? 180 : 0)
        let term    = ThreePaneSlotSizing(minWidth: 160)
        return config(for: arrangement, editor: editor, content: pdf, terminal: term, contentVisible: contentVisible)
    }

    static func code(arrangement: PanelArrangement, contentVisible: Bool = true) -> ThreePaneLayoutConfig {
        let editor  = ThreePaneSlotSizing(minWidth: 200)
        let output  = ThreePaneSlotSizing(minWidth: contentVisible ? 200 : 0)
        let term    = ThreePaneSlotSizing(minWidth: 160)
        return config(for: arrangement, editor: editor, content: output, terminal: term, contentVisible: contentVisible)
    }

    private static func config(
        for arrangement: PanelArrangement,
        editor: ThreePaneSlotSizing,
        content: ThreePaneSlotSizing,
        terminal: ThreePaneSlotSizing,
        contentVisible: Bool = true
    ) -> ThreePaneLayoutConfig {
        // When content is hidden, reduce divider count (only 1 divider between terminal and editor)
        let divider: CGFloat = 10
        switch arrangement {
        case .editorContentTerminal:
            return ThreePaneLayoutConfig(leading: editor, middle: content, trailing: terminal, dividerWidth: divider)
        case .terminalEditorContent:
            return ThreePaneLayoutConfig(leading: terminal, middle: editor, trailing: content, dividerWidth: divider)
        case .contentEditorTerminal:
            return ThreePaneLayoutConfig(leading: content, middle: editor, trailing: terminal, dividerWidth: divider)
        }
    }
}

// MARK: - Layout View

struct ThreePaneLayoutView<Leading: View, Middle: View, Trailing: View>: View {
    let config: ThreePaneLayoutConfig
    @Binding var leadingWidth: CGFloat?
    @Binding var trailingWidth: CGFloat?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let trailing: () -> Trailing
    var onDragEnd: (() -> Void)?

    // Drag state: frozen snapshot of widths at drag start to prevent feedback loops
    @State private var dragState: DragSnapshot?

    private struct DragSnapshot {
        enum Side { case leading, trailing }
        let side: Side
        let startLeft: CGFloat
        let startRight: CGFloat
        let totalContentWidth: CGFloat
    }

    private var leadingCollapsed: Bool { config.leading.minWidth == 0 }
    private var trailingCollapsed: Bool { config.trailing.minWidth == 0 }
    private var middleCollapsed: Bool { config.middle.minWidth == 0 }

    /// Number of visible dividers (skip dividers adjacent to collapsed panes)
    private var visibleDividerCount: CGFloat {
        if leadingCollapsed || trailingCollapsed || middleCollapsed { return 1 }
        return 2
    }

    var body: some View {
        GeometryReader { proxy in
            let totalContentWidth = max(0, proxy.size.width - (config.dividerWidth * visibleDividerCount))
            let resolved = config.resolvedWidths(
                leadingStored: leadingWidth,
                trailingStored: trailingWidth,
                totalContentWidth: totalContentWidth
            )
            let widths = activeWidths(resolved: resolved, totalContentWidth: totalContentWidth)

            HStack(spacing: 0) {
                if !leadingCollapsed {
                    leading()
                        .frame(width: widths.left)
                }

                if !leadingCollapsed && !middleCollapsed {
                    resizeHandle(
                        onDrag: { translation in
                            if dragState == nil {
                                dragState = DragSnapshot(
                                    side: .leading,
                                    startLeft: widths.left,
                                    startRight: widths.right,
                                    totalContentWidth: totalContentWidth
                                )
                            }
                            guard let snap = dragState else { return }
                            let maxLeft = max(config.leading.minWidth, snap.totalContentWidth - snap.startRight - config.middle.minWidth)
                            leadingWidth = min(max(snap.startLeft + translation, config.leading.minWidth), maxLeft)
                        },
                        onDragEnd: {
                            dragState = nil
                            onDragEnd?()
                        }
                    )
                }

                middle()
                    .frame(width: middleCollapsed ? nil : widths.middle)
                    .frame(maxWidth: middleCollapsed ? 0 : .infinity)

                if !trailingCollapsed && !middleCollapsed {
                    resizeHandle(
                        onDrag: { translation in
                            if dragState == nil {
                                dragState = DragSnapshot(
                                    side: .trailing,
                                    startLeft: widths.left,
                                    startRight: widths.right,
                                    totalContentWidth: totalContentWidth
                                )
                            }
                            guard let snap = dragState else { return }
                            let maxRight = max(config.trailing.minWidth, snap.totalContentWidth - snap.startLeft - config.middle.minWidth)
                            trailingWidth = min(max(snap.startRight - translation, config.trailing.minWidth), maxRight)
                        },
                        onDragEnd: {
                            dragState = nil
                            onDragEnd?()
                        }
                    )
                }

                if !trailingCollapsed {
                    trailing()
                        .frame(width: widths.right)
                }
            }
        }
        .transaction { t in t.animation = nil }
    }

    /// During a drag, recompute widths using the frozen opposite-side width to prevent oscillation.
    private func activeWidths(
        resolved: (left: CGFloat, middle: CGFloat, right: CGFloat),
        totalContentWidth: CGFloat
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        guard let snap = dragState else { return resolved }

        switch snap.side {
        case .leading:
            // Leading is being dragged; keep trailing frozen at its snapshot value
            let left = min(max(leadingWidth ?? resolved.left, config.leading.minWidth),
                           max(config.leading.minWidth, totalContentWidth - snap.startRight - config.middle.minWidth))
            let right = snap.startRight
            let mid = max(config.middle.minWidth, totalContentWidth - left - right)
            return (left, mid, right)
        case .trailing:
            // Trailing is being dragged; keep leading frozen at its snapshot value
            let left = snap.startLeft
            let right = min(max(trailingWidth ?? resolved.right, config.trailing.minWidth),
                            max(config.trailing.minWidth, totalContentWidth - snap.startLeft - config.middle.minWidth))
            let mid = max(config.middle.minWidth, totalContentWidth - left - right)
            return (left, mid, right)
        }
    }

    private func resizeHandle(
        onDrag: @escaping (CGFloat) -> Void,
        onDragEnd: @escaping () -> Void
    ) -> some View {
        AppChromeResizeHandle(
            width: config.dividerWidth,
            onHoverChanged: { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            },
            dragGesture: AnyGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onDrag(value.translation.width) }
                    .onEnded { _ in onDragEnd() }
            )
        )
    }
}

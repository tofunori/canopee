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

    func resolvedWidths(
        leadingStored: CGFloat?,
        trailingStored: CGFloat?,
        totalContentWidth: CGFloat
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let leftCollapsed = leading.minWidth == 0
        let rightCollapsed = trailing.minWidth == 0
        let midCollapsed = middle.minWidth == 0

        let minimumTotal = leading.minWidth + middle.minWidth + trailing.minWidth
        let availableWidth = max(totalContentWidth, minimumTotal)

        let visibleCount = [!leftCollapsed, !midCollapsed, !rightCollapsed].filter { $0 }.count
        let equalShare = visibleCount > 0 ? availableWidth / CGFloat(visibleCount) : 0
        let seededLeft = leftCollapsed ? 0 : (leadingStored ?? equalShare)
        let seededRight = rightCollapsed ? 0 : (trailingStored ?? equalShare)

        let leftMax = leftCollapsed ? 0 : max(leading.minWidth, availableWidth - middle.minWidth - trailing.minWidth)
        let left = min(max(seededLeft, leading.minWidth), leftMax)

        let rightMax = rightCollapsed ? 0 : max(trailing.minWidth, availableWidth - left - middle.minWidth)
        let right = min(max(seededRight, trailing.minWidth), rightMax)

        let mid = midCollapsed ? 0 : max(middle.minWidth, availableWidth - left - right)

        return (left, mid, right)
    }
}

// MARK: - Factory methods

extension ThreePaneLayoutConfig {
    static func latex(arrangement: PanelArrangement, editorVisible: Bool = true, contentVisible: Bool = true) -> ThreePaneLayoutConfig {
        let editor  = ThreePaneSlotSizing(minWidth: editorVisible ? 160 : 0)
        let pdf     = ThreePaneSlotSizing(minWidth: contentVisible ? 180 : 0)
        let term    = ThreePaneSlotSizing(minWidth: 160)
        return config(for: arrangement, editor: editor, content: pdf, terminal: term)
    }

    static func code(arrangement: PanelArrangement, editorVisible: Bool = true, contentVisible: Bool = true) -> ThreePaneLayoutConfig {
        let editor  = ThreePaneSlotSizing(minWidth: editorVisible ? 200 : 0)
        let output  = ThreePaneSlotSizing(minWidth: contentVisible ? 200 : 0)
        let term    = ThreePaneSlotSizing(minWidth: 160)
        return config(for: arrangement, editor: editor, content: output, terminal: term)
    }

    private static func config(
        for arrangement: PanelArrangement,
        editor: ThreePaneSlotSizing,
        content: ThreePaneSlotSizing,
        terminal: ThreePaneSlotSizing
    ) -> ThreePaneLayoutConfig {
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

// MARK: - Layout protocol

private struct ThreePanePlacement: Layout {
    var leftWidth: CGFloat
    var middleWidth: CGFloat
    var rightWidth: CGFloat
    var dividerWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let ld = (leftWidth > 0 && middleWidth > 0) ? dividerWidth : 0
        let rd = (rightWidth > 0 && middleWidth > 0) ? dividerWidth : 0
        let sizes: [CGFloat] = [leftWidth, ld, middleWidth, rd, rightWidth]
        var x = bounds.minX
        for (i, subview) in subviews.enumerated() {
            let w = sizes[i]
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: max(w, 0), height: bounds.height)
            )
            x += w
        }
    }
}

// MARK: - Public view (ghost divider pattern)

/// During drag: panes stay frozen at their starting size. A ghost line follows
/// the cursor. On release: panes resize once to the final position.
/// This avoids resizing heavy AppKit views (Terminal, NSTextView, PDFKit) 60x/sec.
struct ThreePaneLayoutView<Leading: View, Middle: View, Trailing: View>: View {
    let config: ThreePaneLayoutConfig
    @Binding var leadingWidth: CGFloat?
    @Binding var trailingWidth: CGFloat?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let trailing: () -> Trailing
    var onDragEnd: (() -> Void)?

    @State private var containerWidth: CGFloat = 0
    @State private var ghostOffset: CGFloat? // x offset of ghost divider from container leading edge
    @State private var ghostDragSide: DragSide?
    @State private var dragFrozenLeft: CGFloat?
    @State private var dragFrozenRight: CGFloat?

    private var isDragging: Bool { ghostOffset != nil }

    private var dividerCount: CGFloat {
        var n: CGFloat = 0
        if config.leading.minWidth > 0 && config.middle.minWidth > 0 { n += 1 }
        if config.trailing.minWidth > 0 && config.middle.minWidth > 0 { n += 1 }
        return n
    }

    private var totalContent: CGFloat {
        max(0, containerWidth - dividerCount * config.dividerWidth)
    }

    /// The actual pane widths used for layout — these only change on drag END, not during.
    private var widths: (left: CGFloat, middle: CGFloat, right: CGFloat) {
        config.resolvedWidths(
            leadingStored: leadingWidth,
            trailingStored: trailingWidth,
            totalContentWidth: totalContent
        )
    }

    var body: some View {
        let w = widths

        ZStack(alignment: .leading) {
            ThreePanePlacement(
                leftWidth: w.left,
                middleWidth: w.middle,
                rightWidth: w.right,
                dividerWidth: config.dividerWidth
            ) {
                leading().clipped()
                dividerHandle(side: .leading, w: w)
                middle().clipped()
                dividerHandle(side: .trailing, w: w)
                trailing().clipped()
            }

            // Ghost divider: a visible line that follows the cursor during drag
            if let offset = ghostOffset {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 2)
                    .offset(x: offset)
                    .allowsHitTesting(false)
                    .transition(.identity)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { containerWidth = proxy.size.width }
            }
        )
        .transaction { t in t.animation = nil }
    }

    private enum DragSide { case leading, trailing }

    /// Compute the x position of a divider given current widths
    private func dividerX(side: DragSide, w: (left: CGFloat, middle: CGFloat, right: CGFloat)) -> CGFloat {
        switch side {
        case .leading:
            return w.left + config.dividerWidth / 2
        case .trailing:
            let ld = (w.left > 0 && w.middle > 0) ? config.dividerWidth : 0
            return w.left + ld + w.middle + config.dividerWidth / 2
        }
    }

    @ViewBuilder
    private func dividerHandle(side: DragSide, w: (left: CGFloat, middle: CGFloat, right: CGFloat)) -> some View {
        AppChromeResizeHandle(
            width: config.dividerWidth,
            onHoverChanged: { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            },
            dragGesture: AnyGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragFrozenLeft == nil {
                            dragFrozenLeft = w.left
                            dragFrozenRight = w.right
                            ghostDragSide = side
                        }
                        guard let fl = dragFrozenLeft, let fr = dragFrozenRight else { return }
                        let t = value.translation.width
                        let total = totalContent

                        // Compute where the divider WOULD be
                        let newLeft: CGFloat
                        let newRight: CGFloat
                        switch side {
                        case .leading:
                            let maxL = max(config.leading.minWidth, total - fr - config.middle.minWidth)
                            newLeft = min(max(fl + t, config.leading.minWidth), maxL)
                            newRight = fr
                        case .trailing:
                            let maxR = max(config.trailing.minWidth, total - fl - config.middle.minWidth)
                            newRight = min(max(fr - t, config.trailing.minWidth), maxR)
                            newLeft = fl
                        }

                        // Position the ghost at where the divider would be
                        ghostOffset = dividerX(side: side, w: (newLeft, max(0, total - newLeft - newRight), newRight))
                    }
                    .onEnded { value in
                        // Apply final sizes in one shot
                        if let fl = dragFrozenLeft, let fr = dragFrozenRight {
                            let t = value.translation.width
                            let total = totalContent
                            switch ghostDragSide ?? side {
                            case .leading:
                                let maxL = max(config.leading.minWidth, total - fr - config.middle.minWidth)
                                leadingWidth = min(max(fl + t, config.leading.minWidth), maxL)
                                trailingWidth = fr
                            case .trailing:
                                let maxR = max(config.trailing.minWidth, total - fl - config.middle.minWidth)
                                trailingWidth = min(max(fr - t, config.trailing.minWidth), maxR)
                                leadingWidth = fl
                            }
                        }
                        ghostOffset = nil
                        ghostDragSide = nil
                        dragFrozenLeft = nil
                        dragFrozenRight = nil
                        onDragEnd?()
                    }
            )
        )
    }
}

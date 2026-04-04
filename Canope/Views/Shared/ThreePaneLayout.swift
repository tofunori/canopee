import SwiftUI

// MARK: - Configuration

struct ThreePaneSlotSizing {
    let minWidth: CGFloat
    let idealWidth: CGFloat
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
        let minimumTotal = leading.minWidth + middle.minWidth + trailing.minWidth
        let availableWidth = max(totalContentWidth, minimumTotal)

        let seededLeft = leadingStored ?? leading.idealWidth
        let seededRight = trailingStored ?? trailing.idealWidth

        let leftMaxBeforeRightClamp = max(leading.minWidth, availableWidth - middle.minWidth - trailing.minWidth)
        let left = min(max(seededLeft, leading.minWidth), leftMaxBeforeRightClamp)

        let rightMaxBeforeLeftClamp = max(trailing.minWidth, availableWidth - left - middle.minWidth)
        let right = min(max(seededRight, trailing.minWidth), rightMaxBeforeLeftClamp)

        let leftMax = max(leading.minWidth, availableWidth - right - middle.minWidth)
        let clampedLeft = min(left, leftMax)
        let rightMax = max(trailing.minWidth, availableWidth - clampedLeft - middle.minWidth)
        let clampedRight = min(right, rightMax)
        let clampedMiddle = max(middle.minWidth, availableWidth - clampedLeft - clampedRight)

        return (clampedLeft, clampedMiddle, clampedRight)
    }
}

// MARK: - Factory methods

extension ThreePaneLayoutConfig {
    static func latex(arrangement: PanelArrangement) -> ThreePaneLayoutConfig {
        let editor = ThreePaneSlotSizing(minWidth: 160, idealWidth: 620)
        let pdf    = ThreePaneSlotSizing(minWidth: 180, idealWidth: 320)
        let term   = ThreePaneSlotSizing(minWidth: 160, idealWidth: 320)
        return config(for: arrangement, editor: editor, content: pdf, terminal: term)
    }

    static func code(arrangement: PanelArrangement) -> ThreePaneLayoutConfig {
        let editor = ThreePaneSlotSizing(minWidth: 220, idealWidth: 620)
        let output = ThreePaneSlotSizing(minWidth: 240, idealWidth: 380)
        let term   = ThreePaneSlotSizing(minWidth: 180, idealWidth: 320)
        return config(for: arrangement, editor: editor, content: output, terminal: term)
    }

    private static func config(
        for arrangement: PanelArrangement,
        editor: ThreePaneSlotSizing,
        content: ThreePaneSlotSizing,
        terminal: ThreePaneSlotSizing
    ) -> ThreePaneLayoutConfig {
        switch arrangement {
        case .editorContentTerminal:
            return ThreePaneLayoutConfig(leading: editor, middle: content, trailing: terminal, dividerWidth: 10)
        case .terminalEditorContent:
            return ThreePaneLayoutConfig(leading: terminal, middle: editor, trailing: content, dividerWidth: 10)
        case .contentEditorTerminal:
            return ThreePaneLayoutConfig(leading: content, middle: editor, trailing: terminal, dividerWidth: 10)
        }
    }
}

// MARK: - Layout View

struct ThreePaneLayoutView<Leading: View, Middle: View, Trailing: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let config: ThreePaneLayoutConfig
    @Binding var leadingWidth: CGFloat?
    @Binding var trailingWidth: CGFloat?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let trailing: () -> Trailing
    var onDragEnd: (() -> Void)?

    @State private var leadingDragStart: CGFloat?
    @State private var trailingDragStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let totalContentWidth = max(0, proxy.size.width - (config.dividerWidth * 2))
            let widths = config.resolvedWidths(
                leadingStored: leadingWidth,
                trailingStored: trailingWidth,
                totalContentWidth: totalContentWidth
            )

            HStack(spacing: 0) {
                leading()
                    .frame(width: widths.left)

                AppChromeResizeHandle(
                    width: config.dividerWidth,
                    onHoverChanged: { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    },
                    dragGesture: AnyGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = leadingDragStart ?? widths.left
                                if leadingDragStart == nil { leadingDragStart = widths.left }
                                let maxLeft = max(config.leading.minWidth, totalContentWidth - widths.right - config.middle.minWidth)
                                leadingWidth = min(max(start + value.translation.width, config.leading.minWidth), maxLeft)
                            }
                            .onEnded { _ in
                                leadingDragStart = nil
                                onDragEnd?()
                            }
                    )
                )

                middle()
                    .frame(width: widths.middle)

                AppChromeResizeHandle(
                    width: config.dividerWidth,
                    onHoverChanged: { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    },
                    dragGesture: AnyGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = trailingDragStart ?? widths.right
                                if trailingDragStart == nil { trailingDragStart = widths.right }
                                let maxRight = max(config.trailing.minWidth, totalContentWidth - widths.left - config.middle.minWidth)
                                trailingWidth = min(max(start - value.translation.width, config.trailing.minWidth), maxRight)
                            }
                            .onEnded { _ in
                                trailingDragStart = nil
                                onDragEnd?()
                            }
                    )
                )

                trailing()
                    .frame(width: widths.right)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }
}

import SwiftUI
import ObjectiveC

@MainActor
enum SplitViewHelper {
    fileprivate static let delegateKey = malloc(1)!

    static func thickenSplitViews(_ view: NSView) {
        if let splitView = view as? NSSplitView {
            splitView.dividerStyle = .thick
            if splitView.delegate == nil || splitView.delegate is SplitViewGrabDelegate {
                let delegate = (objc_getAssociatedObject(splitView, delegateKey) as? SplitViewGrabDelegate)
                    ?? SplitViewGrabDelegate()
                objc_setAssociatedObject(
                    splitView,
                    delegateKey,
                    delegate,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                splitView.delegate = delegate
            }
            splitView.needsDisplay = true
        }
        for sub in view.subviews { thickenSplitViews(sub) }
    }

    static func expandedDividerRect(for splitView: NSSplitView, dividerIndex: Int, inset: CGFloat) -> NSRect {
        guard dividerIndex >= 0, dividerIndex < splitView.subviews.count - 1 else { return .zero }

        let precedingFrame = splitView.subviews[dividerIndex].frame
        let followingFrame = splitView.subviews[dividerIndex + 1].frame

        if splitView.isVertical {
            let gapStart = precedingFrame.maxX
            let gapEnd = followingFrame.minX
            let width = max(splitView.dividerThickness, gapEnd - gapStart)
            return NSRect(
                x: gapStart - inset,
                y: 0,
                width: width + inset * 2,
                height: splitView.bounds.height
            ).integral
        } else {
            let gapStart = precedingFrame.maxY
            let gapEnd = followingFrame.minY
            let height = max(splitView.dividerThickness, gapEnd - gapStart)
            return NSRect(
                x: 0,
                y: gapStart - inset,
                width: splitView.bounds.width,
                height: height + inset * 2
            ).integral
        }
    }
}

final class SplitViewGrabDelegate: NSObject, NSSplitViewDelegate {
    private let extraHitInset: CGFloat = 5

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        SplitViewHelper.expandedDividerRect(for: splitView, dividerIndex: dividerIndex, inset: extraHitInset)
    }
}

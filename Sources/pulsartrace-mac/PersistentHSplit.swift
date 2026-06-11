import AppKit
import SwiftUI

/// A two-pane horizontal split backed by NSSplitView — chosen over
/// `HSplitView` because `autosaveName` gives divider-position persistence
/// across launches for free and the delegate enforces hard minimum widths
/// (§3: list ≥ 240, detail ≥ 320).
///
/// IMPORTANT: content crosses an NSHostingView boundary — SwiftUI
/// environment does NOT flow across it automatically. Both panes must
/// receive their models via init injection (RecordingsSplitView does), or
/// re-apply `.environment(...)` on the pane views here.
struct PersistentHSplit<Leading: View, Trailing: View>: NSViewRepresentable {
    let autosaveName: String
    /// Leading pane's share of the width on first run — once AppKit has
    /// autosaved a divider position, the restored value wins.
    let defaultFraction: CGFloat
    let leadingMinWidth: CGFloat
    let trailingMinWidth: CGFloat
    let leading: Leading
    let trailing: Trailing

    func makeNSView(context: Context) -> NSSplitView {
        let split = DefaultFractionSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        let left = NSHostingView(rootView: leading)
        let right = NSHostingView(rootView: trailing)
        // NSSplitView is the sole geometry authority: the default
        // `.standardBounds` sizing options would install min/intrinsic-size
        // constraints from the SwiftUI content that fight the delegate's
        // divider clamps (unsatisfiable-constraint spew near the minimums).
        left.sizingOptions = []
        right.sizingOptions = []
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        // The master list keeps its width when the window resizes — the
        // detail flexes. Also keeps the autosaved divider position honest.
        split.setHoldingPriority(.init(251), forSubviewAt: 0)
        // The divider position can only be applied once the view has real
        // bounds, so the default is staged and lands on the first layout —
        // and only when AppKit has no autosaved position for this name.
        let savedKey = "NSSplitView Subview Frames \(autosaveName)"
        if UserDefaults.standard.object(forKey: savedKey) == nil {
            split.pendingDefaultFraction = defaultFraction
            split.leadingMin = leadingMinWidth
            split.trailingMin = trailingMinWidth
        }
        // Set AFTER the subviews exist so the restored position applies.
        split.autosaveName = autosaveName
        return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        guard let left = nsView.arrangedSubviews[0] as? NSHostingView<Leading>,
              let right = nsView.arrangedSubviews[1] as? NSHostingView<Trailing>
        else {
            assertionFailure("PersistentHSplit subview types drifted from makeNSView")
            return
        }
        left.rootView = leading
        right.rootView = trailing
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(leadingMin: leadingMinWidth, trailingMin: trailingMinWidth)
    }

    /// Applies the staged first-run divider fraction on the first layout
    /// pass with real bounds (programmatic `setPosition` bypasses the
    /// delegate clamps, hence the manual min-width clamp).
    final class DefaultFractionSplitView: NSSplitView {
        var pendingDefaultFraction: CGFloat?
        var leadingMin: CGFloat = 0
        var trailingMin: CGFloat = 0

        override func layout() {
            super.layout()
            guard let fraction = pendingDefaultFraction, bounds.width > 0 else {
                return
            }
            pendingDefaultFraction = nil
            let position = min(
                max(bounds.width * fraction, leadingMin),
                bounds.width - dividerThickness - trailingMin)
            setPosition(position, ofDividerAt: 0)
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leadingMin: CGFloat
        let trailingMin: CGFloat

        init(leadingMin: CGFloat, trailingMin: CGFloat) {
            self.leadingMin = leadingMin
            self.trailingMin = trailingMin
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(proposedMinimumPosition, leadingMin)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(proposedMaximumPosition,
                splitView.bounds.width - splitView.dividerThickness - trailingMin)
        }
    }
}

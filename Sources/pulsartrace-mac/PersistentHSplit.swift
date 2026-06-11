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
    let leadingMinWidth: CGFloat
    let trailingMinWidth: CGFloat
    let leading: Leading
    let trailing: Trailing

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.addArrangedSubview(NSHostingView(rootView: leading))
        split.addArrangedSubview(NSHostingView(rootView: trailing))
        // Set AFTER the subviews exist so the restored position applies.
        split.autosaveName = autosaveName
        return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        (nsView.arrangedSubviews[0] as? NSHostingView<Leading>)?.rootView = leading
        (nsView.arrangedSubviews[1] as? NSHostingView<Trailing>)?.rootView = trailing
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(leadingMin: leadingMinWidth, trailingMin: trailingMinWidth)
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

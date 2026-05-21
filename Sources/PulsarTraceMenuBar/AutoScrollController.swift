import Foundation
import Observation

/// Decides whether the live-transcript scroll view should auto-scroll to the
/// latest line (R45 — smart auto-scroll).
///
/// The view feeds in a measured "distance from bottom" each time the scroll
/// geometry changes; the controller flips `shouldFollow` between follow-mode
/// (user is at/near the bottom) and pause-mode (user scrolled up to read).
/// While paused, `linesDidGrow(by:)` accumulates `pendingNewLines` so the
/// view can show a "Jump to latest ↓ N" pill. Scrolling back into the
/// near-bottom band — or tapping the pill — resets to follow-mode.
///
/// Pure logic: knows nothing about SwiftUI or pixel coordinates beyond the
/// `CGFloat` distance it is told.
@MainActor
@Observable
public final class AutoScrollController {

    /// True while new lines should trigger an auto-scroll to the bottom.
    public private(set) var shouldFollow: Bool = true

    /// Lines that arrived while `shouldFollow == false` — drives the pill.
    public private(set) var pendingNewLines: Int = 0

    /// Points-distance from the bottom of the content to the bottom of the
    /// viewport under which the controller re-engages follow-mode.
    private let nearBottomThreshold: CGFloat

    /// - Parameter nearBottomThreshold: how close to the bottom (in points)
    ///   counts as "at the bottom". 40pt is the default — tight enough to feel
    ///   like "at the bottom," loose enough that trackpad inertia doesn't drop
    ///   the user out of follow-mode mid-stream.
    public init(nearBottomThreshold: CGFloat = 40) {
        self.nearBottomThreshold = nearBottomThreshold
    }

    /// Feed the controller the current distance from the bottom of the
    /// content to the bottom of the viewport. Negative values (content
    /// shorter than viewport) count as near-bottom.
    public func updateDistanceFromBottom(_ distance: CGFloat) {
        let nearBottom = distance <= nearBottomThreshold
        if nearBottom {
            if !shouldFollow {
                shouldFollow = true
                pendingNewLines = 0
            }
        } else {
            if shouldFollow {
                shouldFollow = false
            }
        }
    }

    /// Tell the controller that the line count grew by `delta`. Returns
    /// `true` if the view should programmatically scroll to the bottom now.
    /// Non-positive deltas are no-ops.
    @discardableResult
    public func linesDidGrow(by delta: Int) -> Bool {
        guard delta > 0 else { return false }
        if shouldFollow {
            return true
        }
        pendingNewLines += delta
        return false
    }

    /// The user explicitly asked to catch up — re-engage follow-mode and
    /// clear pending. The view scrolls to the bottom separately.
    public func jumpToLatest() {
        shouldFollow = true
        pendingNewLines = 0
    }
}

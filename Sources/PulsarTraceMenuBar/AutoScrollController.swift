import Foundation
import Observation

/// Decides whether the live-transcript scroll view should auto-scroll to the
/// latest line (R45 — smart auto-scroll).
///
/// The view feeds in a measured "distance from bottom" each time the scroll
/// geometry changes; the controller flips `shouldFollow` between follow-mode
/// (user is at/near the bottom) and pause-mode (user scrolled up to read).
/// While paused, `linesDidGrow(by:)` accumulates `pendingNewLines` so the
/// view can show a "Jump to latest ↓ N" pill. Scrolling back to the bottom —
/// or tapping the pill — resets to follow-mode.
///
/// The pause and resume thresholds are asymmetric (hysteresis): pausing is
/// generous (you have to scroll up by ~three lines) so the per-new-line
/// content-height bump can't flip follow-mode off; resuming is strict (you
/// have to be essentially at the bottom). Symmetric thresholds caused
/// oscillation — every new line tripped the threshold and the pill flashed
/// on each append.
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

    /// Distance beyond which follow-mode pauses. Generous on purpose: when a
    /// new line arrives, the content grows by ~one line-height (~18pt) for
    /// one frame before the auto-scroll catches up. The pause threshold must
    /// be bigger than that transient bump or follow-mode would oscillate on
    /// every new line.
    private let pauseThreshold: CGFloat
    /// Distance below which follow-mode resumes — strict, "essentially at
    /// the bottom." Asymmetry with `pauseThreshold` is intentional: once the
    /// user scrolls away to read earlier text, they must scroll back near
    /// the bottom before auto-follow re-engages.
    private let resumeThreshold: CGFloat

    /// - Parameters:
    ///   - pauseThreshold: distance (in points) the user must scroll above
    ///     the bottom for follow-mode to pause. Default 60pt — about three
    ///     body-font line-heights — so the per-new-line content bump cannot
    ///     trip the pause.
    ///   - resumeThreshold: distance (in points) the user must scroll within
    ///     of the bottom for follow-mode to resume. Default 8pt — under half
    ///     a line — so resume only fires when the user is genuinely at the
    ///     bottom.
    public init(
        pauseThreshold: CGFloat = 60,
        resumeThreshold: CGFloat = 8
    ) {
        self.pauseThreshold = pauseThreshold
        self.resumeThreshold = resumeThreshold
    }

    /// Feed the controller the current distance from the bottom of the
    /// content to the bottom of the viewport. Negative values (content
    /// shorter than viewport) count as at-the-bottom.
    public func updateDistanceFromBottom(_ distance: CGFloat) {
        if shouldFollow {
            if distance > pauseThreshold {
                shouldFollow = false
            }
        } else {
            if distance <= resumeThreshold {
                shouldFollow = true
                pendingNewLines = 0
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

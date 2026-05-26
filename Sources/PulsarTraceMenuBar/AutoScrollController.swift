import Foundation
import Observation

/// Live-transcript auto-scroll state — the pill-driving half of R45.
///
/// The actual "should I scroll on a new line?" decision lives in the
/// NSScrollView-backed view (`LiveScrollableTranscript`), which can sample
/// the user's scroll position *before* the new line lays out — something
/// pure-SwiftUI `GeometryReader` + `PreferenceKey` can't do, because those
/// fire post-layout. This type is just the shared `@Observable` state that
/// the scroll view writes and the SwiftUI overlay (the "Jump to latest"
/// pill) reads.
@MainActor
@Observable
public final class AutoScrollController {

    /// True when the user is at (or essentially at) the bottom of the
    /// transcript. The scroll view writes this on every live scroll event;
    /// the parent view reads it to decide whether to show the pill.
    public private(set) var isAtBottom: Bool = true

    /// Lines that arrived while `isAtBottom == false` — drives the
    /// "↓ N new" pill.
    public private(set) var pendingNewLines: Int = 0

    /// Monotonic counter — bumped each time the user explicitly asks to
    /// catch up (taps the pill). The scroll view watches this via
    /// `@Observable` and animates a scroll-to-bottom when it changes.
    public private(set) var jumpToLatestGeneration: Int = 0

    public init() {}

    /// Called by the scroll view on every live scroll event with the
    /// current at-bottom check. Clears `pendingNewLines` on the
    /// false→true edge (user scrolled back).
    public func setIsAtBottom(_ value: Bool) {
        if value {
            if !isAtBottom {
                isAtBottom = true
                pendingNewLines = 0
            }
        } else {
            if isAtBottom {
                isAtBottom = false
            }
        }
    }

    /// Called by the scroll view when new lines arrived AND the user was
    /// not at the bottom — accrues pending. Non-positive deltas are no-ops.
    public func notePendingNewLines(_ delta: Int) {
        guard delta > 0 else { return }
        pendingNewLines += delta
    }

    /// User tapped the pill — bump the generation so the scroll view will
    /// scroll, and reset our visible state.
    public func jumpToLatest() {
        jumpToLatestGeneration &+= 1
        isAtBottom = true
        pendingNewLines = 0
    }
}

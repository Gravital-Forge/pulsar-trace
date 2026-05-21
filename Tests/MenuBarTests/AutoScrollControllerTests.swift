import Testing
import Foundation
@testable import PulsarTraceMenuBar

/// `AutoScrollController` decides whether the live-transcript view should
/// auto-scroll to the latest line (R45). It's a small @Observable state
/// machine fed pixel-distance-from-bottom by the SwiftUI side. Asymmetric
/// thresholds (hysteresis) keep follow-mode stable across the per-new-line
/// content-height bump.
@Suite("AutoScrollController")
@MainActor
struct AutoScrollControllerTests {

    @Test("initial state: follow on, no pending lines")
    func initialState() {
        let c = AutoScrollController()
        #expect(c.shouldFollow)
        #expect(c.pendingNewLines == 0)
    }

    @Test("while following, distance at or below pauseThreshold keeps follow on")
    func followingKeepsFollowWithinPauseBand() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(0)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(60)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(-10) // content shorter than viewport
        #expect(c.shouldFollow)
    }

    @Test("while following, distance beyond pauseThreshold pauses follow")
    func followingPausesBeyondPauseThreshold() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(61)
        #expect(!c.shouldFollow)
    }

    @Test("while paused, distance in the hysteresis band does NOT resume follow")
    func pausedStaysPausedWithinHysteresisBand() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(200)
        #expect(!c.shouldFollow)

        // Within the hysteresis band (resumeThreshold < d ≤ pauseThreshold):
        // user has scrolled most of the way back but isn't at the bottom yet.
        c.updateDistanceFromBottom(50)
        #expect(!c.shouldFollow)
        c.updateDistanceFromBottom(9)
        #expect(!c.shouldFollow)
    }

    @Test("while paused, distance at or below resumeThreshold resumes follow and clears pending")
    func pausedResumesAtOrBelowResumeThreshold() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(200)
        _ = c.linesDidGrow(by: 3)
        #expect(!c.shouldFollow)
        #expect(c.pendingNewLines == 3)

        c.updateDistanceFromBottom(8)
        #expect(c.shouldFollow)
        #expect(c.pendingNewLines == 0)
    }

    @Test("a per-new-line content bump does NOT pause follow")
    func hysteresisAbsorbsLineHeightBump() {
        // The classic oscillation case: user is at the bottom, follow-mode on.
        // A new line arrives and the content grows by ~one line-height before
        // the auto-scroll catches up. The transient distance bump must not
        // trip pause, or every new line would flash the pill.
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(0)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(18) // one line-height transient
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(0)  // auto-scroll caught up
        #expect(c.shouldFollow)
    }

    @Test("linesDidGrow while following returns true and does not accumulate pending")
    func growWhileFollowingReturnsTrue() {
        let c = AutoScrollController()
        #expect(c.linesDidGrow(by: 2))
        #expect(c.pendingNewLines == 0)
    }

    @Test("linesDidGrow while paused returns false and accumulates pending")
    func growWhilePausedAccumulatesPending() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(200)
        #expect(!c.linesDidGrow(by: 2))
        #expect(c.pendingNewLines == 2)
        #expect(!c.linesDidGrow(by: 3))
        #expect(c.pendingNewLines == 5)
    }

    @Test("linesDidGrow with non-positive delta is a no-op")
    func growWithZeroDeltaIsNoOp() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(200)
        _ = c.linesDidGrow(by: 2)
        #expect(c.pendingNewLines == 2)
        // Re-rendering with the same line count must not re-bump pending.
        _ = c.linesDidGrow(by: 0)
        #expect(c.pendingNewLines == 2)
        // A negative delta (line count somehow shrank — shouldn't happen but
        // we defend against it) is also a no-op.
        _ = c.linesDidGrow(by: -1)
        #expect(c.pendingNewLines == 2)
    }

    @Test("jumpToLatest re-engages follow and clears pending")
    func jumpToLatestResets() {
        let c = AutoScrollController(pauseThreshold: 60, resumeThreshold: 8)
        c.updateDistanceFromBottom(200)
        _ = c.linesDidGrow(by: 4)
        #expect(!c.shouldFollow)
        #expect(c.pendingNewLines == 4)

        c.jumpToLatest()
        #expect(c.shouldFollow)
        #expect(c.pendingNewLines == 0)
    }

    @Test("custom thresholds are honored")
    func customThresholds() {
        let c = AutoScrollController(pauseThreshold: 100, resumeThreshold: 20)
        c.updateDistanceFromBottom(80)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(101)
        #expect(!c.shouldFollow)
        c.updateDistanceFromBottom(50) // in hysteresis band, paused stays paused
        #expect(!c.shouldFollow)
        c.updateDistanceFromBottom(20)
        #expect(c.shouldFollow)
    }
}

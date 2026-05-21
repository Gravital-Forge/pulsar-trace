import Testing
import Foundation
@testable import PulsarTraceMenuBar

/// `AutoScrollController` decides whether the live-transcript view should
/// auto-scroll to the latest line (R45). It's a small @Observable state
/// machine fed pixel-distance-from-bottom by the SwiftUI side.
@Suite("AutoScrollController")
@MainActor
struct AutoScrollControllerTests {

    @Test("initial state: follow on, no pending lines")
    func initialState() {
        let c = AutoScrollController()
        #expect(c.shouldFollow)
        #expect(c.pendingNewLines == 0)
    }

    @Test("distance at or below threshold keeps follow on")
    func nearBottomKeepsFollow() {
        let c = AutoScrollController(nearBottomThreshold: 40)
        c.updateDistanceFromBottom(0)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(40)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(-10) // content shorter than viewport
        #expect(c.shouldFollow)
    }

    @Test("distance beyond threshold pauses follow")
    func scrolledAwayPausesFollow() {
        let c = AutoScrollController(nearBottomThreshold: 40)
        c.updateDistanceFromBottom(41)
        #expect(!c.shouldFollow)
    }

    @Test("scrolling back into the band re-engages follow and clears pending")
    func returnToBottomResumesFollowAndClearsPending() {
        let c = AutoScrollController(nearBottomThreshold: 40)
        c.updateDistanceFromBottom(200)
        _ = c.linesDidGrow(by: 3)
        #expect(!c.shouldFollow)
        #expect(c.pendingNewLines == 3)

        c.updateDistanceFromBottom(10)
        #expect(c.shouldFollow)
        #expect(c.pendingNewLines == 0)
    }

    @Test("linesDidGrow while following returns true and does not accumulate pending")
    func growWhileFollowingReturnsTrue() {
        let c = AutoScrollController()
        #expect(c.linesDidGrow(by: 2))
        #expect(c.pendingNewLines == 0)
    }

    @Test("linesDidGrow while paused returns false and accumulates pending")
    func growWhilePausedAccumulatesPending() {
        let c = AutoScrollController(nearBottomThreshold: 40)
        c.updateDistanceFromBottom(200)
        #expect(!c.linesDidGrow(by: 2))
        #expect(c.pendingNewLines == 2)
        #expect(!c.linesDidGrow(by: 3))
        #expect(c.pendingNewLines == 5)
    }

    @Test("linesDidGrow with non-positive delta is a no-op")
    func growWithZeroDeltaIsNoOp() {
        let c = AutoScrollController(nearBottomThreshold: 40)
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
        let c = AutoScrollController(nearBottomThreshold: 40)
        c.updateDistanceFromBottom(200)
        _ = c.linesDidGrow(by: 4)
        #expect(!c.shouldFollow)
        #expect(c.pendingNewLines == 4)

        c.jumpToLatest()
        #expect(c.shouldFollow)
        #expect(c.pendingNewLines == 0)
    }

    @Test("threshold is configurable")
    func customThreshold() {
        let c = AutoScrollController(nearBottomThreshold: 100)
        c.updateDistanceFromBottom(80)
        #expect(c.shouldFollow)
        c.updateDistanceFromBottom(101)
        #expect(!c.shouldFollow)
    }
}

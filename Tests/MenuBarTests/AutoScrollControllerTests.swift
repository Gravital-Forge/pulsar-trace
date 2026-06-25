import Testing
import Foundation
@testable import PulsarTraceMenuBar

/// `AutoScrollController` is the shared @Observable state between the
/// NSScrollView-backed live transcript view and the SwiftUI "Jump to latest"
/// pill (PT-R45). The "should I scroll on a new line?" decision lives in the
/// scroll view itself — it samples the user's at-bottom state *before* the
/// new line lays out, which pure SwiftUI can't do. This suite covers the
/// pill-driving state machine: isAtBottom, pendingNewLines, jump generation.
@Suite("AutoScrollController")
@MainActor
struct AutoScrollControllerTests {

    @Test("initial state: at the bottom, no pending lines, generation 0")
    func initialState() {
        let c = AutoScrollController()
        #expect(c.isAtBottom)
        #expect(c.pendingNewLines == 0)
        #expect(c.jumpToLatestGeneration == 0)
    }

    @Test("setIsAtBottom(false) flips isAtBottom but does not touch pending")
    func leavingBottomFlipsFlag() {
        let c = AutoScrollController()
        c.notePendingNewLines(2) // can't actually happen while at bottom, but
                                 // we just want pendingNewLines to be nonzero
                                 // — verify the flag flip doesn't clear it.
        c.setIsAtBottom(false)
        #expect(!c.isAtBottom)
        #expect(c.pendingNewLines == 2)
    }

    @Test("setIsAtBottom(true) on the false→true edge clears pending")
    func returnToBottomClearsPending() {
        let c = AutoScrollController()
        c.setIsAtBottom(false)
        c.notePendingNewLines(3)
        #expect(c.pendingNewLines == 3)

        c.setIsAtBottom(true)
        #expect(c.isAtBottom)
        #expect(c.pendingNewLines == 0)
    }

    @Test("redundant setIsAtBottom calls are no-ops")
    func redundantSetsAreNoOps() {
        let c = AutoScrollController()
        // Already at bottom: setting true again should not bump pending.
        c.notePendingNewLines(1) // contrived but tests the no-op path
        c.setIsAtBottom(true)
        #expect(c.pendingNewLines == 1)

        c.setIsAtBottom(false)
        let pending = c.pendingNewLines
        c.setIsAtBottom(false)
        #expect(c.pendingNewLines == pending)
    }

    @Test("notePendingNewLines accumulates positive deltas")
    func pendingAccumulates() {
        let c = AutoScrollController()
        c.setIsAtBottom(false)
        c.notePendingNewLines(2)
        c.notePendingNewLines(3)
        #expect(c.pendingNewLines == 5)
    }

    @Test("notePendingNewLines with non-positive delta is a no-op")
    func pendingIgnoresNonPositive() {
        let c = AutoScrollController()
        c.setIsAtBottom(false)
        c.notePendingNewLines(4)
        c.notePendingNewLines(0)
        c.notePendingNewLines(-1)
        #expect(c.pendingNewLines == 4)
    }

    @Test("jumpToLatest bumps the generation, resets isAtBottom and pending")
    func jumpToLatestResetsAndBumps() {
        let c = AutoScrollController()
        c.setIsAtBottom(false)
        c.notePendingNewLines(4)
        let gen = c.jumpToLatestGeneration

        c.jumpToLatest()
        #expect(c.isAtBottom)
        #expect(c.pendingNewLines == 0)
        #expect(c.jumpToLatestGeneration == gen &+ 1)
    }
}

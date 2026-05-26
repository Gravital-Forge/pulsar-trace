// Tests/UnitTests/PauseGateTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("PauseGate")
struct PauseGateTests {

    @Test("an open gate does not suspend")
    func openDoesNotSuspend() async {
        let gate = PauseGate(initiallyOpen: true)
        // No timeout needed: a passing call returns immediately. Wrap in a
        // task with a tight timeout to fail loudly if behaviour regresses.
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await gate.waitOpen() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(100))
                Issue.record("waitOpen blocked on an open gate")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @Test("a closed gate unblocks every waiter when reopened")
    func closedThenOpenUnblocks() async {
        let gate = PauseGate(initiallyOpen: false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { await gate.waitOpen() }
            }
            // Give the waiters a moment to suspend, then open.
            try? await Task.sleep(for: .milliseconds(20))
            await gate.open()
            // If `open()` did not release them, the implicit await will hang
            // and the test framework's per-test timeout will fail.
            await group.waitForAll()
        }
    }
}

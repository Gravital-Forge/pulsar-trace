import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Unit coverage of `LiveRunnerPhaseTracker` — the lock-protected phase
/// tracker + heartbeat task that makes a wedged `LiveRunner.run` loop
/// observable in the operational log.
///
/// The tracker holds `(phase, frameIndex, since)`. A healthy run loop updates
/// the phase ~16x/sec, so `since` is always tiny. A wedged loop leaves the
/// phase frozen, and the heartbeat task notices the growing age and logs.
@Suite("LiveRunnerPhaseTracker")
struct LiveRunnerPhaseTrackerTests {

    @Test("set() updates the phase and resets the since-timestamp")
    func setUpdatesPhase() async throws {
        let tracker = LiveRunnerPhaseTracker()
        tracker.set("await-foo")
        let first = tracker.snapshot()
        #expect(first.phase == "await-foo")

        // Sleep so `since` has measurably aged before the next set.
        try await Task.sleep(for: .milliseconds(20))
        tracker.set("await-bar")
        let second = tracker.snapshot()
        #expect(second.phase == "await-bar")
        // A fresh `set` resets `since` — the second snapshot's age is small.
        #expect(Date().timeIntervalSince(second.since) < 0.1)
    }

    @Test("set() updates frameIndex when provided; leaves it unchanged when not")
    func setUpdatesFrameIndexOnlyWhenProvided() {
        let tracker = LiveRunnerPhaseTracker()
        tracker.set("frame-system-received", frameIndex: 42)
        #expect(tracker.snapshot().frameIndex == 42)

        tracker.set("await-sink-appendSystemUtterance")
        // The frame index sticks across phase changes within the same frame.
        #expect(tracker.snapshot().frameIndex == 42)

        tracker.set("frame-system-received", frameIndex: 43)
        #expect(tracker.snapshot().frameIndex == 43)
    }

    @Test(
        "heartbeat logs a warning once the current phase ages past the threshold",
        .disabled("flaky under parallel UnitTests pool starvation — even 5s polling is exceeded when the heartbeat Task is starved. Verify with --filter LiveRunnerPhaseTracker")
    )
    func heartbeatLogsWhenPhaseExceedsThreshold() async throws {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let tracker = LiveRunnerPhaseTracker()
        tracker.set("await-sink-appendSystemUtterance", frameIndex: 10847)

        let heartbeat = Task {
            await tracker.runHeartbeat(
                interval: .milliseconds(50),
                threshold: .milliseconds(100),
                logger: logger)
        }
        // Poll until we've observed at least one heartbeat. A fixed sleep
        // window was brittle under parallel UnitTests load (the heartbeat
        // task could be starved past a 300ms ceiling); polling waits the
        // actual signal with a generous ceiling — same shape as the sibling
        // `heartbeatAgeGrowsAcrossTicks` test.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if !capture.messages.isEmpty { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        heartbeat.cancel()
        await heartbeat.value

        let messages = capture.messages
        #expect(!messages.isEmpty, "heartbeat should have logged at least once")
        let first = try #require(messages.first)
        #expect(first.contains("LiveRunner"))
        #expect(first.contains("await-sink-appendSystemUtterance"))
        #expect(first.contains("frameIdx=10847"))
    }

    @Test("heartbeat stays silent while the phase keeps changing under the threshold")
    func heartbeatSilentOnRapidPhaseChanges() async throws {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let tracker = LiveRunnerPhaseTracker()

        let heartbeat = Task {
            await tracker.runHeartbeat(
                interval: .milliseconds(20),
                threshold: .milliseconds(200),
                logger: logger)
        }
        // Churn the phase faster than the threshold for the full window.
        for i in 0..<30 {
            tracker.set("phase-\(i)", frameIndex: i)
            try await Task.sleep(for: .milliseconds(10))
        }
        heartbeat.cancel()
        await heartbeat.value

        #expect(capture.messages.isEmpty,
                "heartbeat must not log while phases change under the threshold; got \(capture.messages)")
    }

    @Test("heartbeat exits promptly on task cancellation")
    func heartbeatHonorsCancellation() async throws {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        let tracker = LiveRunnerPhaseTracker()

        let heartbeat = Task {
            await tracker.runHeartbeat(
                interval: .seconds(10),
                threshold: .seconds(1),
                logger: logger)
        }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        heartbeat.cancel()
        await heartbeat.value
        let elapsed = ContinuousClock.now - start
        // Without cancellation awareness this would block on the 10 s sleep.
        #expect(elapsed < .seconds(2))
    }

    @Test("successive heartbeat lines show the age growing while the phase stays frozen")
    func heartbeatAgeGrowsAcrossTicks() async throws {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let tracker = LiveRunnerPhaseTracker()
        tracker.set("await-library-bestMatch", frameIndex: 999)

        let heartbeat = Task {
            await tracker.runHeartbeat(
                interval: .milliseconds(80),
                threshold: .milliseconds(50),
                logger: logger)
        }
        // Poll until we've observed at least 2 heartbeats. A fixed sleep
        // window was brittle under parallel test load (one tick fits in
        // 500ms when the scheduler is busy); polling waits the actual
        // signal with a generous ceiling.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if capture.messages.compactMap(extractAge(from:)).count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        heartbeat.cancel()
        await heartbeat.value

        let ages = capture.messages.compactMap(extractAge(from:))
        #expect(ages.count >= 2,
                "expected at least two heartbeats while wedged; got \(capture.messages)")
        // Ages must be non-decreasing across successive ticks.
        for i in 1..<ages.count {
            #expect(ages[i] >= ages[i - 1],
                    "age went backwards: \(ages)")
        }
    }

    // MARK: - Helpers

    /// Pull the integer milliseconds out of an "age=NNNms" or "age=Ns" token.
    /// Returns nil if no recognized age token is found.
    private func extractAge(from message: String) -> Int? {
        guard let range = message.range(
            of: #"age=([0-9]+)(ms|s)"#,
            options: .regularExpression) else { return nil }
        let slice = message[range]
        let parts = slice.dropFirst("age=".count)
        let unitIsMs = parts.hasSuffix("ms")
        let numStr = parts.dropLast(unitIsMs ? 2 : 1)
        guard let n = Int(numStr) else { return nil }
        return unitIsMs ? n : n * 1000
    }
}

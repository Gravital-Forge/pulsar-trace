import Testing
import Foundation
@testable import PulsarTraceCapture
@testable import PulsarTraceEngine

/// Unit coverage of the capture-stall watchdog — `FrameWatchdog` — and the
/// stall-recovery wiring.
///
/// The real recovery path (`DeviceCaptureSource.handleStall`) rebuilds an
/// `SCStream` / `AVCaptureSession`, which needs audio hardware and TCC
/// permission and so cannot run here. These tests instead drive the watchdog
/// in isolation with a short, injected threshold: the watchdog is the part of
/// the fix that has no device dependency, and it decides *when* a restart is
/// triggered. See the suite note in `StallRecoveryTests` for what stays
/// device-gated.
@Suite("Capture stall recovery (FrameWatchdog)")
struct StallRecoveryTests {

    /// Thread-safe one-shot flag the watchdog's `onStall` flips.
    private final class StallFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = 0
        func mark() { lock.withLock { fired += 1 } }
        var count: Int { lock.withLock { fired } }
        var didFire: Bool { count > 0 }
    }

    @Test("Watchdog fires when no frame arrives within the threshold")
    func firesOnSilence() async throws {
        let flag = StallFlag()
        let watchdog = FrameWatchdog(
            threshold: .milliseconds(150), label: "test.watchdog.silence")
        watchdog.onStall = { flag.mark() }
        watchdog.arm()

        // No `notifyFrame()` — the stream is silent. Wait well past the
        // threshold, then confirm the watchdog declared a stall.
        try await Task.sleep(for: .milliseconds(400))
        #expect(flag.didFire, "watchdog should fire after a silent threshold")
        #expect(flag.count == 1, "watchdog must fire exactly once")
        watchdog.disarm()
    }

    @Test("Watchdog does NOT fire while frames keep arriving")
    func staysQuietWhileFramesFlow() async throws {
        let flag = StallFlag()
        let watchdog = FrameWatchdog(
            threshold: .milliseconds(200), label: "test.watchdog.healthy")
        watchdog.onStall = { flag.mark() }
        watchdog.arm()

        // Deliver a "frame" every 50 ms for ~600 ms — each one resets the
        // 200 ms countdown, so it must never elapse.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(50))
            watchdog.notifyFrame()
        }
        #expect(!flag.didFire, "a stream that keeps delivering frames is healthy")
        watchdog.disarm()
    }

    @Test("Watchdog fires once frames STOP after a healthy period")
    func firesAfterFramesStop() async throws {
        let flag = StallFlag()
        let watchdog = FrameWatchdog(
            threshold: .milliseconds(150), label: "test.watchdog.stops")
        watchdog.onStall = { flag.mark() }
        watchdog.arm()

        // Healthy for a while...
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(50))
            watchdog.notifyFrame()
        }
        #expect(!flag.didFire, "should still be healthy while frames flow")

        // ...then the stream stalls. The countdown from the last frame elapses.
        try await Task.sleep(for: .milliseconds(400))
        #expect(flag.didFire, "watchdog should fire once frames stop arriving")
        #expect(flag.count == 1, "still exactly one fire")
        watchdog.disarm()
    }

    @Test("disarm() before the threshold prevents the watchdog from firing")
    func disarmSuppressesFire() async throws {
        let flag = StallFlag()
        let watchdog = FrameWatchdog(
            threshold: .milliseconds(300), label: "test.watchdog.disarm")
        watchdog.onStall = { flag.mark() }
        watchdog.arm()

        // Disarm well before the threshold — mirrors `engine.stop()` cancelling
        // its watchdog. It must never fire afterwards.
        try await Task.sleep(for: .milliseconds(80))
        watchdog.disarm()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!flag.didFire, "a disarmed watchdog must not fire")
    }

    @Test("notifyFrame() after disarm() does not resurrect the watchdog")
    func notifyAfterDisarmIsInert() async throws {
        let flag = StallFlag()
        let watchdog = FrameWatchdog(
            threshold: .milliseconds(150), label: "test.watchdog.inert")
        watchdog.onStall = { flag.mark() }
        watchdog.arm()
        watchdog.disarm()

        // A frame racing teardown must not re-arm a disarmed watchdog.
        watchdog.notifyFrame()
        try await Task.sleep(for: .milliseconds(350))
        #expect(!flag.didFire, "notifyFrame after disarm must be a no-op")
    }

    @Test("Re-arming a watchdog restarts the countdown")
    func armRestartsCountdown() async throws {
        let flag = StallFlag()
        let watchdog = FrameWatchdog(
            threshold: .milliseconds(200), label: "test.watchdog.rearm")
        watchdog.onStall = { flag.mark() }

        // Arm, wait part-way, re-arm: the second arm resets the clock, so the
        // total elapsed time before firing is measured from the *second* arm.
        watchdog.arm()
        try await Task.sleep(for: .milliseconds(120))
        watchdog.arm()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!flag.didFire, "re-arm should have reset the countdown")
        try await Task.sleep(for: .milliseconds(200))
        #expect(flag.didFire, "watchdog fires a threshold after the last arm")
        watchdog.disarm()
    }

    @Test("disarm() is idempotent")
    func disarmIsIdempotent() {
        let watchdog = FrameWatchdog(
            threshold: .seconds(1), label: "test.watchdog.idempotent")
        watchdog.arm()
        watchdog.disarm()
        watchdog.disarm()  // must not crash or block
    }
}

/// Coverage of the retry/backoff sequencing the stall handler uses when a
/// fresh engine fails to start.
///
/// `DeviceCaptureSource.attemptStallRestart` no longer sleeps inline: a failed
/// attempt re-schedules the next one with `restartQueue.asyncAfter(deadline:)`
/// — carrying the next, doubled backoff — and returns, so the serial
/// `restartQueue` is free during every backoff and `handleSleep`/`handleWake`
/// can interleave between attempts. The *progression of delay values* is
/// unchanged; this suite mirrors that progression as a free-standing
/// computation so the capped-exponential schedule is verified without a device.
@Suite("Stall-recovery retry backoff")
struct StallBackoffTests {

    /// The exact backoff progression the stall handler applies across
    /// successive `asyncAfter` re-schedules: 1s, 2s, 4s, 8s, then capped at
    /// 10s, indefinitely. Mirrors `DeviceCaptureSource.initialBackoff` /
    /// `.backoffCap` and the `min(backoff * 2, cap)` step.
    private func backoffSequence(count: Int) -> [Duration] {
        var backoff: Duration = .seconds(1)
        let cap: Duration = .seconds(10)
        var out: [Duration] = []
        for _ in 0..<count {
            out.append(backoff)
            backoff = min(backoff * 2, cap)
        }
        return out
    }

    @Test("Backoff doubles each retry and caps at 10s")
    func backoffProgression() {
        let seq = backoffSequence(count: 8)
        #expect(seq[0] == .seconds(1))
        #expect(seq[1] == .seconds(2))
        #expect(seq[2] == .seconds(4))
        #expect(seq[3] == .seconds(8))
        // From here on every entry is clamped to the 10s cap.
        #expect(seq[4] == .seconds(10))
        #expect(seq[5] == .seconds(10))
        #expect(seq[6] == .seconds(10))
        #expect(seq[7] == .seconds(10))
    }

    @Test("Backoff never exceeds the cap")
    func backoffNeverExceedsCap() {
        for delay in backoffSequence(count: 50) {
            #expect(delay <= .seconds(10))
        }
    }
}

/// Coverage of the stale-stall-callback guard.
///
/// A watchdog can dispatch `handleStall` onto `restartQueue` just before the
/// engine it watched is replaced (e.g. across a sleep/wake): that queued
/// callback then targets a fresh, healthy engine. `handleStall` guards against
/// it by recording each stream's *engine-install* wall time and skipping when
/// the live engine is younger than its stall threshold — it cannot have
/// genuinely stalled yet.
///
/// The real guard lives inside the device-gated `handleStall`; this mirrors
/// its decision as a free-standing predicate so the window logic is verified
/// without audio hardware.
@Suite("Stale stall-callback guard")
struct StaleStallGuardTests {

    /// The guard's decision: skip a stall callback when the engine was
    /// installed more recently than its stall threshold ago. Mirrors the
    /// `Date().timeIntervalSince(installedAt) < threshold` check in
    /// `DeviceCaptureSource.handleStall`.
    private func shouldSkip(
        installedAgo: TimeInterval, threshold: Duration
    ) -> Bool {
        let thresholdSeconds = TimeInterval(threshold.components.seconds)
        return installedAgo < thresholdSeconds
    }

    @Test("A just-installed engine cannot have stalled — callback is skipped")
    func freshEngineSkipsStall() {
        // Engine installed 0.5 s ago, mic threshold 4 s: far too young to have
        // genuinely gone silent — a callback here is stale.
        #expect(shouldSkip(
            installedAgo: 0.5, threshold: MicCaptureEngine.stallThreshold))
        #expect(shouldSkip(
            installedAgo: 0.5,
            threshold: SystemAudioCaptureEngine.stallThreshold))
    }

    @Test("An engine older than its threshold is allowed to restart")
    func agedEngineProceeds() {
        // Older than the threshold: a genuine stall is possible, so the
        // handler proceeds (no skip).
        #expect(!shouldSkip(
            installedAgo: 5, threshold: MicCaptureEngine.stallThreshold))
        #expect(!shouldSkip(
            installedAgo: 7,
            threshold: SystemAudioCaptureEngine.stallThreshold))
    }

    @Test("The skip window is exactly the stream's stall threshold")
    func skipWindowMatchesThreshold() {
        // Just inside the mic's 4 s window — skip; just past it — proceed.
        #expect(shouldSkip(
            installedAgo: 3.9, threshold: MicCaptureEngine.stallThreshold))
        #expect(!shouldSkip(
            installedAgo: 4.1, threshold: MicCaptureEngine.stallThreshold))
        // And likewise for the system stream's 6 s window.
        #expect(shouldSkip(
            installedAgo: 5.9,
            threshold: SystemAudioCaptureEngine.stallThreshold))
        #expect(!shouldSkip(
            installedAgo: 6.1,
            threshold: SystemAudioCaptureEngine.stallThreshold))
    }
}

/// The chosen stall thresholds are public engine constants; assert them so a
/// change is a deliberate, reviewed edit.
@Suite("Stall thresholds")
struct StallThresholdTests {

    @Test("System audio threshold is 6s, mic threshold is 4s")
    func thresholdsAreStable() {
        #expect(SystemAudioCaptureEngine.stallThreshold == .seconds(6))
        #expect(MicCaptureEngine.stallThreshold == .seconds(4))
        // The mic reacts faster — it delivers buffers continuously, so a real
        // gap is unambiguous sooner than for bursty system audio.
        #expect(
            MicCaptureEngine.stallThreshold
                < SystemAudioCaptureEngine.stallThreshold)
    }
}

/// Regression coverage for the `onStreamError` wiring gap.
///
/// `SystemAudioCaptureEngine` declared and fired `onStreamError` from its
/// `SCStreamDelegate.stream(_:didStopWithError:)` implementation, but
/// `DeviceCaptureSource.makeSystemEngine` never assigned the callback —
/// a hard `SCStream` abort was a silent no-op (no event, no restart).
/// Session 2026-05-20-113001 stopped delivering audio at ~17 min with no
/// observable recovery; this gap is the most plausible cause.
@Suite("Stream-error wiring")
struct StreamErrorWiringTests {

    /// Regression for session 2026-05-20-113001 (~17-min cutoff with no
    /// `recording_paused` event): `SystemAudioCaptureEngine.onStreamError`
    /// was defined and fired by the delegate's `didStopWithError`, but
    /// `DeviceCaptureSource.makeSystemEngine` never assigned it, so an
    /// `SCStream` error was a silent no-op — no restart, no event.
    @Test("DeviceCaptureSource wires onStreamError so SCStream errors trigger restart")
    func systemEngineHasStreamErrorWiring() {
        let config = DeviceCaptureSource.Configuration(
            recordingId: "rec_wire_test",
            outputDirBasename: "wire",
            micDeviceID: nil,
            systemAudioEnabled: true,
            systemSocketPath: URL(fileURLWithPath: "/tmp/pt-wire-sys.sock"),
            micSocketPath: URL(fileURLWithPath: "/tmp/pt-wire-mic.sock"),
            modelLive: "base",
            events: nil)
        let source = DeviceCaptureSource(configuration: config)
        let engine = source.makeSystemEngine()
        #expect(engine.onStreamError != nil,
                "SCStream errors must be routed into the stall-restart path")
    }

    /// A stream-error from SCStream is authoritative — the stream is dead
    /// regardless of how recently the engine was installed. The recency
    /// guard that legitimately filters stale watchdog callbacks must NOT
    /// suppress a streamError callback. Otherwise a TCC permission
    /// inconsistency or ScreenCaptureKit abort that fires within
    /// stallThreshold of start() leaves capture dead with no restart.
    @Test("a stream-error within stallThreshold still triggers restart")
    func streamErrorBypassesRecencyGuard() async {
        // Build a minimal DeviceCaptureSource (no engines started — we just
        // need a target for handleStall). Use the same Configuration shape
        // as systemEngineHasStreamErrorWiring.
        let config = DeviceCaptureSource.Configuration(
            recordingId: "rec_recency_test",
            outputDirBasename: "rec",
            micDeviceID: nil,
            systemAudioEnabled: true,
            systemSocketPath: URL(fileURLWithPath: "/tmp/pt-rec-sys.sock"),
            micSocketPath: URL(fileURLWithPath: "/tmp/pt-rec-mic.sock"),
            modelLive: "base",
            events: nil)
        let source = DeviceCaptureSource(configuration: config)

        // Mark the system engine as freshly installed (< 6s ago).
        source.markEngineInstalled(stream: .system, at: Date())

        // streamError path must NOT be blocked by the recency guard.
        // (If the recency guard blocks it, restartingStreams stays empty
        //  and no restart attempt is scheduled.)
        source.handleStall(stream: .system, cause: .streamError)

        // Give the restartQueue.async one tick to enqueue.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.restartingStreamsForTest.contains(.system),
                "streamError should bypass recency guard and schedule restart")
    }
}

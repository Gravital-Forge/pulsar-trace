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

/// A fake microphone engine driven entirely by the test — no `AVCaptureSession`,
/// no hardware, no TCC. `start()` succeeds without delivering any frame (the
/// wedged-USB-device signature: `startRunning()` returns yet no buffers flow);
/// the test drives frame delivery explicitly via `deliverFrame()`. Conforms to
/// the production `MicCapturing` seam so it flows through `makeMicEngine`'s
/// exact wiring (`onEvent` / `onStall` assignment).
private final class FakeMicEngine: MicCapturing, @unchecked Sendable {
    var onEvent: (@Sendable (AudioStreamEvent) -> Void)?
    var onStall: (@Sendable () -> Void)?
    let deviceName = "fake-mic"

    /// A path-free error the fake throws from `start()` when configured to
    /// simulate a device that will not come up (drives the failed-start retry
    /// path). Named so the redacted `type(of:)` category in the log is stable.
    struct FakeStartError: Error {}

    private let lock = NSLock()
    private var _started = 0
    private var _stopped = 0
    private var _sequence = 0
    private let _throwsOnStart: Bool

    /// `throwsOnStart: true` makes `start()` throw `FakeStartError` — the
    /// "device will not start" signature that drives `scheduleRetry`.
    init(throwsOnStart: Bool = false) { _throwsOnStart = throwsOnStart }

    var startCount: Int { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopped } }

    func start() throws {
        lock.withLock { _started += 1 }
        if _throwsOnStart { throw FakeStartError() }
    }
    func stop() { lock.withLock { _stopped += 1 } }

    /// Deliver one frame through the production `onEvent` route, exactly as a
    /// real capture callback would.
    func deliverFrame() {
        let index = lock.withLock { () -> Int in
            defer { _sequence += 1 }
            return _sequence
        }
        onEvent?(.frame(AudioFrame(samples: [0], sequenceIndex: index)))
    }
}

/// Hands out fresh `FakeMicEngine` instances (one per `makeMicEngine` call —
/// initial start plus every stall restart) and keeps a reference to each so a
/// test can drive the *latest* one. Thread-safe: the factory closure runs on
/// `restartQueue`.
private final class FakeMicFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _engines: [FakeMicEngine] = []
    private let _throwFirstN: Int

    /// `throwFirstN`: the first `throwFirstN` engines this factory hands out
    /// throw from `start()`; the rest start cleanly. `throwFirstN: 1` drives the
    /// zombie-retry Gap 1 scenario — the initial stall attempt fails (so a
    /// `scheduleRetry` is pending across the sleep/wake), while a later orphaned
    /// retry would succeed and (without the fix) install over the healthy
    /// wake-rebuilt engine.
    init(throwFirstN: Int = 0) { _throwFirstN = throwFirstN }

    var engines: [FakeMicEngine] { lock.withLock { _engines } }
    var latest: FakeMicEngine? { lock.withLock { _engines.last } }
    var count: Int { lock.withLock { _engines.count } }

    func make() -> any MicCapturing {
        let engine: FakeMicEngine = lock.withLock {
            let shouldThrow = _engines.count < _throwFirstN
            let e = FakeMicEngine(throwsOnStart: shouldThrow)
            _engines.append(e)
            return e
        }
        return engine
    }
}

/// Frame-verified mic stall recovery — the rec_2026-07-30-133002 incident.
///
/// A wedged USB mic lets `AVCaptureSession.startRunning()` return successfully
/// yet delivers no buffers. The old recovery path treated a returning
/// `start()` as proof of recovery: it enqueued `.resumed`, emitted
/// `recording_resumed`, and cleared the restart membership immediately — so a
/// silently-dead mic was reported as recovered and never retried. The fix
/// withholds every recovery signal until a *real frame* proves the fresh
/// engine is producing audio, and schedules a no-frame timeout that re-enters
/// the retry loop when it does not.
///
/// These tests drive a real `DeviceCaptureSource` through the production wiring
/// with injected fake engines — no hardware, no TCC — so they run in a plain
/// `swift test` pass alongside the rest of `StallRecoveryTests`.
@Suite("Frame-verified mic stall recovery")
struct FrameVerifiedRecoveryTests {

    /// Read the `type` field of every event line the writer persisted, in
    /// order. Mirrors the `eventTypes` helper used across the pipeline suites.
    private func eventTypes(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard
                    let data = line.data(using: .utf8),
                    let obj = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    let type = obj["type"] as? String
                else { return nil }
                return type
            }
    }

    /// Build a `DeviceCaptureSource` wired to a fake mic factory, with a short
    /// injected no-frame slack so the timeout fires on sub-second timers. A
    /// unique socket dir per call avoids cross-test collisions; the sockets are
    /// never bound (no `prepareForCapture`) — the fake engines never connect.
    private func makeSource(
        factory: FakeMicFactory,
        events: EventWriter?,
        noFrameTimeout: Duration
    ) -> DeviceCaptureSource {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fv-\(UUID().uuidString)")
        let config = DeviceCaptureSource.Configuration(
            recordingId: "rec_fv_test",
            outputDirBasename: "fv",
            micDeviceID: nil,
            systemAudioEnabled: false,
            systemSocketPath: dir.appendingPathComponent("sys.sock"),
            micSocketPath: dir.appendingPathComponent("mic.sock"),
            modelLive: "base",
            events: events)
        return DeviceCaptureSource(
            configuration: config,
            micEngineFactory: { factory.make() },
            systemEngineFactory: nil,
            noFrameTimeoutOverride: noFrameTimeout)
    }

    /// Poll `predicate` until true or the deadline elapses. Deterministic
    /// bounded wait — no fixed sleep racing a timer (house style, c1620c3).
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("A restart whose start() delivers no frame does NOT report resumed")
    func silentRestartWithholdsResume() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        let factory = FakeMicFactory()
        // Age the engine past the recency guard so handleStall proceeds, then
        // a short no-frame timeout so the retry is observable quickly.
        let source = makeSource(
            factory: factory, events: events, noFrameTimeout: .milliseconds(200))
        source.markEngineInstalled(stream: .mic, at: Date(timeIntervalSinceNow: -60))

        // The mic stalls; recovery begins. The fresh engine's start() returns
        // (fake) but it delivers no frame — the wedged-device signature.
        source.handleStall(stream: .mic)

        // A restart engine is built and started, membership held, awaiting
        // its first frame — but NO recording_resumed is emitted.
        let awaiting = await waitUntil {
            source.awaitingFirstFrameForTest.contains(.mic)
        }
        #expect(awaiting, "a started-but-silent restart must await its first frame")
        #expect(source.restartingStreamsForTest.contains(.mic),
                "membership stays held until recovery is frame-verified")

        // The no-frame timeout must fire and re-enter the retry loop — a second
        // restart engine gets built and started. (No initial engine was built:
        // the test never calls startCapture, so restart #1 is factory index 0
        // and the retry engine is index 1.)
        let retried = await waitUntil { factory.count >= 2 }
        #expect(retried,
                "no-frame timeout must retry: build another fresh engine")

        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(types.contains("recording_paused"),
                "stall recovery emits recording_paused")
        #expect(!types.contains("recording_resumed"),
                "recording_resumed must NOT be emitted for a silent restart")

        // Latch `stopped` so the perpetual retry loop bails on its next
        // scheduled attempt (otherwise it keeps building fake engines past the
        // test and leaks retry timers into later suites' output).
        await source.stopCapture(reason: "test_teardown")
    }

    @Test("A restart that delivers a frame reports resumed exactly once, marker first")
    func frameVerifiedResumeAnnouncesOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        let factory = FakeMicFactory()
        // Long no-frame timeout so the frame — not the timeout — drives the
        // outcome; the test delivers a frame well within it.
        let source = makeSource(
            factory: factory, events: events, noFrameTimeout: .seconds(30))
        source.markEngineInstalled(stream: .mic, at: Date(timeIntervalSinceNow: -60))

        // Observe the mic socket's enqueue order: the .resumed marker must be
        // enqueued BEFORE the first post-recovery frame.
        final class OrderLog: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [AudioStreamEvent] = []
            func record(_ e: AudioStreamEvent) { lock.withLock { events.append(e) } }
            var all: [AudioStreamEvent] { lock.withLock { events } }
        }
        let order = OrderLog()
        source.serverForTest(.mic).onEnqueueForTest = { order.record($0) }

        source.handleStall(stream: .mic)

        // Wait until the fresh restart engine is installed and awaiting a frame.
        let awaiting = await waitUntil {
            source.awaitingFirstFrameForTest.contains(.mic)
        }
        #expect(awaiting, "restart engine should be awaiting its first frame")

        // The fresh restart engine (factory index 0 — no startCapture in this
        // test, so the restart is the first engine built) now delivers a frame:
        // real audio is flowing, recovery is proven.
        #expect(factory.count >= 1, "a restart engine must have been built")
        factory.latest?.deliverFrame()

        // recording_resumed is emitted exactly once, membership cleared.
        let resumed = await waitUntil {
            !source.restartingStreamsForTest.contains(.mic)
                && !source.awaitingFirstFrameForTest.contains(.mic)
        }
        #expect(resumed, "a frame must clear the awaiting/restarting state")

        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(types.filter { $0 == "recording_resumed" }.count == 1,
                "exactly one recording_resumed on real recovery")

        // Ordering invariant: on the socket, .resumed precedes the first frame.
        let enqueued = order.all
        let resumedIdx = enqueued.firstIndex {
            if case .resumed = $0 { return true } else { return false }
        }
        let firstFrameIdx = enqueued.firstIndex {
            if case .frame = $0 { return true } else { return false }
        }
        #expect(resumedIdx != nil, ".resumed marker must be enqueued")
        #expect(firstFrameIdx != nil, "the verifying frame must be forwarded")
        if let r = resumedIdx, let f = firstFrameIdx {
            #expect(r < f,
                    ".resumed must be enqueued before the first post-recovery frame")
        }
    }

    @Test("Sleep during the awaiting window releases membership, emits no resumed")
    func sleepDuringAwaitReleasesMembership() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        let factory = FakeMicFactory()
        // Long timeout so the no-frame timeout does NOT fire during the test —
        // the pause path, not the timeout, must release the membership.
        let source = makeSource(
            factory: factory, events: events, noFrameTimeout: .seconds(30))
        source.markEngineInstalled(stream: .mic, at: Date(timeIntervalSinceNow: -60))

        source.handleStall(stream: .mic)
        let awaiting = await waitUntil {
            source.awaitingFirstFrameForTest.contains(.mic)
        }
        #expect(awaiting, "restart engine should be awaiting its first frame")

        // System sleep arrives while we're still awaiting the first frame.
        source.simulateSleepForTest()

        // The awaiting + restarting state must be released — a stream left
        // permanently in restartingStreams would block all future recovery.
        let released = await waitUntil {
            !source.restartingStreamsForTest.contains(.mic)
                && !source.awaitingFirstFrameForTest.contains(.mic)
        }
        #expect(released,
                "sleep during the awaiting window must release the membership")

        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(!types.contains("recording_resumed"),
                "no recording_resumed — recovery was never frame-verified")
    }

    /// Read every persisted event as a `(type, reason)` pair — `reason` is `nil`
    /// for payloads without one. Used to distinguish a `recording_resumed`
    /// emitted for `sleep` (the wake path, expected) from one emitted for
    /// `stall_recovery` (a zombie retry chain, the Gap 1 bug).
    private func typedEvents(in url: URL) throws -> [(type: String, reason: String?)] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> (type: String, reason: String?)? in
                guard
                    let data = line.data(using: .utf8),
                    let obj = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    let type = obj["type"] as? String
                else { return nil }
                return (type, obj["reason"] as? String)
            }
    }

    /// Zombie retry chain after a short sleep/wake (Gap 1).
    ///
    /// A failed first stall attempt schedules a `scheduleRetry` `asyncAfter`
    /// block carrying the backoff delay. A system sleep then clears
    /// `restartingStreams`, and the wake path rebuilds a healthy engine. If the
    /// sleep is shorter than the pending backoff, the retry fires *after* wake:
    /// without an ownership guard it sees `stopped == false, paused == false`,
    /// builds and installs a SECOND engine over the healthy wake-rebuilt one
    /// (two live engines on one stream), and its first frame emits an unpaired
    /// `recording_resumed(stall_recovery)`.
    ///
    /// Fix: `restartingStreams` membership is the chain's ownership token. The
    /// sleep revoked it, so the orphaned retry must return without constructing
    /// an engine or touching state. Asserted by counting factory invocations
    /// (no build after wake) and by the absence of a `stall_recovery` resume.
    @Test("A retry orphaned by a short sleep/wake builds no engine and emits no resumed")
    func zombieRetryAfterSleepWakeIsOrphaned() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = EventWriter(directory: dir.appendingPathComponent("events"))
        await events.bootstrap()

        // First engine throws on start() (drives scheduleRetry); later engines
        // (the wake rebuild, and any zombie retry) start cleanly. A long
        // no-frame timeout keeps that path out of the picture entirely.
        let factory = FakeMicFactory(throwFirstN: 1)
        let source = makeSource(
            factory: factory, events: events, noFrameTimeout: .seconds(30))
        source.markEngineInstalled(stream: .mic, at: Date(timeIntervalSinceNow: -60))

        // Stall: the fresh engine's start() throws, so a scheduleRetry is
        // pending with the 1 s initial backoff (backoff is not injectable, so
        // the test rides the production initial value and polls under it).
        source.handleStall(stream: .mic)
        let failedFirst = await waitUntil {
            factory.count == 1 && source.restartingStreamsForTest.contains(.mic)
        }
        #expect(failedFirst,
                "first stall attempt failed and scheduled a retry (membership held)")

        // A short sleep lands before the 1 s retry fires: it revokes the
        // restart membership and stops the engines.
        source.simulateSleepForTest()
        let membershipRevoked = await waitUntil {
            !source.restartingStreamsForTest.contains(.mic)
        }
        #expect(membershipRevoked, "sleep must revoke the restart membership")

        // Wake rebuilds a healthy engine (factory index 1, starts cleanly) and
        // un-gates frames (paused -> false) — so the orphaned retry, when it
        // fires, sees neither stopped nor paused and (without the fix) would
        // proceed to build engine #3 over the healthy one.
        source.simulateWakeForTest()
        let wakeDone = await waitUntil {
            factory.count == 2 && !source.pausedForTest
        }
        #expect(wakeDone, "wake must rebuild the engine and clear paused")

        // Checkpoint the factory count once the engine landscape is healthy:
        // one failed attempt + one wake rebuild == 2 engines constructed.
        let countAfterWake = factory.count
        #expect(countAfterWake == 2,
                "expected exactly the failed attempt + wake rebuild before the retry")

        // Ride past the 1 s retry deadline. With the ownership guard the
        // orphaned retry returns without building; without it, it builds a
        // third engine (and installs it over the healthy one).
        let builtAnother = await waitUntil(timeout: .seconds(3)) {
            factory.count > countAfterWake
        }
        #expect(!builtAnother,
                "an orphaned retry must NOT construct a new engine after wake")
        #expect(factory.count == countAfterWake,
                "factory invocation count must be unchanged by the orphaned retry")

        // No stall_recovery resume may be emitted — the retry chain was orphaned
        // before it could announce a (false) recovery. resumed(sleep) is fine.
        await events.flush()
        let evts = try typedEvents(in: await events.currentFileURL())
        #expect(!evts.contains { $0.type == "recording_resumed" && $0.reason == "stall_recovery" },
                "no recording_resumed(stall_recovery) — the retry chain was orphaned")

        await source.stopCapture(reason: "test_teardown")
    }
}

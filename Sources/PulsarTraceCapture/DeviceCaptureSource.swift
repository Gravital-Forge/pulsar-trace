import Foundation
import PulsarTraceEngine

/// Owns one recording session's real device capture: the microphone engine,
/// the system-audio engine, their two socket servers, and the sleep/wake
/// monitor. It is the producer side of the `AudioFrameSource` seam — the
/// engine consumes the two sockets via `SocketSource` and cannot tell this
/// from a fixture WAV (Hard Invariant #3).
///
/// `DeviceCaptureSource` is also the authoritative emitter of the
/// recording-lifecycle events (`recording_started` / `_paused` / `_resumed` /
/// `_stopped`): it owns the hardware and the session clock.
///
/// Lifecycle: `prepareForCapture()` (bind sockets — call before the engine
/// connects) → `startCapture()` (start hardware) → `stopCapture(reason:)`.
public final class DeviceCaptureSource: @unchecked Sendable {

    /// One recording session's capture configuration.
    public struct Configuration: Sendable {
        /// Recording id (`rec_<short>`) — scopes sockets and stamps events.
        public let recordingId: String
        /// Basename of the recording's output folder (events carry basenames).
        public let outputDirBasename: String
        /// Microphone `uniqueID`, or `nil` for the system default (R5).
        public let micDeviceID: String?
        /// Whether to capture system audio; `false` for a mic-only run (R6).
        public let systemAudioEnabled: Bool
        /// Where the system-audio socket is bound.
        public let systemSocketPath: URL
        /// Where the microphone socket is bound.
        public let micSocketPath: URL
        /// Whisper model name the live pass will use (recorded in the event).
        public let modelLive: String
        /// Events-log writer, or `nil` to skip event emission.
        public let events: EventWriter?

        public init(
            recordingId: String,
            outputDirBasename: String,
            micDeviceID: String?,
            systemAudioEnabled: Bool,
            systemSocketPath: URL,
            micSocketPath: URL,
            modelLive: String,
            events: EventWriter?
        ) {
            self.recordingId = recordingId
            self.outputDirBasename = outputDirBasename
            self.micDeviceID = micDeviceID
            self.systemAudioEnabled = systemAudioEnabled
            self.systemSocketPath = systemSocketPath
            self.micSocketPath = micSocketPath
            self.modelLive = modelLive
            self.events = events
        }
    }

    internal enum Stream: Sendable, Hashable { case system, mic }

    /// Identifies what triggered `handleStall` so the recency guard can be
    /// applied selectively.
    ///
    /// - `watchdog`: the `FrameWatchdog` fired — silence past the stall
    ///   threshold. The guard is appropriate: a watchdog cannot legitimately
    ///   fire before `stallThreshold` has elapsed, so an early callback is
    ///   stale and safe to skip.
    /// - `streamError`: `SCStream.didStopWithError` fired — the stream is
    ///   dead now, regardless of how recently the engine was installed. The
    ///   recency guard must NOT apply.
    internal enum StallCause: Sendable { case watchdog, streamError }

    private let configuration: Configuration
    private let systemServer: CaptureSocketServer
    private let micServer: CaptureSocketServer
    private let sleepWake = SleepWakeMonitor()

    /// Serializes every operation that rebuilds engine state — `handleSleep`,
    /// `handleWake`, and `handleStall`. They all stop and replace engines, so
    /// they must never overlap. A dedicated serial queue (not the `Task`
    /// executor) gives a single, ordered place to fence them.
    private let restartQueue = DispatchQueue(label: "com.pulsartrace.capture.restart")

    private let lock = NSLock()
    private var micEngine: MicCaptureEngine?
    private var systemEngine: SystemAudioCaptureEngine?
    private var paused = false
    /// Streams with a stall restart in flight — guards against a watchdog on
    /// the *fresh* engine firing again before the restart settles, and against
    /// re-entering `handleStall` for a stream already being rebuilt.
    private var restartingStreams: Set<Stream> = []
    /// Wall-clock time each stream's *current* engine was installed (initial
    /// start, `handleWake`, or a successful `handleStall` install). A stall
    /// callback dispatched just before an engine was replaced (e.g. across a
    /// sleep/wake) is stale: if the live engine is younger than its stall
    /// threshold, it cannot have genuinely stalled, so `handleStall` skips.
    private var engineInstalledAt: [Stream: Date] = [:]
    /// Set once `stopCapture()` begins. A sleep/wake handler that fires during
    /// or after teardown is a no-op — it must not resurrect engines or enqueue
    /// onto a closing socket.
    private var stopped = false
    private var startWall: Date?
    private var pauseWall: Date?
    private var resolvedMicName = "none"

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.systemServer = CaptureSocketServer(socketPath: configuration.systemSocketPath)
        self.micServer = CaptureSocketServer(socketPath: configuration.micSocketPath)
    }

    /// Create the socket directory and `bind()` + `listen()` both sockets.
    /// Must return before the engine `connect()`s — there is no connect-retry
    /// on the engine side.
    public func prepareForCapture() throws {
        let socketDir = configuration.micSocketPath.deletingLastPathComponent()
        try SecureFiles.ensurePrivateDirectory(at: socketDir)
        try micServer.start()
        if configuration.systemAudioEnabled {
            try systemServer.start()
        }
    }

    /// Start hardware capture, begin serving both sockets, and emit
    /// `recording_started`.
    public func startCapture() async throws {
        lock.withLock { startWall = Date() }

        micServer.beginServing()
        if configuration.systemAudioEnabled {
            systemServer.beginServing()
        }

        let mic = makeMicEngine()
        try mic.start()
        lock.withLock {
            micEngine = mic
            resolvedMicName = mic.deviceName
            engineInstalledAt[.mic] = Date()
        }

        if configuration.systemAudioEnabled {
            let system = makeSystemEngine()
            try await system.start()
            lock.withLock {
                systemEngine = system
                engineInstalledAt[.system] = Date()
            }
        }

        sleepWake.onSleep = { [weak self] in self?.handleSleep() }
        sleepWake.onWake = { [weak self] in self?.handleWake() }
        sleepWake.start()

        await emit(RecordingStartedEvent(
            recordingId: configuration.recordingId,
            outputDirBasename: configuration.outputDirBasename,
            micDevice: lock.withLock { resolvedMicName },
            systemAudioEnabled: configuration.systemAudioEnabled,
            modelLive: configuration.modelLive))
    }

    /// Stop hardware capture, flush both streams (drain + end-of-stream
    /// sentinel), tear down the sockets, and emit `recording_stopped`.
    public func stopCapture(reason: String) async {
        // Latch `stopped` first: `sleepWake.stop()` halts new power callbacks,
        // but a sleep/wake handler already in flight checks this flag and
        // bails rather than racing the teardown below.
        lock.withLock { stopped = true }
        sleepWake.stop()

        let (mic, system, start) = lock.withLock {
            (micEngine, systemEngine, startWall)
        }
        mic?.stop()
        await system?.stop()

        // `stop()` drains the queue and writes EOS before joining, so the
        // tail of captured audio is not dropped.
        micServer.stop()
        if configuration.systemAudioEnabled {
            systemServer.stop()
        }

        let duration = start.map { Date().timeIntervalSince($0) } ?? 0
        await emit(RecordingStoppedEvent(
            recordingId: configuration.recordingId,
            durationSeconds: duration,
            reason: reason))
    }

    // MARK: - Engine construction

    // `internal` (not `private`) so `StallRecoveryTests` can construct the
    // engines via the production wiring path and assert that the watchdog /
    // stream-error callbacks are assigned. The tests don't start the engines —
    // they just inspect the closure slots.
    internal func makeMicEngine() -> MicCaptureEngine {
        let engine = MicCaptureEngine(deviceID: configuration.micDeviceID)
        engine.onEvent = { [weak self] event in self?.route(event, .mic) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .mic) }
        return engine
    }

    internal func makeSystemEngine() -> SystemAudioCaptureEngine {
        let engine = SystemAudioCaptureEngine(filter: .allApps)
        engine.onEvent = { [weak self] event in self?.route(event, .system) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .system) }
        // A hard `SCStream` failure (e.g. TCC revoked mid-session, display
        // rearrangement, ScreenCaptureKit internal abort) reaches
        // `SystemAudioCaptureEngine.stream(_:didStopWithError:)`, which fires
        // `onStreamError`. Without this assignment the callback fires into
        // the void and capture dies silently — observed on session
        // 2026-05-20-113001 (~17 min in, no `recording_paused` event).
        // Route into the same path as a silent stall: `handleStall` emits
        // `recording_paused` (reason `stall_recovery`), stops the engine,
        // and rebuilds a fresh one with exponential backoff. The error's
        // type name is logged for diagnosability (its description is not
        // logged because it can carry a filesystem path — Hard Invariant #7).
        engine.onStreamError = { [weak self] error in
            guard let self else { return }
            self.log("system audio stream error (\(type(of: error)))")
            self.handleStall(stream: .system, cause: .streamError)
        }
        return engine
    }

    /// Route a captured event to its socket. Frames are dropped while paused
    /// so no audio from a sleep window leaks onto the wire; everything is
    /// dropped once teardown has begun.
    private func route(_ event: AudioStreamEvent, _ stream: Stream) {
        let (isPaused, isStopped) = lock.withLock { (paused, stopped) }
        if isStopped { return }
        if isPaused, case .frame = event { return }
        switch stream {
        case .system: systemServer.enqueue(event)
        case .mic: micServer.enqueue(event)
        }
    }

    // MARK: - Restart coordination

    /// Run an `async` body to completion synchronously on the calling thread.
    /// Used inside `restartQueue` blocks (a background serial queue, never the
    /// async executor) so `handleSleep` / `handleWake` / `handleStall` run
    /// strictly one at a time on that queue without overlapping engine state.
    ///
    /// Only ever wraps *bounded* awaits (engine `start()`/`stop()`, event
    /// emission). A multi-second `Task.sleep` must never run under it — that
    /// would pin the serial `restartQueue` thread; the stall-retry backoff is
    /// re-scheduled via `restartQueue.asyncAfter` instead.
    private func runBlocking(_ body: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await body(); done.signal() }
        done.wait()
    }

    /// `runBlocking` variant that carries a result back to the caller via a
    /// `Sendable` box — the body runs in a detached task, so a captured `var`
    /// cannot be mutated directly.
    private func runBlocking<T: Sendable>(
        _ body: @escaping @Sendable () async -> T
    ) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.set(await body()); done.signal() }
        done.wait()
        return box.take()
    }

    /// One-shot `Sendable` carrier for `runBlocking`'s returning variant.
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.withLock { value = v } }
        func take() -> T { lock.withLock { value! } }
    }

    // MARK: - Sleep / wake (R7)

    private func handleSleep() {
        restartQueue.async { [self] in
            let skip = lock.withLock { () -> Bool in
                if stopped || paused { return true }
                paused = true
                pauseWall = Date()
                return false
            }
            guard !skip else { return }

            // Mark the gap in both streams before the engines wind down.
            micServer.enqueue(.paused)
            if configuration.systemAudioEnabled {
                systemServer.enqueue(.paused)
            }
            let (mic, system) = lock.withLock { (micEngine, systemEngine) }
            runBlocking { [self] in
                mic?.stop()
                await system?.stop()
                await emit(RecordingPausedEvent(
                    recordingId: configuration.recordingId, reason: "sleep"))
            }
        }
    }

    private func handleWake() {
        restartQueue.async { [self] in
            let pausedAt = lock.withLock { () -> Date? in
                guard !stopped, paused else { return nil }
                return pauseWall
            }
            guard let pausedAt else { return }
            let gap = Date().timeIntervalSince(pausedAt)

            runBlocking { [self] in
                guard !lock.withLock({ stopped }) else { return }
                // Fresh engine instances — the capture sessions were torn down
                // on sleep — feeding the same socket servers.
                let mic = makeMicEngine()
                try? mic.start()
                var system: SystemAudioCaptureEngine?
                if configuration.systemAudioEnabled {
                    let engine = makeSystemEngine()
                    try? await engine.start()
                    system = engine
                }
                // Teardown may have begun while the engines were starting — if
                // so, stop the just-created engines instead of installing them.
                let abort = lock.withLock { () -> Bool in
                    guard !stopped else { return true }
                    micEngine = mic
                    systemEngine = system
                    let now = Date()
                    engineInstalledAt[.mic] = now
                    if system != nil { engineInstalledAt[.system] = now }
                    return false
                }
                if abort {
                    mic.stop()
                    await system?.stop()
                    return
                }
                // Announce the resume on both sockets *before* un-gating
                // frames, so the engine never sees post-resume audio ahead of
                // its resume marker; `paused` still gates `route()` until the
                // line below.
                let gapEvent = AudioStreamEvent.resumed(gap: .seconds(gap))
                micServer.enqueue(gapEvent)
                if configuration.systemAudioEnabled {
                    systemServer.enqueue(gapEvent)
                }
                lock.withLock {
                    paused = false
                    pauseWall = nil
                }
                await emit(RecordingResumedEvent(
                    recordingId: configuration.recordingId, reason: "sleep"))
            }
        }
    }

    // MARK: - Stall recovery

    /// Capped exponential backoff between failed restart attempts: 1s → 2s →
    /// 4s → 8s, then clamped at 10s indefinitely.
    private static let initialBackoff: Duration = .seconds(1)
    private static let backoffCap: Duration = .seconds(10)

    /// One stream's capture watchdog fired: no frame within its threshold,
    /// with no error and no end-of-stream. Restart that one stream in place —
    /// the same stop-engine / build-fresh-engine / resume operation as a
    /// sleep+wake, scoped to a single stream — while the other stream and the
    /// rest of the recording keep running.
    ///
    /// Serialized with `handleSleep` / `handleWake` on `restartQueue`. The
    /// retry backoff does NOT block the serial queue: a failed attempt
    /// re-schedules the next one with `restartQueue.asyncAfter` and returns,
    /// so each queued block is short and `handleSleep`/`handleWake` can
    /// interleave between attempts.
    internal func handleStall(stream: Stream, cause: StallCause = .watchdog) {
        let stallWall = Date()
        restartQueue.async { [self] in
            // Bail if teardown began, a sleep is in progress (the wake rebuilds
            // both engines anyway), or this stream is already being restarted.
            //
            // For the watchdog path only: also bail if this stream's engine was
            // installed more recently than its stall threshold ago. A watchdog
            // callback dispatched just before an engine swap (e.g. across
            // sleep/wake) targets a fresh, healthy engine that has had no chance
            // to genuinely stall and should be ignored.
            //
            // This guard does NOT apply to `.streamError`: SCStream's
            // `didStopWithError` is authoritative — the stream is dead
            // regardless of how recently the engine was installed. A TCC
            // permission inconsistency or ScreenCaptureKit abort can fire
            // within the first second of start(); suppressing that would leave
            // capture silently dead.
            let proceed = lock.withLock { () -> Bool in
                guard !stopped, !paused, !restartingStreams.contains(stream)
                else { return false }
                if cause == .watchdog,
                   let installedAt = engineInstalledAt[stream],
                   Date().timeIntervalSince(installedAt)
                       < secondsValue(stallThreshold(for: stream)) {
                    return false
                }
                restartingStreams.insert(stream)
                return true
            }
            guard proceed else { return }

            log(stream == .system
                ? "system audio stream stalled — restarting"
                : "microphone stream stalled — restarting")

            // Mark the gap on this stream's socket only.
            server(for: stream).enqueue(.paused)

            // Emit the paused event first so each `recording_resumed` is
            // preceded by its `recording_paused` (Hard Invariant #8), then
            // stop the stalled engine. These are bounded awaits, so `runBlocking`
            // is safe here — no multi-second sleep runs under it.
            runBlocking { [self] in
                await emit(RecordingPausedEvent(
                    recordingId: configuration.recordingId,
                    reason: "stall_recovery"))
                switch stream {
                case .system:
                    let engine = lock.withLock { systemEngine }
                    await engine?.stop()
                case .mic:
                    let engine = lock.withLock { micEngine }
                    engine?.stop()
                }
            }

            // First restart attempt; subsequent ones are re-scheduled via
            // `asyncAfter` so the serial queue is free during every backoff.
            attemptStallRestart(
                stream: stream, stallWall: stallWall,
                backoff: DeviceCaptureSource.initialBackoff)
        }
    }

    /// A failed restart attempt, reduced to a path-free error *category* (the
    /// error's Swift type name) so nothing path-bearing crosses into the log.
    private struct StartFailure: Sendable {
        let category: String
    }

    /// One restart attempt for a stalled stream. Runs on `restartQueue`. On
    /// success, installs the fresh engine, resumes, and clears the
    /// `restartingStreams` membership. On failure, re-schedules itself on
    /// `restartQueue` after `backoff` (the queue stays free meanwhile) with
    /// the next, doubled backoff. The `restartingStreams` membership is held
    /// across the whole sequence and cleared only when it ends.
    private func attemptStallRestart(
        stream: Stream, stallWall: Date, backoff: Duration
    ) {
        // `stopCapture` may have latched `stopped` between attempts — abandon
        // the sequence and release the membership if so.
        if lock.withLock({ stopped }) {
            lock.withLock { _ = restartingStreams.remove(stream) }
            return
        }

        let startError: StartFailure? = runBlocking { [self] in
            do {
                switch stream {
                case .system:
                    let fresh = makeSystemEngine()
                    try await fresh.start()
                    // Re-check `stopped` before installing — teardown may have
                    // begun while `start()` was in flight.
                    let abort = lock.withLock { () -> Bool in
                        guard !stopped else { return true }
                        systemEngine = fresh
                        engineInstalledAt[.system] = Date()
                        return false
                    }
                    if abort { await fresh.stop() }
                case .mic:
                    let fresh = makeMicEngine()
                    try fresh.start()
                    let abort = lock.withLock { () -> Bool in
                        guard !stopped else { return true }
                        micEngine = fresh
                        resolvedMicName = fresh.deviceName
                        engineInstalledAt[.mic] = Date()
                        return false
                    }
                    if abort { fresh.stop() }
                }
                return nil
            } catch {
                // Carry only the error's *type name* back across the task
                // boundary — never the full description, which can render a
                // filesystem path (Hard Invariant #7 / R84).
                return StartFailure(category: "\(type(of: error))")
            }
        }

        // Teardown won the race during `start()` — drop the membership and stop.
        if lock.withLock({ stopped }) {
            lock.withLock { _ = restartingStreams.remove(stream) }
            return
        }

        if let startError {
            // The error category was redacted to a bare type name at the
            // task boundary above — no filesystem path can reach this log.
            log("\(stream == .system ? "system audio" : "microphone")"
                + " restart failed (\(startError.category))"
                + " — retrying in \(backoff)")
            let next = min(backoff * 2, DeviceCaptureSource.backoffCap)
            restartQueue.asyncAfter(
                deadline: .now() + secondsValue(backoff)
            ) { [self] in
                attemptStallRestart(
                    stream: stream, stallWall: stallWall, backoff: next)
            }
            return
        }

        // Started and installed. Announce the resume on this stream's socket
        // and emit the lifecycle event; the gap is wall-clock elapsed since
        // the watchdog fired. Release the membership last.
        let gap = Date().timeIntervalSince(stallWall)
        server(for: stream).enqueue(.resumed(gap: .seconds(gap)))
        runBlocking { [self] in
            await emit(RecordingResumedEvent(
                recordingId: configuration.recordingId,
                reason: "stall_recovery"))
        }
        log(stream == .system
            ? "system audio stream recovered"
            : "microphone stream recovered")
        lock.withLock { _ = restartingStreams.remove(stream) }
    }

    private func server(for stream: Stream) -> CaptureSocketServer {
        switch stream {
        case .system: return systemServer
        case .mic: return micServer
        }
    }

    /// The stall threshold of the engine type backing `stream` — used to size
    /// the stale-callback guard in `handleStall`.
    private func stallThreshold(for stream: Stream) -> Duration {
        switch stream {
        case .system: return SystemAudioCaptureEngine.stallThreshold
        case .mic: return MicCaptureEngine.stallThreshold
        }
    }

    /// A `Duration` as a `TimeInterval` (seconds, fractional) for comparison
    /// against `Date` arithmetic.
    private func secondsValue(_ duration: Duration) -> TimeInterval {
        let c = duration.components
        return TimeInterval(c.seconds)
            + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }

    // MARK: - Test hooks

    /// Record the wall-clock time at which `stream`'s engine was installed.
    /// Used by `StallRecoveryTests` to simulate a freshly-installed engine
    /// without starting real hardware (so the recency guard can be tested
    /// in isolation).
    internal func markEngineInstalled(stream: Stream, at date: Date) {
        lock.withLock { engineInstalledAt[stream] = date }
    }

    /// The set of streams currently undergoing a stall restart. Exposed for
    /// `StallRecoveryTests` so the test can confirm `handleStall` enqueued a
    /// restart without starting real hardware.
    internal var restartingStreamsForTest: Set<Stream> {
        lock.withLock { restartingStreams }
    }

    /// Operational diagnostic to stderr — the daemon's log channel.
    private func log(_ message: String) {
        FileHandle.standardError.write(
            Data("pulsartrace-capture: \(message)\n".utf8))
    }

    private func emit<P: EventPayload>(_ payload: P) async {
        guard let events = configuration.events else { return }
        _ = try? await events.append(payload)
    }
}

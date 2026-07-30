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
        /// Microphone `uniqueID`, or `nil` for the system default (PT-R5).
        public let micDeviceID: String?
        /// Whether to capture system audio; `false` for a mic-only run (PT-R6).
        public let systemAudioEnabled: Bool
        /// Where the system-audio socket is bound.
        public let systemSocketPath: URL
        /// Where the microphone socket is bound.
        public let micSocketPath: URL
        /// Live model name (recorded in `recording_started.model_live`; fixed
        /// to parakeet-v3).
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
    private var micEngine: (any MicCapturing)?
    private var systemEngine: (any SystemAudioCapturing)?
    private var paused = false
    /// Streams with a stall restart in flight — guards against a watchdog on
    /// the *fresh* engine firing again before the restart settles, and against
    /// re-entering `handleStall` for a stream already being rebuilt. Held from
    /// the moment `handleStall` accepts a stall until recovery is *frame-
    /// verified* (or the sequence is abandoned) — across every failed `start()`
    /// AND across the awaiting-first-frame window of a `start()` that returned
    /// but delivered nothing.
    private var restartingStreams: Set<Stream> = []
    /// Streams whose fresh engine has been installed by a stall restart but has
    /// not yet delivered its first frame. Recovery is *not* announced
    /// (`recording_resumed`, `.resumed` marker, membership release) until a
    /// real frame proves the new engine is actually producing audio: a wedged
    /// CoreAudio/USB device lets `start()` return successfully yet delivers no
    /// buffers, so a `start()` that returns is not evidence of recovery. The
    /// no-frame timeout (`restartQueue.asyncAfter`) owns the fallback retry.
    /// Incident: rec_2026-07-30-133002 — a USB mic wedged ~72 s in; a restart's
    /// `start()` succeeded silently and the old code announced a recovery that
    /// never happened, leaving the mic dead for 59 min.
    private var awaitingFirstFrame: Set<Stream> = []
    /// Wall-clock time of the *original* stall for each stream awaiting its
    /// first frame — used to size the `.resumed` gap when a frame finally
    /// verifies recovery, so the gap covers the whole stall-to-recovery span
    /// (same as the pre-fix behavior) regardless of how many restart attempts
    /// it took.
    private var stallWallByStream: [Stream: Date] = [:]
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

    /// Engine factories — default to the real engines and are swapped out only
    /// by `StallRecoveryTests` to inject fakes through the production wiring
    /// path (`makeMicEngine` / `makeSystemEngine`). Every constructed engine —
    /// initial start, sleep/wake rebuild, stall restart — flows through these.
    private let micEngineFactory: @Sendable () -> any MicCapturing
    private let systemEngineFactory: @Sendable () -> any SystemAudioCapturing

    /// How long a restart that has installed a fresh engine but seen no frame
    /// waits before being declared dead and retried. When `nil` (production),
    /// the stream's `stallThreshold + 1s` is used; tests inject a small
    /// absolute value so the no-frame retry is observable on sub-second timers
    /// (mirrors how `FrameWatchdog` tests inject short thresholds).
    private let noFrameTimeoutOverride: Duration?

    public convenience init(configuration: Configuration) {
        self.init(
            configuration: configuration,
            micEngineFactory: nil,
            systemEngineFactory: nil,
            noFrameTimeoutOverride: nil)
    }

    /// Designated initializer with the internal test seams. Production callers
    /// use `init(configuration:)`, which passes `nil` for every seam so the
    /// real engines and the production timeout are used.
    internal init(
        configuration: Configuration,
        micEngineFactory: (@Sendable () -> any MicCapturing)?,
        systemEngineFactory: (@Sendable () -> any SystemAudioCapturing)?,
        noFrameTimeoutOverride: Duration?
    ) {
        self.configuration = configuration
        self.systemServer = CaptureSocketServer(socketPath: configuration.systemSocketPath)
        self.micServer = CaptureSocketServer(socketPath: configuration.micSocketPath)
        let micDeviceID = configuration.micDeviceID
        self.micEngineFactory = micEngineFactory
            ?? { MicCaptureEngine(deviceID: micDeviceID) }
        self.systemEngineFactory = systemEngineFactory
            ?? { SystemAudioCaptureEngine(filter: .allApps) }
        self.noFrameTimeoutOverride = noFrameTimeoutOverride
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
    // stream-error callbacks are assigned, and inject fake engines through the
    // factory closures. The engines are built through the injectable factories
    // so a test's fakes flow through exactly this wiring.
    internal func makeMicEngine() -> any MicCapturing {
        let engine = micEngineFactory()
        engine.onEvent = { [weak self] event in self?.route(event, .mic) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .mic) }
        return engine
    }

    internal func makeSystemEngine() -> any SystemAudioCapturing {
        let engine = systemEngineFactory()
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
    ///
    /// The first frame of a stream that is *awaiting first frame* after a stall
    /// restart is what proves the fresh engine is actually producing audio — a
    /// returning `start()` is not evidence, since a wedged device lets it
    /// succeed silently. That frame drives frame-verified recovery: enqueue the
    /// `.resumed` marker BEFORE forwarding the frame (the engine must never see
    /// post-resume audio ahead of its resume marker), forward the frame, then
    /// announce `recording_resumed` off the hot path. The awaiting flag is
    /// cleared atomically so racing delivery-queue frames cannot double-fire.
    private func route(_ event: AudioStreamEvent, _ stream: Stream) {
        // Decide first-frame recovery under the same lock that reads paused /
        // stopped, so exactly one frame wins the awaiting→verified transition.
        let decision = lock.withLock { () -> (drop: Bool, verify: Date?) in
            if stopped { return (true, nil) }
            if case .frame = event {
                if paused { return (true, nil) }
                if awaitingFirstFrame.remove(stream) != nil {
                    // This frame verifies recovery — pair it with the stall's
                    // wall time to size the resume gap, then fall through to
                    // enqueue .resumed ahead of the frame below.
                    let wall = stallWallByStream[stream]
                    stallWallByStream[stream] = nil
                    return (false, wall ?? Date())
                }
            }
            return (false, nil)
        }
        if decision.drop { return }

        // Frame-verified recovery: resume marker precedes the verifying frame.
        if let stallWall = decision.verify {
            let gap = Date().timeIntervalSince(stallWall)
            server(for: stream).enqueue(.resumed(gap: .seconds(gap)))
            server(for: stream).enqueue(event)
            // Announce off the hot delivery path; membership released there.
            restartQueue.async { [self] in announceRecovery(stream: stream) }
            return
        }

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

    // MARK: - Sleep / wake (PT-R7)

    private func handleSleep() {
        restartQueue.async { [self] in
            let skip = lock.withLock { () -> Bool in
                if stopped || paused { return true }
                paused = true
                pauseWall = Date()
                // A stall restart in flight (failed-start backoff, or an
                // awaiting-first-frame window) is moot now: sleep tears down
                // the engines and the wake path rebuilds both fresh. Release
                // the restart membership so a stream is never left permanently
                // in `restartingStreams` — that would block all future stall
                // recovery. The pending `asyncAfter` retry / no-frame timeout
                // still fires but sees `paused` and bails via `bailIfInactive`.
                restartingStreams.removeAll()
                awaitingFirstFrame.removeAll()
                stallWallByStream.removeAll()
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
                var system: (any SystemAudioCapturing)?
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
            // The `restartingStreams` membership is held from a stall's start
            // through frame-verified recovery — including the awaiting-first-
            // frame window — so a *fresh* restart engine's own watchdog firing
            // during that window is ignored here and the no-frame timeout owns
            // the retry. A genuine stall *after* recovery is still caught: the
            // verifying frame reset the engine's watchdog and released the
            // membership, so a later silence re-enters this path cleanly (see
            // `announceRecovery`).
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

    /// One restart attempt for a stalled stream. Runs on `restartQueue`. A
    /// `start()` that returns is NOT treated as recovery: a wedged CoreAudio /
    /// USB device lets `startRunning()` succeed yet delivers no buffers
    /// (incident rec_2026-07-30-133002). On a returning `start()` the fresh
    /// engine is installed and the stream is marked *awaiting its first frame*;
    /// recovery (`.resumed` marker, `recording_resumed`, membership release) is
    /// announced only when `route()` sees a real frame prove the engine is
    /// producing audio. A no-frame timeout re-enters this loop if none arrives.
    /// On a thrown `start()` the attempt re-schedules itself after `backoff`.
    /// The `restartingStreams` membership is held across the whole sequence —
    /// every failed `start()` and every awaiting-first-frame window — and
    /// released only when recovery is frame-verified or the sequence is
    /// abandoned (teardown / sleep).
    private func attemptStallRestart(
        stream: Stream, stallWall: Date, backoff: Duration
    ) {
        // Ownership check FIRST: `restartingStreams` membership is this chain's
        // ownership token. A sleep landing between attempts calls
        // `restartingStreams.removeAll()` and rebuilds both engines on wake — so
        // if this stream is no longer a member, a still-pending `scheduleRetry`
        // block has been *orphaned*. It must NOT proceed: doing so would install
        // a second engine over the healthy wake-rebuilt one (two live engines on
        // one stream) and its first frame would emit an unpaired
        // `recording_resumed`. The sleep path already stopped whatever this
        // chain had installed, so there is nothing to release or stop here —
        // just return. (This is derived *before* the stopped/paused bail so the
        // orphaned case does not touch membership that a sleep already cleared.)
        let owned = lock.withLock { restartingStreams.contains(stream) }
        guard owned else { return }

        // `stopCapture` latched `stopped`, or a sleep latched `paused` while
        // still holding membership, between attempts — abandon the sequence and
        // release the membership. Leaving a stream in `restartingStreams` would
        // block all future stall recovery; on sleep the wake path rebuilds both
        // engines anyway.
        if bailIfInactive(stream) { return }

        let outcome: RestartOutcome = runBlocking { [self] in
            do {
                switch stream {
                case .system:
                    let fresh = makeSystemEngine()
                    try await fresh.start()
                    // Re-check active before installing — teardown or sleep may
                    // have begun while `start()` was in flight.
                    let installed = lock.withLock { () -> Bool in
                        guard !stopped, !paused else { return false }
                        systemEngine = fresh
                        engineInstalledAt[.system] = Date()
                        awaitingFirstFrame.insert(.system)
                        stallWallByStream[.system] = stallWall
                        return true
                    }
                    if !installed { await fresh.stop(); return .aborted }
                    return .installed(AnyCapturing(system: fresh))
                case .mic:
                    let fresh = makeMicEngine()
                    try fresh.start()
                    let installed = lock.withLock { () -> Bool in
                        guard !stopped, !paused else { return false }
                        micEngine = fresh
                        resolvedMicName = fresh.deviceName
                        engineInstalledAt[.mic] = Date()
                        awaitingFirstFrame.insert(.mic)
                        stallWallByStream[.mic] = stallWall
                        return true
                    }
                    if !installed { fresh.stop(); return .aborted }
                    return .installed(AnyCapturing(mic: fresh))
                }
            } catch {
                // Carry only the error's *type name* back across the task
                // boundary — never the full description, which can render a
                // filesystem path (Hard Invariant #7 / PT-R84).
                return .failed(StartFailure(category: "\(type(of: error))"))
            }
        }

        switch outcome {
        case .aborted:
            // Teardown or sleep won the race during `start()`. `installed`
            // stayed false, so the awaiting/restarting state was never set for
            // this fresh engine; still release the membership the sequence held.
            lock.withLock { _ = restartingStreams.remove(stream) }
            return

        case .failed(let startError):
            // The error category was redacted to a bare type name at the
            // task boundary above — no filesystem path can reach this log.
            log("\(stream == .system ? "system audio" : "microphone")"
                + " restart failed (\(startError.category))"
                + " — retrying in \(backoff)")
            scheduleRetry(stream: stream, stallWall: stallWall, backoff: backoff)

        case .installed(let fresh):
            // Started and installed, but NOT yet recovered: a returning
            // `start()` is not evidence of audio (wedged-device signature).
            // Recovery is announced by `route()` on the first real frame; if
            // none arrives within the no-frame timeout, retry. The membership
            // stays held throughout.
            scheduleNoFrameTimeout(
                stream: stream, engine: fresh,
                stallWall: stallWall, backoff: backoff)
        }
    }

    /// Outcome of one `attemptStallRestart` pass.
    private enum RestartOutcome: Sendable {
        /// Teardown or sleep interrupted the attempt before install.
        case aborted
        /// `start()` threw — retry after backoff.
        case failed(StartFailure)
        /// Fresh engine installed; awaiting its first frame to confirm recovery.
        case installed(AnyCapturing)
    }

    /// Type-erased handle to whichever engine a restart installed, so the
    /// no-frame timeout can stop *that specific* fresh engine on a dead restart
    /// without re-reading `micEngine`/`systemEngine` (which a racing sleep/wake
    /// could have replaced).
    private struct AnyCapturing: @unchecked Sendable {
        let stop: @Sendable () async -> Void
        init(mic: any MicCapturing) { stop = { mic.stop() } }
        init(system: any SystemAudioCapturing) { stop = { await system.stop() } }
    }

    /// Release the `restartingStreams` and `awaitingFirstFrame` membership and
    /// return `true` when the stream is no longer active (teardown or sleep).
    /// A stream must never be left permanently in `restartingStreams` — that
    /// would block every future stall recovery for it.
    private func bailIfInactive(_ stream: Stream) -> Bool {
        lock.withLock { () -> Bool in
            guard stopped || paused else { return false }
            _ = restartingStreams.remove(stream)
            _ = awaitingFirstFrame.remove(stream)
            stallWallByStream[stream] = nil
            return true
        }
    }

    /// Re-schedule the next restart attempt after `backoff` (queue stays free),
    /// carrying the next, doubled backoff.
    private func scheduleRetry(
        stream: Stream, stallWall: Date, backoff: Duration
    ) {
        let next = min(backoff * 2, DeviceCaptureSource.backoffCap)
        restartQueue.asyncAfter(
            deadline: .now() + secondsValue(backoff)
        ) { [self] in
            attemptStallRestart(
                stream: stream, stallWall: stallWall, backoff: next)
        }
    }

    /// After installing a fresh engine, wait `stallThreshold + 1s` (or the
    /// injected override) for its first frame. If the stream is still awaiting
    /// one (and neither stopped nor paused), the restart produced no audio —
    /// stop the dead fresh engine and re-enter the retry loop with the next
    /// doubled backoff. The membership is held across this exactly as across a
    /// failed `start()`. `recording_resumed` is never emitted on this path
    /// (Hard Invariant #8).
    private func scheduleNoFrameTimeout(
        stream: Stream, engine: AnyCapturing, stallWall: Date, backoff: Duration
    ) {
        let timeout = noFrameTimeoutOverride
            ?? (stallThreshold(for: stream) + .seconds(1))
        let deadline = secondsValue(timeout)
        restartQueue.asyncAfter(deadline: .now() + deadline) { [self] in
            // Ownership check FIRST (Gap 1): `restartingStreams` membership is
            // this chain's ownership token. A sleep that landed during the
            // window cleared the membership *and* already stopped the engine
            // this timeout captured (it was the installed engine at sleep time),
            // then the wake path rebuilt fresh engines. So an orphaned no-frame
            // timeout must just return — NOT stop `engine` again: a second
            // `stop()` would flush the converter tail (Gap 3 hazard) for an
            // engine the sleep already tore down.
            let owned = lock.withLock { restartingStreams.contains(stream) }
            guard owned else { return }

            // Sleep/teardown while still owning membership: release and stop the
            // fresh engine (the wake path rebuilds both engines). `bailIfInactive`
            // clears `awaitingFirstFrame` under the lock *before* we `stop()`, so
            // the flush tail cannot fake-verify recovery.
            if bailIfInactive(stream) {
                runBlocking { await engine.stop() }
                return
            }
            // A frame already verified recovery — nothing to do.
            let stillAwaiting = lock.withLock {
                awaitingFirstFrame.contains(stream)
            }
            guard stillAwaiting else { return }

            // No frame arrived: the restart is dead. Path-free log line.
            log(stream == .system
                ? "system audio restart produced no frames — retrying"
                : "microphone restart produced no frames — retrying")
            // Gap 3 constraint: clear the awaiting/stall state BEFORE `stop()`.
            // `MicCaptureEngine.stop()` flushes the converter and can emit a
            // zero-padded partial *tail* frame through `route()`. If the stream
            // were still `awaitingFirstFrame` when that tail arrived, the tail
            // would win the awaiting→verified transition and announce a recovery
            // for an engine we are killing precisely because it produced no
            // frames — a second silent death mis-reported as a resume. Clearing
            // first means the tail arrives at `route()` after the flag is gone
            // and is treated as an ordinary (dropped/forwarded) frame.
            lock.withLock {
                _ = awaitingFirstFrame.remove(stream)
                stallWallByStream[stream] = nil
            }
            runBlocking { await engine.stop() }
            scheduleRetry(stream: stream, stallWall: stallWall, backoff: backoff)
        }
    }

    /// Frame-verified recovery. Scheduled onto `restartQueue` from `route()`
    /// after the first post-restart frame proved the fresh engine is producing
    /// audio (the `.resumed` marker was already enqueued ahead of that frame).
    /// Emits `recording_resumed` and releases the `restartingStreams`
    /// membership last — so a genuine post-verification stall is caught: the
    /// verified frame reset the engine's watchdog, so a later silence fires
    /// ≥ threshold after that frame, and with the membership now released
    /// `handleStall` proceeds (the recency guard passes, since ≥ threshold has
    /// elapsed since install).
    private func announceRecovery(stream: Stream) {
        // Gap 2: a sleep (or teardown) may have latched between `route()`
        // scheduling this block and it running on `restartQueue`. Both run on
        // the serial `restartQueue`, so if `handleSleep` was scheduled first it
        // has already emitted `recording_paused` (sleep) and cleared the
        // membership. Emitting `recording_resumed` now would order the stream as
        // paused(stall), paused(sleep), resumed(stall_recovery) — a resume while
        // asleep. Invariant #8 requires paused-before-resumed, NOT a resumed for
        // every paused: a stall `recording_paused` with no resumed is correct
        // when recovery never completed. So if paused/stopped, release any
        // membership still held and return WITHOUT emitting or logging.
        let announce = lock.withLock { () -> Bool in
            guard !stopped, !paused else {
                _ = restartingStreams.remove(stream)
                return false
            }
            return true
        }
        guard announce else { return }

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

    /// Streams whose fresh restart engine is installed but has not yet
    /// delivered a frame. Exposed so `StallRecoveryTests` can observe that a
    /// silent restart is held in the awaiting-first-frame state (recovery
    /// unannounced) rather than falsely reported as resumed.
    internal var awaitingFirstFrameForTest: Set<Stream> {
        lock.withLock { awaitingFirstFrame }
    }

    /// Whether capture is currently paused (sleep or a stall in progress).
    /// Exposed so `StallRecoveryTests` can confirm the wake path has completed
    /// (`paused == false`) before probing an orphaned retry's behavior.
    internal var pausedForTest: Bool {
        lock.withLock { paused }
    }

    /// The socket server backing `stream`. Exposed so `StallRecoveryTests` can
    /// attach `onEnqueueForTest` and assert the `.resumed` marker is enqueued
    /// ahead of the first post-recovery frame.
    internal func serverForTest(_ stream: Stream) -> CaptureSocketServer {
        server(for: stream)
    }

    /// Drive the sleep path (`handleSleep`) through the production wiring.
    /// Exposed so `StallRecoveryTests` can verify that a sleep landing during a
    /// stall's awaiting-first-frame window releases the restart membership.
    internal func simulateSleepForTest() {
        handleSleep()
    }

    /// Drive the wake path (`handleWake`) through the production wiring, mirror
    /// of `simulateSleepForTest`. Exposed so `StallRecoveryTests` can drive a
    /// full short sleep→wake cycle and verify that a retry chain orphaned by the
    /// sleep does not install a second engine over the wake-rebuilt one.
    internal func simulateWakeForTest() {
        handleWake()
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

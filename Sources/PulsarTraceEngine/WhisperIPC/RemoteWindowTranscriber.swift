import Foundation
import Logging

/// `WindowTranscribing` driven by an out-of-process `pulsartrace-whisper`
/// subprocess (`docs/specs/2026-05-26-whisper-subprocess-design.md` §6/§7).
///
/// Phase-4 swap-in replacement for the in-process `WhisperTranscriber`.
/// From the engine's POV (the four call sites in
/// `Sources/pulsartrace-engine/main.swift`) it looks identical — same
/// protocol, same `TranscriptionResult` shape, same throws.
///
/// What's different is what happens when a decode wedges. The old
/// `DecodeWatchdog` could only flip an `abort_callback`, which whisper
/// polls between encode/decode-step boundaries; a wedge *inside* a
/// graph compute step (the 2026-05-26 production case) ignored it for
/// 3:36 until the user stopped the recording. This class instead:
///
///   1. Sets a deadline on the IPC read.
///   2. On deadline expiry: SIGKILLs the subprocess (process death is
///      cooperative-free — no graph-compute boundary needed).
///   3. Spawns a fresh subprocess, re-sends `.initSession`.
///   4. Throws `WhisperTranscribeError.transcriptionFailed(-1)` for the
///      wedged window — LocalAgreement-2 upstream catches up on the
///      next window.
///
/// While waiting for the respawn, a backoff `Task` emits a throttled
/// log line (5/10/20/40/… s, capped at 600 s) so the user sees the
/// stall but the engine log isn't flooded.
public final class RemoteWindowTranscriber: WindowTranscribing, @unchecked Sendable {

    public struct Configuration: Sendable {
        public var binaryURL: URL
        public var modelURL: URL
        public var socketDirectory: URL
        public var lockPath: URL?
        public var forceCPU: Bool
        /// Per-decode deadline. Past this, SIGKILL + respawn. Default
        /// 10 s — matches `DecodeWatchdog.deadline` in the live path.
        public var decodeDeadline: Duration
        /// Bound on the parent-side spawn-and-init wait used for a
        /// respawn. Past this we surface a `.modelLoadFailed`-shaped
        /// error so the engine fails cleanly instead of looping.
        public var respawnDeadline: Duration
        /// Spawn handshake deadline for the wrapped host. Plumbs
        /// through to `WhisperSubprocessHost.Configuration`.
        public var spawnTimeout: Duration
        /// Initial backoff between throttled "still waiting for
        /// respawn" log lines. Spec §6: 5 s.
        public var logBackoffInitial: Duration
        /// Cap on the backoff doubling. Spec §6: 600 s.
        public var logBackoffCap: Duration

        public init(
            binaryURL: URL,
            modelURL: URL,
            socketDirectory: URL,
            lockPath: URL? = nil,
            forceCPU: Bool = false,
            decodeDeadline: Duration = .seconds(10),
            // 180 s — see `WhisperSubprocessHost.Configuration.initTimeout`
            // for the rationale; this value is plumbed straight through
            // there. The throttled backoff logger keeps the operator in
            // the loop while we wait (`respawnWithBackoffLog`).
            respawnDeadline: Duration = .seconds(180),
            spawnTimeout: Duration = .seconds(10),
            logBackoffInitial: Duration = .seconds(5),
            logBackoffCap: Duration = .seconds(600)
        ) {
            self.binaryURL = binaryURL
            self.modelURL = modelURL
            self.socketDirectory = socketDirectory
            self.lockPath = lockPath
            self.forceCPU = forceCPU
            self.decodeDeadline = decodeDeadline
            self.respawnDeadline = respawnDeadline
            self.spawnTimeout = spawnTimeout
            self.logBackoffInitial = logBackoffInitial
            self.logBackoffCap = logBackoffCap
        }
    }

    /// Closure used to manufacture a new host. The default returns a
    /// real `WhisperSubprocessHost`; tests pass a closure that returns
    /// a fake conforming to `WhisperHostProtocol` so the deadline /
    /// respawn paths can be exercised without spawning a real binary.
    public typealias HostFactory = @Sendable (
        WhisperSubprocessHost.Configuration, Logger
    ) -> WhisperHostProtocol

    // MARK: - State

    private let configuration: Configuration
    private let logger: Logger
    private let hostFactory: HostFactory

    /// Guards `host`, `shutdown`, and the request-id mint.
    private let lock = NSLock()
    private var host: WhisperHostProtocol?
    private var shutdownLatched = false

    // MARK: - Init

    public init(
        configuration: Configuration,
        logger: Logger = Logger(label: LogSubsystem.engine),
        hostFactory: @escaping HostFactory = { config, logger in
            WhisperSubprocessHost(configuration: config, logger: logger)
        }
    ) {
        self.configuration = configuration
        self.logger = logger
        self.hostFactory = hostFactory
    }

    deinit {
        shutdown()
    }

    // MARK: - WindowTranscribing

    /// Decode one streaming window via the remote whisper.
    ///
    /// `abort` is intentionally **ignored**. Spec §6: process death
    /// replaces the abort token — there is no in-process mechanism for
    /// us to honor, and a caller passing one is preserving the old
    /// `WindowTranscribing` contract without expecting us to wire it
    /// up. We don't log a warning either: the engine will still pass
    /// the token during Phase 4 transition, and a noisy log on every
    /// call would defeat the throttle the rest of this class enforces.
    public func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions,
        abort: AbortToken?
    ) throws -> TranscriptionResult {
        _ = abort
        if samples.isEmpty {
            throw WhisperTranscribeError.emptyAudio
        }

        // Lazy-start the host on first call so a `RemoteWindowTranscriber`
        // constructed at engine boot but never used (e.g. a doctor
        // command that holds a reference) doesn't spawn a subprocess.
        try ensureHostStarted()

        let request = WhisperIPCRequest.decodeWindow(
            WhisperIPCDecodeWindow(
                requestId: UUID(),
                samplesBase64: WhisperIPCSamples.encode(samples),
                windowStartMs: millis(windowStart),
                options: WhisperIPCOptions(from: options)))

        let response: WhisperIPCResponse
        do {
            response = try currentHostOrThrow().decode(
                request, deadline: configuration.decodeDeadline)
        } catch let e as WhisperSubprocessHost.HostError {
            try handleHostError(e)
            // After `handleHostError` returns, the wedged window is
            // discarded and the next window will try again on the
            // fresh host. Spec §6.
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }

        switch response {
        case .decoded(let payload):
            return Self.makeResult(from: payload)
        case .error(let err):
            // Subprocess-reported error: surface as a transcribe error.
            // `transcription_failed` is the kind whisper.cpp's decode
            // failures already use; other kinds map to nearby ones.
            switch err.kind {
            case "model_not_found":
                throw WhisperTranscribeError.modelNotFound(err.message)
            case "model_load_failed":
                throw WhisperTranscribeError.modelLoadFailed(err.message)
            case "empty_audio":
                throw WhisperTranscribeError.emptyAudio
            default:
                // The fallthrough error collapses to `transcriptionFailed(-1)`
                // on the wire, but the subprocess's `kind` + `message`
                // (e.g. `transcription_failed: whisper_full returned -3`
                // or `decode_internal: ...`) is the only thing that
                // identifies the real cause. Log it so a wedge is
                // diagnosable from the engine log alone.
                logger.error("whisper subprocess returned error [\(err.kind)]: \(err.message)")
                throw WhisperTranscribeError.transcriptionFailed(-1)
            }
        case .ready:
            // A `.ready` response to a decode is a protocol bug. The
            // safe action is to discard the host and treat this window
            // as failed.
            logger.error("whisper subprocess returned .ready to a decode")
            sigkillCurrentHost()
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }
    }

    /// Cooperative shutdown — SIGTERM the host with a short grace.
    /// Idempotent: a second call is a no-op.
    public func shutdown() {
        let host = lock.withLock {
            guard !shutdownLatched else { return WhisperHostProtocol?.none }
            shutdownLatched = true
            let h = self.host
            self.host = nil
            return h
        }
        host?.terminate(grace: .seconds(2))
    }

    // MARK: - Host lifecycle

    private func ensureHostStarted() throws {
        let needsStart = lock.withLock {
            if shutdownLatched { return false }
            if let host, host.isAlive { return false }
            return true
        }
        guard needsStart else {
            if lock.withLock({ shutdownLatched }) {
                throw WhisperTranscribeError.transcriptionFailed(-1)
            }
            return
        }
        try startHost()
    }

    private func startHost() throws {
        let hostConfig = WhisperSubprocessHost.Configuration(
            binaryURL: configuration.binaryURL,
            socketDirectory: configuration.socketDirectory,
            lockPath: configuration.lockPath,
            forceCPU: configuration.forceCPU,
            spawnTimeout: configuration.spawnTimeout,
            initTimeout: configuration.respawnDeadline)
        let newHost = hostFactory(hostConfig, logger)
        do {
            try newHost.startAndInitialize(model: configuration.modelURL.path)
        } catch let e as WhisperSubprocessHost.HostError {
            // Non-recoverable from the engine's POV: surface as a
            // model-load failure so the engine fails the run cleanly.
            throw Self.toModelLoadFailed(e)
        } catch {
            throw WhisperTranscribeError.modelLoadFailed("\(error)")
        }
        lock.withLock { self.host = newHost }
    }

    private func currentHostOrThrow() throws -> WhisperHostProtocol {
        guard let h = (lock.withLock { host }) else {
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }
        return h
    }

    private func sigkillCurrentHost() {
        let h = lock.withLock {
            let host = self.host
            self.host = nil
            return host
        }
        h?.sigkill()
    }

    /// React to a host error from `decode`. On a recoverable wedge
    /// (timeout / EOF / writeFailed / subprocessGone) we SIGKILL the
    /// host, spawn a fresh one with throttled-log backoff, and re-Init
    /// — then return normally so the caller can throw the
    /// `transcriptionFailed` for this wedged window. On a
    /// non-recoverable spawn failure during the respawn, we re-throw
    /// as `.modelLoadFailed`.
    private func handleHostError(
        _ error: WhisperSubprocessHost.HostError
    ) throws {
        switch error {
        case .readTimedOut, .readEOF, .writeFailed, .subprocessGone:
            // Interpolate the actual `HostError` variant — the previous
            // hardcoded "exceeded deadline" message claimed a timeout
            // even when the subprocess crashed within seconds of a
            // 120-second budget. The variant identifies whether it
            // was a true deadline (`readTimedOut`), a peer crash
            // (`readEOF` / `subprocessGone`), or a write failure
            // (`writeFailed`). Keeps "exceeded deadline" in the
            // message so existing log-greps still match.
            logger.warning(
                "whisper decode exceeded deadline; killing subprocess for respawn stream=remote (\(error))")
            sigkillCurrentHost()
            try respawnWithBackoffLog()
        case .binaryNotFound, .spawnFailed, .initRefused,
             .handshakeTimedOut, .handshakeMalformed, .connectFailed:
            // We shouldn't see these from a steady-state `decode` (they
            // surface only from `startAndInitialize`). Defensively
            // map to model-load-failed so a buggy subprocess doesn't
            // wedge the engine indefinitely.
            sigkillCurrentHost()
            throw Self.toModelLoadFailed(error)
        }
    }

    /// Spawn a replacement host. While the spawn is in flight, kick
    /// off a `Task` that emits the throttled-backoff log line — if the
    /// respawn finishes quickly (the normal case) the task is
    /// cancelled before the first emission and no extra log appears.
    private func respawnWithBackoffLog() throws {
        var throttle = RespawnLogThrottle(
            initial: configuration.logBackoffInitial,
            cap: configuration.logBackoffCap)
        // Sendable-safe snapshot of values the backoff task needs.
        let log = logger

        // Bound the total respawn wait by `respawnDeadline`; past
        // that we give up and let the engine fail with
        // `.modelLoadFailed`. The backoff task is also bounded by
        // this deadline.
        let respawnStart = ContinuousClock.now
        let respawnDeadline = respawnDeadline_()

        let backoffTask = Task<Void, Never> {
            while !Task.isCancelled {
                let delay = throttle.nextDelay()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                let elapsed = ContinuousClock.now - respawnStart
                log.warning(
                    "still waiting for whisper subprocess respawn (elapsed≈\(secondsString(elapsed))s)")
                if elapsed >= respawnDeadline { return }
            }
        }
        defer { backoffTask.cancel() }

        do {
            try startHost()
        } catch {
            // Log the actual spawn failure before propagating. Without
            // this, the engine sees `streaming window decode failed;
            // skipping window` (caller's catch) with no further
            // context — the live-transcription wedge of 2026-05-27
            // hid every respawn error this way.
            logger.error("whisper subprocess respawn failed: \(error)")
            throw error
        }
    }

    private func respawnDeadline_() -> Duration {
        configuration.respawnDeadline
    }

    /// Convert a host-side error into the `WhisperTranscribeError`
    /// shape the engine surfaces for non-recoverable failures.
    private static func toModelLoadFailed(
        _ e: WhisperSubprocessHost.HostError
    ) -> WhisperTranscribeError {
        switch e {
        case .binaryNotFound(let p):
            return .modelLoadFailed("pulsartrace-whisper not found: \(p)")
        case .spawnFailed(let m):
            return .modelLoadFailed("spawn failed: \(m)")
        case .initRefused(let m):
            return .modelLoadFailed("init refused: \(m)")
        case .handshakeTimedOut:
            return .modelLoadFailed("handshake timed out")
        case .handshakeMalformed(let s):
            return .modelLoadFailed("handshake malformed: \(s)")
        case .connectFailed(let errnoVal):
            return .modelLoadFailed("UDS connect failed: errno \(errnoVal)")
        case .readTimedOut, .readEOF, .writeFailed, .subprocessGone:
            return .modelLoadFailed("subprocess unhealthy: \(e)")
        }
    }

    /// Convert a `WhisperIPCDecoded` payload into the engine's
    /// `TranscriptionResult`. Segment timestamps come back from the
    /// subprocess in *recording-absolute* milliseconds (the
    /// subprocess already added `windowStartMs` to whisper's segment
    /// offsets), so no further shift is needed here.
    static func makeResult(from payload: WhisperIPCDecoded) -> TranscriptionResult {
        let segments = payload.segments.map { seg in
            TranscriptSegment(
                start: .milliseconds(Int(seg.startMs)),
                end: .milliseconds(Int(seg.endMs)),
                text: seg.text)
        }
        return TranscriptionResult(
            segments: segments,
            language: payload.language)
    }
}

// MARK: - Helpers

private func millis(_ d: Duration) -> Int64 {
    let parts = d.components
    let secMs = parts.seconds &* 1000
    let attoMs = parts.attoseconds / 1_000_000_000_000_000
    return secMs &+ attoMs
}

private func secondsString(_ d: Duration) -> String {
    let parts = d.components
    return "\(parts.seconds)"
}

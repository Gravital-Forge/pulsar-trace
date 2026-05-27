import Foundation
import Logging

/// `RegionTranscribing` driven by an out-of-process `pulsartrace-whisper`
/// subprocess (`docs/specs/2026-05-26-whisper-subprocess-design.md` §6/§7).
///
/// Phase-5 swap-in replacement for the in-process `WhisperTranscriber` at
/// the refinement queue's per-job factory (see
/// `RefinementJobQueue.makeStandard`). From `ResumableRefiner`'s POV it
/// looks identical — same protocol, same `TranscriptionResult` shape,
/// same throws.
///
/// Differences from the in-process path land where a region decode
/// wedges. The old in-process refinement could only abort cooperatively;
/// a `whisper_full` stuck inside a graph-compute step would block the
/// whole refinement worker until the user killed the app (the 2026-05-26
/// production case for live, identical mechanism for refinement). This
/// class instead:
///
///   1. Sets a deadline on the IPC read.
///   2. On deadline expiry: SIGKILLs the subprocess (process death is
///      cooperative-free — no graph-compute boundary needed).
///   3. Spawns a fresh subprocess, re-sends `.initSession`.
///   4. Throws `WhisperTranscribeError.transcriptionFailed(-1)` for the
///      wedged region — `ResumableRefiner`'s checkpoint logic upstream
///      means the next attempt resumes from the previous good region.
///
/// While waiting for the respawn, a backoff `Task` emits a throttled
/// log line (5/10/20/40/… s, capped at 600 s) so the user sees the
/// stall but the engine log isn't flooded.
///
/// **Deadline.** Refinement regions can be much longer than the live
/// path's 8s windows (VAD typically yields 5-30s regions), and the
/// refinement model is `large-v3`, which is substantially slower than
/// `base`. A 30s region on Apple Silicon CPU can realistically take
/// 10-20s; spec §6 leaves the exact value open ("longer deadline; tune
/// by measurement"). Default 120s — generous enough to cover
/// pathological-but-not-wedged decodes without driving false-positive
/// SIGKILLs.
public final class RemoteRegionTranscriber: RegionTranscribing, @unchecked Sendable {

    public struct Configuration: Sendable {
        public var binaryURL: URL
        public var modelURL: URL
        public var socketDirectory: URL
        public var forceCPU: Bool
        /// Per-region decode deadline. Past this, SIGKILL + respawn.
        /// Default 120 s — see class-doc rationale. Spec §6 leaves the
        /// exact value open; tune by measurement.
        public var decodeDeadline: Duration
        /// Bound on the parent-side spawn-and-init wait used for a
        /// respawn. Past this we surface a `.modelLoadFailed`-shaped
        /// error so the refinement job fails cleanly instead of looping.
        public var respawnDeadline: Duration
        /// Initial backoff between throttled "still waiting for
        /// respawn" log lines. Spec §6: 5 s.
        public var logBackoffInitial: Duration
        /// Cap on the backoff doubling. Spec §6: 600 s.
        public var logBackoffCap: Duration

        public init(
            binaryURL: URL,
            modelURL: URL,
            socketDirectory: URL,
            forceCPU: Bool = !WhisperOptions.defaultGPUEnabled,
            decodeDeadline: Duration = .seconds(120),
            respawnDeadline: Duration = .seconds(60),
            logBackoffInitial: Duration = .seconds(5),
            logBackoffCap: Duration = .seconds(600)
        ) {
            self.binaryURL = binaryURL
            self.modelURL = modelURL
            self.socketDirectory = socketDirectory
            self.forceCPU = forceCPU
            self.decodeDeadline = decodeDeadline
            self.respawnDeadline = respawnDeadline
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

    /// Guards `host` and `shutdownLatched`.
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

    // MARK: - RegionTranscribing

    /// Decode one VAD region via the remote whisper.
    public func transcribeRegion(
        _ samples: [Float],
        region: SpeechRegion,
        options: WhisperOptions
    ) throws -> TranscriptionResult {
        if samples.isEmpty {
            throw WhisperTranscribeError.emptyAudio
        }

        // Lazy-start the host on first call so a `RemoteRegionTranscriber`
        // constructed at queue-job boot but never reached (e.g. a job
        // cancelled before any region runs) doesn't spawn a subprocess.
        try ensureHostStarted()

        let request = WhisperIPCRequest.decodeRegion(
            WhisperIPCDecodeRegion(
                requestId: UUID(),
                samplesBase64: WhisperIPCSamples.encode(samples),
                regionStartMs: millis(region.start),
                regionEndMs: millis(region.end),
                options: WhisperIPCOptions(from: options)))

        let response: WhisperIPCResponse
        do {
            response = try currentHostOrThrow().decode(
                request, deadline: configuration.decodeDeadline)
        } catch let e as WhisperSubprocessHost.HostError {
            try handleHostError(e)
            // After `handleHostError` returns, the wedged region is
            // discarded and `ResumableRefiner` upstream will surface
            // this throw. Spec §6: "killed region just resumes from the
            // previous checkpoint."
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }

        switch response {
        case .decoded(let payload):
            // Segment timestamps come back from the subprocess in
            // *recording-absolute* milliseconds (the subprocess applied
            // the regionStartMs shift internally — same contract as
            // the in-process `WhisperTranscriber.transcribeRegion`),
            // so no further shift is needed here.
            return Self.makeResult(from: payload)
        case .error(let err):
            // Subprocess-reported error: surface as a transcribe error.
            switch err.kind {
            case "model_not_found":
                throw WhisperTranscribeError.modelNotFound(err.message)
            case "model_load_failed":
                throw WhisperTranscribeError.modelLoadFailed(err.message)
            case "empty_audio":
                throw WhisperTranscribeError.emptyAudio
            default:
                throw WhisperTranscribeError.transcriptionFailed(-1)
            }
        case .ready:
            // A `.ready` response to a decode is a protocol bug. The
            // safe action is to discard the host and treat this region
            // as failed.
            logger.error("whisper subprocess returned .ready to a region decode")
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
            lockPath: nil,
            forceCPU: configuration.forceCPU,
            spawnTimeout: .seconds(10),
            initTimeout: configuration.respawnDeadline)
        let newHost = hostFactory(hostConfig, logger)
        do {
            try newHost.startAndInitialize(model: configuration.modelURL.path)
        } catch let e as WhisperSubprocessHost.HostError {
            // Non-recoverable from the refinement queue's POV: surface
            // as a model-load failure so the job fails cleanly.
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
    /// `transcriptionFailed` for this wedged region. On a
    /// non-recoverable spawn failure during the respawn, we re-throw
    /// as `.modelLoadFailed`.
    private func handleHostError(
        _ error: WhisperSubprocessHost.HostError
    ) throws {
        switch error {
        case .readTimedOut, .readEOF, .writeFailed, .subprocessGone:
            // Refinement-specific wording so log greps disambiguate
            // refinement from live. No request-id plumbed through —
            // not easily available at this layer and the request UUID
            // is meaningful only between client and subprocess.
            logger.warning(
                "whisper region decode exceeded deadline; killing subprocess for respawn")
            sigkillCurrentHost()
            try respawnWithBackoffLog()
        case .binaryNotFound, .spawnFailed, .initRefused,
             .handshakeTimedOut, .handshakeMalformed, .connectFailed:
            // We shouldn't see these from a steady-state `decode` (they
            // surface only from `startAndInitialize`). Defensively
            // map to model-load-failed so a buggy subprocess doesn't
            // wedge the refiner indefinitely.
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
        // that we give up and let the refinement fail with
        // `.modelLoadFailed`. The backoff task is also bounded by
        // this deadline.
        let respawnStart = ContinuousClock.now
        let respawnDeadline = configuration.respawnDeadline

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
            // Surface model-load-failed; the refinement job logs and
            // exits, leaving `ResumableRefiner` to surface the failure.
            throw error
        }
    }

    /// Convert a host-side error into the `WhisperTranscribeError`
    /// shape the refiner surfaces for non-recoverable failures.
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
    /// `TranscriptionResult`. The subprocess returns
    /// recording-absolute segment timestamps, so we just pass them
    /// through.
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

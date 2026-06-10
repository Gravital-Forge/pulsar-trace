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
            // 180 s — see `WhisperSubprocessHost.Configuration.initTimeout`
            // for the rationale; plumbed straight through there.
            respawnDeadline: Duration = .seconds(180),
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
    /// Owns the host + every lifecycle policy (lazy start, deadline
    /// kill, respawn with throttled backoff, latched shutdown). See
    /// `RemoteTranscriberCore`.
    private let core: RemoteTranscriberCore

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
        self.core = RemoteTranscriberCore(
            policy: RemoteTranscriberCore.Policy(
                hostConfiguration: WhisperSubprocessHost.Configuration(
                    binaryURL: configuration.binaryURL,
                    socketDirectory: configuration.socketDirectory,
                    lockPath: nil,
                    forceCPU: configuration.forceCPU,
                    spawnTimeout: .seconds(10),
                    initTimeout: configuration.respawnDeadline),
                modelPath: configuration.modelURL.path,
                respawnDeadline: configuration.respawnDeadline,
                logBackoffInitial: configuration.logBackoffInitial,
                logBackoffCap: configuration.logBackoffCap,
                // Refinement-specific wording so log greps disambiguate
                // refinement from live.
                deadlineKillMessage:
                    "whisper region decode exceeded deadline; killing subprocess for respawn"),
            logger: logger,
            hostFactory: hostFactory)
    }

    deinit {
        core.shutdown()
    }

    // MARK: - RegionTranscribing

    /// Decode one VAD region via the remote whisper.
    ///
    /// `samples` is the *whole* recording, the same shape the in-process
    /// `WhisperTranscriber.transcribeRegion` accepts. The slice is taken
    /// here and only the slice goes over the wire — passing the whole
    /// buffer would make every region's IPC frame O(recording duration),
    /// which on a long meeting blows past the frame ceiling and surfaces
    /// as "frame payload exceeds maximum" (2026-05-28 incident).
    public func transcribeRegion(
        _ samples: [Float],
        region: SpeechRegion,
        options: WhisperOptions
    ) throws -> TranscriptionResult {
        if samples.isEmpty {
            throw WhisperTranscribeError.emptyAudio
        }

        let lo = Self.sampleIndex(of: region.start, sampleCount: samples.count)
        let hi = Self.sampleIndex(of: region.end, sampleCount: samples.count)
        guard lo < hi else {
            // Region falls outside the buffer — match the in-process
            // contract (empty result, no host spawned).
            return TranscriptionResult(segments: [], language: "unknown")
        }
        let slice = Array(samples[lo..<hi])
        let sliceDurationMs = Int64(lo.distance(to: hi) * 1000 / AudioFormat.sampleRate)

        // Lazy-start the host on first call so a `RemoteRegionTranscriber`
        // constructed at queue-job boot but never reached (e.g. a job
        // cancelled before any region runs) doesn't spawn a subprocess.
        try core.ensureHostStarted()

        // Wire format: the subprocess only sees [0..sliceDurationMs)
        // because that's all we sent. The recording-absolute shift is
        // applied below, on this side, after the response comes back.
        let request = WhisperIPCRequest.decodeRegion(
            WhisperIPCDecodeRegion(
                requestId: UUID(),
                samplesBase64: WhisperIPCSamples.encode(slice),
                regionStartMs: 0,
                regionEndMs: sliceDurationMs,
                options: WhisperIPCOptions(from: options)))

        let response: WhisperIPCResponse
        do {
            response = try core.currentHostOrThrow().decode(
                request, deadline: configuration.decodeDeadline)
        } catch let e as WhisperSubprocessHost.HostError {
            try core.handleHostError(e)
            // After `handleHostError` returns, the wedged region is
            // discarded and `ResumableRefiner` upstream will surface
            // this throw. Spec §6: "killed region just resumes from the
            // previous checkpoint."
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }

        switch response {
        case .decoded(let payload):
            // Subprocess sees regionStartMs=0 → returns region-relative
            // segment times. Shift them back onto the recording
            // timeline by the *original* region.start so callers see
            // the same recording-absolute timestamps the in-process
            // `WhisperTranscriber.transcribeRegion` produces.
            return Self.makeResult(from: payload, shiftedBy: region.start)
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
                // The fallthrough error collapses to `transcriptionFailed(-1)`
                // on the wire, but the subprocess's `kind` + `message`
                // is the only thing that identifies the real cause.
                // Log it so a wedged region is diagnosable from the
                // operational log alone (mac-app refinement: see
                // `LogSystem.bootstrap` wired into `PulsarTraceMacApp`).
                logger.error("whisper subprocess returned error [\(err.kind)]: \(err.message)")
                throw WhisperTranscribeError.transcriptionFailed(-1)
            }
        case .ready:
            // A `.ready` response to a decode is a protocol bug. The
            // safe action is to discard the host and treat this region
            // as failed.
            logger.error("whisper subprocess returned .ready to a region decode")
            core.sigkillCurrentHost()
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }
    }

    /// Cooperative shutdown — SIGTERM the host with a short grace.
    /// Idempotent: a second call is a no-op.
    public func shutdown() {
        core.shutdown()
    }

    /// Convert a `WhisperIPCDecoded` payload into the engine's
    /// `TranscriptionResult`, shifting region-relative segment times by
    /// `shiftedBy` so callers see recording-absolute timestamps.
    static func makeResult(
        from payload: WhisperIPCDecoded,
        shiftedBy shift: Duration
    ) -> TranscriptionResult {
        let segments = payload.segments.map { seg in
            TranscriptSegment(
                start: .milliseconds(Int(seg.startMs)) + shift,
                end: .milliseconds(Int(seg.endMs)) + shift,
                text: seg.text)
        }
        return TranscriptionResult(
            segments: segments,
            language: payload.language)
    }

    /// Clamp a recording-relative time to a valid sample index in
    /// `[0, count]`. Same contract as
    /// `WhisperTranscriber.sampleIndex`, kept private to this file so
    /// the two implementations stay independent.
    private static func sampleIndex(
        of time: Duration, sampleCount: Int
    ) -> Int {
        let idx = Int((time.seconds * Double(AudioFormat.sampleRate)).rounded())
        return min(max(idx, 0), sampleCount)
    }
}

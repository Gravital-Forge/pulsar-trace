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
/// **Chunking.** The wire format is one length-prefixed JSON frame per
/// request, capped at `WhisperFrameCodec.maxPayloadBytes` (8 MiB). A
/// long continuous-speech region overflows it: the 2026-06-05
/// production failure was a single 125.9 s VAD region whose request
/// frame came to 10.75 MB, so the codec refused the write, the failure
/// was misread as a wedged decode (SIGKILL + respawn), and the
/// refinement job re-failed deterministically on every retry of the
/// identical region. `transcribeRegion` therefore splits any slice
/// longer than `maxChunkSamples` (~97.5 s) into near-equal chunks —
/// boundaries snapped to the quietest nearby audio so a forced cut
/// lands on a pause — decodes them sequentially through the same
/// error machinery, and merges the results.
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

    // MARK: - Chunk sizing

    /// Hard ceiling on samples per `decodeRegion` request, derived
    /// from the IPC frame cap: base64 inflates the raw Float32 bytes
    /// by 4/3 and the JSON envelope (request id, bounds, options)
    /// needs headroom.
    /// (8 MiB − 64 KiB) × 3/4 ÷ 4 = 1_560_576 samples ≈ 97.5 s at 16 kHz.
    static let maxChunkSamples: Int =
        (WhisperFrameCodec.maxPayloadBytes - envelopeAllowanceBytes) * 3 / 4
            / MemoryLayout<Float>.size

    private static let envelopeAllowanceBytes = 64 * 1024

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
                    // Deliberately not a Configuration field (unlike the
                    // window transcriber's): refinement always uses the
                    // spawn-handshake default. Surface it only when a
                    // caller actually needs to tune it.
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

        // Lazy-start the host on first call so a `RemoteRegionTranscriber`
        // constructed at queue-job boot but never reached (e.g. a job
        // cancelled before any region runs) doesn't spawn a subprocess.
        try core.ensureHostStarted()

        // A slice longer than `maxChunkSamples` cannot fit in one IPC
        // frame; send it as near-equal chunks instead (single range for
        // the common short region — identical request shape to before).
        // Any chunk failure fails the whole region with the same error
        // the unchunked path threw; no partial results.
        var mergedSegments: [TranscriptSegment] = []
        var firstLanguage: String?
        var pickedLanguage: String?

        for r in Self.chunkRanges(for: slice, maxChunk: Self.maxChunkSamples) {
            // Wire format: the subprocess only sees [0..chunkDurationMs)
            // because that's all we sent. The recording-absolute shift
            // is applied below, on this side, after the response comes
            // back.
            let request = WhisperIPCRequest.decodeRegion(
                WhisperIPCDecodeRegion(
                    requestId: UUID(),
                    samplesBase64: WhisperIPCSamples.encode(Array(slice[r])),
                    regionStartMs: 0,
                    regionEndMs: Int64(r.count * 1000 / AudioFormat.sampleRate),
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
                // Subprocess sees regionStartMs=0 → returns chunk-relative
                // segment times. Shift them back onto the recording
                // timeline by the *original* region.start plus this
                // chunk's offset into the slice, so callers see the same
                // recording-absolute timestamps the in-process
                // `WhisperTranscriber.transcribeRegion` produces.
                let shift = region.start + .milliseconds(
                    Int64(r.lowerBound) * 1000 / Int64(AudioFormat.sampleRate))
                mergedSegments.append(
                    contentsOf: Self.makeResult(from: payload, shiftedBy: shift)
                        .segments)
                if firstLanguage == nil {
                    firstLanguage = payload.language
                }
                if pickedLanguage == nil,
                   !payload.language.isEmpty, payload.language != "unknown" {
                    pickedLanguage = payload.language
                }
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

        // Language: the first chunk that committed to a real language
        // wins; otherwise fall back to whatever the first chunk said.
        // (`slice` is non-empty, so there is always at least one chunk.)
        return TranscriptionResult(
            segments: mergedSegments,
            language: pickedLanguage ?? firstLanguage ?? "unknown")
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

    // MARK: - Chunk-range computation

    /// Snap search radius around each equal-split boundary: ±5 s.
    private static let snapRadiusSamples = 5 * AudioFormat.sampleRate
    /// Snap candidate stride: 10 ms.
    private static let snapStepSamples = AudioFormat.sampleRate / 100
    /// Energy window evaluated per candidate: 100 ms, centered.
    private static let snapWindowSamples = AudioFormat.sampleRate / 10

    /// Split `count` samples into near-equal consecutive ranges, each
    /// at most `maxChunk` long. Interior boundaries are snapped to the
    /// quietest 100 ms window within ±5 s of the equal-split point so
    /// a forced cut lands on a pause instead of mid-word. If snapping
    /// would push any chunk past `maxChunk`, fall back to the plain
    /// equal split (correctness over cut quality). The returned ranges
    /// exactly tile `0..<samples.count` — contiguous, no gaps or
    /// overlaps.
    static func chunkRanges(
        for samples: [Float], maxChunk: Int
    ) -> [Range<Int>] {
        precondition(maxChunk > 0, "maxChunk must be positive")
        let n = samples.count
        if n <= maxChunk { return [0..<n] }

        // Integer math throughout — same input, same split, always.
        let numChunks = (n + maxChunk - 1) / maxChunk
        let equalBoundaries = (1..<numChunks).map { $0 * n / numChunks }

        var snapped: [Int] = []
        var previous = 0
        for b in equalBoundaries {
            let lower = max(b - snapRadiusSamples, previous + 1)
            let upper = min(b + snapRadiusSamples, n - 1)
            var bestIndex = b
            var bestEnergy = Double.infinity
            var candidate = lower
            while candidate <= upper {
                let energy = Self.windowEnergy(
                    samples, centeredOn: candidate)
                // Strict `<`: ties resolve to the lowest index.
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestIndex = candidate
                }
                candidate += snapStepSamples
            }
            snapped.append(bestIndex)
            previous = bestIndex
        }

        // Snapping can stretch a neighbor past `maxChunk`; the equal
        // split satisfies the bound by construction, so prefer it over
        // a nicer cut that would re-break the frame cap.
        let snappedRanges = Self.ranges(from: snapped, total: n)
        let valid = snappedRanges.allSatisfy {
            (1...maxChunk).contains($0.count)
        }
        if valid { return snappedRanges }
        return Self.ranges(from: equalBoundaries, total: n)
    }

    /// Sum of squares over the 100 ms window centered on `center`,
    /// clamped to the array bounds.
    private static func windowEnergy(
        _ samples: [Float], centeredOn center: Int
    ) -> Double {
        let half = snapWindowSamples / 2
        let lo = max(center - half, 0)
        let hi = min(center + half, samples.count)
        var sum = 0.0
        for i in lo..<hi {
            let s = Double(samples[i])
            sum += s * s
        }
        return sum
    }

    /// Turn interior boundary indices into consecutive ranges tiling
    /// `0..<total`.
    private static func ranges(
        from boundaries: [Int], total: Int
    ) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for b in boundaries {
            out.append(start..<b)
            start = b
        }
        out.append(start..<total)
        return out
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

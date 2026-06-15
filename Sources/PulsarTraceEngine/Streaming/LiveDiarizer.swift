import Foundation
import Logging

/// One provisional speaker turn from the live pass: a stitched stable label
/// active over a recording-absolute span, plus the embedding behind it (so the
/// speaker-library lookup can put a name to it).
public struct LiveSpeakerSpan: Sendable, Equatable {
    /// Stable provisional speaker key for this recording — `Them`, `Them #2`,
    /// … Stitched across windows by `LiveDiarizer` (the raw per-window
    /// labels are not stable, so they are not exposed).
    public let provisionalKey: String
    /// Recording-absolute start.
    public let start: Duration
    /// Recording-absolute end.
    public let end: Duration
    /// The speaker embedding for this window's speaker (256-d, WeSpeaker
    /// space — R29). Empty if the window produced none.
    public let embedding: [Float]

    public init(
        provisionalKey: String,
        start: Duration,
        end: Duration,
        embedding: [Float]
    ) {
        self.provisionalKey = provisionalKey
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

/// The narrow seam `LiveRunner` drives live diarization through.
///
/// `LiveDiarizer` is the production conformer (windowed in-process diarization
/// on the ANE). The protocol exists so the run loop can be exercised against a
/// **stub** — in particular one whose `diarizeWindow` hangs — to prove the
/// resilience invariant that a wedged diarizer never stalls transcription or
/// `live.md` (the diarizer runs off the run loop's critical path).
///
/// Every member is `async` so a conformer may be an `actor`.
protocol LiveDiarizing: Sendable {
    /// Diarize one window of recent system-stream audio; `windowStart` is the
    /// window's recording-absolute offset. A hiccup yields `[]`.
    func diarizeWindow(
        samples: [Float], windowStart: Duration
    ) async -> [LiveSpeakerSpan]
    /// Live-speaker centroids keyed by provisional key (R18 library lookup).
    func centroids() async -> [String: [Float]]
    /// The diarization model's content digest (R18 revision scoping).
    func modelRevision() async -> String
}

/// Live (streaming) speaker diarization for the system stream (R15, R16).
///
/// ## Windowed in-process diarization (D40)
///
/// The retired design ran windowed-pyannote in a long-lived Python subprocess
/// (D19). The window geometry survives — `StreamingPipeline` hands this actor
/// a ~10 s window of recent system audio every ~5 s — but each window now runs
/// FluidAudio's offline pipeline (`DiarizerEngine`) in-process on the ANE.
/// Same embedding space as the offline post-pass and the speaker library
/// (R29), no subprocess, no scratch WAVs.
///
/// ## Provisional label stitching
///
/// Per-window labels (`S1`, `S2`, …) are **not stable** across windows.
/// `LiveDiarizer` stitches them into stable per-recording keys (`Them`,
/// `Them #2`, …) by matching each window-speaker's embedding against the
/// running set of live speakers' centroids by cosine similarity. A new voice
/// that matches nothing gets a fresh `Them #N`. This is **best-effort**; the
/// post-pass is the source of truth (R16).
///
/// An `actor`: it owns the running live-speaker set, mutable state not safe
/// to touch concurrently.
public actor LiveDiarizer: LiveDiarizing {

    /// Tunables. The engine (model residency) is injected, not configured —
    /// `pulsartrace-engine` loads it once per process next to Parakeet.
    public struct Configuration: Sendable {
        /// Per-window decode ceiling. A window that overruns this is given up
        /// on (the live pass stays provisional anyway).
        public let windowTimeout: Duration

        public init(windowTimeout: Duration = .seconds(30)) {
            self.windowTimeout = windowTimeout
        }
    }

    /// Cosine-similarity threshold for stitching a window-speaker to an
    /// existing live speaker. Above → same speaker; below → a new `Them #N`.
    /// Calibrated for the WeSpeaker embedding space (D40): on the committed
    /// fixtures, same-speaker cosine measured ~0.93, cross-speaker ~0.35
    /// (see the DiarizationE2E calibration suite).
    public static let stitchThreshold = 0.45

    /// Segments shorter than this carry unreliable WeSpeaker embeddings — the
    /// segmentation tail sub-windows. Measured in the D40 spike: a ~2 s
    /// segment's cosine to the *same* speaker can fall to ~0. Such segments are
    /// labelled by a read-only nearest match but never create a speaker or
    /// refine a centroid, so they cannot spawn ghosts or poison the bank.
    public static let minReliableSegment: Duration = .seconds(2)

    /// Test-only: a diarizer with no engine — `diarizeWindow` returns `[]`;
    /// `_seedForTesting` + `centroids()`/`modelRevision()` only.
    init(testSeamLogger logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.engine = nil
        self.configuration = .init()
        self.logger = logger
    }

    private let engine: DiarizerEngine?
    private let configuration: Configuration
    private let logger: Logger
    private var windowCounter = 0

    /// Running set of live speakers, one centroid per stitched provisional key.
    private struct LiveSpeaker {
        let key: String
        var centroid: [Float]
        var appearances: Int
    }
    private var liveSpeakers: [LiveSpeaker] = []
    private var seededModelRevision: String?

    public init(
        engine: DiarizerEngine,
        configuration: Configuration = .init(),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.engine = engine
        self.configuration = configuration
        self.logger = logger
    }

    /// Diarize one window of recent system-stream audio.
    ///
    /// `windowStart` is the window's offset from the start of the recording;
    /// returned spans are recording-absolute. A failure or timeout yields `[]`
    /// (the live pass degrades, never crashes).
    public func diarizeWindow(
        samples: [Float],
        windowStart: Duration
    ) async -> [LiveSpeakerSpan] {
        guard let engine else { return [] }
        let started = ContinuousClock.now
        windowCounter += 1

        let work = Task { try await engine.diarizeWindowSegments(samples: samples) }
        let segments = await withTaskGroup(
            of: [DiarizerEngine.WindowSegmentEmbedding]?.self
        ) { group -> [DiarizerEngine.WindowSegmentEmbedding]? in
            group.addTask { try? await work.value }
            group.addTask { [windowTimeout = configuration.windowTimeout] in
                try? await Task.sleep(for: windowTimeout)
                work.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let segments else {
            logger.warning("live diarization: window produced no usable result")
            return []
        }

        let spans = stitch(segments: segments, windowStart: windowStart)
        let roundTripMS = Int(((ContinuousClock.now - started).seconds * 1000)
            .rounded())
        // `.debug`: one line per window (~every 5 s) — a performance observable.
        logger.debug("""
            live diarization: window \(windowCounter) done — \
            \(roundTripMS) ms on ANE, \(spans.count) span(s)
            """)
        return spans
    }

    // MARK: - Stitching

    /// Turn one window's per-segment embeddings into stable-keyed,
    /// recording-absolute `LiveSpeakerSpan`s. Segments at least
    /// `minReliableSegment` long drive the bank (match-or-create + refine);
    /// shorter ones are labelled by a read-only nearest match and dropped when
    /// they match nothing — they never create a speaker or update a centroid
    /// (D40 spike: short-segment embeddings are noisy). `internal` so the
    /// stitch logic is unit-testable without CoreML models.
    func stitch(
        segments: [DiarizerEngine.WindowSegmentEmbedding],
        windowStart: Duration
    ) -> [LiveSpeakerSpan] {
        var out: [LiveSpeakerSpan] = []
        for segment in segments {
            guard !segment.vector.isEmpty else { continue }
            let key: String?
            if (segment.end - segment.start) >= Self.minReliableSegment {
                key = stitchKey(for: segment.vector)        // match-or-create + refine
            } else {
                key = nearestKey(for: segment.vector)       // read-only; may be nil
            }
            guard let key else { continue }
            out.append(LiveSpeakerSpan(
                provisionalKey: key,
                start: windowStart + segment.start,
                end: windowStart + segment.end,
                embedding: segment.vector))
        }
        return out
    }

    /// Match an embedding to an existing live speaker (cosine ≥ threshold),
    /// refining its centroid; or create a fresh `Them #N`.
    private func stitchKey(for embedding: [Float]) -> String {
        guard !embedding.isEmpty else {
            return fallbackKey(forRawLabel: "noembed")
        }
        var bestIndex = -1
        var bestScore = Self.stitchThreshold
        for (i, speaker) in liveSpeakers.enumerated() {
            let score = Centroid.cosineSimilarity(speaker.centroid, embedding)
            if score >= bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        if bestIndex >= 0 {
            // Returning live speaker: refine the centroid (running mean).
            let s = liveSpeakers[bestIndex]
            liveSpeakers[bestIndex].centroid = Centroid.runningMean(
                existing: s.centroid,
                appearanceCount: s.appearances,
                appearance: embedding)
            liveSpeakers[bestIndex].appearances += 1
            return s.key
        }
        // A new voice.
        let key = Self.provisionalKey(index: liveSpeakers.count)
        liveSpeakers.append(LiveSpeaker(
            key: key, centroid: embedding, appearances: 1))
        return key
    }

    /// Best existing live speaker for an embedding (cosine ≥ threshold), or
    /// `nil`. Read-only — never creates a speaker or refines a centroid. Used
    /// to label sub-`minReliableSegment` segments without letting their noisy
    /// embeddings spawn ghosts or poison the bank.
    private func nearestKey(for embedding: [Float]) -> String? {
        var bestIndex = -1
        var bestScore = Self.stitchThreshold
        for (i, speaker) in liveSpeakers.enumerated() {
            let score = Centroid.cosineSimilarity(speaker.centroid, embedding)
            if score >= bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex >= 0 ? liveSpeakers[bestIndex].key : nil
    }

    /// Fallback key for a raw label with no embedding — keep it stable per
    /// raw label so the same window-speaker maps consistently.
    private var fallbackByRaw: [String: String] = [:]
    private func fallbackKey(forRawLabel raw: String) -> String {
        if let existing = fallbackByRaw[raw] { return existing }
        let key = Self.provisionalKey(index: liveSpeakers.count
            + fallbackByRaw.count)
        fallbackByRaw[raw] = key
        return key
    }

    /// The Nth provisional speaker key: `Them`, `Them #2`, `Them #3`, …
    /// (R16 — the `?` suffix is added by `LiveRunner.resolveSystemLabel`).
    public static func provisionalKey(index: Int) -> String {
        index == 0 ? "Them" : "Them #\(index + 1)"
    }

    /// The live-speaker centroids, for a read-only speaker-library lookup
    /// (R18) — keyed by provisional key.
    public func centroids() -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for s in liveSpeakers { out[s.key] = s.centroid }
        return out
    }

    /// The diarization model's content digest. The R18 speaker-library lookup
    /// keys centroid compatibility on this — `bestMatch` skips speakers
    /// recorded under a different revision. An empty revision (no engine)
    /// matches nothing in a populated library — safe degradation.
    public func modelRevision() -> String {
        seededModelRevision ?? engine?.modelRevision ?? ""
    }

    /// Test seam: pre-seed the running live-speaker set and the model
    /// revision, so the R18 lookup can be exercised without real models.
    func _seedForTesting(
        speakers: [(key: String, centroid: [Float])],
        modelRevision: String
    ) {
        liveSpeakers = speakers.map {
            LiveSpeaker(key: $0.key, centroid: $0.centroid, appearances: 1)
        }
        seededModelRevision = modelRevision
    }
}

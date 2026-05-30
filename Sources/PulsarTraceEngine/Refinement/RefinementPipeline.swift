import Foundation
import Logging

/// The full offline refinement pass behind `pulsartrace refine` (the
/// v0.1 ship point): an audio file (or recording folder) →
/// whisper transcription → pyannote diarization → reconciled, speaker-labelled
/// `final.md` + `metadata.json`.
///
/// Pipeline stages (R20, R21, R24, R38, R39):
/// 1. Resolve the input into a `RecordingFolder` (bare-WAV vs folder dispatch).
/// 2. Transcribe the system stream with whisper (R20).
/// 3. Diarize the system stream with pyannote (R21) — `Speaker_N` labels.
/// 4. If a mic stream exists, transcribe it too; its utterances are `You`,
///    never diarized (R17). Merge the two streams by timestamp.
/// 5. Render `final.md` with the `<!-- pulsartrace:final -->` marker (R38),
///    written atomically (R24); back up any prior `live.md` / `final.md`.
/// 6. Write the `metadata.json` sidecar (R39).
///
/// Events are emitted in causal order (Hard Invariant #8): `refinement_started`
/// first, the file event after the file is durably on disk, `refinement_completed`
/// last; any failure emits `refinement_failed`.
///
/// Progress (R26): a lightweight `ProgressReporter` closure receives stage
/// updates; the CLI prints them to stderr. The menubar consuming progress over
/// `control.sock` is a future addition — not built here.
public struct RefinementPipeline: Sendable {

    /// A coarse pipeline stage, for progress reporting (R26).
    public enum Stage: String, Sendable {
        case resolvingInput = "resolving input"
        case transcribingSystem = "transcribing system audio"
        case transcribingMic = "transcribing microphone audio"
        case diarizing = "diarizing speakers"
        case merging = "merging transcript and speakers"
        case writingFinal = "writing final.md"
        case writingMetadata = "writing metadata.json"
        case done = "done"
    }

    /// Progress sink. Called on the pipeline's task; keep it cheap.
    public typealias ProgressReporter = @Sendable (Stage) -> Void

    /// Errors the refine pass surfaces. `errorClass` feeds `refinement_failed`.
    public enum RefineError: Error, CustomStringConvertible {
        case input(RecordingFolder.InputError)
        case transcription(Error)
        case diarization(Error)
        case io(Error)

        /// Coarse, stable category for the `refinement_failed` event.
        public var errorClass: String {
            switch self {
            case .input: return "input"
            case .transcription: return "transcription"
            case .diarization: return "diarization"
            case .io: return "io"
            }
        }

        /// Whether re-running `refine` could plausibly succeed.
        public var retryAvailable: Bool {
            switch self {
            case .input: return false           // bad path won't fix itself
            case .transcription, .diarization, .io: return true
            }
        }

        public var description: String {
            switch self {
            case .input(let e): return e.description
            case .transcription(let e): return "transcription failed: \(e)"
            case .diarization(let e): return "diarization failed: \(e)"
            case .io(let e): return "file write failed: \(e)"
            }
        }

        /// A path-free message safe for the operational log (Hard Invariant #7:
        /// no full user file paths in `~/Library/Logs/PulsarTrace/`).
        ///
        /// `description` (and the underlying `CocoaError` / whisper errors it
        /// wraps) can embed full Foundation paths — `.io` and
        /// `.transcription(.modelNotFound/.modelLoadFailed)` in particular.
        /// This collapses each case to its category plus, where available, a
        /// path-stripped error code/domain. The full detail still reaches
        /// stderr via `RefineCommand` — fine for a CLI; only the operational
        /// log must be sanitized.
        public var safeLogMessage: String {
            switch self {
            case .input:
                return "input error"
            case .transcription(let e):
                return "transcription failed (\(Self.safeCause(e)))"
            case .diarization(let e):
                return "diarization failed (\(Self.safeCause(e)))"
            case .io(let e):
                return "file write failed (\(Self.safeCause(e)))"
            }
        }

        /// A path-free identifier for an underlying error: an `NSError`
        /// `domain`/`code` (which never contain a path) or the case label of a
        /// known PulsarTrace error enum. The error's free-text message — which
        /// may embed a path — is deliberately dropped.
        private static func safeCause(_ error: Error) -> String {
            switch error {
            case let e as WhisperTranscribeError:
                switch e {
                case .modelNotFound: return "modelNotFound"
                case .modelLoadFailed: return "modelLoadFailed"
                case .transcriptionFailed(let c): return "whisperCode \(c)"
                case .emptyAudio: return "emptyAudio"
                }
            default:
                let ns = error as NSError
                return "\(ns.domain) code \(ns.code)"
            }
        }
    }

    /// Outcome of a successful refine pass.
    public struct Output: Sendable {
        /// The recording folder the outputs were written into.
        public let recordingDirectory: URL
        /// `final.md` on-disk URL.
        public let finalURL: URL
        /// `metadata.json` on-disk URL.
        public let metadataURL: URL
        /// Distinct speaker labels in the final transcript.
        public let speakers: [String]
        /// Wall-clock seconds the pass took.
        public let durationSeconds: Double
        /// True when this run replaced a pre-existing `final.md` (re-refine).
        public let wasReRefine: Bool
    }

    private let logger: Logger
    private let events: EventWriter?
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - events: events writer; `nil` disables event emission (unit tests).
    ///   - clock: injectable wall clock (deterministic tests).
    public init(
        events: EventWriter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.events = events
        self.clock = clock
        self.logger = logger
    }

    /// Run the full refine pass.
    ///
    /// - Parameters:
    ///   - inputPath: a bare `.wav` file or a recording folder.
    ///   - transcriberFactory: builds a model-resident `WhisperTranscriber`.
    ///     A factory (not a single instance) so the mic and system streams get
    ///     independent transcribers — whisper.cpp keeps a per-context Metal
    ///     residency set and one context per source is the safe usage pattern.
    ///   - diarizer: the pyannote diarization driver.
    ///   - whisperModelName: model name recorded in `metadata.json` / events.
    ///   - whisperModelSHA256: pinned model hash recorded in `metadata.json`.
    ///   - recordingStart: wall-clock recording start for the `final.md` header.
    ///   - library: the persistent speaker library. When supplied,
    ///     post-pass clusters are reconciled against it — known speakers get
    ///     their library name, new speakers an `Unknown #N` placeholder
    ///     (R22, R23). `nil` keeps the no-library `Speaker_N` behaviour.
    ///   - precomputedDiarization: an injected diarization result that bypasses
    ///     the `diarizer` subprocess. The seam that lets reconciliation
    ///     be tested deterministically against committed JSON fixtures without
    ///     spawning pyannote; production passes `nil`.
    ///   - progress: optional progress sink (R26).
    public func run(
        inputPath: URL,
        transcriberFactory: @Sendable () throws -> WhisperTranscriber,
        diarizer: Diarizer,
        whisperModelName: String,
        whisperModelSHA256: String,
        recordingStart: Date = Date(),
        whisperOptions: WhisperOptions = .init(),
        library: SpeakerLibrary? = nil,
        precomputedDiarization: DiarizationResult? = nil,
        progress: ProgressReporter? = nil
    ) async throws -> Output {
        let started = clock()
        progress?(.resolvingInput)

        // --- Stage 1: resolve input -----------------------------------------
        let folder: RecordingFolder
        do {
            folder = try RecordingFolder.resolve(inputPath: inputPath)
        } catch let e as RecordingFolder.InputError {
            // No recording id yet — derive one from the path for the event.
            let id = RecordingFolder.recordingId(
                forName: inputPath.deletingPathExtension().lastPathComponent)
            _ = try? await events?.append(RefinementFailedEvent(
                recordingId: id, errorClass: "input", retryAvailable: false))
            throw RefineError.input(e)
        }

        // `refinement_started` — the first event, before any work (Invariant #8).
        _ = try? await events?.append(RefinementStartedEvent(
            recordingId: folder.recordingId, modelRefine: whisperModelName))
        logger.notice("refinement started: \(folder.recordingId), model=\(whisperModelName)")

        do {
            return try await refine(
                folder: folder,
                transcriberFactory: transcriberFactory,
                diarizer: diarizer,
                whisperModelName: whisperModelName,
                whisperModelSHA256: whisperModelSHA256,
                recordingStart: recordingStart,
                whisperOptions: whisperOptions,
                library: library,
                precomputedDiarization: precomputedDiarization,
                startedAt: started,
                sourceBasename: inputPath.lastPathComponent,
                progress: progress)
        } catch let e as RefineError {
            // Path-stripped (Hard Invariant #7): `\(e)` would expand
            // `description` and embed full CocoaError paths. Full detail still
            // goes to stderr in `RefineCommand`.
            logger.error("refinement failed (\(e.errorClass)): \(e.safeLogMessage)")
            _ = try? await events?.append(RefinementFailedEvent(
                recordingId: folder.recordingId,
                errorClass: e.errorClass,
                retryAvailable: e.retryAvailable))
            throw e
        }
    }

    // MARK: - Refine body

    private func refine(
        folder: RecordingFolder,
        transcriberFactory: @Sendable () throws -> WhisperTranscriber,
        diarizer: Diarizer,
        whisperModelName: String,
        whisperModelSHA256: String,
        recordingStart: Date,
        whisperOptions: WhisperOptions,
        library: SpeakerLibrary?,
        precomputedDiarization: DiarizationResult?,
        startedAt: Date,
        sourceBasename: String,
        progress: ProgressReporter?
    ) async throws -> Output {

        // --- Stage 2: transcribe the system stream --------------------------
        progress?(.transcribingSystem)
        let systemTranscription = try await transcribe(
            wav: folder.systemStream.url,
            transcriberFactory: transcriberFactory,
            options: whisperOptions)

        // --- Stage 3: diarize the system stream -----------------------------
        // Diarization only makes sense if whisper found speech. With no
        // utterances there is nothing to attribute, so skip pyannote entirely
        // (edge case: low-quality input / no usable speech).
        var diarization: DiarizationResult?
        if !systemTranscription.segments.isEmpty {
            progress?(.diarizing)
            if let precomputedDiarization {
                // Test seam: a committed diarization JSON fixture stands in for
                // the pyannote subprocess so reconciliation is
                // deterministic without spawning Python.
                diarization = precomputedDiarization
            } else {
                do {
                    diarization = try await diarizer.diarizeSystemStream(
                        wavPath: folder.systemStream.url)
                } catch {
                    throw RefineError.diarization(error)
                }
            }
        } else {
            logger.notice("no speech in system stream — skipping diarization")
        }

        // --- Stage 3b: reconcile clusters against the speaker library -------
        // (R22, R23) — known speakers get their library name, new speakers an
        // `Unknown #N` placeholder; returning-speaker centroids are refined.
        var reconciliation: SpeakerReconciler.Outcome?
        if let library, let diarization {
            do {
                reconciliation = try await SpeakerReconciler(library: library)
                    .reconcile(
                        diarization: diarization,
                        recordingId: folder.recordingId,
                        recordingFolderName: folder.directory.lastPathComponent)
            } catch {
                // A library failure must not lose a refine: fall back to the
                // raw `Speaker_N` labels and continue.
                logger.error("speaker reconciliation failed — using Speaker_N labels")
                reconciliation = nil
            }
        }

        // --- Stage 4: transcribe + merge the mic stream (if any) ------------
        var micTranscription: StreamTranscription?
        if let mic = folder.micStream {
            progress?(.transcribingMic)
            micTranscription = try await transcribe(
                wav: mic.url,
                transcriberFactory: transcriberFactory,
                options: whisperOptions)
        }

        progress?(.merging)
        let merged = mergeStreams(
            system: systemTranscription,
            diarization: diarization,
            reconciliation: reconciliation,
            mic: micTranscription,
            recordingStart: recordingStart)

        // --- Stage 5: write final.md atomically -----------------------------
        progress?(.writingFinal)
        let markdown = merged.document.render()
        let finalExistedBefore = FileManager.default.fileExists(
            atPath: folder.finalURL.path)

        let writeResult: FinalWriteResult
        do {
            writeResult = try writeFinalMarkdown(markdown, folder: folder)
        } catch {
            throw RefineError.io(error)
        }
        let fileSHA = writeResult.sha256

        // Event order follows the on-disk effect order (Hard Invariant #8):
        // `writeFinalMarkdown` writes `final.md` FIRST, then renames any
        // `live.md` to `.live.md.bak`. Both files have reached their final
        // state before any event fires — so the `final.md` event is emitted
        // first, then `live_md_replaced_by_final`.

        // File event — `final.md` is durably on disk.
        if finalExistedBefore {
            // Re-refine (R27): an existing final.md was replaced.
            _ = try? await events?.append(FinalMDRewrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: fileSHA,
                reason: "re_refine"))
        } else {
            _ = try? await events?.append(FinalMDWrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: fileSHA))
        }

        // `live.md` → `.live.md.bak` rename already happened on disk; emit its
        // event after the `final.md` event so event order mirrors disk order.
        if writeResult.replacedLiveMD {
            _ = try? await events?.append(
                LiveMDReplacedByFinalEvent(recordingId: folder.recordingId))
        }

        // --- Stage 6: write metadata.json -----------------------------------
        progress?(.writingMetadata)
        // The recording's duration is the longer of its streams.
        let durationSeconds = max(
            systemTranscription.audioDuration.seconds,
            micTranscription?.audioDuration.seconds ?? 0.0)
        let metadata = buildMetadata(
            folder: folder,
            speakers: merged.speakers,
            speakerIdByLabel: merged.speakerIdByLabel,
            systemTranscription: systemTranscription,
            diarization: diarization,
            recordingStart: recordingStart,
            refinedAt: startedAt,
            whisperModelName: whisperModelName,
            whisperModelSHA256: whisperModelSHA256,
            sourceBasename: sourceBasename,
            audioDurationSeconds: durationSeconds)
        do {
            try AtomicFile.write(try metadata.encoded(), to: folder.metadataURL)
        } catch {
            throw RefineError.io(error)
        }

        // --- Done ------------------------------------------------------------
        progress?(.done)
        let wallSeconds = clock().timeIntervalSince(startedAt)
        // `speakers_new` / `speakers_matched`: the reconciler reports how many
        // clusters were new vs. library matches.
        // Without a library, every speaker counts as "new".
        let speakersNew = reconciliation?.newCount ?? merged.speakers.count
        let speakersMatched = reconciliation?.matchedCount ?? 0
        _ = try? await events?.append(RefinementCompletedEvent(
            recordingId: folder.recordingId,
            durationSeconds: wallSeconds,
            speakersIdentified: merged.speakers.count,
            speakersNew: speakersNew,
            speakersMatched: speakersMatched))
        let speakerCount = merged.speakers.count
        let wallSecondsText = String(format: "%.1f", wallSeconds)
        logger.notice(
            "refinement completed: \(folder.recordingId), \(speakerCount) speaker(s), \(wallSecondsText)s")

        return Output(
            recordingDirectory: folder.directory,
            finalURL: folder.finalURL,
            metadataURL: folder.metadataURL,
            speakers: merged.speakers,
            durationSeconds: wallSeconds,
            wasReRefine: finalExistedBefore)
    }

    // MARK: - Transcription

    /// One transcription result plus the accumulated audio duration.
    private struct StreamTranscription {
        let segments: [TranscriptSegment]
        let language: String
        let audioDuration: Duration
    }

    /// Transcribe a single WAV through `FixturePlaybackSource` → whisper.
    ///
    /// A partial / slightly-malformed WAV header is tolerated by `WAVReader`,
    /// which recovers what is readable rather than crashing (edge case).
    private func transcribe(
        wav: URL,
        transcriberFactory: @Sendable () throws -> WhisperTranscriber,
        options: WhisperOptions
    ) async throws -> StreamTranscription {
        do {
            let transcriber = try transcriberFactory()
            let source = FixturePlaybackSource(file: wav, realtime: false)
            let pipeline = OfflineTranscriptionPipeline(logger: logger)
            let samples = try await pipeline.accumulate(source)

            // No usable speech at all: hand back an empty transcript rather
            // than letting `whisper_full` throw `emptyAudio`. The pipeline then
            // writes a valid, explanatory `final.md` (edge case).
            guard !samples.isEmpty else {
                return StreamTranscription(
                    segments: [], language: "unknown", audioDuration: .zero)
            }
            let duration = Duration.milliseconds(
                samples.count * 1000 / AudioFormat.sampleRate)

            // VAD-segmented transcription: when a Silero VAD model is
            // available, detect this stream's speech regions and decode each
            // independently, so a speaker's turn ends at the pause where they
            // stopped to listen. The time-order merge can then interleave the
            // other stream's utterances in causal order, instead of floating
            // one long glued-together turn ahead of them. A VAD failure is
            // non-fatal — fall back to a whole-buffer decode.
            let result: TranscriptionResult
            if let vadModelURL = options.vadModelURL {
                var regions: [SpeechRegion] = []
                do {
                    regions = try WhisperTranscriber.detectSpeechRegions(
                        in: samples, vadModelURL: vadModelURL, logger: logger)
                } catch {
                    logger.warning(
                        "VAD region detection failed — whole-buffer decode")
                }
                result = try transcriber.transcribe(
                    samples, regions: regions, options: options)
            } else {
                result = try transcriber.transcribe(samples, options: options)
            }
            return StreamTranscription(
                segments: result.segments,
                language: result.language,
                audioDuration: duration)
        } catch {
            throw RefineError.transcription(error)
        }
    }

    // MARK: - Merge

    /// The merged transcript and its distinct speaker labels.
    private struct MergedTranscript {
        let document: TranscriptDocument
        /// Distinct speaker display labels, first-appearance order.
        let speakers: [String]
        /// Display label → stable library speaker id, for reconciled speakers
        /// for reconciled speakers. `You` and unreconciled speakers are absent.
        let speakerIdByLabel: [String: String]
    }

    /// Merge the system stream (diarized → library names, or `Speaker_N`) with
    /// the optional mic stream (always `You`) into one time-ordered
    /// `TranscriptDocument`.
    ///
    /// When a `reconciliation` is supplied, each diarized speaker's
    /// `Speaker_N` label is replaced by the persistent library name
    /// (`Steve`, `Unknown #1`) — R22. Without it, the `Speaker_N`
    /// behaviour is kept.
    ///
    /// When there are no utterances at all, an empty-transcript `final.md` is
    /// still produced — with a single explanatory note line — so a consumer
    /// gets a valid file rather than a crash or garbage (edge case).
    private func mergeStreams(
        system: StreamTranscription,
        diarization: DiarizationResult?,
        reconciliation: SpeakerReconciler.Outcome?,
        mic: StreamTranscription?,
        recordingStart: Date
    ) -> MergedTranscript {
        Self.mergeStreams(
            systemSegments: system.segments,
            diarization: diarization,
            reconciliation: reconciliation,
            micSegments: mic?.segments,
            recordingStart: recordingStart)
    }

    /// Static merge variant — takes flat segment arrays so `assembleAndWrite`
    /// can call it without constructing `StreamTranscription` wrappers.
    private static func mergeStreams(
        systemSegments: [TranscriptSegment],
        diarization: DiarizationResult?,
        reconciliation: SpeakerReconciler.Outcome?,
        micSegments: [TranscriptSegment]?,
        recordingStart: Date
    ) -> MergedTranscript {
        // System-stream labels: real `Speaker_N` from diarization, or the
        // unknown-speaker fallback when diarization was skipped.
        var systemLabels: [String]
        if let diarization {
            systemLabels = DiarizationMerge.speakerLabels(
                for: systemSegments, diarization: diarization)
        } else {
            systemLabels = Array(
                repeating: DiarizationMerge.unknownSpeaker,
                count: systemSegments.count)
        }

        // R22: rewrite each `Speaker_N` display label to its
        // reconciled library name. `DiarizationMerge` emits `Speaker_N` and
        // co-attributed `Speaker_0+Speaker_1`; build a `Speaker_N → name` map
        // (via the raw-label round-trip) and remap each `+`-joined component.
        var speakerIdByLabel: [String: String] = [:]
        if let diarization, let reconciliation {
            var nameByDisplay: [String: String] = [:]
            for rawLabel in diarization.speakers {
                let display = diarization.displayLabel(for: rawLabel)
                if let name = reconciliation.nameByRawLabel[rawLabel] {
                    nameByDisplay[display] = name
                    if let id = reconciliation.speakerIdByRawLabel[rawLabel] {
                        speakerIdByLabel[name] = id
                    }
                }
            }
            systemLabels = systemLabels.map { label in
                label.split(separator: "+")
                    .map { nameByDisplay[String($0)] ?? String($0) }
                    .sorted()
                    .joined(separator: "+")
            }
        }

        // Index-aligned (segment, label) for both streams, then a stable
        // time-order merge.
        var rows: [(segment: TranscriptSegment, label: String)] = []
        for (i, seg) in systemSegments.enumerated() {
            rows.append((seg, systemLabels[i]))
        }
        for seg in micSegments ?? [] {
            rows.append((seg, "You"))   // R17: the mic stream is always "You".
        }
        // Sort by start offset; ties broken by end then label for determinism.
        rows.sort { a, b in
            if a.segment.start != b.segment.start {
                return a.segment.start < b.segment.start
            }
            if a.segment.end != b.segment.end {
                return a.segment.end < b.segment.end
            }
            return a.label < b.label
        }

        // Empty transcript: emit a valid file with an explanatory note.
        guard !rows.isEmpty else {
            let note = TranscriptSegment(
                start: .zero, end: .zero,
                text: "_(no speech detected in this recording)_")
            let document = TranscriptDocument(
                recordingStart: recordingStart,
                segments: [note],
                speakerLabels: ["pulsartrace"],
                marker: .final)
            return MergedTranscript(
                document: document, speakers: [], speakerIdByLabel: [:])
        }

        let document = TranscriptDocument(
            recordingStart: recordingStart,
            segments: rows.map(\.segment),
            speakerLabels: rows.map(\.label),
            marker: .final)

        // Distinct speakers, in first-appearance order, splitting any
        // co-attributed `Speaker_0+Speaker_1` label into its components.
        var seen = Set<String>()
        var speakers: [String] = []
        for row in rows {
            for component in row.label.split(separator: "+").map(String.init) {
                if seen.insert(component).inserted { speakers.append(component) }
            }
        }
        return MergedTranscript(
            document: document,
            speakers: speakers,
            speakerIdByLabel: speakerIdByLabel)
    }

    // MARK: - final.md write + backups

    /// Result of the `final.md` atomic write.
    private struct FinalWriteResult {
        /// SHA-256 of the bytes written.
        let sha256: String
        /// True when a pre-existing `live.md` was renamed to `.live.md.bak`.
        let replacedLiveMD: Bool
    }

    /// Atomically write `final.md`, backing up any prior `live.md` / `final.md`.
    ///
    /// On-disk effect order: a pre-existing `final.md` is backed up, `final.md`
    /// is atomically written, THEN any `live.md` is renamed to `.live.md.bak`.
    /// Both files have reached their final state before this returns; the
    /// caller emits the `final.md` event first and `live_md_replaced_by_final`
    /// after, so event order mirrors this disk order (Hard Invariant #8).
    ///
    /// - `final.md` present (re-refine, R27) → copied to `final.md.bak` before
    ///   the atomic replace.
    /// - `live.md` present → renamed to `.live.md.bak`; the caller emits
    ///   `live_md_replaced_by_final` when this returns `replacedLiveMD == true`.
    private func writeFinalMarkdown(
        _ markdown: String,
        folder: RecordingFolder
    ) throws -> FinalWriteResult {
        try Self.writeFinalMarkdown(markdown, folder: folder)
    }

    /// Static variant so `assembleAndWrite` can call it without a pipeline instance.
    private static func writeFinalMarkdown(
        _ markdown: String,
        folder: RecordingFolder
    ) throws -> FinalWriteResult {
        let fm = FileManager.default

        // Back up a pre-existing final.md before it is replaced (R27).
        if fm.fileExists(atPath: folder.finalURL.path) {
            let backup = folder.directory.appendingPathComponent(
                RecordingFolder.FileName.finalBackup)
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
            }
            try fm.copyItem(at: folder.finalURL, to: backup)
        }

        // Atomic write-then-rename (R24): a reader/editor sees old-or-new.
        let sha = try AtomicFile.write(markdown, to: folder.finalURL)

        // A live.md from a recording pass is superseded by final.md: preserve
        // it as `.live.md.bak`. The caller emits `live_md_replaced_by_final`.
        var replacedLiveMD = false
        let liveURL = folder.liveURL
        if fm.fileExists(atPath: liveURL.path) {
            let liveBackup = folder.directory.appendingPathComponent(
                RecordingFolder.FileName.liveBackup)
            if fm.fileExists(atPath: liveBackup.path) {
                try? fm.removeItem(at: liveBackup)
            }
            try fm.moveItem(at: liveURL, to: liveBackup)
            replacedLiveMD = true
        }
        return FinalWriteResult(sha256: sha, replacedLiveMD: replacedLiveMD)
    }

    // MARK: - metadata.json

    private func buildMetadata(
        folder: RecordingFolder,
        speakers: [String],
        speakerIdByLabel: [String: String],
        systemTranscription: StreamTranscription,
        diarization: DiarizationResult?,
        recordingStart: Date,
        refinedAt: Date,
        whisperModelName: String,
        whisperModelSHA256: String,
        sourceBasename: String,
        audioDurationSeconds: Double
    ) -> RefinementMetadata {
        Self.buildMetadata(
            folder: folder,
            speakers: speakers,
            speakerIdByLabel: speakerIdByLabel,
            language: systemTranscription.language,
            diarization: diarization,
            recordingStart: recordingStart,
            refinedAt: refinedAt,
            whisperModelName: whisperModelName,
            whisperModelSHA256: whisperModelSHA256,
            sourceBasename: sourceBasename,
            audioDurationSeconds: audioDurationSeconds)
    }

    /// Static variant so `assembleAndWrite` can call it without a pipeline instance.
    private static func buildMetadata(
        folder: RecordingFolder,
        speakers: [String],
        speakerIdByLabel: [String: String],
        language: String,
        diarization: DiarizationResult?,
        recordingStart: Date,
        refinedAt: Date,
        whisperModelName: String,
        whisperModelSHA256: String,
        sourceBasename: String,
        audioDurationSeconds: Double
    ) -> RefinementMetadata {
        // `metadata.json` records the stable `speaker_id` ↔ name mapping (R83):
        // an agent keys off the id across renames.
        let speakerEntries = speakers.map { label in
            RefinementMetadata.Speaker(
                label: label,
                isMicrophone: label == "You",
                speakerId: speakerIdByLabel[label])
        }
        let pyannote = diarization.map {
            RefinementMetadata.PyannoteModelInfo(
                id: $0.model,
                revision: $0.modelRevision,
                libraryVersion: $0.modelVersion)
        }
        return RefinementMetadata(
            recordingId: folder.recordingId,
            recordingStart: Timestamps.event(recordingStart),
            refinedAt: Timestamps.event(refinedAt),
            durationSeconds: audioDurationSeconds,
            speakers: speakerEntries,
            whisperModel: .init(name: whisperModelName, sha256: whisperModelSHA256),
            pyannoteModel: pyannote,
            language: language,
            sourceBasename: sourceBasename)
    }

    // MARK: - assembleAndWrite (public static entry point for ResumableRefiner)

    /// Outcome of `assembleAndWrite`. Returned so the queue's
    /// `ResumableRefiner.run` can include real speaker counts in its
    /// `refinement_completed` event.
    public struct AssembleResult: Sendable {
        public let speakerCount: Int
        public let speakersNew: Int
        public let speakersMatched: Int
        public let durationSeconds: Double
    }

    /// The merge + write half of `run(_:)`, exposed so `ResumableRefiner` can
    /// reuse it after assembling segments incrementally from a checkpoint
    /// file.
    ///
    /// Now mirrors `RefinementPipeline.refine`'s tail: runs `SpeakerReconciler`
    /// when a library is supplied (so queue-driven refines get real speaker
    /// names instead of Speaker_N), writes `final.md` + `metadata.json`
    /// atomically, and emits `final_md_written` / `final_md_rewritten` /
    /// `live_md_replaced_by_final` events in causal order with on-disk effects
    /// (Hard Invariant #8). Returns an `AssembleResult` carrying the counts
    /// the caller needs for `refinement_completed`.
    ///
    /// This method is NOT a stable public API — it exists for the in-process
    /// queue worker. The `pulsartrace refine` CLI continues to call `run(_:)`.
    public static func assembleAndWrite(
        folder: RecordingFolder,
        systemSegments: [TranscriptSegment],
        micSegments: [TranscriptSegment],
        diarization: DiarizationResult?,
        language: String,
        whisperModelName: String,
        whisperModelSHA256: String,
        recordingStart: Date,
        sourceBasename: String,
        library: SpeakerLibrary? = nil,
        refinedAt: Date = Date(),
        events: EventWriter? = nil
    ) async throws -> AssembleResult {
        // 1. Reconcile against the speaker library when one is supplied.
        //    A reconciler failure must not lose a refine — fall back to
        //    raw Speaker_N labels (matches RefinementPipeline.refine).
        var reconciliation: SpeakerReconciler.Outcome?
        if let library, let diarization {
            do {
                reconciliation = try await SpeakerReconciler(library: library)
                    .reconcile(
                        diarization: diarization,
                        recordingId: folder.recordingId,
                        recordingFolderName: folder.directory.lastPathComponent)
            } catch {
                reconciliation = nil
            }
        }

        // 2. Merge system + mic segments; apply diarization + reconciliation.
        let merged = mergeStreams(
            systemSegments: systemSegments,
            diarization: diarization,
            reconciliation: reconciliation,
            micSegments: micSegments.isEmpty ? nil : micSegments,
            recordingStart: recordingStart)

        // 3. Write final.md atomically, recording whether a prior final.md
        //    existed (so the right event variant is emitted below) and
        //    whether a live.md was renamed.
        let finalExistedBefore = FileManager.default.fileExists(
            atPath: folder.finalURL.path)
        let markdown = merged.document.render()
        let writeResult = try writeFinalMarkdown(markdown, folder: folder)

        // 4. File events — emit in disk-effect order (Hard Invariant #8).
        if finalExistedBefore {
            _ = try? await events?.append(FinalMDRewrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: writeResult.sha256,
                reason: "re_refine"))
        } else {
            _ = try? await events?.append(FinalMDWrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: writeResult.sha256))
        }
        if writeResult.replacedLiveMD {
            _ = try? await events?.append(
                LiveMDReplacedByFinalEvent(recordingId: folder.recordingId))
        }

        // 5. Compute duration from the segments (best-effort: last end ts).
        let systemEnd = systemSegments.last?.end.seconds ?? 0.0
        let micEnd = micSegments.last?.end.seconds ?? 0.0
        let audioDurationSeconds = max(systemEnd, micEnd)

        // 6. Write metadata.json.
        let metadata = buildMetadata(
            folder: folder,
            speakers: merged.speakers,
            speakerIdByLabel: merged.speakerIdByLabel,
            language: language,
            diarization: diarization,
            recordingStart: recordingStart,
            refinedAt: refinedAt,
            whisperModelName: whisperModelName,
            whisperModelSHA256: whisperModelSHA256,
            sourceBasename: sourceBasename,
            audioDurationSeconds: audioDurationSeconds)
        try AtomicFile.write(try metadata.encoded(), to: folder.metadataURL)

        return AssembleResult(
            speakerCount: merged.speakers.count,
            speakersNew: reconciliation?.newCount ?? merged.speakers.count,
            speakersMatched: reconciliation?.matchedCount ?? 0,
            durationSeconds: audioDurationSeconds)
    }
}

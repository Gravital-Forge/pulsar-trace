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

        let writeResult: TranscriptAssembly.FinalWriteResult
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
    ) -> TranscriptAssembly.MergedTranscript {
        TranscriptAssembly.mergeStreams(
            systemSegments: system.segments,
            diarization: diarization,
            reconciliation: reconciliation,
            micSegments: mic?.segments,
            recordingStart: recordingStart)
    }

    // MARK: - final.md write + backups

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
    ) throws -> TranscriptAssembly.FinalWriteResult {
        try TranscriptAssembly.writeFinalMarkdown(markdown, folder: folder)
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
        TranscriptAssembly.buildMetadata(
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
}

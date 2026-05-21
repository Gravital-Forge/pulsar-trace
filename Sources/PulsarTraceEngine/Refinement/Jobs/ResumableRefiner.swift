// Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift
import Foundation
import Logging

/// Runs a refine pass with per-region and per-stage checkpointing so the job
/// can be paused between any two regions and resumed from the exact spot where
/// it stopped (D-Q6).
///
/// Progress is written to `refine-progress.json` inside the recording folder
/// after every completed VAD region and at every stage transition. On a fresh
/// run the file is created; on a resumed run it is read and the completed
/// work is skipped.
public actor ResumableRefiner {

    public typealias TranscribeRegion =
        @Sendable ([Float], SpeechRegion, WhisperTranscriber.Options) async throws
        -> TranscriptionResult
    public typealias DetectRegions =
        @Sendable ([Float]) throws -> [SpeechRegion]
    public typealias Diarize =
        @Sendable (URL) async throws -> DiarizationResult
    public typealias StageReporter = @Sendable (RefinementJobState) async -> Void

    private static let stageIndex: [RefinementJobState.Stage: Int] = {
        Dictionary(uniqueKeysWithValues:
            RefinementJobState.Stage.allCases.enumerated().map { ($1, $0) })
    }()

    private let transcribe: TranscribeRegion
    private let detectRegions: DetectRegions
    private let diarize: Diarize
    private let pauseGate: PauseGate
    private let events: EventWriter?
    /// Persistent speaker library used by `mergeAndWrite` for reconciliation
    /// (R22, R23). `nil` keeps the raw `Speaker_N` labels — the queue's
    /// `makeStandard` opens a real library and passes it in for production.
    private let library: SpeakerLibrary?
    private let reportState: StageReporter?
    private let logger: Logger

    public init(
        transcribe: @escaping TranscribeRegion,
        detectRegions: @escaping DetectRegions,
        diarize: @escaping Diarize,
        pauseGate: PauseGate,
        events: EventWriter?,
        library: SpeakerLibrary? = nil,
        onStageUpdate: StageReporter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.transcribe = transcribe
        self.detectRegions = detectRegions
        self.diarize = diarize
        self.pauseGate = pauseGate
        self.events = events
        self.library = library
        self.reportState = onStageUpdate
        self.logger = logger
    }

    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)
        // Clear any prior lastError on a fresh start — a healthy completion
        // should not leave the previous failure's text behind.
        if progress.lastError != nil {
            progress.lastError = nil
            try? persist(progress, folder: folder)
        }

        // refinement_started — emitted before any work, matching the
        // CLI's RefinementPipeline.run contract (Hard Invariant #8).
        _ = try? await events?.append(RefinementStartedEvent(
            recordingId: job.recordingId, modelRefine: job.modelName))

        let startedAt = Date()
        do {
            try await advance(&progress, to: .resolvingInput, folder: folder)

            try await advance(&progress, to: .transcribingSystem, folder: folder)
            try await transcribeSystemStream(folder: folder, progress: &progress)

            try await advance(&progress, to: .diarizing, folder: folder)
            let diarization = try await runDiarization(folder: folder, progress: &progress)

            try await advance(&progress, to: .transcribingMic, folder: folder)
            if folder.micStream != nil {
                try await transcribeMicStream(folder: folder, progress: &progress)
            }

            try await advance(&progress, to: .merging, folder: folder)
            try await advance(&progress, to: .writingFinal, folder: folder)
            try await advance(&progress, to: .writingMetadata, folder: folder)
            let assembled = try await mergeAndWrite(
                folder: folder, progress: progress, diarization: diarization, job: job)

            let wallSeconds = Date().timeIntervalSince(startedAt)
            _ = try? await events?.append(RefinementCompletedEvent(
                recordingId: job.recordingId,
                durationSeconds: wallSeconds,
                speakersIdentified: assembled.speakerCount,
                speakersNew: assembled.speakersNew,
                speakersMatched: assembled.speakersMatched))
        } catch {
            progress.lastError = Self.redactPath(
                "\(type(of: error)): \(error)",
                folder: folder.directory)
            try? persist(progress, folder: folder)
            logger.warning("refinement job \(job.id) failed: \(progress.lastError ?? "?")")
            let classified = RefinementJobError.classify(error)
            _ = try? await events?.append(RefinementFailedEvent(
                recordingId: job.recordingId,
                errorClass: classified.errorClass,
                retryAvailable: classified.retryAvailable))
            throw error
        }
    }

    /// Replace any occurrence of `folder`'s path in `s` with `<folder>` and any
    /// occurrence of the user's home directory with `~`, so the redacted text is
    /// safe to put in the progress file even if the underlying error rendered a
    /// filesystem path (Hard Invariant #7).
    ///
    /// Order matters: `folder.path` is replaced first because it is a longer,
    /// more-specific prefix than `NSHomeDirectory()` on a typical layout.
    /// Replacing the home directory second is still correct because `<folder>`
    /// doesn't contain `/Users/…`, so the second replacement never double-rewrites.
    static func redactPath(_ s: String, folder: URL) -> String {
        var out = s.replacingOccurrences(of: folder.path, with: "<folder>")
        out = out.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return out
    }

    // MARK: - Stage helpers

    private func loadOrInitProgress(folder: RecordingFolder, job: RefinementJob) -> RefinementProgress {
        let url = folder.directory.appendingPathComponent("refine-progress.json")
        if let data = try? Data(contentsOf: url),
           let p = try? RefinementProgress.decode(data),
           p.jobId == job.id, p.recordingId == job.recordingId {
            return p
        }
        return RefinementProgress.empty(jobId: job.id, recordingId: job.recordingId)
    }

    private func advance(
        _ progress: inout RefinementProgress,
        to stage: RefinementJobState.Stage,
        folder: RecordingFolder
    ) async throws {
        await pauseGate.waitOpen()
        progress.stage = stage
        progress.lastCheckpointAt = Date()
        try persist(progress, folder: folder)
        let totalStages = RefinementJobState.Stage.allCases.count
        let stepIndex = Self.stageIndex[stage]!
        await reportState?(.running(
            stage: stage, stepsCompleted: stepIndex, stepsTotal: totalStages,
            regionIndex: nil, regionsTotal: nil))
    }

    private func persist(_ progress: RefinementProgress, folder: RecordingFolder) throws {
        let url = folder.directory.appendingPathComponent("refine-progress.json")
        _ = try AtomicFile.write(try progress.encoded(), to: url)
    }

    // MARK: - Transcription with checkpointing

    private func transcribeSystemStream(
        folder: RecordingFolder,
        progress: inout RefinementProgress
    ) async throws {
        let samples = try await loadSamples(at: folder.systemStream.url)
        if progress.systemRegions.isEmpty {
            let regions = try detectRegions(samples)
            progress.systemRegions = regions.map(Self.toWindow)
            try persist(progress, folder: folder)
        }
        try await iterateRegions(
            samples: samples,
            allRegions: progress.systemRegions.map(Self.toRegion),
            isMic: false,
            progress: &progress,
            folder: folder)
    }

    private func transcribeMicStream(
        folder: RecordingFolder,
        progress: inout RefinementProgress
    ) async throws {
        guard let mic = folder.micStream else { return }
        let samples = try await loadSamples(at: mic.url)
        if progress.micRegions.isEmpty {
            let regions = try detectRegions(samples)
            progress.micRegions = regions.map(Self.toWindow)
            try persist(progress, folder: folder)
        }
        try await iterateRegions(
            samples: samples,
            allRegions: progress.micRegions.map(Self.toRegion),
            isMic: true,
            progress: &progress,
            folder: folder)
    }

    private func iterateRegions(
        samples: [Float],
        allRegions: [SpeechRegion],
        isMic: Bool,
        progress: inout RefinementProgress,
        folder: RecordingFolder
    ) async throws {
        while let i = (isMic
                       ? progress.nextMicRegionIndex
                       : progress.nextSystemRegionIndex) {
            await pauseGate.waitOpen()
            let region = allRegions[i]
            let result = try await transcribe(samples, region, .init())
            for seg in result.segments {
                let partial = RefinementProgress.PartialSegment(
                    startMillis: Int(seg.start.seconds * 1000),
                    endMillis: Int(seg.end.seconds * 1000),
                    text: seg.text,
                    regionIndex: i)
                if isMic {
                    progress.micSegments.append(partial)
                } else {
                    progress.systemSegments.append(partial)
                }
            }
            if progress.language == nil { progress.language = result.language }
            if isMic {
                progress.completedMicRegionIndices.append(i)
            } else {
                progress.completedSystemRegionIndices.append(i)
            }
            progress.lastCheckpointAt = Date()
            try persist(progress, folder: folder)
            let total = isMic ? progress.micRegions.count : progress.systemRegions.count
            let baseStage: RefinementJobState.Stage = isMic ? .transcribingMic : .transcribingSystem
            let stepIndex = Self.stageIndex[baseStage]!
            let completed = isMic ? progress.completedMicRegionIndices.count
                                  : progress.completedSystemRegionIndices.count
            await reportState?(.running(
                stage: baseStage,
                stepsCompleted: stepIndex,
                stepsTotal: RefinementJobState.Stage.allCases.count,
                regionIndex: completed,
                regionsTotal: total))
        }
    }

    private func runDiarization(
        folder: RecordingFolder,
        progress: inout RefinementProgress
    ) async throws -> DiarizationResult? {
        guard !progress.systemSegments.isEmpty else { return nil }
        // D-Q7 retry: re-run on cancel, propagate other errors.
        while true {
            await pauseGate.waitOpen()
            do {
                return try await diarize(folder.systemStream.url)
            } catch let e as Diarizer.DiarizeError {
                if case .cancelled = e { continue }
                throw e
            }
        }
    }

    // MARK: - Final assembly

    @discardableResult
    private func mergeAndWrite(
        folder: RecordingFolder,
        progress: RefinementProgress,
        diarization: DiarizationResult?,
        job: RefinementJob
    ) async throws -> RefinementPipeline.AssembleResult {
        let system = progress.systemSegments.map {
            TranscriptSegment(
                start: .milliseconds($0.startMillis),
                end: .milliseconds($0.endMillis),
                text: $0.text)
        }
        let mic = progress.micSegments.map {
            TranscriptSegment(
                start: .milliseconds($0.startMillis),
                end: .milliseconds($0.endMillis),
                text: $0.text)
        }
        let folderName = folder.directory.lastPathComponent
        let recordingStart = RecordingFolderTimestamp.parse(folderName) ?? Date()
        return try await RefinementPipeline.assembleAndWrite(
            folder: folder,
            systemSegments: system,
            micSegments: mic,
            diarization: diarization,
            language: progress.language ?? "unknown",
            whisperModelName: job.modelName,
            whisperModelSHA256: job.modelSHA256,
            recordingStart: recordingStart,
            sourceBasename: folder.systemStream.url.lastPathComponent,
            library: library,
            refinedAt: Date(),
            events: events)
    }

    // MARK: - Conversions

    private static func toWindow(_ r: SpeechRegion) -> RefinementProgress.RegionWindow {
        .init(startMillis: Int(r.start.seconds * 1000), endMillis: Int(r.end.seconds * 1000))
    }

    private static func toRegion(_ w: RefinementProgress.RegionWindow) -> SpeechRegion {
        SpeechRegion(start: .milliseconds(w.startMillis), end: .milliseconds(w.endMillis))
    }

    /// Load mono Float32 samples from a WAV file at `wav`.
    ///
    /// Uses `WAVReader(contentsOf:)`, the engine's canonical WAV decoder that
    /// produces 16 kHz mono Float32 from what `WAVWriter` writes. Made `async`
    /// so a future version can dispatch to a background executor without
    /// changing the actor's call sites.
    private func loadSamples(at wav: URL) async throws -> [Float] {
        try WAVReader(contentsOf: wav).samples
    }
}

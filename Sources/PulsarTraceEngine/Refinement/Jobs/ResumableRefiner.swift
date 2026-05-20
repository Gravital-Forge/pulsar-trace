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
///
/// B4 — happy-path stage iteration only. Pause/resume (gate-closing) is wired
/// in B5; `PauseGate` is already threaded through here so B5 can activate it
/// without changing the call sites.
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
    private let reportState: StageReporter?
    private let logger: Logger

    public init(
        transcribe: @escaping TranscribeRegion,
        detectRegions: @escaping DetectRegions,
        diarize: @escaping Diarize,
        pauseGate: PauseGate,
        events: EventWriter?,
        onStageUpdate: StageReporter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.transcribe = transcribe
        self.detectRegions = detectRegions
        self.diarize = diarize
        self.pauseGate = pauseGate
        self.events = events
        self.reportState = onStageUpdate
        self.logger = logger
    }

    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)

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
        try mergeAndWrite(folder: folder, progress: progress, diarization: diarization, job: job)
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

    private func mergeAndWrite(
        folder: RecordingFolder,
        progress: RefinementProgress,
        diarization: DiarizationResult?,
        job: RefinementJob
    ) throws {
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
        try RefinementPipeline.assembleAndWrite(
            folder: folder,
            systemSegments: system,
            micSegments: mic,
            diarization: diarization,
            language: progress.language ?? "unknown",
            whisperModelName: job.modelName,
            whisperModelSHA256: job.modelSHA256,
            recordingStart: Date(),
            sourceBasename: folder.systemStream.url.lastPathComponent)
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

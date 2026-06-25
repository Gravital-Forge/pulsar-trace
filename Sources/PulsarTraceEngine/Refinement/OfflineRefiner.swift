import Foundation
import Logging

/// One-shot, no-queue refine — the entry point for the `pulsartrace refine`
/// CLI. The menubar app no longer calls this; it uses
/// `RefinementJobQueue` + `ResumableRefiner` so a refine is pause-resumable
/// and back-to-back recordings don't block each other.
///
/// This path stays so the CLI can take a bare WAV (or a folder) without
/// touching the queue: bare-WAV runs are typically one-shot scripts where
/// pause/resume is not useful. The shared merge + write step is in
/// `TranscriptAssembly.assembleAndWrite`.
///
/// `OfflineRefiner` owns everything `RefinementPipeline` needs but does not
/// build itself: wiring the in-process `Diarizer` (FluidAudio CoreML/ANE,
/// D40 — no venv, no token, no IPC), opening the persistent speaker library,
/// and constructing the WhisperKit transcriber + FluidVAD wiring.
public struct OfflineRefiner: Sendable {

    /// A lightweight progress line — the CLI prints these to stderr, the
    /// menubar can surface them in the menu.
    public typealias ProgressReporter = @Sendable (String) -> Void

    private let events: EventWriter
    private let paths: AppPaths

    /// - Parameters:
    ///   - events: the process-wide events writer.
    ///   - paths: app paths — resolves the speaker-library location.
    public init(events: EventWriter, paths: AppPaths = .standard) {
        self.events = events
        self.paths = paths
    }

    /// Setup failures that precede the pipeline (so they are never confused
    /// with a `RefineError.input` path problem — verified:
    /// `RecordingFolder.InputError` only has path-shaped cases).
    public enum SetupError: Error, CustomStringConvertible, Equatable {
        case unknownModel(String)

        public var description: String {
            switch self {
            case .unknownModel(let name):
                return "unknown refine model '\(name)' (expected: "
                    + WhisperKitModelCatalog.all.map(\.name).joined(separator: ", ")
                    + ")"
            }
        }
    }

    /// Run the offline refine pass over one audio file or recording folder.
    ///
    /// - Parameters:
    ///   - inputPath: audio file or recording folder.
    ///   - modelName: a `WhisperKitModelCatalog` name
    ///     (`large-v3-turbo` | `large-v3-whisperkit`).
    ///   - language: ISO-639-1 code pinning the decode language
    ///     (`refine --language`), or `nil` → the allowed-languages policy /
    ///     auto-detect (`WhisperKitLanguagePolicy`).
    ///   - progress: optional human-readable progress callback.
    /// - Returns: the `RefinementPipeline.Output`.
    /// - Throws: `SetupError`, or `RefinementPipeline.RefineError` — callers
    ///   must propagate, never swallow.
    @discardableResult
    public func refine(
        inputPath: URL,
        modelName: String,
        language: String? = nil,
        progress: ProgressReporter? = nil
    ) async throws -> RefinementPipeline.Output {
        guard let model = WhisperKitModelCatalog.model(named: modelName) else {
            throw SetupError.unknownModel(modelName)
        }

        progress?("preparing \(model.name) (ANE)…")
        let whisperKit = WhisperKitRegionTranscriber(
            configuration: .init(
                model: model,
                downloadBase: paths.modelsCacheDirectory
                    .appendingPathComponent("whisperkit", isDirectory: true)),
            events: events)
        let transcriber: RefinementTranscriber = .whisperKit(
            whisperKit, vad: FluidVADRegionDetector())
        let options = TranscriptionOptions(language: language)

        let diarizer = Self.makeDiarizer(events: events)

        // The persistent speaker library at the standard location. A failure
        // to open it is non-fatal — refine continues with `Speaker_N` labels.
        let library = try? await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)
        if library == nil {
            progress?("speaker library unavailable — using Speaker_N labels")
        }

        let pipeline = RefinementPipeline(events: events)
        let stageProgress: RefinementPipeline.ProgressReporter = { stage in
            progress?("\(stage.rawValue)…")
        }

        return try await pipeline.run(
            inputPath: inputPath,
            transcriber: transcriber,
            diarizer: diarizer,
            whisperModelName: model.name,
            whisperModelSHA256: "",   // SDK-managed CoreML bundle (D39)
            recordingStart: Date(),
            options: options,
            library: library,
            progress: stageProgress)
    }

    // MARK: - Diarizer wiring

    /// Build a `Diarizer` over the FluidAudio ANE backend (D40). Models load
    /// lazily from the shared cache root (D10) on the first diarize call;
    /// `events` receives `model_downloaded` after a fresh download.
    public static func makeDiarizer(events: EventWriter? = nil) -> Diarizer {
        Diarizer(configuration: .init(), events: events)
    }
}

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
/// build itself: wiring the dev-environment `Diarizer` (venv interpreter,
/// repo root, `.env`), opening the persistent speaker library, and
/// constructing the WhisperKit transcriber + FluidVAD wiring.
///
/// Robustness overrides (D3): the repo root is otherwise the `#filePath`
/// dev-tree path baked into the binary at build time.
/// `PULSARTRACE_REPO_ROOT`, `PULSARTRACE_VENV_PYTHON` and `HF_TOKEN`
/// environment variables take precedence so a binary can run off a machine
/// that is not the build host, ahead of full app packaging.
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
                downloadBase: ModelStore.defaultCacheDirectory()
                    .appendingPathComponent("whisperkit", isDirectory: true)),
            events: events)
        let transcriber: RefinementTranscriber = .whisperKit(
            whisperKit, vad: FluidVADRegionDetector())
        let whisperOptions = WhisperOptions(language: language)

        let diarizer = try Self.makeDiarizer()

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
            whisperOptions: whisperOptions,
            library: library,
            progress: stageProgress)
    }

    // MARK: - Diarizer wiring (dev environment)

    /// Build a `Diarizer` against the dev venv + repo `.env` (D3/D9).
    ///
    /// Packaging will later swap this for the bundled `python-build-standalone`
    /// runtime; the IPC boundary is identical, only this wiring changes.
    public static func makeDiarizer() throws -> Diarizer {
        let repoRoot = repoRootURL()
        let pythonWorkingDir = repoRoot
            .appendingPathComponent("python/pulsartrace-ai")

        // `PULSARTRACE_VENV_PYTHON` overrides the venv interpreter outright;
        // otherwise it is resolved under the (possibly overridden) repo root.
        let venvPython: URL
        if let p = ProcessInfo.processInfo.environment["PULSARTRACE_VENV_PYTHON"],
           !p.isEmpty {
            venvPython = URL(fileURLWithPath: p)
        } else {
            venvPython = repoRoot
                .appendingPathComponent("python/pulsartrace-ai/.venv/bin/python")
        }

        var env = dotEnv(repoRoot: repoRoot)
        // A `HF_TOKEN` from the real process environment wins over the `.env`
        // file (dev convenience vs. an explicit caller-supplied token).
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"],
           !token.isEmpty {
            env["HF_TOKEN"] = token
        }
        // Cache the pyannote model under PulsarTrace's own cache dir (D10).
        if let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first {
            env["HF_HOME"] = caches
                .appendingPathComponent("PulsarTrace/huggingface").path
        }

        let config = Diarizer.Configuration(
            pythonExecutable: venvPython,
            workingDirectory: pythonWorkingDir,
            environment: env)
        return Diarizer(configuration: config)
    }

    /// Repo root.
    ///
    /// `PULSARTRACE_REPO_ROOT` (if set) takes precedence — a cheap robustness
    /// override so the binary can be run off the build host ahead of full
    /// app packaging (D3). The `#filePath`-derived path is the dev-tree
    /// fallback: a build-machine path baked into the binary.
    private static func repoRootURL() -> URL {
        if let root = ProcessInfo.processInfo.environment["PULSARTRACE_REPO_ROOT"],
           !root.isEmpty {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: #filePath)  // …/Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift
            .deletingLastPathComponent()        // …/Refinement
            .deletingLastPathComponent()        // …/PulsarTraceEngine
            .deletingLastPathComponent()        // …/Sources
            .deletingLastPathComponent()        // repo root
    }

    /// Load `KEY=VALUE` pairs from the repo `.env` (dev-only, D9).
    private static func dotEnv(repoRoot: URL) -> [String: String] {
        let envFile = repoRoot.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}

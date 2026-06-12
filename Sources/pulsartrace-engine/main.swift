import Foundation
import Logging
import PulsarTraceEngine

/// `pulsartrace-engine` — the streaming engine binary.
///
/// In its simplest mode it consumes an `AudioFrameSource` and reports a frame
/// count. `--transcribe` runs a source through `WhisperTranscriber` and
/// prints the R13 markdown transcript. Whisper streaming and diarization run
/// behind the same source-consuming loop.
///
/// Usage:
///   pulsartrace-engine --stdin                  Read raw f32le PCM from stdin.
///   pulsartrace-engine --fixture <path>         Replay a WAV fixture (fast mode).
///   pulsartrace-engine --source fixture <path>  Same; verbose source syntax.
///   pulsartrace-engine --socket <path>          Read framed PCM from a socket.
///   pulsartrace-engine --source fixture <path> --transcribe [--model base]
///                                               Offline-transcribe + print R13 markdown.
@main
struct EngineMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let lifecycle = await AppLifecycle.start()

        let exitCode: Int32
        do {
            if args.contains("--live") {
                let summary = try await live(args: args, lifecycle: lifecycle)
                FileHandle.standardOutput.write(Data((summary + "\n").utf8))
            } else if args.contains("--transcribe") {
                let markdown = try await transcribe(args: args, lifecycle: lifecycle)
                FileHandle.standardOutput.write(Data(markdown.utf8))
            } else {
                let result = try await run(args: args)
                FileHandle.standardOutput.write(Data(
                    ("frames=\(result.frameCount) samples=\(result.sampleCount) "
                     + "seconds=\(result.frameCount * AudioFormat.frameMilliseconds / 1000)\n")
                    .utf8))
            }
            exitCode = 0
        } catch let error as UsageError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            exitCode = 2
        } catch {
            FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
            exitCode = 1
        }

        await lifecycle.stop()
        exit(exitCode)
    }

    /// Build the requested source, consume it, return the frame summary.
    static func run(args: [String]) async throws -> FrameConsumer.Result {
        let consumer = FrameConsumer()

        if args.contains("--stdin") {
            let source = RawPCMPipeSource(fd: FileHandle.standardInput.fileDescriptor)
            return try await consumer.consume(source)
        }
        if let path = fixturePath(in: args) {
            let source = FixturePlaybackSource(
                file: URL(fileURLWithPath: path), realtime: false)
            return try await consumer.consume(source)
        }
        if let path = value(after: "--socket", in: args) {
            let source = SocketSource(socketPath: URL(fileURLWithPath: path))
            return try await consumer.consume(source)
        }
        throw UsageError(message: """
            usage: pulsartrace-engine [--stdin | --fixture <wav> | --socket <path>]
            """)
    }

    /// Offline-transcribe a fixture source and render R13 markdown.
    ///
    /// Downloads/verifies the requested model on first use (R54c/R54d), keeps
    /// it resident in one `WhisperTranscriber`, and runs the whole fixture
    /// through a single `whisper_full` call.
    static func transcribe(args: [String], lifecycle: AppLifecycle) async throws -> String {
        guard let path = fixturePath(in: args) else {
            throw UsageError(message: """
                usage: pulsartrace-engine --source fixture <wav> --transcribe [--model base|large-v3]
                """)
        }
        let modelName = value(after: "--model", in: args) ?? "base"
        guard let model = ModelCatalog.model(named: modelName) else {
            throw UsageError(message: "unknown model '\(modelName)'; known: "
                + ModelCatalog.all.map(\.name).joined(separator: ", "))
        }

        let store = ModelStore(events: lifecycle.events)
        let modelURL = try await store.ensureAvailable(model)

        let transcriber = try WhisperTranscriber(modelURL: modelURL)
        let pipeline = OfflineTranscriptionPipeline()
        let source = FixturePlaybackSource(
            file: URL(fileURLWithPath: path), realtime: false)
        let output = try await pipeline.run(source: source, transcriber: transcriber)
        return output.markdown
    }

    /// Run the live pass — streaming transcription + provisional
    /// live diarization — over a source, growing an append-only `live.md`.
    ///
    /// Sources:
    /// - `--stdin` / `--source fixture <wav>` — a single stream, treated as the
    ///   **system stream** (diarized, `Them …` labels).
    /// - `--system-socket <path>` (+ optional `--mic-socket <path>`) —
    ///   real-capture mode: the system stream and, when paired, the `You` mic
    ///   stream, each read from a `pulsartrace-capture` Unix domain socket.
    ///
    /// `live.md` is written into a recording folder: `--out <dir>` if given,
    /// else a sibling folder named for the fixture stem, else a timestamped
    /// folder in the cwd.
    ///
    /// Live diarization is best-effort: if the pyannote subprocess cannot
    /// start it is skipped and system speakers stay the generic
    /// `Them?`. `--no-live-diarization` skips it outright.
    static func live(args: [String], lifecycle: AppLifecycle) async throws -> String {
        // --- resolve the source(s) ------------------------------------------
        let source: any AudioFrameSource
        var micSource: (any AudioFrameSource)?
        let stemName: String
        if args.contains("--stdin") {
            source = RawPCMPipeSource(fd: FileHandle.standardInput.fileDescriptor)
            stemName = "live-" + Self.timestampStem()
        } else if let path = fixturePath(in: args) {
            // Realtime mode so the live pass runs at wall-clock pace (R10).
            source = FixturePlaybackSource(
                file: URL(fileURLWithPath: path), realtime: true)
            // `--mic-fixture <path>` pairs a second realtime fixture as the
            // mic stream so a one-WAV repro can exercise the dual-stream
            // contention on the single shared ParakeetEngine actor — pass
            // the same WAV to drive 2× decode load on one resident model.
            if let micPath = value(after: "--mic-fixture", in: args) {
                micSource = FixturePlaybackSource(
                    file: URL(fileURLWithPath: micPath), realtime: true)
            }
            stemName = URL(fileURLWithPath: path)
                .deletingPathExtension().lastPathComponent
        } else if let systemSocket = value(after: "--system-socket", in: args)
                    ?? value(after: "--mic-socket", in: args) {
            // Capture-daemon sockets. The system socket is the primary
            // (diarized) stream; a mic socket is a paired `You` stream only
            // when a system socket is also present.
            source = SocketSource(socketPath: URL(fileURLWithPath: systemSocket))
            if value(after: "--system-socket", in: args) != nil,
               let micPath = value(after: "--mic-socket", in: args) {
                micSource = SocketSource(socketPath: URL(fileURLWithPath: micPath))
            }
            stemName = value(after: "--recording-id", in: args)
                ?? "live-" + Self.timestampStem()
        } else {
            throw UsageError(message: """
                usage: pulsartrace-engine --live \
                [--stdin | --source fixture <wav> [--mic-fixture <wav>] | --system-socket <path> [--mic-socket <path>]] \
                [--out <dir>] [--recording-id <id>] [--no-live-diarization]
                """)
        }

        // --- recording folder for live.md -----------------------------------
        let recordingFolder: URL
        if let out = value(after: "--out", in: args) {
            recordingFolder = URL(fileURLWithPath: out, isDirectory: true)
        } else {
            recordingFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(stemName, isDirectory: true)
        }
        let recordingStart = Date()
        // An explicit `--recording-id` is already a finished `rec_<short>` id
        // (RecordPlan builds it; pulsartrace-capture uses it verbatim) — it
        // must NOT be re-derived: slugging turns `rec_x` into `rec_rec-x`,
        // which broke the events-log join between `live_md_started` and the
        // capture/refinement events of the same recording. Derive only when
        // no id was given (fixture/stdin/CLI runs named by their stem).
        let recordingId = value(after: "--recording-id", in: args)
            ?? RecordingFolder.recordingId(forName: stemName)

        // --- live transcriber (resident, ANE) --------------------------------
        // Parakeet v3 via FluidAudio (D39): in-process CoreML — no subprocess,
        // no Metal, no flock, and no live model knob. Both streams share one
        // resident engine; the actor serializes decodes (the in-process
        // analogue of the old SerializingHostProxy). First launch downloads
        // ~0.5 GB from huggingface.co. A wedged window decode is bounded by
        // ParakeetWindowTranscriber's 30 s deadline — the window is skipped
        // and the post-pass recovers the audio.
        //
        // Cache root: ModelStore.defaultCacheDirectory() until task 16 of
        // docs/specs/2026-06-12-ane-transcription-pipeline/ replaces it with
        // AppPaths.modelsCacheDirectory and deletes ModelStore.
        let parakeet = try await ParakeetEngine.load(
            cacheRoot: ModelStore.defaultCacheDirectory(),
            events: lifecycle.events,
            logger: Logger(label: LogSubsystem.engine))
        let transcriber: any WindowTranscribing =
            ParakeetWindowTranscriber(engine: parakeet)
        let micTranscriber: (any WindowTranscribing)? = micSource != nil
            ? ParakeetWindowTranscriber(engine: parakeet)
            : nil

        // --- live diarization config (dev venv + .env, like RefineCommand) --
        let liveDiarizerConfig: LiveDiarizer.Configuration?
        if args.contains("--no-live-diarization") {
            liveDiarizerConfig = nil
        } else {
            liveDiarizerConfig = Self.liveDiarizerConfig()
        }

        // --- speaker library, READ-ONLY (R18/R32) ---------------------------
        // The live pass only ever reads the library; only the post-pass writes.
        let library: SpeakerLibrary?
        do {
            library = try await SpeakerLibrary(
                databaseURL: AppPaths.standard.speakersDatabaseURL)
        } catch {
            // Live continues without name lookups, but a corrupt library must
            // be diagnosable — this was previously a silent `try?`.
            Logger(label: LogSubsystem.engine).error(
                """
                speaker library unavailable for live pass — continuing \
                without name lookups: \(PathRedactor.redactHome("\(error)"))
                """)
            library = nil
        }

        // Optional per-window language allow-list (e.g.
        // `--allowed-languages en,pl`). Empty → unrestricted auto-detect
        // (the legacy behaviour); non-empty → the engine pre-detects per
        // window and forces the highest-probability allowed code, so a
        // `nn` misfire on English audio cannot poison the committer.
        let allowedLanguages: [String] = value(
            after: "--allowed-languages", in: args)
            .map { $0.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty } } ?? []
        let transcriberConfig = StreamingTranscriber.Configuration(
            whisperOptions: WhisperOptions(allowedLanguages: allowedLanguages))

        let pipeline = StreamingPipeline(events: lifecycle.events)
        let output = try await pipeline.run(
            configuration: .init(
                recordingFolder: recordingFolder,
                recordingStart: recordingStart,
                recordingId: recordingId,
                transcriberConfig: transcriberConfig,
                liveDiarizerConfig: liveDiarizerConfig),
            systemTranscriber: transcriber,
            micTranscriber: micTranscriber,
            systemSource: source,
            micSource: micSource,
            library: library)

        let medianLag = String(format: "%.1f", output.medianLagSeconds)
        let maxLag = String(format: "%.1f", output.maxLagSeconds)
        return "live.md=\(output.liveURL.path) lines=\(output.utteranceLines) "
            + "bytes=\(output.bytesWritten) mic_echoes_dropped=\(output.micEchoesDropped) "
            + "median_lag_seconds=\(medianLag) max_lag_seconds=\(maxLag) "
            + "language=\(output.language)"
    }

    /// A filesystem-safe timestamp stem for a `--stdin` live recording folder.
    static func timestampStem() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Build the `LiveDiarizer.Configuration` against the dev venv + repo
    /// `.env` — mirrors `RefineCommand.makeDiarizer`'s wiring (project-docs/DECISIONS.md
    /// D3/D9). A future change swaps this for the bundled python runtime.
    static func liveDiarizerConfig() -> LiveDiarizer.Configuration {
        let env = ProcessInfo.processInfo.environment
        let repoRoot: URL
        if let root = env["PULSARTRACE_REPO_ROOT"], !root.isEmpty {
            repoRoot = URL(fileURLWithPath: root)
        } else {
            repoRoot = URL(fileURLWithPath: #filePath)   // …/Sources/pulsartrace-engine/main.swift
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        let workingDir = repoRoot.appendingPathComponent("python/pulsartrace-ai")
        let venvPython: URL
        if let p = env["PULSARTRACE_VENV_PYTHON"], !p.isEmpty {
            venvPython = URL(fileURLWithPath: p)
        } else {
            venvPython = workingDir.appendingPathComponent(".venv/bin/python")
        }

        var subprocessEnv = Self.dotEnv(repoRoot: repoRoot)
        if let token = env["HF_TOKEN"], !token.isEmpty {
            subprocessEnv["HF_TOKEN"] = token
        }
        if let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first {
            subprocessEnv["HF_HOME"] = caches
                .appendingPathComponent("PulsarTrace/huggingface").path
        }
        return LiveDiarizer.Configuration(
            pythonExecutable: venvPython,
            workingDirectory: workingDir,
            environment: subprocessEnv)
    }

    /// Load `KEY=VALUE` pairs from the repo `.env` (dev-only, D9).
    static func dotEnv(repoRoot: URL) -> [String: String] {
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

    /// Resolve the fixture WAV path from either `--fixture <p>` or
    /// `--source fixture <p>`.
    static func fixturePath(in args: [String]) -> String? {
        if let p = value(after: "--fixture", in: args) { return p }
        if let i = args.firstIndex(of: "--source"),
           i + 2 < args.count, args[i + 1] == "fixture" {
            return args[i + 2]
        }
        return nil
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

struct UsageError: Error {
    let message: String
}

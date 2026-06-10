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
            // contention on the shared SerializingHostProxy that the real
            // live pass produces — pass the same WAV to drive 2× decode
            // load on one whisper subprocess.
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
                [--out <dir>] [--recording-id <id>] [--model base|large-v3] [--no-live-diarization]
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
        let recordingId = RecordingFolder.recordingId(forName: stemName)

        // --- whisper model (resident) ---------------------------------------
        let modelName = value(after: "--model", in: args) ?? "base"
        guard let model = ModelCatalog.model(named: modelName) else {
            throw UsageError(message: "unknown model '\(modelName)'")
        }
        let modelURL = try await ModelStore(events: lifecycle.events)
            .ensureAvailable(model)
        // Live engine: whisper runs in a subprocess so a wedged decode can be
        // recovered (SIGKILL + respawn) without killing this engine — capture,
        // WAV writers, live.md, events all stay live. The parent-side
        // watchdog lives inside `RemoteWindowTranscriber`; the old in-process
        // `DecodeWatchdog` is gone (the abort_callback path it relied on is
        // structurally insufficient — see the 2026-05-26 wedge case).
        //
        // Both the system and mic streams share **one** subprocess via a
        // `SerializingHostProxy` (Phase 4-fix). The `pulsartrace-whisper`
        // binary takes a process-wide `flock` (spec §4 Layer 2), so two
        // independent subprocesses would have one exit with code 75. The
        // proxy serializes every `decode`/`startAndInitialize` call behind
        // a single `NSLock` — that lock-around-decode is the IPC equivalent
        // of the in-process `metalLock` `WhisperTranscriber` used and the
        // same single-decode-at-a-time invariant the binary's flock enforces.
        // Both `RemoteWindowTranscriber` instances are constructed with
        // `hostFactory: { _, _ in proxy }` so they share the inner host;
        // a wedge in either stream sigkills the shared inner and the
        // first follow-up decode on either transcriber respawns it.
        // See docs/specs/2026-05-26-whisper-subprocess-design.md §6/§7/§9.
        // `lockPath: <standard path>` — both live (here) and refinement
        // (`RefinementJobQueue.makeStandard`) point at the *same*
        // `~/Library/Application Support/PulsarTrace/whisper.lock`
        // because the design's single-instance invariant (spec §4 G4 /
        // Layer 2) is one whisper subprocess globally, not one per
        // workload. The mac-app's pause-for-recording dance enforces
        // mutual exclusion at the queue layer; the shared flock is the
        // OS-level backstop. Passing `nil` here used to imply "no lock,"
        // but the subprocess defaults the path internally
        // (`pulsartrace-whisper/main.swift`'s `ParsedArgs.lockPath`
        // fallback) — so this is now explicit instead of misleading.
        let whisperHostConfig = WhisperSubprocessHost.Configuration(
            binaryURL: WhisperBinaryResolver.defaultBinaryURL(),
            socketDirectory: AppPaths.standard.socketDirectory,
            lockPath: AppPaths.standard.applicationSupport
                .appendingPathComponent("whisper.lock", isDirectory: false),
            forceCPU: !WhisperOptions.defaultGPUEnabled,
            spawnTimeout: .seconds(10),
            // 180 s — generous warm-restart budget so a transient GPU /
            // CoreML stall after a wedge SIGKILL doesn't trip
            // `init refused`. See WhisperSubprocessHost.Configuration.
            initTimeout: .seconds(180))
        let sharedHostProxy = SerializingHostProxy(
            configuration: whisperHostConfig,
            logger: Logger(label: LogSubsystem.engine))
        let whisperConfig = RemoteWindowTranscriber.Configuration(
            binaryURL: WhisperBinaryResolver.defaultBinaryURL(),
            modelURL: modelURL,
            socketDirectory: AppPaths.standard.socketDirectory,
            forceCPU: !WhisperOptions.defaultGPUEnabled,
            // 10 s matches the prior in-process `DecodeWatchdog.deadline`.
            decodeDeadline: .seconds(10),
            respawnDeadline: .seconds(180))
        let sharedHostFactory: RemoteWindowTranscriber.HostFactory = { _, _ in
            sharedHostProxy
        }
        let transcriber: any WindowTranscribing = RemoteWindowTranscriber(
            configuration: whisperConfig,
            logger: Logger(label: LogSubsystem.engine),
            hostFactory: sharedHostFactory)
        let micTranscriber: (any WindowTranscribing)?
        if micSource != nil {
            micTranscriber = RemoteWindowTranscriber(
                configuration: whisperConfig,
                logger: Logger(label: LogSubsystem.engine),
                hostFactory: sharedHostFactory)
        } else {
            micTranscriber = nil
        }

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

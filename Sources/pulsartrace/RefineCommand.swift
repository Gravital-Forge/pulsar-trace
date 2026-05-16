import Foundation
import PulsarTraceEngine

/// `pulsartrace refine PATH [--model base|large-v3]` — the v0.1 offline command
/// (R48). Drives `RefinementPipeline`: an audio file or recording folder →
/// `final.md` + `metadata.json`.
///
/// Progress (R26) is reported as lightweight stderr lines. The menubar
/// consuming progress over `control.sock` is Epic 8 — for the CLI, stderr is
/// the whole progress surface.
enum RefineCommand {

    /// Parsed `refine` arguments.
    struct Options {
        let inputPath: URL
        let modelName: String
    }

    enum ArgError: Error, CustomStringConvertible {
        case missingPath
        case unknownModel(String)
        case unexpectedArgument(String)
        case missingModelValue

        var description: String {
            switch self {
            case .missingPath:
                return "refine: missing PATH argument"
            case .unknownModel(let m):
                return "refine: unknown --model '\(m)' (expected: base, large-v3)"
            case .unexpectedArgument(let a):
                return "refine: unexpected argument '\(a)'"
            case .missingModelValue:
                return "refine: --model needs a value (base or large-v3)"
            }
        }
    }

    /// Run `pulsartrace refine`. Returns the process exit code.
    ///
    /// - Parameters:
    ///   - args: arguments *after* the `refine` subcommand token.
    ///   - events: the process-wide events writer (from `AppLifecycle`).
    static func run(_ args: [String], events: EventWriter) async -> Int32 {
        let options: Options
        do {
            options = try parse(args)
        } catch {
            err("\(error)")
            err("usage: pulsartrace refine PATH [--model base|large-v3]")
            return 2
        }

        guard let model = ModelCatalog.model(named: options.modelName) else {
            err("refine: unknown model '\(options.modelName)'")
            return 2
        }

        do {
            // The whisper model must be present and verified before transcription
            // (R54c/R54d). Cached after the first run.
            err("refine: ensuring whisper model '\(model.name)' is available…")
            let modelStore = ModelStore(events: events)
            let modelURL = try await modelStore.ensureAvailable(model)

            let diarizer = try makeDiarizer()

            // Epic 5: the persistent speaker library at the standard location.
            // A failure to open it is non-fatal — refine continues with the
            // raw `Speaker_N` labels rather than aborting.
            let library = try? await SpeakerLibrary(
                databaseURL: AppPaths.standard.speakersDatabaseURL,
                events: events)
            if library == nil {
                err("refine: speaker library unavailable — using Speaker_N labels")
            }

            let pipeline = RefinementPipeline(events: events)
            let progress: RefinementPipeline.ProgressReporter = { stage in
                err("refine: \(stage.rawValue)…")
            }

            let output = try await pipeline.run(
                inputPath: options.inputPath,
                transcriberFactory: { try WhisperTranscriber(modelURL: modelURL) },
                diarizer: diarizer,
                whisperModelName: model.name,
                whisperModelSHA256: model.sha256,
                recordingStart: Date(),
                library: library,
                progress: progress)

            out("refine: wrote \(output.finalURL.path)")
            out("refine: wrote \(output.metadataURL.path)")
            let verb = output.wasReRefine ? "re-refined" : "refined"
            out("refine: \(verb) — \(output.speakers.count) speaker(s) in "
                + "\(String(format: "%.1f", output.durationSeconds))s")
            return 0
        } catch let e as RefinementPipeline.RefineError {
            err("refine: failed (\(e.errorClass)) — \(e)")
            return 1
        } catch {
            err("refine: failed — \(error)")
            return 1
        }
    }

    // MARK: - Argument parsing

    static func parse(_ args: [String]) throws -> Options {
        var path: String?
        var model = "large-v3"   // PRD default for the refine pass (R20).

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--model":
                guard i + 1 < args.count else { throw ArgError.missingModelValue }
                model = args[i + 1]
                i += 2
            case let a where a.hasPrefix("--model="):
                model = String(a.dropFirst("--model=".count))
                i += 1
            case let a where a.hasPrefix("-"):
                throw ArgError.unexpectedArgument(a)
            default:
                if path == nil {
                    path = arg
                } else {
                    throw ArgError.unexpectedArgument(arg)
                }
                i += 1
            }
        }

        guard let path else { throw ArgError.missingPath }
        guard ModelCatalog.model(named: model) != nil else {
            throw ArgError.unknownModel(model)
        }
        return Options(
            inputPath: URL(fileURLWithPath: path),
            modelName: model)
    }

    // MARK: - Diarizer wiring (dev environment)

    /// Build a `Diarizer` against the dev venv + repo `.env` (project-docs/DECISIONS.md D3/D9).
    ///
    /// Epic 10 swaps this for the bundled `python-build-standalone` runtime; the
    /// IPC boundary is identical, only this wiring changes.
    ///
    /// Robustness overrides (project-docs/DECISIONS.md D3): the repo root is otherwise the
    /// `#filePath`-derived dev-tree path baked into the binary at build time.
    /// `PULSARTRACE_REPO_ROOT`, `PULSARTRACE_VENV_PYTHON` and `HF_TOKEN`
    /// environment variables take precedence so the binary can run off a
    /// machine that is not the build host, ahead of full Epic 10 packaging.
    static func makeDiarizer() throws -> Diarizer {
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
    /// Epic 10 packaging (project-docs/DECISIONS.md D3). The `#filePath`-derived path is the
    /// dev-tree fallback: a build-machine path baked into the binary.
    private static func repoRootURL() -> URL {
        if let root = ProcessInfo.processInfo.environment["PULSARTRACE_REPO_ROOT"],
           !root.isEmpty {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: #filePath)  // …/Sources/pulsartrace/RefineCommand.swift
            .deletingLastPathComponent()        // …/Sources/pulsartrace
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

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

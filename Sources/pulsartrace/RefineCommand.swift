import Foundation
import PulsarTraceEngine

/// `pulsartrace refine PATH [--model large-v3-turbo|large-v3-whisperkit]
/// [--language CODE] [--diarize-mic on|off]` — the v0.1 offline command
/// (PT-R48). Drives
/// `RefinementPipeline`: an audio file or recording folder →
/// `final.md` + `metadata.json`.
///
/// Progress (PT-R26) is reported as lightweight stderr lines. The menubar
/// consuming progress over `control.sock` is a future addition — not built
/// here; for the CLI, stderr is the whole progress surface.
enum RefineCommand {

    /// Parsed `refine` arguments.
    struct Options {
        let inputPath: URL
        let modelName: String
        let language: String?
        /// PT-P8-R9 — the mic-diarization override, tri-state: `nil` = respect
        /// the existing stamp (default); `true`/`false` = persist that stamp to
        /// `options.json` before refining, so subsequent refines agree.
        let diarizeMicOverride: Bool?
    }

    enum ArgError: Error, CustomStringConvertible {
        case missingPath
        case unknownModel(String)
        case unknownLanguage(String)
        case missingLanguageValue
        case unexpectedArgument(String)
        case missingModelValue
        case missingDiarizeMicValue
        case invalidDiarizeMicValue(String)

        var description: String {
            switch self {
            case .missingPath:
                return "refine: missing PATH argument"
            case .unknownModel(let m):
                return "refine: unknown --model '\(m)' (expected: "
                    + WhisperKitModelCatalog.all.map(\.name).joined(separator: ", ") + ")"
            case .unknownLanguage(let c):
                return "refine: unknown --language '\(c)' (ISO-639-1, e.g. en, pl)"
            case .missingLanguageValue:
                return "refine: --language needs a value (ISO-639-1, e.g. en, pl)"
            case .unexpectedArgument(let a):
                return "refine: unexpected argument '\(a)'"
            case .missingModelValue:
                return "refine: --model needs a value ("
                    + WhisperKitModelCatalog.all.map(\.name).joined(separator: "|") + ")"
            case .missingDiarizeMicValue:
                return "refine: --diarize-mic needs a value (on|off)"
            case .invalidDiarizeMicValue(let v):
                return "refine: --diarize-mic expects on|off, got '\(v)'"
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
            err("usage: pulsartrace refine PATH [--model large-v3-turbo|large-v3-whisperkit] [--language CODE] [--diarize-mic on|off]")
            return 2
        }

        // PT-P8-R9: the override persists — subsequent refines agree with this
        // one. Written to the SAME directory the pipeline reads its
        // `options.json` stamp from (`RecordingFolder.resolve(...).directory`),
        // so the flag and the sidecar can never disagree. Omitted flag leaves
        // any existing stamp untouched.
        if let override = options.diarizeMicOverride {
            do {
                let directory = try RecordingFolder.resolve(
                    inputPath: options.inputPath).directory
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                var recordingOptions = RecordingOptions.read(from: directory)
                recordingOptions.diarizeMic = override
                try recordingOptions.write(to: directory)
            } catch {
                err("refine: could not write the mic-diarization stamp — \(error)")
                return 1
            }
        }

        do {
            // The whole refine orchestration — model prep, VAD, diarizer
            // wiring, speaker library, pipeline — lives in `OfflineRefiner`
            // so the menubar can run an identical refine in-process
            // without shelling to this CLI (PT-P2-D5).
            let refiner = OfflineRefiner(events: events, paths: .standard)
            let output = try await refiner.refine(
                inputPath: options.inputPath,
                modelName: options.modelName,
                language: options.language,
                progress: { err("refine: \($0)") })

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
        var model = WhisperKitModelCatalog.defaultModel.name
        var language: String?
        var diarizeMicOverride: Bool?

        func parseDiarizeMic(_ raw: String) throws -> Bool {
            switch raw.lowercased() {
            case "on": return true
            case "off": return false
            default: throw ArgError.invalidDiarizeMicValue(raw)
            }
        }

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
            case "--language":
                guard i + 1 < args.count else { throw ArgError.missingLanguageValue }
                language = args[i + 1]
                i += 2
            case let a where a.hasPrefix("--language="):
                language = String(a.dropFirst("--language=".count))
                i += 1
            case "--diarize-mic":
                guard i + 1 < args.count else { throw ArgError.missingDiarizeMicValue }
                diarizeMicOverride = try parseDiarizeMic(args[i + 1])
                i += 2
            case let a where a.hasPrefix("--diarize-mic="):
                diarizeMicOverride = try parseDiarizeMic(
                    String(a.dropFirst("--diarize-mic=".count)))
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
        guard WhisperKitModelCatalog.model(named: model) != nil else {
            throw ArgError.unknownModel(model)
        }
        // Validated against the language catalog.
        if let language,
           LanguageCatalog.language(forCode: language) == nil {
            throw ArgError.unknownLanguage(language)
        }
        return Options(
            inputPath: URL(fileURLWithPath: path),
            modelName: model,
            language: language?.lowercased(),
            diarizeMicOverride: diarizeMicOverride)
    }

    // MARK: - Output helpers

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

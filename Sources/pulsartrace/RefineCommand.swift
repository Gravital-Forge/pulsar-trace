import Foundation
import PulsarTraceEngine

/// `pulsartrace refine PATH [--model large-v3-turbo|large-v3-whisperkit]
/// [--language CODE]` — the v0.1 offline command (R48). Drives
/// `RefinementPipeline`: an audio file or recording folder →
/// `final.md` + `metadata.json`.
///
/// Progress (R26) is reported as lightweight stderr lines. The menubar
/// consuming progress over `control.sock` is a future addition — not built
/// here; for the CLI, stderr is the whole progress surface.
enum RefineCommand {

    /// Parsed `refine` arguments.
    struct Options {
        let inputPath: URL
        let modelName: String
        let language: String?
    }

    enum ArgError: Error, CustomStringConvertible {
        case missingPath
        case unknownModel(String)
        case unknownLanguage(String)
        case missingLanguageValue
        case unexpectedArgument(String)
        case missingModelValue

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
            err("usage: pulsartrace refine PATH [--model large-v3-turbo|large-v3-whisperkit] [--language CODE]")
            return 2
        }

        do {
            // The whole refine orchestration — model prep, VAD, diarizer
            // wiring, speaker library, pipeline — lives in `OfflineRefiner`
            // so the menubar can run an identical refine in-process
            // without shelling to this CLI (D23).
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
        // Validated against the language catalog. NOTE: until task 17
        // replaces it, the catalog type is still the CWhisper-backed
        // `WhisperLanguageCatalog`; task 16/17 swap this line to
        // `LanguageCatalog.language(forCode:)` mechanically.
        if let language,
           WhisperLanguageCatalog.language(forCode: language) == nil {
            throw ArgError.unknownLanguage(language)
        }
        return Options(
            inputPath: URL(fileURLWithPath: path),
            modelName: model,
            language: language?.lowercased())
    }

    // MARK: - Output helpers

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

import Foundation
import PulsarTraceEngine

/// `pulsartrace refine PATH [--model base|large-v3]` — the v0.1 offline command
/// (R48). Drives `RefinementPipeline`: an audio file or recording folder →
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
            // The whole refine orchestration — model fetch, VAD, diarizer
            // wiring, speaker library, pipeline — lives in `OfflineRefiner`
            // so the menubar can run an identical refine in-process
            // without shelling to this CLI (D23).
            let refiner = OfflineRefiner(events: events, paths: .standard)
            let output = try await refiner.refine(
                inputPath: options.inputPath,
                model: model,
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

    // MARK: - Output helpers

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

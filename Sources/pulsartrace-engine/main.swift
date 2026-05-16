import Foundation
import PulsarTraceEngine

/// `pulsartrace-engine` — the streaming engine binary.
///
/// Epic 1 scope: consume an `AudioFrameSource` and report a frame count.
/// Epic 2 adds `--transcribe`: run a source through `WhisperTranscriber` and
/// print the R13 markdown transcript. Whisper streaming and diarization land in
/// later epics behind the same source-consuming loop.
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
            if args.contains("--transcribe") {
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

    /// Epic 2: offline-transcribe a fixture source and render R13 markdown.
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

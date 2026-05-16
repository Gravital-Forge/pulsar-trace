import Foundation
import PulsarTraceEngine

/// `pulsartrace-engine` — the streaming engine binary.
///
/// Epic 1 scope: consume an `AudioFrameSource` and report a frame count. This
/// proves the source abstraction and the pipe path end to end. Whisper
/// streaming, diarization, and file output land in later epics behind the same
/// source-consuming loop.
///
/// Usage:
///   pulsartrace-engine --stdin            Read raw f32le PCM (16kHz mono) from stdin.
///   pulsartrace-engine --fixture <path>   Replay a WAV fixture (fast mode).
///   pulsartrace-engine --socket <path>    Read framed PCM from a Unix socket.
@main
struct EngineMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let lifecycle = await AppLifecycle.start()

        let exitCode: Int32
        do {
            let result = try await run(args: args)
            FileHandle.standardOutput.write(Data(
                ("frames=\(result.frameCount) samples=\(result.sampleCount) "
                 + "seconds=\(result.frameCount * AudioFormat.frameMilliseconds / 1000)\n")
                .utf8))
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
            // Raw f32le PCM from stdin — the `ffmpeg ... | pulsartrace-engine`
            // smoke path. stdin (fd 0) is left open for the parent.
            let source = RawPCMPipeSource(fd: FileHandle.standardInput.fileDescriptor)
            return try await consumer.consume(source)
        }
        if let path = value(after: "--fixture", in: args) {
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

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

struct UsageError: Error {
    let message: String
}

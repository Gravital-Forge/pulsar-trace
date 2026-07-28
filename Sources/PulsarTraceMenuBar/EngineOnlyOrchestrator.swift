import Foundation
import PulsarTraceEngine

/// Drives a fixture-capture session (PT-R127): spawns only
/// `pulsartrace-engine` — no capture daemon, no `ready` handshake — and
/// conforms to `RecordingOrchestrating` so `RecordingViewModel` treats a
/// fixture session exactly like a device session. The engine exits on its
/// own at fixture EOF; the view model turns that into a clean stop.
// PT-R127
public actor EngineOnlyOrchestrator: RecordingOrchestrating {

    private let engineBinary: URL
    private let engineArguments: [String]
    private var engine: Process?
    private var exitTask: Task<Int32, Never>?

    public init(engineBinary: URL, engineArguments: [String]) {
        self.engineBinary = engineBinary
        self.engineArguments = engineArguments
    }

    /// Launch the engine. `readyTimeout` is unused — there is no capture
    /// handshake to wait for.
    public func start(readyTimeout: Duration) async throws {
        let process = Process()
        process.executableURL = engineBinary
        process.arguments = engineArguments
        // stdio → /dev/null: an undrained pipe blocks the child in write()
        // once full; the engine's file log is the observable channel.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { proc in
            continuation.yield(proc.terminationStatus)
            continuation.finish()
        }
        do {
            try process.run()
        } catch {
            throw RecordOrchestrator.StartError.engineLaunchFailed("\(error)")
        }
        engine = process
        exitTask = Task {
            var code: Int32 = -1
            for await c in stream { code = c }
            return code
        }
    }

    public func waitForEngineExit() async {
        _ = await exitTask?.value
    }

    public func isEngineRunning() async -> Bool {
        engine?.isRunning ?? false
    }

    public func stop() async {
        if let engine, engine.isRunning {
            engine.terminate()
        }
        _ = await exitTask?.value
    }
}

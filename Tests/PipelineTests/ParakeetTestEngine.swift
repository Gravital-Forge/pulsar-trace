import Logging
@testable import PulsarTraceEngine

/// One resident Parakeet engine per test process, shared by every
/// PipelineTests suite that needs a real live decode (ParakeetTranscriber,
/// StreamingPipeline, IPCTwoDaemon, and LiveRunnerResilience).
/// Memoizing the Task (not the engine) makes a
/// second concurrent first-caller await the in-flight load instead of
/// racing a duplicate ~0.5 GB download.
enum ParakeetTestEngine {
    private static let task = Task<ParakeetEngine, Error> {
        try await ParakeetEngine.load(
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            events: nil,
            logger: Logger(label: "test.parakeet"))
    }

    static func shared() async throws -> ParakeetEngine {
        try await task.value
    }
}

import Logging
@testable import PulsarTraceEngine

/// One resident diarizer engine per test process, shared by every
/// DiarizationE2E suite. Memoizing the Task (not the engine) makes a second
/// concurrent first-caller await the in-flight load instead of racing a
/// duplicate model download. First run downloads the `speaker-diarization`
/// bundles (~21 MB) into the standard cache root — subsequent runs are
/// offline.
enum DiarizerTestEngine {
    private static let task = Task<DiarizerEngine, Error> {
        try await DiarizerEngine.load(
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            events: nil,
            logger: Logger(label: "test.diarizer"))
    }

    static func shared() async throws -> DiarizerEngine {
        try await task.value
    }
}

import Testing
import Foundation
@testable import PulsarTraceEngine

/// End-to-end: spawn the REAL `pulsartrace-engine --diarizer-worker`, diarize a
/// window of silence, and confirm a result comes back. Gated on the built
/// engine binary + diarizer model cache being present (loads real CoreML).
@Suite("DiarWorker integration (real worker process)", .serialized)
struct DiarWorkerIntegrationTests {
    private var enginePath: URL? {
        // .build/debug/pulsartrace-engine relative to the package root.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let p = cwd.appendingPathComponent(".build/debug/pulsartrace-engine")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
    private var modelsReady: Bool {
        let dir = AppPaths.standard.modelsCacheDirectory.appendingPathComponent("speaker-diarization")
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Embedding.mlmodelc").path)
    }

    @Test("real worker returns a result for a window of audio",
          .enabled(if: ProcessInfo.processInfo.environment["PT_DIAR_WORKER_E2E"] == "1"))
    func realWorkerRoundTrip() async throws {
        guard let enginePath, modelsReady else { return }
        let socketURL = AppPaths.standard.diarizerSocketURL(recordingId: "itest-\(UUID().uuidString.prefix(8))")
        let launcher = DiarWorkerProcessLauncher(
            socketURL: socketURL,
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            executableURL: enginePath)
        let client = DiarWorkerClient(launcher: launcher, deadline: .seconds(20))
        await client.start()
        #expect(await client.modelRevision().isEmpty == false)
        // 10 s of silence at 16 kHz → a valid (likely empty) result, not nil.
        let window = [Float](repeating: 0, count: 16_000 * 10)
        let result = await client.diarizeRawWindow(samples: window)
        #expect(result != nil)
        await client.shutdown()
    }
}

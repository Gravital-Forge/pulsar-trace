import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 4: IPC integration tests (R67a, §12 "Layer 4").
///
/// The `capture.sock` binary frame protocol is a contract that in-process
/// `Pipeline` tests skip. These tests put a real Unix domain socket between a
/// fixture-driven writer (`FixtureSocketServer` — standing in for what
/// `pulsartrace-capture` would write) and a `SocketSource` consumer, and assert
/// the engine sees the same frame count as the in-process pipeline does.
///
/// The type is named `Pipeline_IPC_Tests` so `swift test --filter Pipeline.IPC`
/// selects exactly these tests — the `--filter` regex matches the test type
/// name, and `Pipeline.IPC` (`.` = any one char) matches `Pipeline_IPC_Tests`.
///
/// The suite is `.serialized`: each test stands up real sockets and background
/// reader/writer threads, and POSIX file descriptors are a process-wide
/// resource — running these in parallel lets one test's fd churn race another's
/// `socket()`/`close()`. Serializing keeps them deterministic.
@Suite("Pipeline IPC integration", .serialized)
struct Pipeline_IPC_Tests {

    /// A short-lived socket path under the temp directory.
    private func tempSocketPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ipc-\(UUID().uuidString).sock")
    }

    @Test("SocketSource over a real UDS matches the in-process frame count")
    func socketMatchesInProcess() async throws {
        let fixture = FixtureLocator.audio("single-speaker-30s.wav")

        // In-process baseline.
        let inProcess = try await FrameConsumer().consume(
            FixturePlaybackSource(file: fixture, realtime: false)).frameCount

        // Over a real socket.
        let socketPath = tempSocketPath()
        let server = try FixtureSocketServer(socketPath: socketPath, wavURL: fixture)
        try server.start()
        defer { server.stop() }

        let source = SocketSource(socketPath: socketPath)
        try await source.start()
        // `start()` has connected; wait until the server thread is past
        // `accept()` so it is guaranteed to be serving frames before the
        // consumer reads — closes a real thread-scheduling race that could
        // otherwise yield a premature EOF.
        server.waitForAccept()
        let overSocket = try await FrameConsumer().consume(source).frameCount

        #expect(overSocket == inProcess)
    }

    @Test("SocketSource terminates cleanly on the end-of-stream sentinel")
    func socketCleanTermination() async throws {
        let fixture = FixtureLocator.audio("sine-440hz-5s.wav")
        let socketPath = tempSocketPath()
        let server = try FixtureSocketServer(socketPath: socketPath, wavURL: fixture)
        try server.start()
        defer { server.stop() }

        let source = SocketSource(socketPath: socketPath)
        try await source.start()
        server.waitForAccept()
        let result = try await FrameConsumer().consume(source)
        #expect(result.frameCount == 250)  // 5 s / 20 ms
    }

    @Test("Connecting to a missing socket fails cleanly")
    func socketConnectFailure() async {
        let source = SocketSource(socketPath: tempSocketPath())
        await #expect(throws: SocketSource.SocketError.self) {
            try await source.start()
        }
    }

    @Test("Frame protocol bytes from the server decode back to PCM")
    func socketFrameBytesDecode() async throws {
        let fixture = FixtureLocator.audio("sine-440hz-5s.wav")
        let socketPath = tempSocketPath()
        let server = try FixtureSocketServer(socketPath: socketPath, wavURL: fixture)
        try server.start()
        defer { server.stop() }

        let source = SocketSource(socketPath: socketPath)
        try await source.start()
        server.waitForAccept()

        var firstFrameSamples: [Float]?
        for try await event in source {
            if case .frame(let frame) = event {
                firstFrameSamples = frame.samples
                break
            }
        }
        await source.stop()
        #expect(firstFrameSamples?.count == AudioFormat.samplesPerFrame)
    }
}

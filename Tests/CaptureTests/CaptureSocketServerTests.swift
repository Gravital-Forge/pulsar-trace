import Testing
import Foundation
@testable import PulsarTraceCapture
@testable import PulsarTraceEngine

/// Unit coverage of `CaptureSocketServer` — the capture-daemon socket writer.
/// No audio devices: events are enqueued directly and read back through the
/// engine's real `SocketSource`, exercising the full wire round-trip.
@Suite("CaptureSocketServer")
struct CaptureSocketServerTests {

    @Test("Frames and pause/resume control events round-trip to a SocketSource")
    func roundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = CaptureSocketServer(
            socketPath: dir.appendingPathComponent("cap.sock"))
        try server.start()

        // The engine connects while the server is listening but not yet
        // accepting — the connection waits in the listen backlog.
        let source = SocketSource(
            socketPath: dir.appendingPathComponent("cap.sock"))
        try await source.start()
        server.beginServing()

        func frame(_ value: Float) -> AudioFrame {
            AudioFrame(
                samples: [Float](repeating: value, count: 320),
                sequenceIndex: 0)
        }
        server.enqueue(.frame(frame(0.1)))
        server.enqueue(.frame(frame(0.2)))
        server.enqueue(.paused)
        server.enqueue(.resumed(gap: .milliseconds(2500)))
        server.enqueue(.frame(frame(0.3)))
        server.finish()

        var events: [AudioStreamEvent] = []
        for try await event in source { events.append(event) }
        server.stop()

        #expect(events.count == 5)
        guard events.count == 5 else { return }
        if case .frame(let f) = events[0] { #expect(f.samples.first == 0.1) }
        else { Issue.record("event 0 should be a frame") }
        #expect(events[2] == .paused)
        #expect(events[3] == .resumed(gap: .milliseconds(2500)))
        if case .frame(let f) = events[4] { #expect(f.samples.first == 0.3) }
        else { Issue.record("event 4 should be a frame") }
    }

    @Test("A consumer that disconnects early does not crash the server")
    func consumerDisconnect() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = CaptureSocketServer(
            socketPath: dir.appendingPathComponent("cap.sock"))
        try server.start()
        let source = SocketSource(
            socketPath: dir.appendingPathComponent("cap.sock"))
        try await source.start()
        server.beginServing()

        // Drop the consumer immediately, then keep enqueueing. SO_NOSIGPIPE
        // turns the broken pipe into an EPIPE the write loop absorbs.
        await source.stop()
        for i in 0..<1000 {
            server.enqueue(.frame(AudioFrame(
                samples: [Float](repeating: Float(i), count: 320),
                sequenceIndex: i)))
        }
        server.finish()
        server.stop()  // returns cleanly — the process is still alive
    }
}

import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 4 — IPC integration for the real-capture path, with no audio
/// devices. Two concerns the in-process Pipeline tests do not exercise:
///
/// 1. **Two-socket consumption** — the engine reads a system stream *and* a
///    paired mic stream, each from its own Unix domain socket, exactly as it
///    would from `pulsartrace-capture`. `FixtureSocketServer` stands in for the
///    daemon (it writes the identical `FrameProtocol` bytes).
/// 2. **Pause/resume propagation** — a `.paused` / `.resumed` control event in
///    the audio stream (capture daemon sleep/wake, R7) reaches `live.md` as a
///    gap annotation.
///
/// `.serialized`: one resident ANE model serves the whole process
/// (`ParakeetTestEngine`).
@Suite("Capture IPC integration", .serialized)
struct IPCTwoDaemonTests {

    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ipc7-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A short socket path directly under the temp directory. Unix domain
    /// socket paths have a ~104-byte limit, so they cannot nest under a
    /// long per-test UUID folder.
    private func tempSocketPath(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pt7\(tag)-\(UUID().uuidString).sock")
    }

    private var fixedStart: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 16; c.hour = 14; c.minute = 30
        return Calendar.current.date(from: c)!
    }

    @Test("the live pass consumes a system socket and a paired mic socket")
    func twoSocketLivePass() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let systemSocket = tempSocketPath("s")
        let micSocket = tempSocketPath("m")
        let systemServer = try FixtureSocketServer(
            socketPath: systemSocket,
            wavURL: FixtureLocator.audio("mic-and-system-paired/system.wav"))
        let micServer = try FixtureSocketServer(
            socketPath: micSocket,
            wavURL: FixtureLocator.audio("mic-and-system-paired/mic.wav"))
        try systemServer.start()
        try micServer.start()
        defer { systemServer.stop(); micServer.stop() }

        let systemSource = SocketSource(socketPath: systemSocket)
        let micSource = SocketSource(socketPath: micSocket)
        try await systemSource.start()
        try await micSource.start()

        let engine = try await ParakeetTestEngine.shared()
        let output = try await StreamingPipeline().run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_ipc-two-socket",
                liveDiarizerConfig: nil),
            systemTranscriber: ParakeetWindowTranscriber(engine: engine),
            micTranscriber: ParakeetWindowTranscriber(engine: engine),
            systemSource: systemSource,
            micSource: micSource,
            library: nil)

        // The engine read both sockets and produced a well-formed live.md.
        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "<!-- pulsartrace:live -->")
        #expect(lines[1].hasPrefix("## Transcript — "))
        #expect(output.utteranceLines > 0)
        // The mic stream's utterances are labelled `You` (R17).
        #expect(text.contains("You:**"))
    }

    @Test("a paused/resumed control event in the stream annotates live.md (R7)")
    func pauseResumeGapAnnotation() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A scripted system stream: a little audio, a pause, a resume after a
        // 2m 05s gap, then a little more audio.
        func silence(_ count: Int, from: Int) -> [AudioStreamEvent] {
            (0..<count).map { i in
                .frame(AudioFrame(
                    samples: [Float](repeating: 0, count: 320),
                    sequenceIndex: from + i))
            }
        }
        var events = silence(50, from: 0)
        events.append(.paused)
        events.append(.resumed(gap: .seconds(125)))
        events += silence(50, from: 50)

        let engine = try await ParakeetTestEngine.shared()
        let output = try await StreamingPipeline().run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_ipc-pause-resume",
                liveDiarizerConfig: nil),
            systemTranscriber: ParakeetWindowTranscriber(engine: engine),
            systemSource: ScriptedSource(events),
            library: nil)

        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        #expect(text.contains("_(recording paused)_"))
        #expect(text.contains("_(recording resumed after 2m 05s)_"))
        // The pause note precedes the resume note (causal order).
        if let pause = text.range(of: "_(recording paused)_"),
           let resume = text.range(of: "_(recording resumed") {
            #expect(pause.lowerBound < resume.lowerBound)
        } else {
            Issue.record("both gap annotations should be present")
        }
    }
}

/// A test `AudioFrameSource` that replays an explicit, scripted sequence of
/// `AudioStreamEvent`s — including `.paused` / `.resumed` control events that
/// no fixture WAV can produce.
final class ScriptedSource: AudioFrameSource, @unchecked Sendable {
    typealias Element = AudioStreamEvent

    private let events: [AudioStreamEvent]

    init(_ events: [AudioStreamEvent]) {
        self.events = events
    }

    func start() async throws {}
    func stop() async {}

    func makeAsyncIterator() -> Iterator {
        Iterator(events: events)
    }

    struct Iterator: AsyncIteratorProtocol {
        let events: [AudioStreamEvent]
        var index = 0

        mutating func next() async -> AudioStreamEvent? {
            guard index < events.count else { return nil }
            defer { index += 1 }
            return events[index]
        }
    }
}

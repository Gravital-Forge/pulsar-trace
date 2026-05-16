import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the `control.sock` JSON-line control protocol codec (§17).
@Suite("ControlProtocol")
struct ControlProtocolTests {

    @Test("start command round-trips through encode/decode")
    func startCommandRoundTrip() throws {
        let req = ControlProtocol.StartRequest(
            outputDirBasename: "2026-04-30-standup",
            systemAudioEnabled: true,
            modelLive: "base")
        let command = ControlProtocol.Command.start(req)
        let line = try ControlProtocol.encode(command)
        #expect(line.hasSuffix("\n"))
        let decoded = try ControlProtocol.decodeCommand(line)
        #expect(decoded == command)
    }

    @Test("stop command round-trips")
    func stopCommandRoundTrip() throws {
        let line = try ControlProtocol.encode(.stop)
        #expect(try ControlProtocol.decodeCommand(line) == .stop)
    }

    @Test("progress event round-trips")
    func progressEventRoundTrip() throws {
        let event = ControlProtocol.Event.progress(
            ControlProtocol.Progress(stage: "transcribing", fraction: 0.42))
        let line = try ControlProtocol.encode(event)
        #expect(try ControlProtocol.decodeEvent(line) == event)
    }

    @Test("status event round-trips")
    func statusEventRoundTrip() throws {
        let event = ControlProtocol.Event.status(
            ControlProtocol.Status(state: "running", framesProcessed: 1500))
        let line = try ControlProtocol.encode(event)
        #expect(try ControlProtocol.decodeEvent(line) == event)
    }

    @Test("error event round-trips")
    func errorEventRoundTrip() throws {
        let event = ControlProtocol.Event.error(message: "stream failed")
        let line = try ControlProtocol.encode(event)
        #expect(try ControlProtocol.decodeEvent(line) == event)
    }

    @Test("Each encoded message is exactly one line")
    func singleLinePerMessage() throws {
        let line = try ControlProtocol.encode(.status)
        #expect(line.filter { $0 == "\n" }.count == 1)
    }
}

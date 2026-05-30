import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("WindowTranscribing seam")
struct WindowTranscribingTests {

    /// A stub conforming to the seam — proves the protocol exists and is usable
    /// without a real whisper context.
    final class StubWindowTranscriber: WindowTranscribing, @unchecked Sendable {
        func transcribeWindow(
            _ samples: [Float],
            windowStart: Duration,
            options: WhisperOptions,
            abort: AbortToken?
        ) throws -> TranscriptionResult {
            TranscriptionResult(
                segments: [TranscriptSegment(
                    start: windowStart, end: windowStart, text: "stub")],
                language: "en")
        }
    }

    @Test("a stub can stand in for the window transcriber")
    func stubConforms() throws {
        let stub: any WindowTranscribing = StubWindowTranscriber()
        let result = try stub.transcribeWindow(
            [0.1, 0.2], windowStart: .seconds(1), options: .init(), abort: nil)
        #expect(result.segments.first?.text == "stub")
    }
}

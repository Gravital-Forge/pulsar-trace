import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("TranscriptAssembly refine-side mic-echo dedup (PT-P8-R11)")
struct TranscriptAssemblyDedupTests {

    private static let start = Date(timeIntervalSince1970: 1_777_000_000)

    private func seg(_ text: String, _ s: Double, _ e: Double) -> TranscriptSegment {
        TranscriptSegment(start: .seconds(s), end: .seconds(e), text: text)
    }

    @Test("a mic segment duplicating a system segment inside the window is dropped")
    func echoDropped() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [seg("let's review the quarterly numbers now", 10, 13)],
            diarization: nil,
            reconciliation: nil,
            micSegments: [seg("let's review the quarterly numbers now", 11, 14)],
            recordingStart: Self.start)
        // Only the system row survives; no "You" line was minted for the echo.
        #expect(!merged.document.speakerLabels.contains("You"))
    }

    @Test("a distinct mic segment inside the window is kept")
    func distinctMicKept() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [seg("let's review the quarterly numbers now", 10, 13)],
            diarization: nil,
            reconciliation: nil,
            micSegments: [seg("I have a question about the forecast", 11, 14)],
            recordingStart: Self.start)
        #expect(merged.document.speakerLabels.contains("You"))
    }

    @Test("a duplicate outside the ±5 s window is kept")
    func outsideWindowKept() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [seg("let's review the quarterly numbers now", 10, 13)],
            diarization: nil,
            reconciliation: nil,
            micSegments: [seg("let's review the quarterly numbers now", 30, 33)],
            recordingStart: Self.start)
        #expect(merged.document.speakerLabels.contains("You"))
    }

    @Test("with no system segments every mic segment passes through")
    func noSystemPassthrough() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [],
            diarization: nil,
            reconciliation: nil,
            micSegments: [seg("solo note to self", 0, 2)],
            recordingStart: Self.start)
        #expect(merged.document.speakerLabels.contains("You"))
    }
}

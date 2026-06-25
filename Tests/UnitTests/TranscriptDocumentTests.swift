import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the PT-R13 transcript markdown format.
@Suite("TranscriptDocument (PT-R13)")
struct TranscriptDocumentTests {

    /// A fixed wall-clock start so the header is deterministic in tests.
    private static let start = Date(timeIntervalSince1970: 1_777_000_000)
    // 1_777_000_000 → 2026-04-23 in UTC.

    @Test("Offset stamp is HH:MM:SS seconds-since-start")
    func offsetStampFormat() {
        #expect(TranscriptDocument.offsetStamp(.seconds(0)) == "00:00:00")
        #expect(TranscriptDocument.offsetStamp(.seconds(5)) == "00:00:05")
        #expect(TranscriptDocument.offsetStamp(.seconds(65)) == "00:01:05")
        #expect(TranscriptDocument.offsetStamp(.seconds(3661)) == "01:01:01")
    }

    @Test("Offset stamp handles recordings longer than 4 hours")
    func offsetStampLongRecording() {
        // 4h 12m 33s — the hours field simply grows, no wraparound.
        let offset = Duration.seconds(4 * 3600 + 12 * 60 + 33)
        #expect(TranscriptDocument.offsetStamp(offset) == "04:12:33")
    }

    @Test("Negative offset clamps to zero")
    func offsetStampNegative() {
        #expect(TranscriptDocument.offsetStamp(.seconds(-10)) == "00:00:00")
    }

    @Test("Document renders the PT-R13 marker + header + utterance lines")
    func rendersR13Format() {
        let doc = TranscriptDocument(
            recordingStart: Self.start,
            segments: [
                TranscriptSegment(start: .seconds(5), end: .seconds(9),
                                  text: "So the main issue is the auth flow."),
                TranscriptSegment(start: .seconds(12), end: .seconds(18),
                                  text: "Right, the redirect URI isn't handled."),
            ]
        )
        let md = doc.render()
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines[0] == "<!-- pulsartrace:final -->")
        #expect(lines[1].hasPrefix("## Transcript — "))
        #expect(lines[2] == "")
        #expect(lines[3] == "**[00:00:05] Speaker:** So the main issue is the auth flow.")
        #expect(lines[4] == "**[00:00:12] Speaker:** Right, the redirect URI isn't handled.")
    }

    @Test("the transcription pass uses the single placeholder speaker label for every line")
    func placeholderSpeaker() {
        let doc = TranscriptDocument(
            recordingStart: Self.start,
            segments: [
                TranscriptSegment(start: .seconds(0), end: .seconds(1), text: "one"),
                TranscriptSegment(start: .seconds(2), end: .seconds(3), text: "two"),
            ]
        )
        for line in doc.render().split(separator: "\n") where line.hasPrefix("**[") {
            #expect(line.contains("] Speaker:**"))
        }
    }

    @Test("Document ends with a trailing newline")
    func trailingNewline() {
        let doc = TranscriptDocument(
            recordingStart: Self.start,
            segments: [TranscriptSegment(start: .zero, end: .seconds(1), text: "x")]
        )
        #expect(doc.render().hasSuffix("\n"))
    }

    @Test("Empty transcript still renders marker + header")
    func emptyTranscript() {
        let doc = TranscriptDocument(recordingStart: Self.start, segments: [])
        let lines = doc.render().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "<!-- pulsartrace:final -->")
        #expect(lines[1].hasPrefix("## Transcript — "))
    }
}

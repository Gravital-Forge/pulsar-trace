import Testing
@testable import PulsarTraceEngine

@Suite("ParakeetTokenMapper")
struct ParakeetTokenMapperTests {

    private func tok(_ piece: String, _ start: Double, _ end: Double)
        -> ParakeetTokenMapper.InputToken {
        .init(token: piece, start: start, end: end)
    }

    @Test func groupsSentencePiecesIntoWords() {
        // "▁Hello ▁wor ld ." → words "Hello", "world." (punctuation piece
        // glues onto the current word, exactly as SentencePiece intends).
        let result = ParakeetTokenMapper.transcriptionResult(
            tokens: [
                tok("▁Hello", 0.10, 0.40),
                tok("▁wor", 0.55, 0.70),
                tok("ld", 0.70, 0.85),
                tok(".", 0.85, 0.90),
            ],
            fallbackText: "Hello world.",
            windowStart: .seconds(2),
            windowDuration: .seconds(4))
        #expect(result.segments.map(\.text) == ["Hello", "world."])
        // Recording-absolute: window-relative times shifted by windowStart.
        #expect(result.segments[0].start == .milliseconds(2100))
        #expect(result.segments[0].end == .milliseconds(2400))
        #expect(result.segments[1].start == .milliseconds(2550))
        #expect(result.segments[1].end == .milliseconds(2900))
        // Parakeet reports no language; "unknown" never overwrites a real
        // detected language upstream (StreamingTranscriber contract).
        #expect(result.language == "unknown")
    }

    @Test func leadingPieceWithoutWordMarkerStartsAWord() {
        let result = ParakeetTokenMapper.transcriptionResult(
            tokens: [tok("Hel", 0, 0.2), tok("lo", 0.2, 0.4)],
            fallbackText: "Hello",
            windowStart: .zero,
            windowDuration: .seconds(1))
        #expect(result.segments.map(\.text) == ["Hello"])
    }

    @Test func emptyTokensFallsBackToWholeWindowSegment() {
        let result = ParakeetTokenMapper.transcriptionResult(
            tokens: [],
            fallbackText: "Some text without timings",
            windowStart: .seconds(10),
            windowDuration: .seconds(4))
        #expect(result.segments == [TranscriptSegment(
            start: .seconds(10), end: .seconds(14),
            text: "Some text without timings")])
    }

    @Test func emptyEverythingYieldsNoSegments() {
        let result = ParakeetTokenMapper.transcriptionResult(
            tokens: [], fallbackText: "  ",
            windowStart: .zero, windowDuration: .seconds(4))
        #expect(result.segments.isEmpty)
    }

    @Test func whitespaceOnlyWordsAreDropped() {
        let result = ParakeetTokenMapper.transcriptionResult(
            tokens: [tok("▁", 0, 0.1), tok("▁Hi", 0.2, 0.3)],
            fallbackText: "Hi",
            windowStart: .zero, windowDuration: .seconds(1))
        #expect(result.segments.map(\.text) == ["Hi"])
    }
}

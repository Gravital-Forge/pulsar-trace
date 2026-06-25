> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 04: ParakeetTokenMapper (pure)

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetTokenMapper.swift`
- Test: `Tests/UnitTests/ParakeetTokenMapperTests.swift`

Design note: the mapper takes its **own** input struct (not FluidAudio's `TokenTiming`, whose memberwise init may not be public) so unit tests fabricate inputs freely; `ParakeetEngine` adapts `TokenTiming` → `InputToken` in one line (task 06). One `TranscriptSegment` **per word** gives `LiveAgreementCommitter` exact per-word timing (its `tokens(from:start:end:)` splits a segment's text on whitespace and spreads the span evenly — a single-word segment makes that exact).

- [ ] **Step 1: Write the failing tests**

`Tests/UnitTests/ParakeetTokenMapperTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ParakeetTokenMapper` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — `cannot find 'ParakeetTokenMapper' in scope`.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetTokenMapper.swift`:

```swift
import Foundation

/// Maps Parakeet TDT token timings to PulsarTrace `TranscriptSegment`s.
///
/// Parakeet (via FluidAudio) returns SentencePiece pieces with per-token
/// timestamps; a piece starting with `"▁"` (U+2581) begins a new word. The
/// mapper emits **one segment per word**, carrying the word's real start/end.
/// `LiveAgreementCommitter.tokens(from:start:end:)` splits segment text on
/// whitespace and spreads the span evenly across words — single-word
/// segments make that exact, so the committer gets Parakeet's true word
/// timing and the streaming anchor advances precisely.
///
/// Pure and synchronous: the FluidAudio types stay out of the signature
/// (`InputToken` mirrors `TokenTiming`) so unit tests fabricate inputs
/// without loading any model.
public enum ParakeetTokenMapper {

    /// One SentencePiece piece with its time span, window-relative seconds.
    /// Mirrors FluidAudio's `TokenTiming` (`token`, `startTime`, `endTime`).
    public struct InputToken: Sendable, Equatable {
        public let token: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(token: String, start: TimeInterval, end: TimeInterval) {
            self.token = token
            self.start = start
            self.end = end
        }
    }

    /// The SentencePiece word-boundary marker (U+2581 LOWER ONE EIGHTH BLOCK).
    static let wordMarker: Character = "\u{2581}"

    public static func transcriptionResult(
        tokens: [InputToken],
        fallbackText: String,
        windowStart: Duration,
        windowDuration: Duration
    ) -> TranscriptionResult {
        guard !tokens.isEmpty else {
            // No per-token timing (FluidAudio's `tokenTimings` is optional):
            // fall back to one window-spanning segment so text is never lost.
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return TranscriptionResult(segments: [], language: "unknown")
            }
            return TranscriptionResult(
                segments: [TranscriptSegment(
                    start: windowStart,
                    end: windowStart + windowDuration,
                    text: text)],
                language: "unknown")
        }

        struct Word {
            var pieces: [String] = []
            var start: TimeInterval
            var end: TimeInterval
            var text: String { pieces.joined() }
        }

        var words: [Word] = []
        for piece in tokens {
            var text = piece.token
            let startsWord = text.first == wordMarker
            if startsWord { text.removeFirst() }
            if startsWord || words.isEmpty {
                words.append(Word(pieces: [text], start: piece.start, end: piece.end))
            } else {
                words[words.count - 1].pieces.append(text)
                words[words.count - 1].end = piece.end
            }
        }

        let segments: [TranscriptSegment] = words.compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: windowStart + .milliseconds(Int((word.start * 1000).rounded())),
                end: windowStart + .milliseconds(Int((word.end * 1000).rounded())),
                text: text)
        }
        // Parakeet has no language-ID output; "unknown" is the contract value
        // StreamingTranscriber treats as "no information".
        return TranscriptionResult(segments: segments, language: "unknown")
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ParakeetTokenMapper`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetTokenMapper.swift Tests/UnitTests/ParakeetTokenMapperTests.swift
git commit -m "feat(live): ParakeetTokenMapper — SentencePiece timings to per-word segments"
```

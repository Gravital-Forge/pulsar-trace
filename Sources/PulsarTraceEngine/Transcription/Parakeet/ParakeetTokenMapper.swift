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
            // The leading marker decides the word boundary, but strip ALL
            // markers: U+2581 is category So (a symbol), not whitespace, so the
            // later `.whitespacesAndNewlines` trim won't catch a stray one and
            // a piece like "▁▁foo" would leak a block glyph into the text.
            text.removeAll { $0 == wordMarker }
            if startsWord || words.isEmpty {
                words.append(Word(pieces: [text], start: piece.start, end: piece.end))
            } else {
                words[words.count - 1].pieces.append(text)
                // Keep the word span monotonic: a continuation piece whose `end`
                // precedes the word's current `end` must not shrink/invert it.
                words[words.count - 1].end = max(words[words.count - 1].end, piece.end)
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

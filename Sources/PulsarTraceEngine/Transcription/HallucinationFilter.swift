import Foundation

/// Drops whisper's silence hallucinations from the **offline / refine**
/// transcription path (project-docs/DECISIONS.md D31).
///
/// `BlankTokenFilter` already removes bracketed non-speech markers and the
/// unambiguous YouTube-only stock phrases (`"thanks for watching"`,
/// `"please subscribe"`, …) — and it does so on the *text alone*, which is
/// safe because no real meeting says them. But whisper also hallucinates
/// phrases that *are* legitimate meeting utterances — most commonly a
/// confidently-decoded `"Thank you."` — over a near-silent stretch of the
/// system-audio stream. `BlankTokenFilter` deliberately keeps `"Thank you."`
/// so a real person saying it survives, so a hallucinated one slips through
/// and lands in `final.md` with an `Unrecognized` label (it matches no
/// diarization span — see `DiarizationMerge.unknownSpeaker`).
///
/// This filter closes that gap **without ever dropping a real utterance**: it
/// drops a segment only when *both*
///   1. its normalized text matches a known stock hallucination phrase, AND
///   2. an objective per-segment signal says the underlying audio is
///      silence / non-speech — a high whisper `no_speech_prob`, or a very low
///      average token log-probability (the decoder was guessing).
///
/// A genuine "Thank you." spoken into a live microphone decodes with a low
/// `no_speech_prob` and a healthy avg logprob, so it fails gate (2) and is
/// always kept. The phrase text alone never causes a drop.
///
/// Scope: offline only. The streaming `transcribeWindow` path is left
/// unchanged — it VAD-gates short windows upstream so the silent-window
/// failure mode cannot arise, and LocalAgreement-2 must see every committed
/// token (D31 records this scoping rationale).
enum HallucinationFilter {

    /// Per-segment decoder confidence signals whisper exposes for one segment.
    struct SegmentConfidence: Equatable {
        /// whisper's `no_speech_prob` for the segment: probability in [0, 1]
        /// that the audio under the segment is non-speech. High → silence.
        let noSpeechProb: Float
        /// Mean per-token log-probability across the segment's tokens
        /// (≤ 0; closer to 0 is more confident). A very negative value means
        /// the decoder was guessing — a hallmark of a hallucinated segment.
        let avgLogProb: Float
    }

    /// `no_speech_prob` at or above this is treated as silence. whisper's own
    /// pre-filter uses `no_speech_thold = 0.6` to *reject* a segment outright;
    /// by the time a segment reaches us it already passed that bar, so a
    /// stricter 0.6 here would never fire. We instead pair a *lower* bar with
    /// the phrase-match: a segment that is both a stock phrase AND sits in the
    /// `0.30…0.60` grey zone whisper let through is almost certainly a
    /// silence hallucination. Genuine speech sits well below 0.30.
    static let noSpeechProbThreshold: Float = 0.30

    /// Average token log-probability at or below this marks a low-confidence
    /// decode. Genuine speech on the offline path decodes around -0.4…-0.1;
    /// a hallucinated stock phrase on silence is far more negative. The bar
    /// is deliberately conservative so a real utterance never trips it.
    static let avgLogProbThreshold: Float = -0.80

    /// Normalized stock phrases whisper hallucinates over silence. These are
    /// matched ONLY in combination with an objective silence signal (see
    /// `shouldDrop`); on their own they are legitimate meeting utterances and
    /// must never be dropped on text alone.
    ///
    /// Stored already-normalized (lowercase, no surrounding punctuation /
    /// whitespace) — compare against `normalize(_:)` output.
    static let stockPhrases: Set<String> = [
        "thank you",
        "thank you so much",
        "thanks",
        "thank you very much",
        "thank you for watching",
        "thanks for watching",
        "thank you for watching this video",
        "please subscribe",
        "please subscribe to my channel",
        "you",
        "bye",
        "bye bye",
        "okay",
        "thanks for listening",
    ]

    /// Lowercase, trim whitespace, and strip surrounding punctuation so
    /// `"Thank you."`, `" thank you "`, and `"thank you!"` all normalize to
    /// `"thank you"`. Interior punctuation/spacing is left intact.
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuationAndSpace = CharacterSet(charactersIn: " \t\n.!?,;:-—\"'")
        return trimmed
            .lowercased()
            .trimmingCharacters(in: punctuationAndSpace)
    }

    /// True when `text` is a known stock hallucination phrase **and** the
    /// per-segment confidence signals indicate the underlying audio is
    /// silence / a low-confidence guess.
    ///
    /// Dropping requires BOTH conditions — a phrase match alone never drops a
    /// segment, so a real person saying "Thank you." (low `no_speech_prob`,
    /// healthy `avgLogProb`) is provably safe.
    static func shouldDrop(text: String, confidence: SegmentConfidence) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        guard stockPhrases.contains(normalized) else { return false }

        // Objective silence / low-confidence gate. Either signal firing is
        // enough — both target the same "the decoder was looking at silence"
        // condition from different angles.
        let looksLikeSilence =
            confidence.noSpeechProb >= noSpeechProbThreshold
            || confidence.avgLogProb <= avgLogProbThreshold
        return looksLikeSilence
    }
}

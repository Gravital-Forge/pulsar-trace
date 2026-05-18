import Foundation

/// LocalAgreement-2 commit logic for streaming transcription (R10).
///
/// The streaming path runs whisper repeatedly on overlapping windows of recent
/// audio. Each run produces a *hypothesis* — the best transcript whisper can
/// give for that window — but the tail of any single hypothesis is unstable: a
/// word near the window edge often changes once more audio arrives. Emitting it
/// immediately would mean `live.md` had to be rewritten, which the append-only
/// invariant forbids.
///
/// LocalAgreement-2 (Liu et al. 2020; the approach `whisper_streaming` uses)
/// resolves this without any rewrite: a word is *committed* only once **two
/// consecutive hypotheses agree on it**. Concretely, the committer keeps the
/// previous hypothesis, and on each new one finds the longest common prefix of
/// the two (over the *uncommitted* region) — that prefix is stable and is
/// committed; everything past it stays provisional and is simply not emitted
/// yet. Because a committed word is one that survived two independent decodes,
/// `live.md` only ever grows (R36) and never has to take a word back.
///
/// This type is the pure, deterministic core of that algorithm — token-level,
/// no audio, no whisper. `StreamingTranscriber` feeds it whisper hypotheses;
/// the unit suite exercises it directly.
public struct LiveAgreementCommitter {

    /// One token as seen by the committer: the word plus the recording-absolute
    /// time span whisper attributed to the segment it came from.
    public struct Token: Sendable, Equatable {
        /// Normalized comparison key (lowercased, punctuation-stripped). Two
        /// tokens "agree" when their `key`s are equal — so trailing-comma vs
        /// no-comma jitter between hypotheses does not block a commit.
        public let key: String
        /// The token text as it should appear in the transcript (original
        /// casing/punctuation from the *newer* hypothesis).
        public let text: String
        /// Recording-absolute start of the segment this token belongs to.
        public let start: Duration
        /// Recording-absolute end of the segment this token belongs to.
        public let end: Duration

        public init(key: String, text: String, start: Duration, end: Duration) {
            self.key = key
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Tokens committed so far, across the whole stream. Append-only.
    public private(set) var committed: [Token] = []
    /// The previous hypothesis's *uncommitted-region* tokens, kept so the next
    /// hypothesis can be intersected with it (the "2" in LocalAgreement-2).
    private var previousHypothesisTail: [Token] = []

    public init() {}

    /// Feed a fresh whisper hypothesis for the current window.
    ///
    /// `hypothesis` is the full token list whisper produced for the window,
    /// already shifted to recording-absolute time. The committer:
    ///  1. trims the leading tokens that re-transcribe already-committed words
    ///     — found by **key-matching** against the committed tail, so it is
    ///     robust to the timestamp jitter two windows give the same words,
    ///  2. computes the longest common prefix of this hypothesis's *uncommitted*
    ///     tail and the previous hypothesis's tail (LocalAgreement-2),
    ///  3. commits that prefix and returns exactly the tokens newly committed.
    ///
    /// - Returns: the tokens committed by *this* call, in order — possibly
    ///   empty (no agreement yet). Never returns a token it returned before.
    public mutating func ingest(_ hypothesis: [Token]) -> [Token] {
        // (1) Trim the part of `hypothesis` that re-transcribes committed
        // words. The window overlaps already-transcribed audio, so its first N
        // tokens re-state the committed tail. Find the longest committed
        // suffix that matches a hypothesis prefix (by normalized key) and drop
        // that prefix. Key-matching is path-independent of timestamps — the
        // brittle part of a time-based skip.
        let tail = trimCommittedPrefix(from: hypothesis)

        // (2) Longest common prefix with the previous hypothesis's tail.
        let agreedCount = Self.commonPrefixLength(previousHypothesisTail, tail)
        let newlyCommitted = Array(tail.prefix(agreedCount))

        // (3) Commit, and remember this hypothesis's tail for the next round.
        committed.append(contentsOf: newlyCommitted)
        // The next comparison should be against the *still-uncommitted* part of
        // this hypothesis, so a token isn't re-counted once it's committed.
        previousHypothesisTail = Array(tail.dropFirst(agreedCount))
        return newlyCommitted
    }

    /// Drop the leading tokens of `hypothesis` that re-transcribe the already-
    /// committed tail, returning the still-uncommitted remainder.
    ///
    /// Finds the largest `k` such that the last `k` committed keys equal the
    /// first `k` hypothesis keys, and drops those `k`. When the committed tail
    /// and the hypothesis prefix do not align at all (a gap, or whisper
    /// re-segmented heavily) it falls back to a time cutoff so a window that
    /// genuinely overlaps committed audio still cannot re-commit it.
    private func trimCommittedPrefix(from hypothesis: [Token]) -> [Token] {
        guard let lastCommitted = committed.last, !hypothesis.isEmpty else {
            return hypothesis
        }
        let committedKeys = committed.map(\.key)
        let hypothesisKeys = hypothesis.map(\.key)
        // Try the longest overlap first.
        let maxK = min(committedKeys.count, hypothesisKeys.count)
        for k in stride(from: maxK, through: 1, by: -1) {
            if Array(committedKeys.suffix(k)) == Array(hypothesisKeys.prefix(k)) {
                return Array(hypothesis.dropFirst(k))
            }
        }
        // No key overlap: drop tokens that start before the committed tail
        // ends — they cannot be new words. A small tolerance absorbs the
        // per-word timestamp approximation.
        let cutoff = lastCommitted.end - .milliseconds(200)
        return hypothesis.drop { $0.start < cutoff }.map { $0 }
    }

    /// Flush at end-of-stream: the final hypothesis's tail has no successor to
    /// agree with, so its remaining tokens are committed unconditionally.
    ///
    /// This is the *only* place a single-hypothesis token is committed — and it
    /// is correct, because there will be no further audio to revise it. Without
    /// this the last few words of every recording would be silently dropped.
    public mutating func flush() -> [Token] {
        let remaining = previousHypothesisTail
        committed.append(contentsOf: remaining)
        previousHypothesisTail = []
        return remaining
    }

    /// Length of the longest common prefix of two token lists, comparing on
    /// the normalized `key` only.
    static func commonPrefixLength(_ a: [Token], _ b: [Token]) -> Int {
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit && a[i].key == b[i].key { i += 1 }
        return i
    }

    /// Normalize a word into a comparison key: lowercased, trimmed of
    /// surrounding punctuation/whitespace. Internal apostrophes/hyphens are
    /// kept so "don't" and "dont" are *not* falsely equated.
    public static func normalizationKey(_ word: String) -> String {
        word.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: " \t\n.,!?;:\"'()[]"))
    }

    /// Split a whisper segment's text into committer `Token`s, distributing the
    /// segment's time span evenly across its words (whisper gives per-segment,
    /// not per-word, timestamps — even distribution is a stable approximation).
    public static func tokens(
        from text: String,
        start: Duration,
        end: Duration
    ) -> [Token] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let spanMS = max(0, Int((end - start).components.seconds) * 1000
            + Int((end - start).components.attoseconds / 1_000_000_000_000_000))
        let perWordMS = spanMS / words.count
        return words.enumerated().map { index, word in
            let wStart = start + .milliseconds(perWordMS * index)
            let wEnd = index == words.count - 1
                ? end
                : start + .milliseconds(perWordMS * (index + 1))
            return Token(
                key: normalizationKey(word),
                text: word,
                start: wStart,
                end: wEnd)
        }
    }
}

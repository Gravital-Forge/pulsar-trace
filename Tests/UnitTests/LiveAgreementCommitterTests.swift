import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the LocalAgreement-2 committer (PT-R10).
///
/// The committer is the pure core of streaming transcription: it only commits
/// a word once two consecutive whisper hypotheses agree on it, so `live.md`
/// never has to be rewritten (PT-R36).
@Suite("LocalAgreement-2 committer")
struct LiveAgreementCommitterTests {

    /// Build a hypothesis token list from plain words at evenly-spaced times.
    private func hypothesis(_ words: [String], startMS: Int = 0) -> [LiveAgreementCommitter.Token] {
        words.enumerated().map { i, w in
            LiveAgreementCommitter.Token(
                key: LiveAgreementCommitter.normalizationKey(w),
                text: w,
                start: .milliseconds(startMS + i * 500),
                end: .milliseconds(startMS + (i + 1) * 500))
        }
    }

    @Test("first hypothesis commits nothing — no prior to agree with")
    func firstHypothesisCommitsNothing() {
        var committer = LiveAgreementCommitter()
        let out = committer.ingest(hypothesis(["the", "auth", "flow"]))
        #expect(out.isEmpty)
        #expect(committer.committed.isEmpty)
    }

    @Test("two agreeing hypotheses commit their common prefix")
    func commonPrefixCommits() {
        var committer = LiveAgreementCommitter()
        _ = committer.ingest(hypothesis(["the", "auth", "flow", "breaks"]))
        // Second hypothesis agrees on "the auth flow" but diverges on the tail.
        let out = committer.ingest(hypothesis(["the", "auth", "flow", "broke"]))
        #expect(out.map(\.text) == ["the", "auth", "flow"])
        #expect(committer.committed.map(\.text) == ["the", "auth", "flow"])
    }

    @Test("the unstable tail word is held back, not emitted")
    func unstableTailHeldBack() {
        var committer = LiveAgreementCommitter()
        _ = committer.ingest(hypothesis(["hello", "world", "foo"]))
        let out = committer.ingest(hypothesis(["hello", "world", "bar"]))
        // "foo"/"bar" disagree — only the agreed prefix commits.
        #expect(out.map(\.text) == ["hello", "world"])
        #expect(!committer.committed.contains { $0.text == "foo" || $0.text == "bar" })
    }

    @Test("a committed word is never re-emitted by a later hypothesis")
    func noReemission() {
        var committer = LiveAgreementCommitter()
        _ = committer.ingest(hypothesis(["one", "two", "three"]))
        let first = committer.ingest(hypothesis(["one", "two", "four"]))
        #expect(first.map(\.text) == ["one", "two"])
        // A third hypothesis still starting with "one two" must not re-commit.
        let second = committer.ingest(hypothesis(["one", "two", "five"]))
        #expect(second.isEmpty)
        #expect(committer.committed.map(\.text) == ["one", "two"])
    }

    @Test("flush commits the final hypothesis's tail unconditionally")
    func flushCommitsTail() {
        var committer = LiveAgreementCommitter()
        _ = committer.ingest(hypothesis(["alpha", "beta"]))
        _ = committer.ingest(hypothesis(["alpha", "beta", "gamma"]))
        // "gamma" never had a successor to agree with — flush commits it.
        let flushed = committer.flush()
        #expect(flushed.map(\.text) == ["gamma"])
        #expect(committer.committed.map(\.text) == ["alpha", "beta", "gamma"])
    }

    @Test("normalization key ignores trailing punctuation jitter")
    func normalizationIgnoresPunctuation() {
        // whisper often emits "flow" then "flow," between windows — these must
        // be treated as agreement, not divergence.
        #expect(LiveAgreementCommitter.normalizationKey("flow,")
            == LiveAgreementCommitter.normalizationKey("flow"))
        #expect(LiveAgreementCommitter.normalizationKey("Auth.")
            == LiveAgreementCommitter.normalizationKey("auth"))
    }

    @Test("punctuation-only difference still commits the prefix")
    func punctuationDifferenceCommits() {
        var committer = LiveAgreementCommitter()
        _ = committer.ingest(hypothesis(["the", "flow", "works"]))
        // Same words, the middle one now has a comma.
        let out = committer.ingest(hypothesis(["the", "flow,", "works"]))
        #expect(out.count == 3)
    }

    @Test("overlapping window: tokens inside the committed region are skipped")
    func overlappingWindowSkipsCommitted() {
        var committer = LiveAgreementCommitter()
        // Commit "one two".
        _ = committer.ingest(hypothesis(["one", "two", "three"], startMS: 0))
        _ = committer.ingest(hypothesis(["one", "two", "X"], startMS: 0))
        #expect(committer.committed.map(\.text) == ["one", "two"])
        // A later window re-transcribes "one two three four" — "one two" lie in
        // the committed region (start < last committed end) and are dropped;
        // only "three"/"four" are candidates.
        let w3 = hypothesis(["one", "two", "three", "four"], startMS: 0)
        let w4 = hypothesis(["one", "two", "three", "five"], startMS: 0)
        _ = committer.ingest(w3)
        let out = committer.ingest(w4)
        #expect(out.map(\.text) == ["three"])
    }

    @Test("commonPrefixLength counts the agreeing prefix length")
    func commonPrefixLengthCounts() {
        let a = hypothesis(["a", "b", "c", "d"])
        let b = hypothesis(["a", "b", "x", "y"])
        #expect(LiveAgreementCommitter.commonPrefixLength(a, b) == 2)
        #expect(LiveAgreementCommitter.commonPrefixLength(a, a) == 4)
        #expect(LiveAgreementCommitter.commonPrefixLength(a, []) == 0)
    }

    @Test("tokens(from:) splits a segment and distributes its time span")
    func tokensSplitSegment() {
        let toks = LiveAgreementCommitter.tokens(
            from: "the quick brown fox",
            start: .seconds(0),
            end: .seconds(4))
        #expect(toks.map(\.text) == ["the", "quick", "brown", "fox"])
        #expect(toks.first?.start == .seconds(0))
        #expect(toks.last?.end == .seconds(4))
        // Times are monotonically increasing.
        for i in 1..<toks.count {
            #expect(toks[i].start >= toks[i - 1].start)
        }
    }
}

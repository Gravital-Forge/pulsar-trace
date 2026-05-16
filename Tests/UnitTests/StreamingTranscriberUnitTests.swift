import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `StreamingTranscriber`'s pure utterance-grouping logic
/// (Epic 6). The whisper-driven streaming behaviour is exercised end-to-end in
/// the Pipeline suite; this covers the deterministic grouping in isolation.
@Suite("Streaming transcriber grouping (Epic 6)")
struct StreamingTranscriberUnitTests {

    private func token(_ text: String, startMS: Int, endMS: Int)
        -> LiveAgreementCommitter.Token {
        LiveAgreementCommitter.Token(
            key: LiveAgreementCommitter.normalizationKey(text),
            text: text,
            start: .milliseconds(startMS),
            end: .milliseconds(endMS))
    }

    @Test("a contiguous run of tokens groups into one utterance")
    func contiguousRunIsOneUtterance() {
        let tokens = [
            token("the", startMS: 0, endMS: 300),
            token("auth", startMS: 300, endMS: 600),
            token("flow", startMS: 600, endMS: 900),
        ]
        let out = StreamingTranscriber.groupTokens(tokens, gap: .milliseconds(800))
        #expect(out.count == 1)
        #expect(out[0].text == "the auth flow")
        #expect(out[0].start == .milliseconds(0))
        #expect(out[0].end == .milliseconds(900))
    }

    @Test("a silence gap splits tokens into separate utterances")
    func silenceGapSplits() {
        let tokens = [
            token("hello", startMS: 0, endMS: 400),
            token("there", startMS: 400, endMS: 800),
            // 2s of silence here — exceeds the 800ms gap.
            token("welcome", startMS: 2800, endMS: 3200),
            token("back", startMS: 3200, endMS: 3600),
        ]
        let out = StreamingTranscriber.groupTokens(tokens, gap: .milliseconds(800))
        #expect(out.count == 2)
        #expect(out[0].text == "hello there")
        #expect(out[1].text == "welcome back")
    }

    @Test("empty token list groups to no utterances")
    func emptyGroupsToNothing() {
        let out = StreamingTranscriber.groupTokens([], gap: .milliseconds(800))
        #expect(out.isEmpty)
    }

    @Test("a small gap under the threshold does not split")
    func smallGapDoesNotSplit() {
        let tokens = [
            token("one", startMS: 0, endMS: 300),
            // 500ms gap — under the 800ms threshold.
            token("two", startMS: 800, endMS: 1100),
        ]
        let out = StreamingTranscriber.groupTokens(tokens, gap: .milliseconds(800))
        #expect(out.count == 1)
    }
}

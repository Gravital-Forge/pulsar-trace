import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of mic-echo deduplication (R19).
///
/// When the user listens on speakers, the mic picks up the system audio and
/// the same words appear twice. R19: a mic utterance > 0.5 similar to a system
/// utterance within ±5 s is an echo — the mic-side copy is dropped.
@Suite("Mic-echo dedup (R19)")
struct MicEchoDedupTests {

    @Test("identical text within the window is detected as an echo")
    func identicalTextIsEcho() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "so the auth flow breaks on mobile",
            start: .seconds(10), end: .seconds(13))
        // Mic picks up the same words ~1s later.
        #expect(dedup.isMicEcho(
            text: "so the auth flow breaks on mobile",
            start: .seconds(11), end: .seconds(14)))
    }

    @Test("a slightly degraded echo (one word changed) is still detected")
    func degradedEchoDetected() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "the redirect URI is not handled correctly",
            start: .seconds(20), end: .seconds(24))
        // Mic version drops/garbles a word — still well above 0.5 similar.
        #expect(dedup.isMicEcho(
            text: "the redirect URI not handled correctly",
            start: .seconds(21), end: .seconds(25)))
    }

    @Test("unrelated mic speech is not an echo")
    func unrelatedSpeechNotEcho() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "so the auth flow breaks on mobile",
            start: .seconds(10), end: .seconds(13))
        #expect(!dedup.isMicEcho(
            text: "let me share my screen for a moment",
            start: .seconds(11), end: .seconds(14)))
    }

    @Test("an echo outside the ±5s window is not dropped")
    func echoOutsideWindowNotDropped() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "so the auth flow breaks on mobile",
            start: .seconds(10), end: .seconds(13))
        // Same text but 20s later — too far to be an echo of this utterance.
        #expect(!dedup.isMicEcho(
            text: "so the auth flow breaks on mobile",
            start: .seconds(33), end: .seconds(36)))
    }

    @Test("an echo just inside the window is dropped")
    func echoJustInsideWindow() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "quarterly numbers look strong this time",
            start: .seconds(10), end: .seconds(13))
        // Mic version ends 5s after the system one ends — within ±5s.
        #expect(dedup.isMicEcho(
            text: "quarterly numbers look strong this time",
            start: .seconds(15), end: .seconds(18)))
    }

    @Test("similarity: identical strings score 1.0")
    func similarityIdentical() {
        let n = MicEchoDedup.normalize("the auth flow breaks")
        #expect(MicEchoDedup.similarity(n, n) == 1.0)
    }

    @Test("similarity: disjoint strings score 0.0")
    func similarityDisjoint() {
        let a = MicEchoDedup.normalize("apple banana cherry")
        let b = MicEchoDedup.normalize("xylophone yacht zebra")
        #expect(MicEchoDedup.similarity(a, b) == 0.0)
    }

    @Test("similarity: half-shared words score around 0.5")
    func similarityHalfShared() {
        let a = MicEchoDedup.normalize("one two three four")
        let b = MicEchoDedup.normalize("one two five six")
        // 2 shared / max(4,4) = 0.5
        #expect(MicEchoDedup.similarity(a, b) == 0.5)
    }

    @Test("threshold is strict: exactly 0.5 similar is not an echo")
    func exactlyHalfNotEcho() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "one two three four",
            start: .seconds(10), end: .seconds(12))
        // 0.5 similar — R19 requires *strictly greater than* 0.5.
        #expect(!dedup.isMicEcho(
            text: "one two five six",
            start: .seconds(10), end: .seconds(12)))
    }

    @Test("normalize lowercases, strips punctuation, collapses whitespace")
    func normalizeBehaviour() {
        #expect(MicEchoDedup.normalize("The  Auth-Flow, BREAKS!")
            == "the auth flow breaks")
    }

    @Test("empty text is never an echo")
    func emptyTextNotEcho() {
        var dedup = MicEchoDedup()
        dedup.noteSystemUtterance(
            text: "some real system speech here",
            start: .seconds(5), end: .seconds(8))
        #expect(!dedup.isMicEcho(text: "", start: .seconds(6), end: .seconds(7)))
    }
}

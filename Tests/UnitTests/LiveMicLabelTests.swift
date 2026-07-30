import Foundation
import Testing
@testable import PulsarTraceEngine

/// PT-P8-R13 — the mic twin of `resolveSystemLabel`. The four behaviors are the
/// contract; the owner centroid + revision arrive as plain values (loaded once
/// at pipeline start — no per-utterance actor hop to `OwnerVoiceProfileStore`).
@Suite("Live mic label resolution (PT-P8-R13)")
struct LiveMicLabelTests {

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256); v[axis] = 1; return v
    }

    private func span(_ key: String, _ s: Double, _ e: Double, _ v: [Float])
        -> LiveSpeakerSpan {
        LiveSpeakerSpan(provisionalKey: key, start: .seconds(s),
                        end: .seconds(e), embedding: v)
    }

    @Test("owner-profile match resolves to You without a question mark")
    func ownerMatch() {
        let label = LiveRunner.resolveMicLabel(
            spans: [span("Guest", 0, 3, vec(0))],
            utteranceStart: .seconds(0), utteranceEnd: .seconds(3),
            ownerCentroid: vec(0), ownerRevision: "rev-a", spanRevision: "rev-a",
            libraryMatches: [:])
        #expect(label == "You")
    }

    @Test("library match resolves to the name with the ? suffix rule of the system twin")
    func libraryMatch() {
        let label = LiveRunner.resolveMicLabel(
            spans: [span("Guest", 0, 3, vec(7))],
            utteranceStart: .seconds(0), utteranceEnd: .seconds(3),
            ownerCentroid: vec(0), ownerRevision: "rev-a", spanRevision: "rev-a",
            libraryMatches: ["Guest": "Priya"])
        // The system twin (`resolveSystemLabel`) renders a matched library name
        // with the PT-R16 provisional `?` suffix (`"\(name)?"`) — mic mirrors it.
        #expect(label == "Priya?")
    }

    @Test("no owner, no library: Guest-family provisional with ?")
    func provisionalGuest() {
        let label = LiveRunner.resolveMicLabel(
            spans: [span("Guest #2", 0, 3, vec(7))],
            utteranceStart: .seconds(0), utteranceEnd: .seconds(3),
            ownerCentroid: nil, ownerRevision: nil, spanRevision: "rev-a",
            libraryMatches: [:])
        #expect(label == "Guest #2?")
    }

    @Test("no diarization coverage: neutral fallback, same as the system twin")
    func noCoverage() {
        let label = LiveRunner.resolveMicLabel(
            spans: [],
            utteranceStart: .seconds(0), utteranceEnd: .seconds(3),
            ownerCentroid: nil, ownerRevision: nil, spanRevision: nil,
            libraryMatches: [:])
        #expect(label == "Speaker?")   // LiveRunner.noCoverageLabel + "?"
    }

    /// The owner centroid is unusable when its model revision differs from the
    /// live diarizer's (PT-R112/PT-R113 revision scoping): a would-be owner then
    /// falls through to the provisional Guest label, never a false `You`.
    @Test("owner centroid from a mismatched revision does not resolve to You")
    func ownerRevisionMismatch() {
        let label = LiveRunner.resolveMicLabel(
            spans: [span("Guest", 0, 3, vec(0))],
            utteranceStart: .seconds(0), utteranceEnd: .seconds(3),
            ownerCentroid: vec(0), ownerRevision: "rev-old", spanRevision: "rev-a",
            libraryMatches: [:])
        #expect(label == "Guest?")
    }
}

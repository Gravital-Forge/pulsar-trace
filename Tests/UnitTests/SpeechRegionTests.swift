import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `SpeechRegion.coalesced(_:minGap:)` — the gap-merge step
/// that turns raw VAD speech regions into turn-sized regions for the
/// VAD-segmented offline transcription path.
///
/// Pure logic, no model: a region closer than `minGap` to its predecessor is a
/// within-turn breath and gets merged; a longer gap is a turn boundary and is
/// kept. This is what stops the refined transcript from either fragmenting a
/// turn into breath-sized lines or gluing two turns into one.
@Suite("SpeechRegion coalescing")
struct SpeechRegionTests {

    private func region(_ start: Double, _ end: Double) -> SpeechRegion {
        SpeechRegion(
            start: .milliseconds(Int(start * 1000)),
            end: .milliseconds(Int(end * 1000)))
    }

    @Test("an empty region list coalesces to empty")
    func emptyStaysEmpty() {
        #expect(SpeechRegion.coalesced([], minGap: .seconds(1)).isEmpty)
    }

    @Test("a single region passes through unchanged")
    func singleRegionUnchanged() {
        let only = region(1.0, 4.0)
        let out = SpeechRegion.coalesced([only], minGap: .seconds(1))
        #expect(out == [only])
    }

    @Test("regions closer than minGap merge into one turn")
    func closeRegionsMerge() {
        // Three breath-separated regions (0.3 s gaps) — one turn.
        let out = SpeechRegion.coalesced(
            [region(0, 2), region(2.3, 4), region(4.3, 6)],
            minGap: .milliseconds(800))
        #expect(out == [region(0, 6)])
    }

    @Test("a gap at or above minGap is kept as a turn boundary")
    func wideGapSplitsTurns() {
        // 0–2 s, then 2 s of silence, then 4–9 s — two distinct turns.
        let out = SpeechRegion.coalesced(
            [region(0, 2), region(4, 9)],
            minGap: .milliseconds(800))
        #expect(out == [region(0, 2), region(4, 9)])
    }

    @Test("merging spans every within-turn region but stops at the wide gap")
    func mixedGapsSplitOnlyAtTurnBoundary() {
        // Turn A: 0–2, 2.4–5 (0.4 s gap). Turn B: 9–11, 11.2–13 (0.2 s gap).
        // A→B gap is 4 s — the only real boundary.
        let out = SpeechRegion.coalesced(
            [region(0, 2), region(2.4, 5), region(9, 11), region(11.2, 13)],
            minGap: .milliseconds(800))
        #expect(out == [region(0, 5), region(9, 13)])
    }

    @Test("a coalesced region's end is the latest end it absorbed")
    func mergedEndIsLatestAbsorbed() {
        // A short region nested inside the span of the previous one — the
        // merged region must keep the later end (6.0), not take the last
        // region's earlier end (5.8).
        let out = SpeechRegion.coalesced(
            [region(0, 6), region(5.5, 5.8)],
            minGap: .milliseconds(800))
        #expect(out == [region(0, 6)])
    }
}

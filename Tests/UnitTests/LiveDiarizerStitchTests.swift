import Foundation
import Testing

@testable import PulsarTraceEngine

/// Unit tests for the live diarizer's per-segment stitching (D40 separation
/// fix). Pure logic — no CoreML models: the diarizer is built with the
/// engine-less test seam and `stitch(segments:windowStart:)` is driven with
/// synthetic embeddings.
@Suite("LiveDiarizerStitch")
struct LiveDiarizerStitchTests {

    /// A 256-d unit basis vector with `1` at `axis` — orthogonal basis vectors
    /// have cosine 0 (distinct speakers); near-duplicates have cosine ~1.
    private func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    private func seg(
        _ start: Double, _ end: Double, _ vector: [Float]
    ) -> DiarizerEngine.WindowSegmentEmbedding {
        .init(
            start: .milliseconds(Int(start * 1000)),
            end: .milliseconds(Int(end * 1000)),
            vector: vector)
    }

    @Test func distinctVoicesAcrossWindowsSpawnSecondSpeaker() async {
        let d = LiveDiarizer()   // zero-arg → the engine-less test seam (engine = nil)
        let w0 = await d.stitch(segments: [seg(0, 5, basis(0))], windowStart: .zero)
        let w1 = await d.stitch(segments: [seg(0, 5, basis(1))], windowStart: .seconds(5))
        #expect(w0.map(\.provisionalKey) == ["Them"])
        #expect(w1.map(\.provisionalKey) == ["Them #2"])
        #expect(Set(await d.centroids().keys) == ["Them", "Them #2"])
    }

    @Test func sameVoiceStaysOneSpeaker() async {
        let d = LiveDiarizer()
        _ = await d.stitch(segments: [seg(0, 5, basis(0))], windowStart: .zero)
        var near = basis(0)
        near[1] = 0.1   // cosine to basis(0) ≈ 0.995 → same speaker
        let w1 = await d.stitch(segments: [seg(0, 5, near)], windowStart: .seconds(5))
        #expect(w1.map(\.provisionalKey) == ["Them"])
        #expect(await d.centroids().keys.count == 1)
    }

    @Test func shortSegmentWithEmptyBankIsDropped() async {
        let d = LiveDiarizer()
        let w = await d.stitch(segments: [seg(0, 1, basis(0))], windowStart: .zero)  // 1 s < 2 s
        #expect(w.isEmpty)
        #expect(await d.centroids().isEmpty)
    }

    @Test func shortSegmentLabeledReadOnlyAfterSpeakerExists() async {
        let d = LiveDiarizer()
        _ = await d.stitch(segments: [seg(0, 5, basis(0))], windowStart: .zero)   // Them (reliable)
        let before = await d.centroids()["Them"]

        var near = basis(0)
        near[1] = 0.1
        let w1 = await d.stitch(segments: [seg(0, 1, near)], windowStart: .seconds(5))
        #expect(w1.map(\.provisionalKey) == ["Them"])           // labelled by nearest match
        #expect(await d.centroids().keys.count == 1)
        #expect(await d.centroids()["Them"] == before)          // read-only: centroid unchanged

        let w2 = await d.stitch(segments: [seg(0, 1, basis(1))], windowStart: .seconds(10))
        #expect(w2.isEmpty)                                     // far + short → dropped
        #expect(await d.centroids().keys.count == 1)            // no ghost speaker
    }
}

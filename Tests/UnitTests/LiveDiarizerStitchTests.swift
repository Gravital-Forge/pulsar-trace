import Testing
import Foundation
@testable import PulsarTraceEngine

/// A `RawWindowDiarizing` fake that returns a scripted result per call.
actor ScriptedRawDiarizer: RawWindowDiarizing {
    private var queue: [DiarWindowResult?]
    let revision: String
    init(_ queue: [DiarWindowResult?], revision: String = "rev") {
        self.queue = queue
        self.revision = revision
    }
    func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
    func modelRevision() async -> String { revision }
}

@Suite("LiveDiarizer stitching over a raw diarizer")
struct LiveDiarizerStitchTests {
    private func emb(_ v: Float, _ n: Int = 256) -> [Float] { [Float](repeating: v, count: n) }

    @Test("a window's raw spans become recording-absolute stitched spans")
    func stitchesOneWindow() async {
        let raw = DiarWindowResult(
            spans: [.init(speaker: "S1", startMillis: 0, endMillis: 2000)],
            embeddings: [.init(speaker: "S1", vector: emb(1.0))])
        let diarizer = LiveDiarizer(rawDiarizer: ScriptedRawDiarizer([raw]))
        let spans = await diarizer.diarizeWindow(samples: [], windowStart: .seconds(10))
        #expect(spans.count == 1)
        #expect(spans[0].provisionalKey == "Them")            // first speaker → "Them"
        #expect(spans[0].start == .seconds(10))               // windowStart + 0ms
        #expect(spans[0].end == .seconds(12))                 // windowStart + 2000ms
        #expect(await diarizer.centroids()["Them"] == emb(1.0))
    }

    @Test("a nil raw result yields no spans (degraded window)")
    func nilRawResultYieldsEmpty() async {
        let diarizer = LiveDiarizer(rawDiarizer: ScriptedRawDiarizer([nil]))
        let spans = await diarizer.diarizeWindow(samples: [], windowStart: .seconds(5))
        #expect(spans.isEmpty)
    }

    @Test("modelRevision is read from the raw diarizer")
    func modelRevisionPassThrough() async {
        let diarizer = LiveDiarizer(rawDiarizer: ScriptedRawDiarizer([], revision: "digest-xyz"))
        #expect(await diarizer.modelRevision() == "digest-xyz")
    }
}

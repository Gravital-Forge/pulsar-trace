import Foundation
import Testing
@testable import PulsarTraceEngine

/// The live diarization sliding-window buffer (Fix B/C): cadence-gated
/// window emission and bounded memory via trim.
@Suite("DiarBufferManager")
struct DiarBufferManagerTests {

    // 16 kHz mono — windows in samples for readable tests.
    private let step = 16_000      // 1 s cadence
    private let window = 48_000    // 3 s window

    @Test("no window until the buffer reaches one full window")
    func noWindowBeforeFill() {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        #expect(mgr.append([Float](repeating: 0, count: window - 1)) == nil)
    }

    @Test("first window emits at fill, covering the last `window` samples")
    func firstWindowAtFill() throws {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        // Bound to a local first: #require can't call a mutating member on
        // the receiver inside its macro expansion.
        let result = mgr.append([Float](repeating: 0, count: window))
        let req = try #require(result)
        #expect(req.samples.count == window)
        #expect(req.startSampleIndex == 0)
    }

    @Test("next window only after a full step of new audio")
    func cadenceGating() throws {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        _ = mgr.append([Float](repeating: 0, count: window))
        #expect(mgr.append([Float](repeating: 0, count: step - 1)) == nil)
        // Bound to a local first: #require can't call a mutating member on
        // the receiver inside its macro expansion.
        let result = mgr.append([Float](repeating: 0, count: 1))
        let req = try #require(result)
        #expect(req.startSampleIndex == step)
    }

    @Test("buffer is trimmed to 2x window; absolute indexing survives the trim")
    func trimKeepsAbsoluteIndexing() {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        var last: DiarBufferManager.WindowRequest?
        for _ in 0..<20 {                       // 20 s of audio
            if let req = mgr.append([Float](repeating: 0, count: step)) {
                last = req
            }
        }
        #expect(mgr.bufferedSampleCount <= 2 * window)
        #expect(last?.startSampleIndex == 20 * step - window)
        #expect(last?.samples.count == window)
    }
}

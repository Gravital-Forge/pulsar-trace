import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the canonical audio format and `AudioFrame` (R76).
@Suite("AudioFrame")
struct AudioFrameTests {

    @Test("Canonical frame is 320 samples = 20ms at 16kHz")
    func canonicalFrameSize() {
        #expect(AudioFormat.samplesPerFrame == 320)
    }

    @Test("Canonical frame serializes to 1280 bytes Float32")
    func canonicalFrameBytes() {
        #expect(AudioFormat.bytesPerFrame == 1280)
    }

    @Test("Frame start time is derived from its sequence index")
    func frameStartTime() {
        let frame = AudioFrame.silence(sequenceIndex: 50)
        #expect(frame.startTime == .milliseconds(1000))
    }

    @Test("Silence frame is all zero samples")
    func silenceFrame() {
        let frame = AudioFrame.silence(sequenceIndex: 0)
        #expect(frame.samples.allSatisfy { $0 == 0 })
    }
}

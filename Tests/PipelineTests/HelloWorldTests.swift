import Testing
import Foundation
@testable import PulsarTraceEngine

/// Proves the `Pipeline` test target and fixture locator work (Epic 1).
@Suite("Pipeline hello-world")
struct PipelineHelloWorldTests {

    @Test("Pipeline test harness runs")
    func harnessRuns() {
        #expect(AudioFormat.sampleRate == 16_000)
    }

    @Test("All committed audio fixtures are present")
    func fixturesPresent() {
        let names = [
            "single-speaker-30s.wav",
            "two-speakers-alternating.wav",
            "two-speakers-overlap.wav",
            "silence-then-speech.wav",
            "sine-440hz-5s.wav",
            "mic-and-system-paired/mic.wav",
            "mic-and-system-paired/system.wav",
        ]
        for name in names {
            #expect(FileManager.default.fileExists(atPath: FixtureLocator.audio(name).path),
                    "missing fixture: \(name)")
        }
    }
}

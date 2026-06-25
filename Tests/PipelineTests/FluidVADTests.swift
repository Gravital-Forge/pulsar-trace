import Foundation
import Testing
@testable import PulsarTraceEngine

/// Integration coverage for the FluidAudio (Silero-CoreML) VAD region
/// detector. Downloads the small VAD model on first run.
@Suite("FluidVAD region detection", .serialized)
struct FluidVADTests {

    @Test func findsSpeechRegionsInAFixture() async throws {
        let detector = FluidVADRegionDetector()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio/two-speakers-alternating.wav")
        let samples = try WAVReader(contentsOf: fixture).samples
        let regions = try await detector.detectRegions(samples)
        #expect(!regions.isEmpty)
        let duration = Duration.milliseconds(samples.count * 1000 / AudioFormat.sampleRate)
        var previousEnd = Duration.zero - .milliseconds(1)
        for region in regions {
            #expect(region.start >= .zero)
            #expect(region.end <= duration + .seconds(1))
            #expect(region.end > region.start)
            #expect(region.start > previousEnd)   // sorted, non-overlapping
            previousEnd = region.end
        }
    }

    @Test func silenceYieldsNoRegions() async throws {
        let detector = FluidVADRegionDetector()
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 5)
        let regions = try await detector.detectRegions(silence)
        #expect(regions.isEmpty)
    }
}

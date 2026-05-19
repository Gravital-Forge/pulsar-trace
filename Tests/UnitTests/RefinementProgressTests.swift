// Tests/UnitTests/RefinementProgressTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementProgress")
struct RefinementProgressTests {

    @Test("an empty progress at .resolvingInput round-trips")
    func roundTripEmpty() throws {
        let progress = RefinementProgress(
            schemaVersion: 1,
            jobId: "job_x",
            recordingId: "rec_x",
            stage: .resolvingInput,
            systemRegions: [],
            completedSystemRegionIndices: [],
            systemSegments: [],
            micRegions: [],
            completedMicRegionIndices: [],
            micSegments: [],
            language: nil,
            lastCheckpointAt: Date(timeIntervalSince1970: 1_716_120_000))

        let data = try progress.encoded()
        let decoded = try RefinementProgress.decode(data)
        #expect(decoded == progress)
    }

    @Test("nextSystemRegionIndex returns the lowest index not yet completed")
    func nextSystemRegion() {
        var p = RefinementProgress.empty(jobId: "j", recordingId: "r")
        p.systemRegions = (0..<5).map {
            RefinementProgress.RegionWindow(
                startMillis: $0 * 1000, endMillis: ($0 + 1) * 1000)
        }
        p.completedSystemRegionIndices = [0, 1, 2]
        #expect(p.nextSystemRegionIndex == 3)

        p.completedSystemRegionIndices = [0, 2, 4]
        #expect(p.nextSystemRegionIndex == 1)  // index 1 still pending

        p.completedSystemRegionIndices = [0, 1, 2, 3, 4]
        #expect(p.nextSystemRegionIndex == nil)
    }
}

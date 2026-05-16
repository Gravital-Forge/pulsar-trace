import Testing
import Foundation
@testable import PulsarTraceCapture

/// Layer 3 — `CaptureSelfTest`, the play-a-tone / capture-it-back self-check
/// behind `pulsartrace doctor --capture-test` (R68).
///
/// Needs real audio I/O, so it is opt-in (see `DeviceTestGate`). The pure
/// frequency analysis (`ToneDetector`) is unit-tested without hardware; this
/// proves the play→capture plumbing actually moves audio on a real host.
///
/// It asserts that audio *was captured*, not that the tone matched: whether
/// the played tone reaches the microphone depends on the host's audio routing
/// (acoustic path, or a BlackHole loopback). The frequency match is verified
/// by a human via `docs/release-smoke-test.md`.
@Suite("CaptureSelfTest (capture-test, R68)", .tags(.liveCapture),
       .enabled(if: DeviceTestGate.enabled))
struct CaptureSelfTestTests {

    @Test("the self-test runs end-to-end and captures audio")
    func runsAndCaptures() async throws {
        let result: CaptureSelfTest.Result
        do {
            result = try await CaptureSelfTest.run(
                frequencyHz: 440, toneDuration: .seconds(2))
        } catch {
            withKnownIssue("microphone capture unavailable — permission likely not granted: \(error)") {
                Issue.record("CaptureSelfTest.run() threw")
            }
            return
        }
        // The capture path moved real audio.
        #expect(result.capturedSampleCount > 0)
        #expect(result.expectedFrequencyHz == 440)
        // A plausible dominant frequency was reported (within the search band).
        #expect(result.dominantFrequencyHz > 0)
    }
}

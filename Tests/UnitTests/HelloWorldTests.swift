import Testing
@testable import PulsarTraceEngine

/// Proves the `Unit` test target and Swift Testing harness work (Epic 1).
@Suite("Unit hello-world")
struct HelloWorldTests {
    @Test("Unit test harness runs")
    func harnessRuns() {
        #expect(AudioFormat.samplesPerFrame == 320)
    }
}

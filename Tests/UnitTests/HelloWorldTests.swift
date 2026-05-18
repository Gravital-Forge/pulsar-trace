import Testing
@testable import PulsarTraceEngine

/// Proves the `Unit` test target and Swift Testing harness work.
@Suite("Unit hello-world")
struct HelloWorldTests {
    @Test("Unit test harness runs")
    func harnessRuns() {
        #expect(AudioFormat.samplesPerFrame == 320)
    }
}

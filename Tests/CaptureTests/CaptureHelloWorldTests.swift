import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 3: Capture tests (R66, §12 "Layer 3").
///
/// `DeviceCaptureSource` and real audio capture land in Epic 7. Epic 1 ships
/// only the `Capture` target plumbing and the BlackHole-detection helper. These
/// tests prove the target builds and that capture tests skip cleanly on a host
/// without BlackHole (this EC2 Mac has no audio devices at all).
@Suite("Capture hello-world")
struct CaptureHelloWorldTests {

    @Test("Capture test harness runs")
    func harnessRuns() {
        #expect(AudioFormat.channelCount == 1)
    }

    @Test("BlackHole-gated capture test skips cleanly when absent")
    func capturePathSkipsWithoutBlackHole() throws {
        // This is the pattern every real Layer-3 capture test (Epic 7) uses:
        // call requireInstalled() first; absent BlackHole raises a skip.
        do {
            try BlackHole.requireInstalled()
        } catch let error as BlackHole.NotInstalled {
            withKnownIssue("BlackHole not installed: \(error)") {
                Issue.record("capture path requires BlackHole")
            }
            return
        }
        // Reached only on a machine with BlackHole installed.
        #expect(BlackHole.isInstalled)
    }

    @Test("BlackHole detection does not crash on a device-less host")
    func detectionIsSafe() {
        // Must not trap even when CoreAudio reports zero devices.
        _ = BlackHole.isInstalled
        #expect(Bool(true))
    }
}

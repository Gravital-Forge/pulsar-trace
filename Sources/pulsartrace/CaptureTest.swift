import Foundation
import PulsarTraceCapture
import PulsarTraceEngine

/// `pulsartrace doctor --capture-test` — the end-to-end capture self-check
/// (R68): a 440 Hz tone is played, captured back through the real microphone
/// path, and its dominant frequency verified.
///
/// Unlike the rest of `doctor` (which only inspects state), this exercises the
/// audio hardware, so it is opt-in via the `--capture-test` flag.
enum CaptureTest {

    /// Run the capture self-test and print the result.
    ///
    /// - Parameter baseFailure: whether the preceding `doctor` report already
    ///   failed — folded into the exit code so `--capture-test` never masks a
    ///   failure the plain report found.
    /// - Returns: the process exit code.
    static func run(baseFailure: Bool) async -> Int32 {
        out("Capture self-test — playing a 440 Hz tone, verifying the "
            + "microphone path…")
        do {
            let result = try await CaptureSelfTest.run()
            let detected = String(format: "%.0f", result.dominantFrequencyHz)
            let expected = String(format: "%.0f", result.expectedFrequencyHz)
            if result.passed {
                out("  [ ok ]  captured \(result.capturedSampleCount) samples "
                    + "from \(result.micDevice)")
                out("  [ ok ]  dominant frequency \(detected) Hz "
                    + "≈ expected \(expected) Hz")
                out("")
                out("Capture path verified.")
                return baseFailure ? 1 : 0
            } else {
                out("  [FAIL]  dominant frequency \(detected) Hz "
                    + "≠ expected \(expected) Hz")
                out("          captured \(result.capturedSampleCount) samples "
                    + "from \(result.micDevice) — the tone was not heard; "
                    + "check the microphone and output volume")
                return 1
            }
        } catch {
            err("doctor --capture-test: \(error)")
            return 1
        }
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

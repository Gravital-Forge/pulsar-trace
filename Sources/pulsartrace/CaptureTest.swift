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
            let rms = String(format: "%.5f", result.capturedRMS)
            let samples = "\(result.capturedSampleCount) samples from "
                + result.micDevice

            switch result.outcome {
            case .passed:
                out("  [ ok ]  captured \(samples) (RMS \(rms))")
                out("  [ ok ]  dominant frequency \(detected) Hz "
                    + "≈ expected \(expected) Hz")
                out("")
                out("Capture path verified.")
                return baseFailure ? 1 : 0

            case .silent:
                // Distinct from a frequency mismatch: no signal was captured
                // at all, so there is no detected frequency to report.
                out("  [FAIL]  no audio signal captured — the microphone path "
                    + "is silent")
                out("          captured \(samples), but RMS is \(rms) "
                    + "(digital silence)")
                out("          captured audio written to "
                    + "\(result.capturedAudioURL.path) — it plays as silence")
                out("          possible causes: this process lacks effective "
                    + "Microphone access (TCC), or the mic is muted")
                return 1

            case .frequencyMismatch:
                out("  [FAIL]  captured audio carries no \(expected) Hz tone "
                    + "(dominant \(detected) Hz)")
                out("          captured \(samples) (RMS \(rms)) — audio is "
                    + "present, but not the test tone; check audio routing")
                out("          captured audio written to "
                    + "\(result.capturedAudioURL.path) — play it to hear it")
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

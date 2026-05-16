import AVFoundation
import Foundation
import PulsarTraceEngine

/// The end-to-end capture self-check behind `pulsartrace doctor --capture-test`
/// (R68): play a known tone, capture it back through the real microphone
/// path, and verify the captured audio carries that frequency.
///
/// This proves the whole capture chain — `AVCaptureSession` → resample/downmix
/// → `AudioFrame` — actually moves audio, which a permission check alone
/// cannot. It needs real audio hardware, so it runs only when explicitly
/// invoked; the pure frequency analysis (`ToneDetector`) is unit-tested
/// separately.
public enum CaptureSelfTest {

    /// What a capture self-test resolved to. The two failure modes are
    /// genuinely different problems and must not be conflated: `silent` means
    /// the capture path delivered no signal at all (a permission/routing fault
    /// upstream of any analysis), whereas `frequencyMismatch` means real audio
    /// arrived but did not carry the test tone (an audio-routing issue).
    public enum Outcome: String, Sendable {
        /// The captured audio carried the test tone within tolerance.
        case passed
        /// The captured audio was silent — no signal reached the analysis.
        case silent
        /// Audio was captured, but its dominant frequency was not the tone.
        case frequencyMismatch
    }

    /// An RMS level at or below this is treated as silence — no usable signal
    /// (a real microphone in a real room never reads a true zero).
    public static let silenceThreshold = 0.001

    /// The outcome of a capture self-test.
    public struct Result: Sendable {
        /// Microphone the audio was captured from.
        public let micDevice: String
        /// Number of audio samples captured.
        public let capturedSampleCount: Int
        /// RMS level of the captured audio (0 ⇒ pure silence). A diagnostic:
        /// a near-zero RMS means the capture path delivered silent buffers.
        public let capturedRMS: Double
        /// A WAV of exactly what was captured — written so a failed self-test
        /// can be diagnosed by ear.
        public let capturedAudioURL: URL
        /// Frequency that was played.
        public let expectedFrequencyHz: Double
        /// Dominant frequency found in the captured audio. Meaningful only
        /// when `outcome` is `passed` or `frequencyMismatch` — for `silent`
        /// audio there is no frequency to find.
        public let dominantFrequencyHz: Double
        /// What the self-test resolved to.
        public let outcome: Outcome
    }

    /// A self-test that could not even run (as opposed to one that ran and
    /// failed the frequency check).
    public enum SelfTestError: Error, CustomStringConvertible {
        case captureFailedToStart(String)
        case playbackFailed(String)
        case noAudioCaptured

        public var description: String {
            switch self {
            case .captureFailedToStart(let m):
                return "microphone capture did not start: \(m)"
            case .playbackFailed(let m):
                return "could not play the test tone: \(m)"
            case .noAudioCaptured:
                return "no audio was captured — check the microphone"
            }
        }
    }

    /// Play a `frequencyHz` tone and capture it back through the microphone.
    ///
    /// - Parameters:
    ///   - frequencyHz: the tone to play and look for (default A4, 440 Hz).
    ///   - toneDuration: how long the tone plays / capture runs.
    public static func run(
        frequencyHz: Double = 440,
        toneDuration: Duration = .seconds(3)
    ) async throws -> Result {
        let sampleRate = AudioFormat.sampleRate

        // The test tone, written to a temp WAV so AVAudioPlayer can play it.
        let tone = ToneDetector.sine(
            frequencyHz: frequencyHz, sampleRate: sampleRate, duration: toneDuration)
        let toneURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-capture-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: toneURL) }
        do {
            try WAVWriter.write(samples: tone, to: toneURL)
        } catch {
            throw SelfTestError.playbackFailed("\(error)")
        }

        // Start microphone capture, accumulating frames.
        let collector = SampleCollector()
        let mic = MicCaptureEngine(deviceID: nil)
        mic.onEvent = { event in
            if case .frame(let frame) = event {
                collector.append(frame.samples)
            }
        }
        do {
            try mic.start()
        } catch {
            throw SelfTestError.captureFailedToStart("\(error)")
        }
        defer { mic.stop() }

        // Play the tone and let capture run for its full length plus a margin.
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: toneURL)
        } catch {
            throw SelfTestError.playbackFailed("\(error)")
        }
        player.play()
        try? await Task.sleep(for: toneDuration + .milliseconds(500))
        player.stop()
        mic.stop()

        let captured = collector.samples()
        guard !captured.isEmpty else { throw SelfTestError.noAudioCaptured }

        // Diagnostics: the RMS level distinguishes silence (a broken capture
        // path) from a real signal the analysis simply could not match, and
        // the WAV lets a failed run be inspected by ear.
        let rms = (captured.isEmpty)
            ? 0
            : (captured.reduce(0.0) { $0 + Double($1) * Double($1) }
                / Double(captured.count)).squareRoot()
        let capturedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsartrace-capture-test.wav")
        try? WAVWriter.write(samples: captured, to: capturedURL)

        // Silence is decided first, before any frequency analysis: running a
        // detector over silent buffers only yields a meaningless artifact
        // (the bottom of the search band), which must not be presented as if
        // a tone were detected.
        let dominant = ToneDetector.dominantFrequency(
            captured, sampleRate: sampleRate,
            range: ToneDetector.searchBand(around: frequencyHz))
        let outcome: Outcome
        if rms <= Self.silenceThreshold {
            outcome = .silent
        } else if ToneDetector.matches(
            captured, expectedHz: frequencyHz, sampleRate: sampleRate) {
            outcome = .passed
        } else {
            outcome = .frequencyMismatch
        }

        return Result(
            micDevice: mic.deviceName,
            capturedSampleCount: captured.count,
            capturedRMS: rms,
            capturedAudioURL: capturedURL,
            expectedFrequencyHz: frequencyHz,
            dominantFrequencyHz: dominant,
            outcome: outcome)
    }
}

/// Thread-safe accumulator for capture frames delivered on a background queue.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []

    func append(_ samples: [Float]) {
        lock.withLock { buffer.append(contentsOf: samples) }
    }

    func samples() -> [Float] {
        lock.withLock { buffer }
    }
}

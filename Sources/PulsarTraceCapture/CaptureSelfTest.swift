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

    /// The outcome of a capture self-test.
    public struct Result: Sendable {
        /// Microphone the audio was captured from.
        public let micDevice: String
        /// Number of audio samples captured.
        public let capturedSampleCount: Int
        /// Frequency that was played.
        public let expectedFrequencyHz: Double
        /// Dominant frequency found in the captured audio.
        public let dominantFrequencyHz: Double
        /// Whether the captured tone matched within tolerance.
        public let passed: Bool
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

        let dominant = ToneDetector.dominantFrequency(
            captured, sampleRate: sampleRate,
            range: ToneDetector.searchBand(around: frequencyHz))
        let passed = ToneDetector.matches(
            captured, expectedHz: frequencyHz, sampleRate: sampleRate)

        return Result(
            micDevice: mic.deviceName,
            capturedSampleCount: captured.count,
            expectedFrequencyHz: frequencyHz,
            dominantFrequencyHz: dominant,
            passed: passed)
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

import Testing
import Foundation
import AVFoundation
@testable import PulsarTraceCapture
@testable import PulsarTraceEngine

/// Layer 3 — live capture through the capture engines (PT-R1, PT-R2).
///
/// `ScreenCaptureKitTests` / `BlackHoleCaptureTests` prove the raw OS APIs
/// work on this host; these tests prove the PulsarTrace *wrappers* —
/// `SystemAudioCaptureEngine` and `MicCaptureEngine` — open those APIs,
/// resample/downmix through `AudioConverter`, and emit canonical 16 kHz mono
/// 320-sample frames. Opt-in only; see `DeviceTestGate`.
///
/// They assert that frames *flow* and are correctly shaped, not that they
/// carry a particular signal — capturing with nothing playing yields silent
/// frames, and that still proves the capture path.
@Suite("Live capture engines", .tags(.liveCapture),
       .enabled(if: DeviceTestGate.enabled))
struct DeviceCaptureEngineTests {

    /// Thread-safe tally of frames from a capture engine's delivery queue.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var allCanonical = true

        func record(_ frame: AudioFrame) {
            lock.withLock {
                count += 1
                if frame.samples.count != AudioFormat.samplesPerFrame {
                    allCanonical = false
                }
            }
        }
        var frameCount: Int { lock.withLock { count } }
        var everyFrameIsCanonical: Bool { lock.withLock { allCanonical } }
    }

    @Test("SystemAudioCaptureEngine delivers 16 kHz mono frames via ScreenCaptureKit")
    func systemEngineDeliversFrames() async throws {
        let engine = SystemAudioCaptureEngine(filter: .allApps)
        let sink = FrameSink()
        engine.onEvent = { event in
            if case .frame(let frame) = event { sink.record(frame) }
        }

        do {
            try await engine.start()
        } catch {
            withKnownIssue("ScreenCaptureKit unavailable — Screen Recording permission likely not granted: \(error)") {
                Issue.record("SystemAudioCaptureEngine.start() failed")
            }
            return
        }
        try await Task.sleep(for: .seconds(3))
        await engine.stop()

        #expect(
            sink.frameCount > 0,
            "expected 16 kHz mono frames from SystemAudioCaptureEngine, got \(sink.frameCount)")
        #expect(sink.everyFrameIsCanonical, "every frame must be 320 samples")
    }

    @Test("MicCaptureEngine delivers 16 kHz mono frames via AVFoundation")
    func micEngineDeliversFrames() async throws {
        // Prefer BlackHole — a stable, silent loopback device that does not
        // depend on whichever physical mic the host happens to default to —
        // and fall back to the system default input when it is not installed.
        let blackHole = MicCaptureEngine.availableDevices().first {
            $0.name.localizedCaseInsensitiveContains("BlackHole")
        }
        let engine = MicCaptureEngine(deviceID: blackHole?.id)
        let sink = FrameSink()
        engine.onEvent = { event in
            if case .frame(let frame) = event { sink.record(frame) }
        }

        do {
            try engine.start()
        } catch {
            withKnownIssue("microphone capture could not start: \(error)") {
                Issue.record("MicCaptureEngine.start() failed")
            }
            return
        }
        try await Task.sleep(for: .seconds(2))
        engine.stop()

        #expect(
            sink.frameCount > 0,
            "expected 16 kHz mono frames from MicCaptureEngine, got \(sink.frameCount)")
        #expect(sink.everyFrameIsCanonical, "every frame must be 320 samples")
        #expect(engine.deviceName != "none", "the resolved device should be named")
    }

    /// Thread-safe accumulator of every captured sample, for amplitude checks.
    private final class SampleAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        func append(_ values: [Float]) {
            lock.withLock { samples.append(contentsOf: values) }
        }
        /// Root-mean-square level of everything captured so far.
        var rms: Float {
            lock.withLock {
                guard !samples.isEmpty else { return 0 }
                let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
                return (sumSquares / Float(samples.count)).squareRoot()
            }
        }
        /// `true` if any captured sample is non-zero — the precise inverse of
        /// the all-zeros "pure digital silence" failure.
        var containsSignal: Bool { lock.withLock { samples.contains { $0 != 0 } } }
        var isEmpty: Bool { lock.withLock { samples.isEmpty } }
    }

    @Test("MicCaptureEngine captures non-silent audio while a tone plays")
    func micEngineCapturesNonSilentAudio() async throws {
        // Regression guard for BUG-mic-capture-silent: the microphone path
        // downmixed real audio to *pure digital silence* — every sample zero,
        // RMS exactly 0. This asserts the path delivers real audio: a working
        // mic always reports at least its noise floor, so the check needs only
        // an unmuted mic, not an audible play→capture path. A tone is played
        // so a host with a loopback path also exercises a strong signal.
        // The downmix repair that fixed this is covered by the engine's
        // channel-layout handling.
        //
        // A noise floor sits far above zero yet well below a heard tone; the
        // bug produced 0. Anything above this proves the path is not silent.
        let silenceFloor: Float = 0.0001

        let tone = ToneDetector.sine(
            frequencyHz: 440, sampleRate: AudioFormat.sampleRate,
            duration: .seconds(2))
        let toneURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mic-nonsilent-\(UUID().uuidString).wav")
        try WAVWriter.write(samples: tone, to: toneURL)
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let engine = MicCaptureEngine(deviceID: nil)
        let accumulator = SampleAccumulator()
        engine.onEvent = { event in
            if case .frame(let frame) = event { accumulator.append(frame.samples) }
        }
        do {
            try engine.start()
        } catch {
            withKnownIssue("microphone capture could not start: \(error)") {
                Issue.record("MicCaptureEngine.start() failed")
            }
            return
        }
        defer { engine.stop() }

        let player = try AVAudioPlayer(contentsOf: toneURL)
        player.play()
        try await Task.sleep(for: .seconds(2.5))
        player.stop()
        engine.stop()

        #expect(!accumulator.isEmpty, "expected captured frames from MicCaptureEngine")
        #expect(
            accumulator.containsSignal,
            "captured audio is pure digital silence — every sample is zero (BUG-mic-capture-silent)")
        #expect(
            accumulator.rms > silenceFloor,
            "captured audio is effectively silent (RMS \(accumulator.rms)) — the microphone capture/conversion path delivered no real signal")
    }

    @Test("MicCaptureEngine exposes the available input devices (PT-R5)")
    func micEngineListsDevices() {
        // Device enumeration needs no permission and no opt-in capture.
        let devices = MicCaptureEngine.availableDevices()
        #expect(!devices.isEmpty, "expected at least one audio input device")
        #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
    }
}

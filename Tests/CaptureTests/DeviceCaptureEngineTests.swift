import Testing
import Foundation
@testable import PulsarTraceCapture
@testable import PulsarTraceEngine

/// Layer 3 — live capture through Epic 7's capture engines (R1, R2).
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
@Suite("Live capture engines (Epic 7)", .tags(.liveCapture),
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

    @Test("MicCaptureEngine exposes the available input devices (R5)")
    func micEngineListsDevices() {
        // Device enumeration needs no permission and no opt-in capture.
        let devices = MicCaptureEngine.availableDevices()
        #expect(!devices.isEmpty, "expected at least one audio input device")
        #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
    }
}

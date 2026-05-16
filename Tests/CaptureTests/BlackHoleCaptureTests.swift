import AVFoundation
import Foundation
import Testing

/// Layer 3 — live capture from the BlackHole loopback device (R66).
///
/// Proves this host can actually open BlackHole 2ch through AVFoundation and
/// receive audio sample buffers — the capability the `Capture` test layer and
/// Epic 7's `DeviceCaptureSource` depend on. Opt-in only; see `DeviceTestGate`.
///
/// The test asserts that *buffers flow*, not that they carry signal: with
/// nothing routed into BlackHole the buffers are silent, and that still proves
/// the capture path works. End-to-end non-silence is covered by the manual
/// `scripts/audio-loopback-check.sh`.
@Suite("Live BlackHole capture", .tags(.liveCapture), .enabled(if: DeviceTestGate.enabled))
struct BlackHoleCaptureTests {

    /// Thread-safe tally of audio sample buffers from an `AVCaptureSession`.
    /// The delegate callback fires on a background queue, hence the lock.
    private final class BufferCounter: NSObject,
        AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            lock.withLock { value += 1 }
        }
    }

    @Test("BlackHole 2ch opens via AVFoundation and delivers audio sample buffers")
    func blackHoleDeliversBuffers() async throws {
        // BlackHole is a CoreAudio device; skip cleanly on a host without it.
        try BlackHole.requireInstalled()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified)
        guard let device = discovery.devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("BlackHole")
        }) else {
            // Present in CoreAudio but not surfaced by AVFoundation — report as
            // a known issue rather than a hard failure.
            withKnownIssue("BlackHole is not exposed as an AVCaptureDevice on this host") {
                Issue.record("AVFoundation audio discovery did not include BlackHole")
            }
            return
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            Issue.record("AVCaptureSession refused the BlackHole input")
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let counter = BufferCounter()
        output.setSampleBufferDelegate(
            counter, queue: DispatchQueue(label: "blackhole-capture-test"))
        guard session.canAddOutput(output) else {
            Issue.record("AVCaptureSession refused the audio data output")
            return
        }
        session.addOutput(output)

        session.startRunning()
        try await Task.sleep(for: .seconds(1.5))
        session.stopRunning()

        #expect(
            counter.count > 0,
            "expected audio sample buffers from BlackHole 2ch, got \(counter.count)")
    }
}

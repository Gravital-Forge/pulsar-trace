import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing

/// Layer 3 — live system-audio capture via ScreenCaptureKit (R2).
///
/// PulsarTrace captures system audio with ScreenCaptureKit, never BlackHole —
/// BlackHole is only the loopback *test fixture*. This proves the host can open
/// an `SCStream` with `capturesAudio` and receive audio buffers, the capability
/// Epic 7's system-audio capture path depends on. Opt-in only; see
/// `DeviceTestGate`.
///
/// Asserts that audio buffers flow (ScreenCaptureKit delivers them continuously
/// while capturing, silent or not); the peak level is surfaced in the
/// expectation message for the developer running it locally.
@Suite("Live ScreenCaptureKit capture", .tags(.liveCapture), .enabled(if: DeviceTestGate.enabled))
struct ScreenCaptureKitTests {

    /// Thread-safe tally of system-audio buffers from an `SCStream`. The stream
    /// output callback fires on a background queue, hence the lock.
    private final class AudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var bufferCount = 0
        private var peakValue: Float = 0

        var buffers: Int { lock.withLock { bufferCount } }
        var peak: Float { lock.withLock { peakValue } }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .audio else { return }
            var localPeak: Float = 0
            try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
                for buffer in audioBufferList {
                    guard let raw = buffer.mData else { continue }
                    let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = raw.bindMemory(to: Float.self, capacity: n)
                    for i in 0..<n { localPeak = max(localPeak, abs(samples[i])) }
                }
            }
            lock.withLock {
                bufferCount += 1
                peakValue = max(peakValue, localPeak)
            }
        }
    }

    @Test("ScreenCaptureKit opens an SCStream and delivers system-audio buffers")
    func screenCaptureKitDeliversAudio() async throws {
        // The first call triggers the Screen Recording TCC check; on a host
        // without the grant it throws — skip rather than fail.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            withKnownIssue(
                "ScreenCaptureKit unavailable — Screen Recording permission likely not granted: \(error.localizedDescription)"
            ) {
                Issue.record("SCShareableContent.current failed")
            }
            return
        }
        guard let display = content.displays.first else {
            Issue.record("ScreenCaptureKit reported no displays")
            return
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let sink = AudioSink()
        try stream.addStreamOutput(
            sink, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "sck-audio-test"))

        try await stream.startCapture()
        try await Task.sleep(for: .seconds(3))
        try await stream.stopCapture()

        #expect(
            sink.buffers > 0,
            "expected system-audio buffers from ScreenCaptureKit, got \(sink.buffers) (peak \(sink.peak))")
    }
}

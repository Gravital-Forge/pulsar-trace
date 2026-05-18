import AVFoundation
import Foundation
import PulsarTraceEngine
import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit and emits canonical 16 kHz mono
/// Float32 frames as `AudioStreamEvent.frame` values (R2).
///
/// ScreenCaptureKit captures system audio without any virtual audio device —
/// BlackHole is only a test fixture, never a production dependency. The
/// `SCStreamOutput` callback fires on a private queue, so mutable state is
/// lock-guarded and the type is `@unchecked Sendable`.
final class SystemAudioCaptureEngine: NSObject,
    SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// Which audio ScreenCaptureKit should capture.
    enum ContentFilter: Sendable {
        /// Everything playing on the default display (production).
        case allApps
        /// Only the audio of the process with this PID — used by Layer 3
        /// capture tests to isolate a known test-tone player.
        case pid(Int32)
    }

    enum SystemCaptureError: Error, CustomStringConvertible {
        case noDisplay
        case noMatchingApplication(Int32)

        var description: String {
            switch self {
            case .noDisplay:
                return "ScreenCaptureKit reported no displays"
            case .noMatchingApplication(let pid):
                return "no running application with PID \(pid)"
            }
        }
    }

    /// Max silence (no delivered frame) before the stream is treated as
    /// silently stalled. System audio is bursty — ScreenCaptureKit delivers
    /// silence buffers while nothing plays — so a healthy stream never goes
    /// this quiet; 6 s comfortably clears normal jitter.
    static let stallThreshold: Duration = .seconds(6)

    /// Frame sink — set before `start()`. Invoked on the capture delivery queue.
    var onEvent: (@Sendable (AudioStreamEvent) -> Void)?
    /// Reports an `SCStream` failure (e.g. TCC revoked mid-session).
    var onStreamError: (@Sendable (Error) -> Void)?
    /// Reports that the stream went silent — no frame within `stallThreshold`
    /// — with no error and no end-of-stream. Wired analogously to
    /// `onStreamError`; invoked once on the watchdog's private queue.
    var onStall: (@Sendable () -> Void)?

    private let filter: ContentFilter
    private let deliveryQueue = DispatchQueue(label: "com.pulsartrace.capture.system")
    private let watchdog = FrameWatchdog(
        threshold: SystemAudioCaptureEngine.stallThreshold,
        label: "com.pulsartrace.capture.system.watchdog")

    private let lock = NSLock()
    private let converter = SampleBufferConverter()
    private var sequenceIndex = 0
    private var running = false
    private var stream: SCStream?

    init(filter: ContentFilter = .allApps) {
        self.filter = filter
        super.init()
    }

    /// Resolve shareable content, configure the `SCStream`, and start capture.
    /// The first `SCShareableContent.current` call triggers the Screen
    /// Recording TCC check.
    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SystemCaptureError.noDisplay
        }

        let contentFilter: SCContentFilter
        switch filter {
        case .allApps:
            contentFilter = SCContentFilter(display: display, excludingWindows: [])
        case .pid(let pid):
            guard let app = content.applications.first(where: {
                $0.processID == pid
            }) else {
                throw SystemCaptureError.noMatchingApplication(pid)
            }
            contentFilter = SCContentFilter(
                display: display, including: [app], exceptingWindows: [])
        }

        // Audio-only in practice: no `.screen` output is added. A minimal video
        // configuration is still required for the stream to start.
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        let stream = SCStream(
            filter: contentFilter, configuration: config, delegate: self)
        try stream.addStreamOutput(
            self, type: .audio, sampleHandlerQueue: deliveryQueue)
        try await stream.startCapture()
        lock.withLock {
            self.stream = stream
            running = true
        }
        watchdog.onStall = onStall
        watchdog.arm()
    }

    /// Stop capture and emit any zero-padded final partial frame.
    func stop() async {
        // Disarm first — drains the watchdog queue so it cannot fire (and
        // request a restart) after `stop()` returns.
        watchdog.disarm()
        let stream = lock.withLock { () -> SCStream? in
            running = false
            return self.stream
        }
        if let stream { try? await stream.stopCapture() }
        lock.withLock { self.stream = nil }
        if let tail = lock.withLock({ converter.flush() }) {
            emitFrame(tail)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        let frames: [[Float]] = lock.withLock {
            guard running else { return [] }
            return converter.frames(from: sampleBuffer)
        }
        for samples in frames { emitFrame(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    private func emitFrame(_ samples: [Float]) {
        watchdog.notifyFrame()
        let index = lock.withLock { () -> Int in
            defer { sequenceIndex += 1 }
            return sequenceIndex
        }
        onEvent?(.frame(AudioFrame(samples: samples, sequenceIndex: index)))
    }
}

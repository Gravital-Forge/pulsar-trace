import AVFoundation
import Foundation
import PulsarTraceEngine

/// Captures the microphone via AVFoundation and emits canonical 16 kHz mono
/// Float32 frames as `AudioStreamEvent.frame` values (R1).
///
/// The engine only produces `.frame` events; pause/resume are injected by
/// `DeviceCaptureSource` around it (sleep/wake, device change). The
/// `AVCaptureAudioDataOutput` delegate fires on a private queue, so the
/// mutable state (`SampleBufferConverter`, the sequence counter) is lock-guarded
/// and the type is `@unchecked Sendable`.
final class MicCaptureEngine: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    enum MicCaptureError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case sessionRejectedInput
        case sessionRejectedOutput

        var description: String {
            switch self {
            case .deviceNotFound(let id):
                return "no audio input device matching '\(id)'"
            case .sessionRejectedInput:
                return "AVCaptureSession rejected the microphone input"
            case .sessionRejectedOutput:
                return "AVCaptureSession rejected the audio data output"
            }
        }
    }

    /// Max silence (no delivered frame) before the mic is treated as silently
    /// stalled. A live `AVCaptureSession` delivers buffers continuously even
    /// from a muted mic, so any real gap this long is a stall; 4 s clears
    /// normal scheduling jitter while reacting faster than system audio.
    static let stallThreshold: Duration = .seconds(4)

    /// Frame sink — set before `start()`. Invoked on the capture delivery queue.
    var onEvent: (@Sendable (AudioStreamEvent) -> Void)?
    /// Reports that the mic went silent — no frame within `stallThreshold` —
    /// with no error. Invoked once on the watchdog's private queue.
    var onStall: (@Sendable () -> Void)?

    /// Display name of the microphone resolved by `start()`; `none` until then.
    private(set) var deviceName = "none"

    private let requestedDeviceID: String?
    private let session = AVCaptureSession()
    private let deliveryQueue = DispatchQueue(label: "com.pulsartrace.capture.mic")
    private let watchdog = FrameWatchdog(
        threshold: MicCaptureEngine.stallThreshold,
        label: "com.pulsartrace.capture.mic.watchdog")

    private let lock = NSLock()
    private let converter = SampleBufferConverter()
    private var sequenceIndex = 0
    private var running = false

    /// - Parameter deviceID: an `AVCaptureDevice.uniqueID`, or `nil` for the
    ///   system default microphone (R5).
    init(deviceID: String?) {
        self.requestedDeviceID = deviceID
        super.init()
    }

    /// Every audio input device AVFoundation exposes — the source for the
    /// menubar mic picker and the CLI `--mic-device` flag (R5).
    static func availableDevices() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Resolve the device, wire up the capture session, and start running.
    func start() throws {
        let device = try resolveDevice()
        deviceName = device.localizedName

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicCaptureError.sessionRejectedInput
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicCaptureError.sessionRejectedOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        lock.withLock { running = true }
        session.startRunning()
        watchdog.onStall = onStall
        watchdog.arm()
    }

    /// Stop running and emit any zero-padded final partial frame.
    func stop() {
        // Disarm first — drains the watchdog queue so it cannot fire (and
        // request a restart) after `stop()` returns.
        watchdog.disarm()
        lock.withLock { running = false }
        if session.isRunning { session.stopRunning() }
        if let tail = lock.withLock({ converter.flush() }) {
            emitFrame(tail)
        }
    }

    private func resolveDevice() throws -> AVCaptureDevice {
        if let requestedDeviceID {
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio, position: .unspecified).devices
            guard let device = devices.first(where: {
                $0.uniqueID == requestedDeviceID
            }) else {
                throw MicCaptureError.deviceNotFound(requestedDeviceID)
            }
            return device
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicCaptureError.deviceNotFound("default")
        }
        return device
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let frames: [[Float]] = lock.withLock {
            guard running else { return [] }
            return converter.frames(from: sampleBuffer)
        }
        for samples in frames { emitFrame(samples) }
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

import Foundation
import PulsarTraceEngine

/// Test seam for the two concrete capture engines.
///
/// `DeviceCaptureSource` constructs its microphone and system-audio engines
/// through injectable factory closures (`makeMicEngine` / `makeSystemEngine`)
/// that default to the real `MicCaptureEngine` / `SystemAudioCaptureEngine`.
/// These protocols expose *exactly* the surface `DeviceCaptureSource` touches,
/// so `StallRecoveryTests` can drive the production wiring — stall handling,
/// frame-verified recovery, the no-frame retry — with fake engines that never
/// touch audio hardware or TCC-gated system services.
///
/// The seam is `internal`: production code always gets the real engines.

/// What `DeviceCaptureSource` needs from a microphone engine.
protocol MicCapturing: AnyObject, Sendable {
    var onEvent: (@Sendable (AudioStreamEvent) -> Void)? { get set }
    var onStall: (@Sendable () -> Void)? { get set }
    var deviceName: String { get }
    func start() throws
    func stop()
}

/// What `DeviceCaptureSource` needs from a system-audio engine.
protocol SystemAudioCapturing: AnyObject, Sendable {
    var onEvent: (@Sendable (AudioStreamEvent) -> Void)? { get set }
    var onStall: (@Sendable () -> Void)? { get set }
    var onStreamError: (@Sendable (Error) -> Void)? { get set }
    func start() async throws
    func stop() async
}

extension MicCaptureEngine: MicCapturing {}
extension SystemAudioCaptureEngine: SystemAudioCapturing {}

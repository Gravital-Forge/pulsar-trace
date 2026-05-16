import AVFoundation
import PulsarTraceEngine
import ScreenCaptureKit

/// Checks — and, where it can, requests — the two TCC permissions
/// `pulsartrace-capture` needs: Microphone (R1) and Screen Recording (R2).
/// The capture daemon is the *only* PulsarTrace process that needs either
/// (R4); the engine has no TCC requirements.
///
/// Each check emits a `permission_changed` event so a consumer tailing the
/// events log sees the permission state at session start and whenever it moves.
public struct PermissionChecker {

    /// The result of checking both permissions.
    public struct Status: Sendable {
        public let microphoneGranted: Bool
        public let screenRecordingGranted: Bool
    }

    let events: EventWriter?

    public init(events: EventWriter?) {
        self.events = events
    }

    /// Microphone TCC status — a synchronous read.
    public func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Screen Recording TCC status. macOS exposes no synchronous query; the
    /// canonical probe on macOS 14+ is whether shareable content can be read.
    public func screenRecordingGranted() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    /// Request the Microphone grant when the user has not yet decided.
    /// Returns the resulting grant state.
    public func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Check both permissions and emit a `permission_changed` event for each,
    /// establishing the session's baseline in the events log.
    public func checkAndEmit() async -> Status {
        let microphone = microphoneGranted()
        let screenRecording = await screenRecordingGranted()
        await emit(permission: "microphone", granted: microphone)
        await emit(permission: "screen_recording", granted: screenRecording)
        return Status(
            microphoneGranted: microphone,
            screenRecordingGranted: screenRecording)
    }

    private func emit(permission: String, granted: Bool) async {
        guard let events else { return }
        _ = try? await events.append(
            PermissionChangedEvent(permission: permission, granted: granted))
    }
}

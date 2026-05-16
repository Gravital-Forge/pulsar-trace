import Foundation
import Testing

extension Tag {
    /// Tests that drive real audio hardware — the BlackHole loopback device and
    /// the TCC-gated AVFoundation / ScreenCaptureKit capture APIs. They need a
    /// physical Mac with audio devices and granted Microphone / Screen
    /// Recording permission, so they never run on CI or in a default
    /// `swift test` pass. See `DeviceTestGate`.
    @Tag static var liveCapture: Self
}

/// Opt-in gate for the Layer-3 live-capture device tests.
///
/// These tests touch real hardware and TCC-gated system services, so they are
/// **disabled unless explicitly opted in** — a plain `swift test`, and CI, skip
/// them cleanly. To run them on a Mac with BlackHole installed and Microphone +
/// Screen Recording permission granted:
///
///     PULSARTRACE_DEVICE_TESTS=1 swift test --filter Capture
///
/// Even when opted in, each test still *skips* (rather than fails) if the
/// specific device or permission it needs is absent, so opting in on an
/// underprovisioned host is a clean run too.
enum DeviceTestGate {
    /// `true` only when `PULSARTRACE_DEVICE_TESTS` is set to `1`, `true`, or `yes`.
    static var enabled: Bool {
        switch ProcessInfo.processInfo.environment["PULSARTRACE_DEVICE_TESTS"]?
            .lowercased()
        {
        case "1", "true", "yes": return true
        default: return false
        }
    }
}

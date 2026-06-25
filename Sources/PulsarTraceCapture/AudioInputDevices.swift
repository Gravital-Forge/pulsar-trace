import AVFoundation

/// One audio input device the host exposes — the unit `pulsartrace record
/// --mic INDEX` (PT-R47) indexes into, and the menubar mic picker (PT-R42) lists.
public struct AudioInputDevice: Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID` — what `pulsartrace-capture --mic-device`
    /// expects. Stable for a given physical device.
    public let uniqueID: String
    /// Human-readable device name (`MacBook Air Microphone`).
    public let name: String

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

/// Enumerates the host's audio input devices.
///
/// The public entry point for device discovery: the CLI maps `--mic INDEX`
/// against `available()`, and the menubar mic picker lists it. Order is the
/// `AVCaptureDevice.DiscoverySession` order, stable within a session — the
/// index is only meaningful alongside a freshly-printed list.
public enum AudioInputDevices {

    /// Every audio input device AVFoundation exposes, in discovery order.
    public static func available() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map {
            AudioInputDevice(uniqueID: $0.uniqueID, name: $0.localizedName)
        }
    }
}

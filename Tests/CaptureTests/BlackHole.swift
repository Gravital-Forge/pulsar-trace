import Foundation
import CoreAudio

/// Detects the BlackHole virtual audio device used by Layer 3 capture tests.
///
/// The `Capture` test layer exercises the real `AVFoundation` /
/// `ScreenCaptureKit` paths and needs BlackHole 2ch installed (R66). On
/// machines without it — including this EC2 Mac, which has no audio devices —
/// `requireInstalled()` raises a skip so the suite passes cleanly with a clear
/// message instead of failing.
enum BlackHole {

    /// Raised when BlackHole is absent; tests catch this to skip gracefully.
    struct NotInstalled: Error, CustomStringConvertible {
        var description: String {
            "BlackHole 2ch is not installed — Capture-layer tests are skipped. "
                + "Install from https://existential.audio/blackhole/ to run them."
        }
    }

    /// `true` if a CoreAudio device whose name contains "BlackHole" exists.
    static var isInstalled: Bool {
        deviceNames.contains { $0.localizedCaseInsensitiveContains("BlackHole") }
    }

    /// Throw `NotInstalled` unless BlackHole is present.
    static func requireInstalled() throws {
        guard isInstalled else { throw NotInstalled() }
    }

    /// Names of all CoreAudio output/input devices on this host.
    static var deviceNames: [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr
        else {
            return []
        }

        return ids.compactMap { name(of: $0) }
    }

    /// Human-readable name of a CoreAudio device, if available.
    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue()
        else {
            return nil
        }
        return cf as String
    }
}

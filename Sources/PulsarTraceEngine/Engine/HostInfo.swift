import Foundation

/// Static facts about the host and build, used to stamp events and log lines.
public enum HostInfo {
    /// PulsarTrace version. Pre-release for now; bumped at distribution.
    public static let appVersion = "0.1.0-dev"

    /// Host macOS version, e.g. `26.3.1`.
    public static var macosVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

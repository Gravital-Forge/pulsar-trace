import Foundation

/// Single home for the owner-only on-disk permission policy (0700 dirs /
/// 0600 files) applied to everything PulsarTrace writes that can contain
/// meeting content or speaker identity: transcripts, audio, the events
/// log, the speaker library, and the per-session sockets.
///
/// Two directory flavors exist because the policy differs by ownership:
/// directories PulsarTrace owns outright are *enforced* private (created
/// 0700 and repaired if a pre-hardening run left them 0755); directories
/// in user-chosen territory (recording output folders) are made private
/// only when PulsarTrace creates them fresh — an existing directory's
/// permissions are the user's deliberate choice and are never touched.
public enum SecureFiles {

    /// Create-and-enforce: a directory PulsarTrace owns. Creates it (and
    /// any intermediates) 0700, then repairs the leaf to 0700 if a
    /// previous version of the app created it with looser permissions.
    public static func ensurePrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory` is a no-op (and applies no attributes) when
        // the directory already exists — repair explicitly.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Create-if-new: a directory in user-chosen territory. Fresh
    /// directories are 0700; an existing one is left exactly as the
    /// user has it.
    public static func createDirectoryPrivateIfNew(at url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// `FileManager.createFile` with owner-only (0600) permissions.
    /// Same truncate-if-exists semantics as the Foundation call it wraps.
    @discardableResult
    public static func createPrivateFile(atPath path: String) -> Bool {
        FileManager.default.createFile(
            atPath: path, contents: nil,
            attributes: [.posixPermissions: 0o600])
    }

    /// Repair an existing file to 0600 — for files created by APIs that
    /// take no mode (SQLite, `FileManager.replaceItemAt`). Missing files
    /// are a silent no-op.
    public static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

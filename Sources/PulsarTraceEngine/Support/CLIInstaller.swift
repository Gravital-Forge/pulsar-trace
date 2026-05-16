import Foundation

/// Installs (and removes) the `pulsartrace` symlink in a `bin` directory —
/// the mechanism behind R51 ("CLI is symlinked into `/usr/local/bin` … with
/// user consent").
///
/// Consent is the explicit `pulsartrace install-cli` invocation; this type
/// only performs the filesystem work. It is pure with respect to its injected
/// `binDirectory`, so the whole state machine is testable against a temp
/// directory — no `/usr/local/bin` write needed.
public struct CLIInstaller: Sendable {
    /// Directory the symlink lives in — `/usr/local/bin` in production.
    public let binDirectory: URL
    /// The real `pulsartrace` executable the symlink should point at.
    public let executableURL: URL
    /// The symlink name in `binDirectory`.
    public let linkName: String

    public init(
        binDirectory: URL,
        executableURL: URL,
        linkName: String = "pulsartrace"
    ) {
        self.binDirectory = binDirectory
        self.executableURL = executableURL.resolvingSymlinksInPath()
        self.linkName = linkName
    }

    /// Full path the symlink occupies.
    public var symlinkURL: URL {
        binDirectory.appendingPathComponent(linkName, isDirectory: false)
    }

    // MARK: - State

    /// What currently occupies `symlinkURL`.
    public enum LinkState: Equatable, Sendable {
        /// Nothing is there.
        case absent
        /// A symlink already pointing at our executable.
        case linkedToUs
        /// A symlink pointing somewhere else (a stale or third-party install).
        case linkedElsewhere(URL)
        /// A real (non-symlink) file is in the way.
        case occupiedByFile
    }

    /// Inspect `symlinkURL`.
    public func currentState() -> LinkState {
        let fm = FileManager.default
        let path = symlinkURL.path
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            // `attributesOfItem` does not follow symlinks, so a broken symlink
            // still has attributes; a true absence throws.
            return .absent
        }
        guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else {
            return .occupiedByFile
        }
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else {
            return .absent
        }
        // A symlink destination may be relative to `binDirectory`.
        let destURL = URL(fileURLWithPath: dest, relativeTo: binDirectory)
            .resolvingSymlinksInPath()
        return destURL == executableURL ? .linkedToUs : .linkedElsewhere(destURL)
    }

    // MARK: - Install

    /// The outcome of `install()`.
    public enum InstallResult: Equatable, Sendable {
        /// A fresh symlink was created.
        case created
        /// The symlink already pointed at us — nothing to do.
        case alreadyInstalled
        /// An existing symlink (stale / elsewhere) was repointed at us.
        case updated
        /// `binDirectory` is not writable; run the returned command with sudo.
        case needsElevation(command: String)
        /// A real file occupies `symlinkURL` — refuse to clobber it.
        case blockedByFile
    }

    /// Create or update the symlink.
    public func install() -> InstallResult {
        switch currentState() {
        case .linkedToUs:
            return .alreadyInstalled
        case .occupiedByFile:
            return .blockedByFile
        case .absent:
            return write(replacingExisting: false)
                ? .created : .needsElevation(command: installCommand)
        case .linkedElsewhere:
            return write(replacingExisting: true)
                ? .updated : .needsElevation(command: installCommand)
        }
    }

    /// The `sudo` command that performs the install when `binDirectory` is not
    /// user-writable — `-f` so it replaces a stale symlink atomically.
    public var installCommand: String {
        "sudo ln -sf \(shellQuote(executableURL.path)) "
            + shellQuote(symlinkURL.path)
    }

    /// Attempt the symlink write. Returns `false` when the filesystem refuses
    /// (a not-writable `binDirectory`) — the caller falls back to elevation.
    private func write(replacingExisting: Bool) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: binDirectory.path) {
            guard (try? fm.createDirectory(
                at: binDirectory, withIntermediateDirectories: true)) != nil
            else { return false }
        }
        if replacingExisting {
            guard (try? fm.removeItem(at: symlinkURL)) != nil else { return false }
        }
        return (try? fm.createSymbolicLink(
            at: symlinkURL, withDestinationURL: executableURL)) != nil
    }

    // MARK: - Uninstall

    /// The outcome of `uninstall()`.
    public enum UninstallResult: Equatable, Sendable {
        /// Our symlink was removed.
        case removed
        /// There was no symlink to remove.
        case notInstalled
        /// `binDirectory` is not writable; run the returned command with sudo.
        case needsElevation(command: String)
        /// What is at `symlinkURL` is not ours — left untouched.
        case notOurs
    }

    /// Remove the symlink — only when it actually points at us.
    public func uninstall() -> UninstallResult {
        switch currentState() {
        case .absent:
            return .notInstalled
        case .occupiedByFile, .linkedElsewhere:
            return .notOurs
        case .linkedToUs:
            return (try? FileManager.default.removeItem(at: symlinkURL)) != nil
                ? .removed
                : .needsElevation(command:
                    "sudo rm \(shellQuote(symlinkURL.path))")
        }
    }

    // MARK: - Helpers

    /// Single-quote a path for safe inclusion in a shell command.
    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

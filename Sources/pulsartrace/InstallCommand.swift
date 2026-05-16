import Foundation
import PulsarTraceEngine

/// `pulsartrace install-cli [--uninstall]` — symlink `pulsartrace` into
/// `/usr/local/bin` so it is on `PATH` (R51).
///
/// R51 requires user consent rather than a silent install. Running this
/// subcommand explicitly *is* that consent — the command prints exactly what
/// it links and where, and never installs as a side effect of another action.
/// When `/usr/local/bin` is not user-writable it prints the `sudo` command to
/// run instead of failing opaquely.
enum InstallCommand {

    /// The conventional location for user-installed CLIs.
    private static let binDirectory = URL(
        fileURLWithPath: "/usr/local/bin", isDirectory: true)

    /// Run `pulsartrace install-cli`. Returns the process exit code.
    static func run(_ args: [String]) -> Int32 {
        var uninstall = false
        for arg in args {
            switch arg {
            case "--uninstall":
                uninstall = true
            default:
                err("install-cli: unexpected argument '\(arg)'")
                err("usage: pulsartrace install-cli [--uninstall]")
                return 2
            }
        }

        guard let executableURL = resolveExecutableURL() else {
            err("install-cli: could not locate the running pulsartrace binary")
            return 1
        }
        let installer = CLIInstaller(
            binDirectory: binDirectory, executableURL: executableURL)

        return uninstall ? runUninstall(installer) : runInstall(installer)
    }

    // MARK: - install

    private static func runInstall(_ installer: CLIInstaller) -> Int32 {
        switch installer.install() {
        case .created:
            out("install-cli: linked \(installer.symlinkURL.path) → "
                + installer.executableURL.path)
            out("`pulsartrace` is now on your PATH.")
            return 0
        case .updated:
            out("install-cli: updated \(installer.symlinkURL.path) → "
                + installer.executableURL.path)
            return 0
        case .alreadyInstalled:
            out("install-cli: already installed at \(installer.symlinkURL.path)")
            return 0
        case .needsElevation(let command):
            err("install-cli: /usr/local/bin is not writable. Run:")
            err("  \(command)")
            return 1
        case .blockedByFile:
            err("install-cli: a file already exists at "
                + "\(installer.symlinkURL.path) and is not a symlink — "
                + "remove it first, then re-run.")
            return 1
        }
    }

    // MARK: - uninstall

    private static func runUninstall(_ installer: CLIInstaller) -> Int32 {
        switch installer.uninstall() {
        case .removed:
            out("install-cli: removed \(installer.symlinkURL.path)")
            return 0
        case .notInstalled:
            out("install-cli: nothing to remove — "
                + "\(installer.symlinkURL.path) does not exist")
            return 0
        case .needsElevation(let command):
            err("install-cli: /usr/local/bin is not writable. Run:")
            err("  \(command)")
            return 1
        case .notOurs:
            err("install-cli: \(installer.symlinkURL.path) is not a "
                + "PulsarTrace symlink — left untouched.")
            return 1
        }
    }

    // MARK: - helpers

    /// The absolute path of the running `pulsartrace` binary, symlinks
    /// resolved so the installed symlink always points at the real file.
    private static func resolveExecutableURL() -> URL? {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath()
        }
        let arg0 = CommandLine.arguments.first ?? ""
        guard !arg0.isEmpty else { return nil }
        return URL(fileURLWithPath: arg0).resolvingSymlinksInPath()
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

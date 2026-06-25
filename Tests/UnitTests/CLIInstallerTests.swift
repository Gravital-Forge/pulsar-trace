import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 1 — `CLIInstaller`, the symlink state machine behind
/// `pulsartrace install-cli` (PT-R51). Runs against a temp `bin` directory so it
/// never touches the real `/usr/local/bin`.
@Suite("CLIInstaller (install-cli, PT-R51)")
struct CLIInstallerTests {

    /// A temp `bin` dir + a stand-in executable file, cleaned up by the caller.
    private func sandbox() -> (binDir: URL, exe: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("pt-install-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let exe = root.appendingPathComponent("pulsartrace")
        fm.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8))
        return (binDir, exe, { try? fm.removeItem(at: root) })
    }

    @Test("a fresh install creates the symlink and reports linkedToUs after")
    func freshInstall() {
        let s = sandbox()
        defer { s.cleanup() }
        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)

        #expect(installer.currentState() == .absent)
        #expect(installer.install() == .created)
        #expect(installer.currentState() == .linkedToUs)
    }

    @Test("installing again is idempotent — alreadyInstalled")
    func idempotentInstall() {
        let s = sandbox()
        defer { s.cleanup() }
        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)

        #expect(installer.install() == .created)
        #expect(installer.install() == .alreadyInstalled)
    }

    @Test("a symlink pointing elsewhere is repointed at us — updated")
    func repointStaleSymlink() throws {
        let s = sandbox()
        defer { s.cleanup() }
        let stale = s.binDir.deletingLastPathComponent()
            .appendingPathComponent("old-pulsartrace")
        FileManager.default.createFile(atPath: stale.path, contents: Data())
        let link = s.binDir.appendingPathComponent("pulsartrace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stale)

        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)
        #expect(installer.currentState() == .linkedElsewhere(stale))
        #expect(installer.install() == .updated)
        #expect(installer.currentState() == .linkedToUs)
    }

    @Test("a real file in the way is never clobbered — blockedByFile")
    func realFileBlocksInstall() {
        let s = sandbox()
        defer { s.cleanup() }
        let occupied = s.binDir.appendingPathComponent("pulsartrace")
        FileManager.default.createFile(atPath: occupied.path, contents: Data("x".utf8))

        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)
        #expect(installer.currentState() == .occupiedByFile)
        #expect(installer.install() == .blockedByFile)
    }

    @Test("uninstall removes our symlink and is a no-op when absent")
    func uninstall() {
        let s = sandbox()
        defer { s.cleanup() }
        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)

        #expect(installer.uninstall() == .notInstalled)
        #expect(installer.install() == .created)
        #expect(installer.uninstall() == .removed)
        #expect(installer.currentState() == .absent)
    }

    @Test("uninstall refuses to remove a symlink that is not ours")
    func uninstallLeavesForeignSymlink() throws {
        let s = sandbox()
        defer { s.cleanup() }
        let foreign = s.binDir.deletingLastPathComponent()
            .appendingPathComponent("other-tool")
        FileManager.default.createFile(atPath: foreign.path, contents: Data())
        let link = s.binDir.appendingPathComponent("pulsartrace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)

        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)
        #expect(installer.uninstall() == .notOurs)
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("the elevation command names both the executable and the symlink")
    func elevationCommand() {
        let s = sandbox()
        defer { s.cleanup() }
        let installer = CLIInstaller(binDirectory: s.binDir, executableURL: s.exe)
        let command = installer.installCommand
        #expect(command.hasPrefix("sudo ln -sf "))
        #expect(command.contains(s.exe.resolvingSymlinksInPath().path))
        #expect(command.contains("pulsartrace"))
    }
}

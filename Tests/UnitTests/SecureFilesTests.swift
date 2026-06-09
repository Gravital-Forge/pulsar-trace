import Foundation
import Testing
@testable import PulsarTraceEngine

/// Unit coverage for `SecureFiles`, the single home of the owner-only
/// (0600/0700) on-disk permission policy for content-bearing artifacts.
@Suite("SecureFiles permission policy")
struct SecureFilesTests {

    private func tempBase() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-secure-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(ofPath path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("ensurePrivateDirectory creates a 0700 directory")
    func ensureCreates0700() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("owned", isDirectory: true)

        try SecureFiles.ensurePrivateDirectory(at: dir)

        #expect(mode(ofPath: dir.path) == 0o700)
    }

    @Test("ensurePrivateDirectory repairs an existing 0755 directory to 0700")
    func ensureRepairsExisting() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        try SecureFiles.ensurePrivateDirectory(at: dir)

        #expect(mode(ofPath: dir.path) == 0o700)
    }

    @Test("createDirectoryPrivateIfNew creates fresh dirs 0700")
    func ifNewCreates0700() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("fresh", isDirectory: true)

        try SecureFiles.createDirectoryPrivateIfNew(at: dir)

        #expect(mode(ofPath: dir.path) == 0o700)
    }

    @Test("createDirectoryPrivateIfNew leaves an existing user dir untouched")
    func ifNewLeavesExisting() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("users-own", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        try SecureFiles.createDirectoryPrivateIfNew(at: dir)

        #expect(mode(ofPath: dir.path) == 0o755)
    }

    @Test("createPrivateFile creates a 0600 file")
    func createPrivateFile0600() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("secret.md")

        #expect(SecureFiles.createPrivateFile(atPath: file.path))

        #expect(mode(ofPath: file.path) == 0o600)
    }

    @Test("restrictToOwner repairs an existing 0644 file to 0600")
    func restrictRepairs() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("legacy.md")
        FileManager.default.createFile(
            atPath: file.path, contents: Data("x".utf8),
            attributes: [.posixPermissions: 0o644])

        SecureFiles.restrictToOwner(file)

        #expect(mode(ofPath: file.path) == 0o600)
    }
}

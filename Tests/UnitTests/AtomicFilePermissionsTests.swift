import Foundation
import Testing
@testable import PulsarTraceEngine

/// `AtomicFile` writes `final.md` / `metadata.json` — meeting content.
/// Both the fresh-write and replace-existing paths must yield 0600.
@Suite("AtomicFile permissions")
struct AtomicFilePermissionsTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-atomic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a fresh atomic write produces a 0600 file")
    func freshWriteIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("final.md")

        try AtomicFile.write("# transcript", to: url)

        #expect(mode(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# transcript")
    }

    @Test("replacing a pre-hardening 0644 file converges to 0600")
    func replaceRepairsPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("final.md")
        FileManager.default.createFile(
            atPath: url.path, contents: Data("old".utf8),
            attributes: [.posixPermissions: 0o644])

        try AtomicFile.write("new", to: url)

        #expect(mode(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    @Test("a successful write leaves no stray temp file")
    func noStrayTempOnSuccess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metadata.json")

        try AtomicFile.write("{}", to: url)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["metadata.json"])
    }
}

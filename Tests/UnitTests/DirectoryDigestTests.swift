import Darwin
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("DirectoryDigest")
struct DirectoryDigestTests {

    private func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-\(UUID().uuidString)", isDirectory: true)
        for (relPath, contents) in files {
            let url = root.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test func digestIsDeterministicAndOrderIndependent() throws {
        let a = try makeTree(["b.bin": "BB", "sub/a.bin": "AA"])
        let b = try makeTree(["sub/a.bin": "AA", "b.bin": "BB"])
        let da = try DirectoryDigest.compute(at: a)
        let db = try DirectoryDigest.compute(at: b)
        #expect(da.sha256 == db.sha256)
        #expect(da.sha256.count == 64)
        #expect(da.totalBytes == 4)
    }

    @Test func contentChangeChangesDigest() throws {
        let a = try makeTree(["m.bin": "one"])
        let b = try makeTree(["m.bin": "two"])
        #expect(try DirectoryDigest.compute(at: a).sha256
            != (try DirectoryDigest.compute(at: b).sha256))
    }

    @Test func pathChangeChangesDigest() throws {
        let a = try makeTree(["x.bin": "same"])
        let b = try makeTree(["y.bin": "same"])
        #expect(try DirectoryDigest.compute(at: a).sha256
            != (try DirectoryDigest.compute(at: b).sha256))
    }

    @Test func absoluteRootPathRecurringInsideTreeDoesNotCollide() throws {
        // Old-bug shape: the prior derivation did
        // `url.path.replacingOccurrences(of: root.path + "/", with: "")`,
        // which strips EVERY occurrence of the absolute root path — not just
        // the leading prefix. Tree A nests the root's own absolute path inside
        // the tree, at `<rootA>/z<rootA-absolute-path>/y.bin`. Under the old
        // derivation that file's relative path collapsed from
        // `z<rootA-absolute-path>/y.bin` to `zy.bin` (the inner occurrence of
        // `rootA.path + "/"` got stripped too). Tree B is a separate root with
        // a single file literally at `zy.bin`, same content. So the old code
        // produced the identical manifest entry `zy.bin` for both trees and
        // they collided on digest. The fixed `.producesRelativePathURLs` /
        // `url.relativePath` derivation keeps the full nested path, so the
        // relative paths — and digests — differ.
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-collideA-\(UUID().uuidString)", isDirectory: true)
        // Embedding `rootA.path` (which contains slashes) as a path component
        // mirrors the absolute path as a real nested directory chain inside A.
        let nestedA = rootA
            .appendingPathComponent("z" + rootA.path)
            .appendingPathComponent("y.bin")
        try FileManager.default.createDirectory(
            at: nestedA.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("Q".utf8).write(to: nestedA)

        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-collideB-\(UUID().uuidString)", isDirectory: true)
        let plainB = rootB.appendingPathComponent("zy.bin")
        try FileManager.default.createDirectory(
            at: plainB.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("Q".utf8).write(to: plainB)

        #expect(try DirectoryDigest.compute(at: rootA).sha256
            != (try DirectoryDigest.compute(at: rootB).sha256))
    }

    @Test func nonDirectoryThrowsNotADirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: DirectoryDigest.DigestError.notADirectory(missing.lastPathComponent)) {
            try DirectoryDigest.compute(at: missing)
        }
    }

    @Test func emptyDirectoryDigestsDeterministically() throws {
        let a = try makeTree([:])
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let b = try makeTree([:])
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let da = try DirectoryDigest.compute(at: a)
        let db = try DirectoryDigest.compute(at: b)
        #expect(da.sha256 == db.sha256)
        #expect(da.sha256.count == 64)
        #expect(da.totalBytes == 0)
    }

    // Gate: root bypasses POSIX permission checks, so the unreadable
    // subdirectory below would stay enumerable and the digest would not throw.
    @Test(.enabled(if: getuid() != 0))
    func unreadableSubdirectoryFailsLoudly() throws {
        // Pin the fail-loudly path: an enumeration error (here, an unreadable
        // subdirectory) is captured by the errorHandler and rethrown, rather
        // than silently digesting a partial tree as if it were complete.
        let root = try makeTree(["readable.bin": "ok"])
        let sub = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: sub.appendingPathComponent("inner.bin"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: sub.path)
        // Restore so the temp tree can be torn down regardless of outcome.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sub.path)
        }
        #expect(throws: (any Error).self) {
            try DirectoryDigest.compute(at: root)
        }
    }

    @Test func goldenVector() throws {
        // The manifest format is frozen — if this changes, every
        // model_downloaded identity changes; that must be deliberate.
        let root = try makeTree(["b.bin": "BB", "sub/a.bin": "AA"])
        let digest = try DirectoryDigest.compute(at: root)
        #expect(digest.sha256
            == "683e8644e8967938e74aab87413065db40f428581756603ce6c2261c19cfac85")
    }
}

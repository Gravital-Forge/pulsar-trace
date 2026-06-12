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

    @Test func repeatedPathSegmentDoesNotCorruptManifest() throws {
        // Tree A's root last component is repeated as an inner subdirectory
        // (`.../seg/seg/y.bin`). The old `replacingOccurrences(of: root + "/")`
        // derivation strips *every* occurrence, corrupting the relative path to
        // `y.bin` instead of `seg/y.bin`. Tree B has a different root name but
        // the SAME inner relative layout (`seg/y.bin`). With correct relative
        // paths both yield `seg/y.bin` and digest identically (root-name
        // independent); the old code made them differ.
        let segment = "seg"
        func makeTree(rootName: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(rootName)-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(rootName, isDirectory: true)
            let url = root
                .appendingPathComponent(segment, isDirectory: true)
                .appendingPathComponent("y.bin")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("Q".utf8).write(to: url)
            return root
        }
        // Root A's last component IS `seg`, so the tree is `.../seg/seg/y.bin`.
        let a = try makeTree(rootName: segment)
        // Root B's last component is different, layout still `seg/y.bin`.
        let b = try makeTree(rootName: "other")
        #expect(try DirectoryDigest.compute(at: a).sha256
            == (try DirectoryDigest.compute(at: b).sha256))
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

    @Test func goldenVector() throws {
        // The manifest format is frozen — if this changes, every
        // model_downloaded identity changes; that must be deliberate.
        let root = try makeTree(["b.bin": "BB", "sub/a.bin": "AA"])
        let digest = try DirectoryDigest.compute(at: root)
        #expect(digest.sha256
            == "683e8644e8967938e74aab87413065db40f428581756603ce6c2261c19cfac85")
    }
}

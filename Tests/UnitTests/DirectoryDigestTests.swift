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
}

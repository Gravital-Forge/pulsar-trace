> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 05: DirectoryDigest (pure)

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/DirectoryDigest.swift`
- Test: `Tests/UnitTests/DirectoryDigestTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/UnitTests/DirectoryDigestTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DirectoryDigest` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — `cannot find 'DirectoryDigest' in scope`.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/DirectoryDigest.swift`:

```swift
import CryptoKit
import Foundation

/// Deterministic content digest of a model directory tree.
///
/// CoreML model bundles (Parakeet, WhisperKit) are directories of files
/// managed by their SDKs — there is no single ggml file to pin a SHA-256
/// against (DECISIONS D39). This digest gives the `model_downloaded` event
/// an honest, reproducible identity: SHA-256 over every regular file's
/// `relativePath + "\0" + fileSHA256 + "\n"`, files ordered by relative
/// path. Two trees with identical contents and layout digest identically,
/// regardless of enumeration order or timestamps.
public enum DirectoryDigest {

    public struct Output: Sendable, Equatable {
        /// Lowercase-hex SHA-256 of the tree manifest described above.
        public let sha256: String
        /// Sum of all regular files' sizes in bytes.
        public let totalBytes: Int
    }

    public enum DigestError: Error {
        case notADirectory(String)
    }

    public static func compute(at root: URL) throws -> Output {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw DigestError.notADirectory(root.lastPathComponent)
        }

        var files: [(relative: String, url: URL)] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let relative = url.path.replacingOccurrences(
                    of: root.path + "/", with: "")
                files.append((relative, url))
            }
        }
        files.sort { $0.relative < $1.relative }

        var manifest = SHA256()
        var totalBytes = 0
        for file in files {
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            totalBytes += data.count
            let fileHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            manifest.update(data: Data("\(file.relative)\u{0}\(fileHash)\n".utf8))
        }
        let digest = manifest.finalize()
            .map { String(format: "%02x", $0) }.joined()
        return Output(sha256: digest, totalBytes: totalBytes)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DirectoryDigest`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/DirectoryDigest.swift Tests/UnitTests/DirectoryDigestTests.swift
git commit -m "feat(models): DirectoryDigest — deterministic tree hash for CoreML bundle events"
```

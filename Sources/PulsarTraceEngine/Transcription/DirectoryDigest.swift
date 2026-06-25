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
///
/// Symlinks are not followed and do not affect the digest (only regular
/// files are hashed). The tree is assumed quiescent during computation —
/// mapped reads race a concurrent rewrite — so call this only after the
/// SDK download has fully completed.
public enum DirectoryDigest {

    public struct Output: Sendable, Equatable {
        /// Lowercase-hex SHA-256 of the tree manifest described above.
        public let sha256: String
        /// Sum of all regular files' sizes in bytes.
        public let totalBytes: Int
    }

    public enum DigestError: Error, Equatable {
        // Payloads deliberately carry only `lastPathComponent`, never full
        // user paths — matches the project rule against full paths in
        // logs/events.
        case notADirectory(String)
        case unreadable(String)   // enumeration could not start
    }

    public static func compute(at root: URL) throws -> Output {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw DigestError.notADirectory(root.lastPathComponent)
        }

        // Capture the first enumeration error and stop the walk; a partial
        // tree must fail loudly rather than digest as if it were complete.
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .producesRelativePathURLs],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }) else {
            throw DigestError.unreadable(root.lastPathComponent)
        }

        var files: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            files.append((url.relativePath, url))
        }
        if let enumerationError {
            throw enumerationError
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

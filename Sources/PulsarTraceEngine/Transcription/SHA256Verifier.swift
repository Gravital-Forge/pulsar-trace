import Foundation
import CryptoKit

/// SHA-256 hashing for model integrity verification (R54d).
///
/// Files are hashed in a streaming fashion (64 KiB chunks) so a 3 GB model is
/// never fully resident just to be hashed.
public enum SHA256Verifier {

    /// Compute the lowercase-hex SHA-256 of the file at `url`.
    public static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase-hex SHA-256 of an in-memory buffer.
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when the file at `url` hashes to `expectedHex` (case-insensitive).
    public static func verify(fileAt url: URL, matches expectedHex: String) throws -> Bool {
        let actual = try hexDigest(ofFileAt: url)
        return actual.caseInsensitiveCompare(expectedHex) == .orderedSame
    }
}

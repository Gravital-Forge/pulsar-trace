import Foundation

/// Atomic write-then-rename for files external tools may be reading.
///
/// `final.md` and `metadata.json` are public API surfaces (PRD §17): an AI
/// agent or an editor may have either file open while a refine pass rewrites
/// it. A naive truncate-then-write would let a consumer observe a half-written
/// file. Instead every write goes to a sibling temp file and is `rename(2)`'d
/// into place — `rename` is atomic on the same volume, so a reader sees either
/// the whole old file or the whole new file, never a torn one. An editor with
/// the file open reloads cleanly (edge case).
///
/// The temp file is created in the *same directory* as the destination so the
/// rename never crosses a filesystem boundary (which would silently fall back
/// to a non-atomic copy).
public enum AtomicFile {

    /// Write `data` to `url` atomically (temp file + `rename`).
    ///
    /// - Returns: the lowercase-hex SHA-256 of the bytes written, so the
    ///   caller can stamp a `final_md_written` / `final_md_rewritten` event
    ///   without re-reading the file.
    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> String {
        let directory = url.deletingLastPathComponent()
        try SecureFiles.createDirectoryPrivateIfNew(at: directory)

        // A unique temp name in the destination directory: same volume, so the
        // rename is a true atomic in-place replace.
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            // Owner-only from the first byte: create the temp file 0600 and
            // stream the payload through a handle. (`Data.write(.atomic)`
            // would create its own 0644 temp file behind our back.)
            guard SecureFiles.createPrivateFile(atPath: tempURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // `replaceItemAt` performs an atomic exchange when the destination
            // already exists, and a plain rename when it does not.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            // When the destination existed, `replaceItemAt` preserves the *old*
            // item's metadata — repair so pre-hardening 0644 files converge to
            // 0600 on their next rewrite.
            SecureFiles.restrictToOwner(url)
        } catch {
            // Never leave a stray temp file behind on failure.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return sha256Hex(data)
    }

    /// Atomically write a UTF-8 string. Convenience over `write(_:to:)`.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> String {
        try write(Data(text.utf8), to: url)
    }

    /// Lowercase-hex SHA-256 of a byte buffer.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256Verifier.hexDigest(of: data)
    }
}

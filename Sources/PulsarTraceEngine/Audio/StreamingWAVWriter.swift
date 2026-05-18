import Foundation

/// Incrementally writes the canonical PulsarTrace storage format — 16 kHz mono
/// **Int16** PCM RIFF/WAVE (R54e) — straight to disk as samples arrive.
///
/// `WAVWriter` only encodes a complete in-RAM buffer in one shot, so until the
/// live pass finishes nothing is on disk: a crash/kill mid-recording loses
/// 100% of captured audio. `StreamingWAVWriter` instead opens the file up
/// front, appends each frame to an open `FileHandle`, and re-patches the RIFF
/// and `data` chunk sizes after every batch — so the file on disk is *always*
/// a valid, correctly-sized WAV reflecting everything appended so far. A later
/// `pulsartrace refine` can consume it even if the engine never reached
/// `finalize()`.
///
/// Not thread-safe by design: it is driven from `LiveRunner`'s single-task run
/// loop, so a plain `final class` (no actor) is correct and avoids needless
/// hops. The on-disk format is byte-identical to `WAVWriter.encode`.
final class StreamingWAVWriter {

    /// Errors surfaced from streaming WAV I/O. Typed so callers can log them
    /// distinctly — never swallowed silently.
    enum StreamingWAVError: Error, CustomStringConvertible {
        case openFailed(URL, underlying: Error)
        case writeFailed(underlying: Error)

        var description: String {
            switch self {
            case .openFailed(let url, let underlying):
                return "could not open \(url.path) for streaming WAV: \(underlying)"
            case .writeFailed(let underlying):
                return "streaming WAV write failed: \(underlying)"
            }
        }
    }

    private let url: URL
    private let sampleRate: Int
    private let handle: FileHandle
    /// Total Int16 samples written to the `data` chunk so far.
    private var sampleCount = 0
    /// Sample count as of the last header patch — used to throttle re-patching
    /// to roughly once per second of audio.
    private var lastPatchedSampleCount = 0
    private var finalized = false

    private static let headerSize = 44
    private static let bytesPerSample = 2

    /// Open `url`, truncating any existing file, and write a 44-byte RIFF/WAVE
    /// header with placeholder (zero) chunk sizes. The file is a valid 0-sample
    /// WAV from this point on.
    init(url: URL, sampleRate: Int = AudioFormat.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate

        // Create (or truncate) the file, then open a handle for writing.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            self.handle = try FileHandle(forWritingTo: url)
        } catch {
            throw StreamingWAVError.openFailed(url, underlying: error)
        }
        do {
            try handle.write(contentsOf: Self.header(dataBytes: 0,
                                                     sampleRate: sampleRate))
        } catch {
            throw StreamingWAVError.writeFailed(underlying: error)
        }
    }

    /// Convert `samples` to Int16 LE, append them to the `data` chunk, and
    /// re-patch the header sizes (throttled to ~once per second of audio).
    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, !finalized else { return }

        var bytes = Data(capacity: samples.count * Self.bytesPerSample)
        for sample in samples {
            var le = UInt16(bitPattern: WAVWriter.int16(from: sample)).littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            throw StreamingWAVError.writeFailed(underlying: error)
        }
        sampleCount += samples.count

        // Re-patch the header at most once per ~1s of appended audio. The file
        // stays a valid WAV losing ≤1s of tail if the process dies before the
        // next patch; `finalize()` always patches the exact final size.
        if sampleCount - lastPatchedSampleCount >= sampleRate {
            try patchHeader()
        }
    }

    /// Patch the header to the exact current size and close the handle.
    /// Idempotent — safe to call again, and safe even if `append` was never
    /// called (the file is then a valid empty WAV).
    func finalize() throws {
        guard !finalized else { return }
        finalized = true
        // Always close the handle, even if patching/syncing throws — otherwise
        // the throw leaks the FileHandle (a retry is a no-op since `finalized`
        // is already set above).
        defer { try? handle.close() }
        do {
            try patchHeader()
            try handle.synchronize()
        } catch let error as StreamingWAVError {
            throw error
        } catch {
            throw StreamingWAVError.writeFailed(underlying: error)
        }
    }

    // MARK: - Header

    /// Seek to the two size fields, overwrite them with the current data size,
    /// then seek back to the end so the next `append` continues the data chunk.
    private func patchHeader() throws {
        let dataBytes = sampleCount * Self.bytesPerSample
        let riffSize = UInt32(Self.headerSize - 8 + dataBytes)  // 36 + dataBytes
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.le32(riffSize))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.le32(UInt32(dataBytes)))
            try handle.seekToEnd()
        } catch {
            throw StreamingWAVError.writeFailed(underlying: error)
        }
        lastPatchedSampleCount = sampleCount
    }

    /// Build a 44-byte RIFF/WAVE header for `dataBytes` of mono Int16 PCM —
    /// byte-identical to the header `WAVWriter.encode` produces.
    private static func header(dataBytes: Int, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data(capacity: headerSize)
        func append32(_ v: UInt32) { data.append(contentsOf: le32(v)) }
        func append16(_ v: UInt16) { data.append(contentsOf: le16(v)) }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // PCM fmt chunk size
        append16(1)                        // format tag: PCM integer
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))

        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataBytes))
        return data
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }
    private static func le16(_ v: UInt16) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }
}

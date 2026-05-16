import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Reads length-prefixed PCM frames (`FrameProtocol`) from a POSIX file
/// descriptor. Shared implementation behind `PipeSource` and `SocketSource`.
///
/// A single dedicated background thread performs all the blocking `read(2)`
/// calls and pushes decoded items into an `AsyncThrowingStream`; the async
/// iterator just awaits the stream. This keeps blocking I/O off the cooperative
/// thread pool without spawning a thread per frame. A zero-length frame or a
/// clean EOF terminates the stream (R75). Control frames (pause/resume, Epic 7)
/// are decoded into `.paused` / `.resumed` items alongside PCM `.frame`s.
final class FrameDescriptorReader: @unchecked Sendable {
    private let fd: Int32
    private let closeOnFinish: Bool
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    /// The stream is a reference type and is safe to share. The *iterator* is
    /// not — it is `mutating` and must not be shared. So the reader owns only
    /// the stream; each per-iteration `Iterator` value pulls its own iterator
    /// out of the stream via `makeFrameIterator()`. The reader thread is still
    /// spawned exactly once, on the first `makeFrameIterator()` call.
    private let stream: AsyncThrowingStream<FrameProtocol.DecodedItem, Error>
    private let continuation: AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.Continuation

    init(fd: Int32, closeOnFinish: Bool) {
        self.fd = fd
        self.closeOnFinish = closeOnFinish
        let (s, c) = AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.makeStream()
        self.stream = s
        self.continuation = c
    }

    /// Request early termination. The reader thread observes the flag, the
    /// stream finishes, and the iterator then returns `nil`.
    func requestStop() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Hand out a fresh iterator into the underlying stream, spawning the
    /// single reader thread on first use. The returned iterator is owned by the
    /// caller's per-iteration value, so its `mutating next()` is never shared.
    func makeFrameIterator() -> AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.AsyncIterator {
        startIfNeeded()
        return stream.makeAsyncIterator()
    }

    /// Spawn the single reader thread on first use.
    private func startIfNeeded() {
        lock.lock()
        let begin = !started
        started = true
        lock.unlock()
        guard begin else { return }

        let thread = Thread { [self] in
            do {
                try readLoop()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            if closeOnFinish { close(fd) }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Blocking read loop running on the dedicated thread.
    private func readLoop() throws {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        /// Fill `buffer` to at least `count` bytes; `false` on EOF first.
        func fill(to count: Int) throws -> Bool {
            while buffer.count < count {
                if isStopped { return false }
                let n = scratch.withUnsafeMutableBytes { ptr -> Int in
                    read(fd, ptr.baseAddress, ptr.count)
                }
                if n == 0 { return false }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                buffer.append(contentsOf: scratch[0..<n])
            }
            return true
        }

        while true {
            if isStopped { return }
            // Length prefix.
            guard try fill(to: 4) else { return }
            let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
                let b = raw.bindMemory(to: UInt8.self)
                return UInt32(b[0]) | (UInt32(b[1]) << 8)
                    | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            }
            buffer.removeFirst(4)

            if length == FrameProtocol.endOfStreamLength { return }
            guard Int(length) <= FrameProtocol.maxPayloadBytes else {
                throw FrameProtocol.FrameError.payloadTooLarge(Int(length))
            }
            // Payload.
            guard try fill(to: Int(length)) else { return }
            let payload = Data(buffer.prefix(Int(length)))
            buffer.removeFirst(Int(length))
            // A control frame (pause/resume) has a length that is neither EOS
            // nor Float32-aligned; everything else is a PCM frame.
            if FrameProtocol.isControlLength(length) {
                continuation.yield(try FrameProtocol.decodeControl(payload))
            } else {
                continuation.yield(.frame(try FrameProtocol.decodePayload(payload)))
            }
        }
    }
}

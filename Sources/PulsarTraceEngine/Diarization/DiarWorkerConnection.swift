import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `SOCK_STREAM` as the `Int32` the C `socket`/`socketpair` calls want, across
/// Darwin (where it is already an `Int32`) and Glibc (where it is an enum whose
/// `rawValue` is the wire constant).
#if canImport(Glibc)
public let sockStreamType: Int32 = Int32(SOCK_STREAM.rawValue)
#else
public let sockStreamType: Int32 = SOCK_STREAM
#endif

/// What `DiarWorkerClient`/`DiarWorkerServer` use to talk to each other —
/// abstracted so tests can substitute a `socketpair`-backed fake (D43).
public protocol DiarWorkerConnecting: Sendable {
    /// Send one already-length-prefixed frame. Throws on a broken pipe.
    func send(_ frame: Data) throws
    /// Inbound frame **bodies** (length prefix already stripped). Finishes on
    /// EOF / peer close.
    var inboundBodies: AsyncStream<Data> { get }
    func close()
}

/// A bidirectional length-prefixed frame transport over a connected fd. A
/// dedicated blocking-read thread reassembles frames into `inboundBodies`;
/// `send` writes on the caller's thread under a lock.
public final class DiarWorkerConnection: DiarWorkerConnecting, @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var closed = false
    public let inboundBodies: AsyncStream<Data>
    private let finish: @Sendable () -> Void

    public init(fd: Int32) {
        self.fd = fd
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBodies = AsyncStream { cont = $0 }
        let c = cont!
        self.finish = { c.finish() }
        Thread.detachNewThread { [fd] in
            DiarWorkerConnection.readLoop(fd: fd, yield: { c.yield($0) }, finish: { c.finish() })
        }
    }

    public func send(_ frame: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { throw DiarWorkerProtocol.CodecError.shortPrefix }
        try frame.withUnsafeBytes { raw in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n == -1 && errno == EINTR { continue }
                throw DiarWorkerConnectionError.writeFailed(errno)
            }
        }
    }

    public func close() {
        writeLock.lock(); let already = closed; closed = true; writeLock.unlock()
        if !already { _ = Foundation.close(fd) }
        finish()
    }

    /// Defense-in-depth: a dropped connection always releases its fd. `close()`
    /// is idempotent via its `already` guard, so this is safe alongside the
    /// supervisor's explicit close (C1).
    deinit { close() }

    /// Blocking read loop: read 4-byte LE length, then exactly `length` bytes,
    /// yield the body. Clean EOF or any error finishes the stream.
    private static func readLoop(fd: Int32, yield: (Data) -> Void, finish: () -> Void) {
        func readExactly(_ count: Int) -> Data? {
            guard count >= 0, count <= DiarWorkerProtocol.maxBodyBytes else { return nil }
            var buf = Data(count: count)
            if count == 0 { return buf }
            var got = 0
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while got < count {
                    let n = read(fd, base + got, count - got)
                    if n > 0 { got += n; continue }
                    if n == 0 { return false }                 // EOF
                    if n == -1 && errno == EINTR { continue }
                    return false
                }
                return true
            }
            return ok ? buf : nil
        }
        while true {
            guard let prefix = readExactly(4) else { break }
            let len = Int(prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard len >= 0, len <= DiarWorkerProtocol.maxBodyBytes, let body = readExactly(len) else { break }
            yield(body)
        }
        finish()
    }
}

public enum DiarWorkerConnectionError: Error, Equatable {
    case writeFailed(Int32)
}

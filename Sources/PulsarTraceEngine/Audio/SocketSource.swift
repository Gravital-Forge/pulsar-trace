import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// An `AudioFrameSource` that reads length-prefixed PCM frames from a Unix
/// domain socket (R73).
///
/// In production this connects to `capture.sock`, written by
/// `pulsartrace-capture` (Epic 7). The frame protocol is identical to
/// `PipeSource`'s, so the engine cannot tell socket-fed audio from pipe-fed
/// audio. In Epic 1 there is no real producer; the IPC integration tests stand
/// up a fixture-driven writer on the other end of the socket.
public final class SocketSource: AudioFrameSource, @unchecked Sendable {
    public typealias Element = AudioStreamEvent

    public enum SocketError: Error, CustomStringConvertible, Equatable {
        case pathTooLong(String)
        case connectFailed(errno: Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path too long: \(p)"
            case .connectFailed(let e): return "connect failed: errno \(e)"
            }
        }
    }

    private let socketPath: URL
    private let lock = NSLock()
    private var reader: FrameDescriptorReader?
    private var connectedFD: Int32 = -1

    /// - Parameter socketPath: filesystem path of the Unix domain socket.
    public init(socketPath: URL) {
        self.socketPath = socketPath
    }

    /// Connect to the socket. Idempotent — a second call is a no-op, so a
    /// caller and the engine's consume loop may both invoke it. The `NSLock`
    /// makes the first-call guard atomic so two concurrent first calls cannot
    /// both `connect()` and leak a file descriptor.
    public func start() async throws {
        // The whole guard-connect-install sequence runs under the lock so two
        // concurrent first calls cannot both `connect()` and leak an fd.
        // `connect()` is synchronous, so holding the lock across it is fine.
        try lock.withLock {
            guard reader == nil else { return }
            let fd = try Self.connect(to: socketPath.path)
            connectedFD = fd
            reader = FrameDescriptorReader(fd: fd, closeOnFinish: true)
        }
    }

    public func stop() async {
        let reader = lock.withLock { self.reader }
        reader?.requestStop()
    }

    public func makeAsyncIterator() -> Iterator {
        let reader = lock.withLock { self.reader }
        precondition(
            reader != nil,
            "SocketSource.makeAsyncIterator() called before start(); call start() first")
        return Iterator(frames: reader!.makeFrameIterator())
    }

    /// Open and connect a `SOCK_STREAM` Unix domain socket.
    ///
    /// The producer must already be `listen()`ing before `connect()` is called.
    /// In Epic 1 this is guaranteed: the only producers are tests, which call
    /// `FixtureSocketServer.start()` (which returns after `listen()`) before
    /// the consumer's `start()`. A connect-retry against a separately-spawned
    /// producer process is an Epic 7 concern (the real capture daemon) and is
    /// intentionally not done here — a naive retry that closes half-open
    /// sockets pollutes the listen backlog.
    static func connect(to path: String) throws -> Int32 {
        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < sunPathCapacity else {
            throw SocketError.pathTooLong(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.connectFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        cstr, maxLen)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, size)
            }
        }
        guard result == 0 else {
            let e = errno
            close(fd)
            throw SocketError.connectFailed(errno: e)
        }
        return fd
    }

    public struct Iterator: AsyncIteratorProtocol {
        /// The per-iteration stream iterator. Lives in this value type — never
        /// on the shared reader — so its `mutating next()` is not shared.
        private var frames: AsyncThrowingStream<[Float], Error>.AsyncIterator
        private var frameIndex = 0

        init(frames: AsyncThrowingStream<[Float], Error>.AsyncIterator) {
            self.frames = frames
        }

        public mutating func next() async throws -> AudioStreamEvent? {
            guard let samples = try await frames.next() else { return nil }
            let frame = AudioFrame(samples: samples, sequenceIndex: frameIndex)
            frameIndex += 1
            return .frame(frame)
        }
    }
}

/// A minimal Unix-domain-socket *server* that streams a fixture WAV as
/// `FrameProtocol` frames. Stands in for `pulsartrace-capture` in the IPC
/// integration tests — it writes exactly the bytes the real capture daemon
/// would. Not used in production.
public final class FixtureSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let samples: [Float]
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var stopped = false
    private var serverThread: Thread?

    /// - Parameters:
    ///   - socketPath: where to bind the listening socket.
    ///   - wavURL: fixture WAV to stream once a client connects.
    public init(socketPath: URL, wavURL: URL) throws {
        self.socketPath = socketPath.path
        self.samples = try WAVReader(contentsOf: wavURL).samples
    }

    /// Bind + listen. Call before a client connects.
    public func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketSource.SocketError.connectFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else {
            close(fd)
            throw SocketSource.SocketError.pathTooLong(socketPath)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        cstr, maxLen)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, size)
            }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd)
            throw SocketSource.SocketError.connectFailed(errno: e)
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd)
            throw SocketSource.SocketError.connectFailed(errno: e)
        }
        listenFD = fd

        let listen = listenFD
        let thread = Thread { [self] in
            let client = accept(listen, nil, nil)
            guard client >= 0 else { return }
            lock.lock()
            if stopped { lock.unlock(); close(client); return }
            clientFD = client
            lock.unlock()

            streamFrames(to: client)

            lock.lock()
            if clientFD == client { clientFD = -1 }
            lock.unlock()
            close(client)
        }
        thread.start()
        serverThread = thread
    }

    /// Stop listening, close any open client connection, remove the socket
    /// file. Closing the client fd unblocks a `write` stalled on a reader that
    /// stopped consuming, so the server thread cannot hang the test.
    public func stop() {
        lock.lock()
        stopped = true
        let listen = listenFD
        let client = clientFD
        listenFD = -1
        clientFD = -1
        lock.unlock()
        if listen >= 0 { close(listen) }
        if client >= 0 { close(client) }
        unlink(socketPath)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Write the samples as 20 ms frames followed by an end-of-stream sentinel.
    private func streamFrames(to fd: Int32) {
        let per = AudioFormat.samplesPerFrame
        var index = 0
        var seq = 0
        while index < samples.count {
            if isStopped { return }
            let end = Swift.min(index + per, samples.count)
            var chunk = Array(samples[index..<end])
            if chunk.count < per {
                chunk.append(contentsOf: [Float](repeating: 0, count: per - chunk.count))
            }
            let data = FrameProtocol.encode(AudioFrame(samples: chunk, sequenceIndex: seq))
            if !writeAll(data, to: fd) { return }
            index = end
            seq += 1
        }
        _ = writeAll(FrameProtocol.encodeEndOfStream(), to: fd)
    }

    /// Write all of `data`; returns `false` on a write error or closed peer.
    @discardableResult
    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// An `AudioFrameSource` that reads length-prefixed PCM frames from a Unix
/// domain socket (PT-R73).
///
/// In production this connects to `capture.sock`, written by
/// `pulsartrace-capture`. The frame protocol is identical to `PipeSource`'s,
/// so the engine cannot tell socket-fed audio from pipe-fed audio. The IPC
/// integration tests stand up a fixture-driven writer on the other end of
/// the socket.
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
    /// For tests this is guaranteed: they call `FixtureSocketServer.start()`
    /// (which returns after `listen()`) before the consumer's `start()`. A
    /// connect-retry against a separately-spawned producer process (the real
    /// capture daemon) is intentionally not done here — a naive retry that
    /// closes half-open sockets pollutes the listen backlog.
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
        private var frames: AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.AsyncIterator
        private var frameIndex = 0

        init(frames: AsyncThrowingStream<FrameProtocol.DecodedItem, Error>.AsyncIterator) {
            self.frames = frames
        }

        public mutating func next() async throws -> AudioStreamEvent? {
            guard let item = try await frames.next() else { return nil }
            return DecodedItemMapper.event(for: item, frameIndex: &frameIndex)
        }
    }
}

/// Maps a `FrameProtocol.DecodedItem` off the wire to an `AudioStreamEvent`.
/// Shared by `SocketSource` and `PipeSource` so both wire-fed sources surface
/// pause/resume identically.
enum DecodedItemMapper {
    static func event(
        for item: FrameProtocol.DecodedItem,
        frameIndex: inout Int
    ) -> AudioStreamEvent {
        switch item {
        case .frame(let samples):
            let frame = AudioFrame(samples: samples, sequenceIndex: frameIndex)
            frameIndex += 1
            return .frame(frame)
        case .paused:
            return .paused
        case .resumed(let gapNanoseconds):
            // Clamp to the representable range; a realistic sleep gap is
            // seconds, far below `Duration.nanoseconds`' `Int` ceiling.
            let clamped = Int(min(gapNanoseconds, UInt64(Int.max)))
            return .resumed(gap: .nanoseconds(clamped))
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
    /// Signalled by the server thread the instant `accept()` returns (success
    /// or failure). `start()` does not return until this fires, so a consumer
    /// can never `connect()` + read before the server is actually accepting —
    /// closing a real thread-scheduling race where `accept()` had not yet run
    /// and the consumer saw a premature EOF.
    private let acceptConfirmed = DispatchSemaphore(value: 0)
    /// Signalled by the server thread as its very last act. `stop()` waits on
    /// it so the thread is fully finished — past every `accept`/`write`/`close`
    /// — before `stop()` returns. Otherwise a dangling server thread from a
    /// just-finished test can read or write a *recycled* file-descriptor
    /// number a later test has since reused, corrupting that test's stream.
    private let threadFinished = DispatchSemaphore(value: 0)

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
            // Signalled as the thread's last act on every exit path so
            // `stop()` can join it before any fd is recycled.
            defer { threadFinished.signal() }

            let client = accept(listen, nil, nil)
            // Confirm accept() has returned — success or failure — so a waiter
            // (`waitForAccept()`) knows the server is past the accept point and
            // a consumer's frames will be served, not dropped on a premature
            // EOF caused by the server thread not yet having been scheduled.
            acceptConfirmed.signal()
            guard client >= 0 else { return }
            // Suppress SIGPIPE on this socket: when the consumer stops reading
            // and closes its end (a test finishing, `source.stop()`), a pending
            // `write()` here would otherwise raise SIGPIPE and kill the whole
            // test process. `SO_NOSIGPIPE` makes `write()` return `EPIPE`
            // instead, which `writeAll` already handles by returning `false`.
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE,
                &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if stopped { lock.unlock(); close(client); return }
            clientFD = client
            lock.unlock()

            streamFrames(to: client)

            // Close `client` exactly once: whoever transitions `clientFD` from
            // `client` to `-1` under the lock owns the close. If `stop()` got
            // there first it already closed the fd — closing it again here
            // could close an fd number a later test has recycled.
            lock.lock()
            let ownsClose = (clientFD == client)
            if ownsClose { clientFD = -1 }
            lock.unlock()
            if ownsClose { close(client) }
        }
        thread.start()
        serverThread = thread
    }

    /// Block until the server thread's `accept()` has returned.
    ///
    /// `accept()` only returns once a client has connected, so a consumer must
    /// call `start()` (which `connect()`s) *before* this. Once this returns the
    /// server is guaranteed to be past `accept()` and about to stream frames —
    /// closing the thread-scheduling race where a consumer could read EOF
    /// before the server began serving.
    public func waitForAccept() {
        acceptConfirmed.wait()
    }

    /// Stop listening, close any open client connection, remove the socket
    /// file, and join the server thread.
    ///
    /// Closing the listen/client fds unblocks the server thread's `accept()` /
    /// `write()`, so it cannot hang. `stop()` then waits on `threadFinished`
    /// before returning: the server thread is guaranteed fully done — past
    /// every fd operation — so it can never touch a file-descriptor number a
    /// later test has recycled.
    public func stop() {
        lock.lock()
        stopped = true
        let listen = listenFD
        let client = clientFD
        let thread = serverThread
        listenFD = -1
        clientFD = -1
        lock.unlock()
        if listen >= 0 { close(listen) }
        if client >= 0 { close(client) }
        // Join the server thread (if one was ever started) before returning.
        if thread != nil { threadFinished.wait() }
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

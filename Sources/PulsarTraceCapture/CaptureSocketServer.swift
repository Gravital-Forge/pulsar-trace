import Foundation
import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A Unix-domain-socket server that streams `FrameProtocol` frames to one
/// connected client — the engine's `SocketSource`. The capture-side analogue
/// of the engine's `FrameDescriptorReader`, and the production counterpart of
/// the tests' `FixtureSocketServer`.
///
/// `pulsartrace-capture` runs one server per audio stream (system + mic).
/// Lifecycle:
///
/// 1. `start()` — `socket()` + `bind()` + `listen()`. Must complete before the
///    engine `connect()`s; there is no connect-retry on the engine side.
/// 2. `beginServing()` — spawns a dedicated thread that `accept()`s the engine
///    connection and then drains the event queue, encoding each event.
/// 3. `enqueue(_:)` — the capture engine pushes `AudioStreamEvent`s (thread-safe).
/// 4. `stop()` — drain the queue, write the end-of-stream sentinel, join the
///    write thread, and tear the socket down. Graceful: queued frames are not
///    dropped.
///
/// `SO_NOSIGPIPE` + `SO_SNDTIMEO` + an `EINTR`-retrying `write()` keep a
/// vanished or stuck consumer from killing or hanging the daemon: a broken
/// pipe surfaces as `EPIPE`, a stalled consumer as a write timeout — both end
/// the write loop cleanly.
final class CaptureSocketServer: @unchecked Sendable {

    enum CaptureSocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)

        var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path too long: \(p)"
            case .socketFailed(let e): return "socket() failed: errno \(e)"
            case .bindFailed(let e): return "bind() failed: errno \(e)"
            case .listenFailed(let e): return "listen() failed: errno \(e)"
            }
        }
    }

    /// Seconds a single `write()` may stall before the consumer is treated as
    /// gone — bounds `stop()`'s join so a wedged engine cannot hang the daemon.
    private static let sendTimeoutSeconds = 5

    private let socketPath: String

    /// Guards the file descriptors and the server thread handle.
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var serverThread: Thread?
    /// Signalled by the server thread as its last act so `stop()` can join it
    /// before any file descriptor number is recycled.
    private let threadFinished = DispatchSemaphore(value: 0)

    /// Guards the event queue and the `finished` flag.
    private let cond = NSCondition()
    private var queue: [AudioStreamEvent] = []
    private var finished = false

    /// Test observation hook — fired synchronously inside `enqueue` for every
    /// event, in enqueue order, before the write thread ever sees it. Used by
    /// `StallRecoveryTests` to assert the `.resumed` marker is enqueued ahead
    /// of the first post-recovery frame (Hard Invariant #8 ordering) without
    /// reading raw bytes off the socket. `nil` in production.
    var onEnqueueForTest: (@Sendable (AudioStreamEvent) -> Void)?

    init(socketPath: URL) {
        self.socketPath = socketPath.path
    }

    /// `socket()` + `bind()` + `listen()`. Call before the engine connects.
    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CaptureSocketError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else {
            close(fd)
            throw CaptureSocketError.pathTooLong(socketPath)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr, maxLen)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, size)
            }
        }
        guard bound == 0 else {
            let e = errno; close(fd); throw CaptureSocketError.bindFailed(e)
        }
        // Backlog of 1: exactly one consumer (the engine) per stream.
        guard listen(fd, 1) == 0 else {
            let e = errno; close(fd); throw CaptureSocketError.listenFailed(e)
        }
        lock.withLock { listenFD = fd }
    }

    /// Spawn the accept + write thread. Returns immediately. A connection that
    /// arrived between `start()` and here waits in the listen backlog, so the
    /// engine may `connect()` before this is called.
    func beginServing() {
        let listen = lock.withLock { listenFD }
        guard listen >= 0 else { return }

        let thread = Thread { [self] in
            defer { threadFinished.signal() }

            let client = accept(listen, nil, nil)
            guard client >= 0 else { return }
            // Defense in depth: only a process running as our own user may
            // consume raw PCM. The socket dir is 0700; verify the peer too.
            guard PeerCredentials.peerIsSameUser(fd: client) else {
                close(client)
                return
            }
            configureClientSocket(client)

            lock.withLock { clientFD = client }
            writeLoop(to: client)

            // Close `client` exactly once — whoever nulls `clientFD` owns it.
            let ownsClose: Bool = lock.withLock {
                guard clientFD == client else { return false }
                clientFD = -1
                return true
            }
            if ownsClose { close(client) }
        }
        thread.stackSize = 1 << 20
        thread.start()
        lock.withLock { serverThread = thread }
    }

    /// Hand an event to the write thread. Dropped silently once the stream has
    /// been finished (`stop()` called).
    func enqueue(_ event: AudioStreamEvent) {
        onEnqueueForTest?(event)
        cond.lock()
        if !finished { queue.append(event) }
        cond.signal()
        cond.unlock()
    }

    /// Mark the stream complete without tearing the socket down: the write
    /// thread drains the queue, writes the end-of-stream sentinel, and exits.
    /// Lets a consumer read the whole stream to its end before `stop()`.
    func finish() {
        cond.lock()
        finished = true
        cond.signal()
        cond.unlock()
    }

    /// Drain the queue, write the end-of-stream sentinel, join the write
    /// thread, and tear down the socket. Idempotent.
    func stop() {
        // Mark the stream finished: a connected write loop drains its queue,
        // writes EOS, and exits; `enqueue` drops anything new.
        cond.lock()
        finished = true
        cond.signal()
        cond.unlock()

        // Close the listen socket so a write thread still blocked in accept()
        // (no consumer ever connected) falls through and exits.
        let listen = lock.withLock { () -> Int32 in
            let fd = listenFD; listenFD = -1; return fd
        }
        if listen >= 0 { close(listen) }

        // Join the write thread: it has drained + written EOS (connected) or
        // dropped out of accept() (unconnected). `SO_SNDTIMEO` bounds the wait.
        let thread = lock.withLock { serverThread }
        if thread != nil { threadFinished.wait() }

        let client = lock.withLock { () -> Int32 in
            let fd = clientFD; clientFD = -1; return fd
        }
        if client >= 0 { close(client) }
        unlink(socketPath)
    }

    /// `SO_NOSIGPIPE` (EPIPE, not a signal, on a vanished consumer) +
    /// `SO_SNDTIMEO` (a stalled `write()` fails rather than hanging forever).
    private func configureClientSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO,
            &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Drain the event queue to the socket; write the EOS sentinel once the
    /// stream is finished. Returns early on a write error (engine gone).
    private func writeLoop(to fd: Int32) {
        while true {
            cond.lock()
            while queue.isEmpty && !finished { cond.wait() }
            let batch = queue
            queue.removeAll(keepingCapacity: true)
            // Once `finished` is set, `enqueue` drops new events, so a batch
            // taken with `finished == true` is the complete remaining stream.
            let isFinal = finished
            cond.unlock()

            for event in batch {
                if !writeAll(Self.encode(event), to: fd) { return }
            }
            if isFinal {
                _ = writeAll(FrameProtocol.encodeEndOfStream(), to: fd)
                return
            }
        }
    }

    /// Encode one `AudioStreamEvent` to its `FrameProtocol` wire bytes.
    private static func encode(_ event: AudioStreamEvent) -> Data {
        switch event {
        case .frame(let frame):
            return FrameProtocol.encode(frame)
        case .paused:
            return FrameProtocol.encodeStreamPaused()
        case .resumed(let gap):
            return FrameProtocol.encodeStreamResumed(
                gapNanoseconds: gap.wholeNanoseconds)
        }
    }

    /// Write all of `data`, retrying on `EINTR`; `false` on a closed or
    /// stalled peer.
    @discardableResult
    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return true
            }
            var offset = 0
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

extension Duration {
    /// This duration in whole nanoseconds, clamped at zero. Used to put a
    /// pause gap on the wire (`FrameProtocol.encodeStreamResumed`).
    var wholeNanoseconds: UInt64 {
        let parts = components
        let seconds = UInt64(max(0, parts.seconds))
        // `components.attoseconds` is the sub-second part in 1e-18 s units;
        // 1 ns = 1e9 as, so divide by 1e9 to get nanoseconds (sub-ns dropped).
        let nanosFromAtto = UInt64(max(0, parts.attoseconds)) / 1_000_000_000
        return seconds &* 1_000_000_000 &+ nanosFromAtto
    }
}

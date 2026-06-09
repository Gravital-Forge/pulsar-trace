import Foundation
import Logging

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Parent-side handle to one `pulsartrace-whisper` subprocess
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §6/§7).
///
/// Owns the `Process`, the captured-stdout handshake pipe, and the UDS
/// client fd. Reused across many decodes; replaced wholesale by
/// `RemoteWindowTranscriber` when a decode times out (Decode →
/// SIGKILL → spawn fresh host → re-`startAndInitialize` →
/// resume).
///
/// Conforms to `WhisperHostProtocol` so tests can inject a fake host
/// without spawning the real binary. Real spawn + handshake + decode +
/// kill is exercised end-to-end by the Phase 7 acceptance suite.
public protocol WhisperHostProtocol: AnyObject {
    /// Spawn the subprocess, wait for the `ready: …` stdout handshake,
    /// connect the UDS, send `.initSession(...)`, wait for `.ready`.
    /// Bounded by the configuration's `spawnTimeout + initTimeout`.
    func startAndInitialize(model: String) throws

    /// Send a decode request and wait for its response. `deadline` is
    /// the per-decode budget; on expiry the call throws
    /// `WhisperSubprocessHost.HostError.readTimedOut` and the caller
    /// SIGKILLs + respawns.
    func decode(
        _ request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse

    /// Cooperative shutdown: SIGTERM + brief wait + force-kill if it
    /// didn't honor SIGTERM. Closes the UDS.
    func terminate(grace: Duration)

    /// Force-kill: SIGKILL + reap. Used by the parent watchdog.
    func sigkill()

    /// True until the subprocess has exited or been killed.
    var isAlive: Bool { get }
}

/// Concrete host: spawns and talks to the real `pulsartrace-whisper`
/// binary.
public final class WhisperSubprocessHost: WhisperHostProtocol, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Path to the `pulsartrace-whisper` executable.
        public var binaryURL: URL
        /// Directory under which the unique UDS path is minted.
        public var socketDirectory: URL
        /// Optional `--lock-path` override; `nil` leaves it at the
        /// subprocess's default (`~/Library/Application Support/PulsarTrace/whisper.lock`).
        public var lockPath: URL?
        /// `true` passes `--cpu` to force the CPU backend.
        public var forceCPU: Bool
        /// How long to wait for the subprocess's `ready: <path>\n` line
        /// on stdout. Past this, SIGKILL + throw `.handshakeTimedOut`.
        public var spawnTimeout: Duration
        /// How long to wait for `.ready` after sending `.initSession`.
        /// Past this, SIGKILL + throw `.initRefused`.
        public var initTimeout: Duration
        /// Extra CLI arguments appended after the host's own
        /// `--socket-path` / `--lock-path` / `--cpu` flags. Defaults to
        /// empty. Used by the Phase 7 acceptance suite to pass
        /// `--hang-on-sentinel` to a test-only build; production callers
        /// leave this empty.
        public var extraArgs: [String]

        public init(
            binaryURL: URL,
            socketDirectory: URL,
            lockPath: URL? = nil,
            forceCPU: Bool = false,
            spawnTimeout: Duration = .seconds(10),
            // 180 s gives a warm respawn enough headroom when GPU /
            // CoreML state from a SIGKILLed predecessor takes seconds
            // to release. The base-model cold load is sub-second on a
            // hot dev box; the 60 s prior default was tight enough
            // that one Metal cleanup stall (2026-05-28 incident)
            // tripped `init refused` and the live pass never recovered.
            initTimeout: Duration = .seconds(180),
            extraArgs: [String] = []
        ) {
            self.binaryURL = binaryURL
            self.socketDirectory = socketDirectory
            self.lockPath = lockPath
            self.forceCPU = forceCPU
            self.spawnTimeout = spawnTimeout
            self.initTimeout = initTimeout
            self.extraArgs = extraArgs
        }
    }

    public enum HostError: Error, CustomStringConvertible, Equatable {
        /// `configuration.binaryURL` does not point at an executable
        /// file. Caller treats this as non-recoverable.
        case binaryNotFound(String)
        /// `Process.run()` itself failed (POSIX exec error, sandbox).
        case spawnFailed(String)
        /// `spawnTimeout` elapsed without seeing `ready: …` on stdout.
        case handshakeTimedOut
        /// The handshake line was malformed (didn't match
        /// `ready: <expected-path>\n`). Includes what we received.
        case handshakeMalformed(String)
        /// `connect(2)` to the UDS failed.
        case connectFailed(errno: Int32)
        /// The subprocess reported an error response to `.initSession`
        /// (model load failed, init-twice, etc).
        case initRefused(String)
        /// The decode `select(2)` budget elapsed with no response on the
        /// fd. The caller SIGKILLs and respawns.
        case readTimedOut
        /// `readFrame` returned a clean nil — the subprocess closed the
        /// UDS between frames. Distinct from `subprocessGone` only in
        /// that no `Process` exit may have been observed yet.
        case readEOF
        /// `writeFrame` failed (EPIPE etc.) — peer died mid-request.
        case writeFailed(String)
        /// The `Process` is no longer running; we observed its exit
        /// status (may be `nil` if exit was raced by reap).
        case subprocessGone(exitStatus: Int32?)

        public var description: String {
            switch self {
            case .binaryNotFound(let p):
                return "pulsartrace-whisper binary not found: \(p)"
            case .spawnFailed(let m):
                return "spawn failed: \(m)"
            case .handshakeTimedOut:
                return "handshake timed out before ready: line"
            case .handshakeMalformed(let s):
                return "handshake malformed: \(s)"
            case .connectFailed(let e):
                return "UDS connect failed: errno \(e)"
            case .initRefused(let m):
                return "init refused: \(m)"
            case .readTimedOut:
                return "decode response read timed out"
            case .readEOF:
                return "subprocess closed UDS between frames"
            case .writeFailed(let m):
                return "write to subprocess failed: \(m)"
            case .subprocessGone(let s):
                return "subprocess exited (status=\(s.map(String.init) ?? "?"))"
            }
        }
    }

    // MARK: - State

    private let configuration: Configuration
    private let logger: Logger

    /// Guards `process`, `clientFD`, `stdoutPipe`, `socketPath`, and
    /// `exitStatus`. POSIX fd ops are not reentrant against each other
    /// in this client (one decode at a time), but `sigkill` may race
    /// with a decode reader; the lock keeps fd lifetime safe.
    private let lock = NSLock()
    private var process: Process?
    private var stdoutPipe: Pipe?
    /// Retained so the subprocess's stderr fd stays alive for the
    /// background drainer (`drainStderrLines`) kicked off by
    /// `startAndInitialize`. The drainer returns on EOF when the
    /// subprocess exits, so there is no explicit teardown.
    private var stderrPipe: Pipe?
    /// The UDS path we minted for this host; cleaned up at terminate.
    private var socketPath: URL?
    /// Client fd. `-1` when not connected.
    private var clientFD: Int32 = -1
    /// Latched on `process.terminationHandler`. `nil` while alive.
    private var _exitStatus: Int32?
    /// Set true the moment `terminate`/`sigkill` is called so a later
    /// race condition (e.g. read returning EBADF after fd close) does
    /// not look like an unexpected subprocess death.
    private var deliberatelyKilled: Bool = false

    public init(configuration: Configuration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }

    deinit {
        // Best-effort cleanup: a leaked host (whose owner forgot
        // terminate) still SIGKILLs its subprocess so we never leave
        // an orphan whisper holding the whisper.lock.
        if isAlive {
            sigkill()
        }
        let path = lock.withLock { socketPath }
        if let path { unlink(path.path) }
    }

    public var isAlive: Bool {
        lock.withLock {
            guard let process else { return false }
            return process.isRunning && _exitStatus == nil
        }
    }

    public var exitStatus: Int32? {
        lock.withLock { _exitStatus }
    }

    // MARK: - Lifecycle

    public func startAndInitialize(model: String) throws {
        // Validate the binary up front. `Process.run()` reports a less
        // specific error than checking the path; doing it here gives a
        // caller-friendly `.binaryNotFound`.
        guard FileManager.default.isExecutableFile(atPath: configuration.binaryURL.path) else {
            throw HostError.binaryNotFound(configuration.binaryURL.path)
        }

        try SecureFiles.ensurePrivateDirectory(at: configuration.socketDirectory)

        // Keep this filename short — `sockaddr_un.sun_path` on macOS is 104
        // bytes (incl. NUL). The socket directory (production:
        // `~/Library/Application Support/PulsarTrace/sockets/`) already eats
        // ~63 bytes, so a long filename overflows bind(2) and the subprocess
        // dies before the handshake. 8 hex chars of randomness is enough for a
        // per-spawn UDS label — the flock + spawn pattern already enforces
        // "at most one whisper subprocess at a time".
        let shortID = UUID().uuidString.prefix(8)
        let socketPath = configuration.socketDirectory
            .appendingPathComponent("w-\(shortID).sock", isDirectory: false)
        // Stale-socket cleanup is the subprocess's responsibility (it
        // `unlink`s before bind); we only ensure the directory exists.

        // `sun_path` is 104 bytes including the NUL terminator on Darwin —
        // so the path itself must be < 104 bytes. A path that overflows here
        // would make the subprocess exit early on bind(2), and the parent's
        // handshake reader would see EOF before `exitStatus` latches,
        // producing a misleading `handshakeTimedOut`. Surface the real cause.
        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard socketPath.path.utf8.count < sunPathCapacity else {
            throw HostError.spawnFailed(
                "socket path too long: \(socketPath.path.utf8.count) bytes "
                + "(max \(sunPathCapacity - 1)) — \(socketPath.path)")
        }

        var args: [String] = ["--socket-path", socketPath.path]
        if let lockPath = configuration.lockPath {
            args.append(contentsOf: ["--lock-path", lockPath.path])
        }
        if configuration.forceCPU {
            args.append("--cpu")
        }
        // Optional extras (e.g. `--hang-on-sentinel`) used by the Phase 7
        // acceptance suite; empty in production.
        args.append(contentsOf: configuration.extraArgs)

        let process = Process()
        process.executableURL = configuration.binaryURL
        process.arguments = args
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Capture the subprocess's stderr into a Pipe so the parent
        // can drain it line-by-line into its logger
        // (`drainStderrLines` below). Inheriting the parent's fd 2
        // (the pre-2026-05-28 default) loses the stderr trail wherever
        // the engine's own stderr is dropped — production runs go
        // through `RecordOrchestrator`, which drains the engine's
        // stderr to /dev/null, so a model-load stall or whisper.cpp
        // assertion was effectively invisible from the daily log
        // (2026-05-28 incident). The drainer is started after
        // `process.run()` succeeds and returns on EOF when the
        // subprocess exits, so there is no teardown to manage.
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.withLock {
                self._exitStatus = proc.terminationStatus
            }
        }

        do {
            try process.run()
        } catch {
            throw HostError.spawnFailed("\(error)")
        }

        lock.withLock {
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.socketPath = socketPath
            self.deliberatelyKilled = false
        }

        // Drain the subprocess's stderr into the parent logger. The
        // drainer reads until EOF, which only fires once *every* copy
        // of the write fd is closed — so close the parent's copy here
        // (Foundation does not do it for us). After this close, EOF
        // arrives the instant the subprocess's own fd 2 closes
        // (exit / SIGKILL), and the drainer returns — no teardown to
        // manage. Every line gets a `[whisper-subprocess]` prefix
        // (`drainStderrLines`); the Phase 7 acceptance suite uses real
        // spawns and exercises this path end-to-end.
        try? stderrPipe.fileHandleForWriting.close()
        let drainerFD = stderrPipe.fileHandleForReading
        let drainerLogger = logger
        DispatchQueue.global(qos: .utility).async {
            Self.drainStderrLines(from: drainerFD, logger: drainerLogger)
        }

        // Phase 1: read the `ready: <path>\n` handshake with a
        // deadline. The Foundation `Pipe` has no read-with-timeout
        // API, so we spawn a thread that does the blocking read and
        // signal a semaphore on completion; if the deadline beats it
        // we close the pipe's read fd to unblock the thread, then
        // SIGKILL and bail.
        let handshakeResult: HandshakeResult
        do {
            handshakeResult = try readHandshake(
                from: stdoutPipe.fileHandleForReading,
                deadline: configuration.spawnTimeout)
        } catch {
            sigkill()
            throw error
        }
        let expectedLine = "ready: \(socketPath.path)"
        let line = handshakeResult.line.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard line == expectedLine else {
            sigkill()
            throw HostError.handshakeMalformed(
                "expected \"\(expectedLine)\", got \"\(line)\"")
        }

        // Phase 2: connect the UDS.
        let fd: Int32
        do {
            fd = try Self.connect(to: socketPath.path)
        } catch let e as SocketSource.SocketError {
            sigkill()
            if case .connectFailed(let errnoVal) = e {
                throw HostError.connectFailed(errno: errnoVal)
            }
            throw HostError.connectFailed(errno: -1)
        } catch {
            sigkill()
            throw HostError.connectFailed(errno: -1)
        }
        // SO_NOSIGPIPE so a vanished subprocess surfaces as EPIPE
        // from `write(2)`, not a fatal SIGPIPE to the engine.
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock { clientFD = fd }

        // Phase 3: send `.initSession`, wait for `.ready` with the
        // init deadline.
        let initRequest = WhisperIPCRequest.initSession(
            model: model,
            gpu: !configuration.forceCPU)
        let response: WhisperIPCResponse
        do {
            response = try sendAndRead(
                request: initRequest,
                deadline: configuration.initTimeout)
        } catch let e as HostError {
            sigkill()
            // Translate "read timed out during init" to `.initRefused`
            // — from the caller's POV they are equivalent (the host is
            // unusable; surface a model-load-style error to the engine
            // so it does not loop-respawn).
            switch e {
            case .readTimedOut:
                throw HostError.initRefused("ready not received within init timeout")
            default:
                throw e
            }
        } catch {
            sigkill()
            throw HostError.initRefused("\(error)")
        }
        switch response {
        case .ready(let ms):
            logger.notice("whisper subprocess ready (model load=\(ms) ms)")
        case .error(let err):
            sigkill()
            throw HostError.initRefused(
                "[\(err.kind)] \(err.message)")
        case .decoded:
            sigkill()
            throw HostError.initRefused("unexpected decoded response to init")
        }
    }

    public func decode(
        _ request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse {
        return try sendAndRead(request: request, deadline: deadline)
    }

    public func terminate(grace: Duration) {
        let (proc, fd) = lock.withLock {
            (self.process, self.clientFD)
        }
        guard let proc else { return }
        lock.withLock { self.deliberatelyKilled = true }

        if proc.isRunning {
            proc.terminate()  // SIGTERM
        }

        // Wait up to `grace` for SIGTERM to take. We don't have
        // `waitpid` with a timeout; spin-wait on `isRunning` at a
        // coarse interval. Grace values here are seconds-scale so the
        // overhead is fine.
        let deadline = ContinuousClock.now + grace
        while proc.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        proc.waitUntilExit()  // reap

        if fd >= 0 {
            close(fd)
            lock.withLock { self.clientFD = -1 }
        }
        cleanupSocketFile()
    }

    public func sigkill() {
        let (proc, fd) = lock.withLock {
            (self.process, self.clientFD)
        }
        lock.withLock { self.deliberatelyKilled = true }
        if let proc, proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()  // reap
        }
        if fd >= 0 {
            close(fd)
            lock.withLock { self.clientFD = -1 }
        }
        cleanupSocketFile()
    }

    // MARK: - Internals

    /// Send one request, then wait for one response with the given
    /// deadline. `decode` and the init handshake both go through here.
    private func sendAndRead(
        request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse {
        let fd = lock.withLock { clientFD }
        guard fd >= 0 else {
            throw HostError.subprocessGone(exitStatus: exitStatus)
        }

        // Write the request frame.
        do {
            let json = try JSONEncoder().encode(request)
            let frame = try WhisperFrameCodec.encode(jsonBytes: json)
            try WhisperFrameCodec.writeFrame(frame, to: fd)
        } catch let e as WhisperFrameCodec.CodecError {
            throw HostError.writeFailed(e.description)
        } catch {
            throw HostError.writeFailed("\(error)")
        }

        // Wait for the fd to be readable within `deadline`, then read
        // one frame. `select(2)` is the simplest POSIX timeout
        // primitive here; the alternatives (a worker thread with
        // semaphore-and-fd-close) are heavier and we don't need them
        // for a single-fd one-shot wait.
        try waitReadable(fd: fd, deadline: deadline)

        let payload: Data?
        do {
            payload = try WhisperFrameCodec.readFrame(from: fd)
        } catch let e as WhisperFrameCodec.CodecError {
            // Mid-frame disconnect — treat as subprocess gone.
            throw HostError.subprocessGone(exitStatus: exitStatus).orWrite(e)
        }
        guard let payload else {
            throw HostError.readEOF
        }
        do {
            return try JSONDecoder().decode(WhisperIPCResponse.self, from: payload)
        } catch {
            throw HostError.writeFailed("response decode failed: \(error)")
        }
    }

    /// Block in `select(2)` until `fd` is readable or `deadline`
    /// elapses. Throws `.readTimedOut` on timeout; `.subprocessGone`
    /// on a `select(2)` error other than `EINTR`. `EINTR` retries
    /// after recomputing the remaining time so a signal-interrupted
    /// select doesn't reset the deadline.
    private func waitReadable(fd: Int32, deadline: Duration) throws {
        let start = ContinuousClock.now
        while true {
            let elapsed = ContinuousClock.now - start
            if elapsed >= deadline {
                throw HostError.readTimedOut
            }
            let remaining = deadline - elapsed
            let parts = remaining.components
            // `timeval.tv_sec` is `time_t` (Int) on Darwin; clamp to
            // sane range. A multi-day select is unlikely (caller's
            // deadline is ≤60 s in practice) but defend anyway.
            let tvSec = max(0, min(Int(parts.seconds), Int(Int32.max)))
            let tvUsec = Int32(parts.attoseconds / 1_000_000_000_000)
            var tv = timeval(tv_sec: tvSec, tv_usec: tvUsec)
            var rfds = fd_set()
            fdZero(&rfds)
            fdSet(fd, set: &rfds)

            let n = select(fd + 1, &rfds, nil, nil, &tv)
            if n > 0 {
                return  // readable
            }
            if n == 0 {
                throw HostError.readTimedOut
            }
            // n < 0
            if errno == EINTR { continue }
            // Subprocess death often races a select() into EBADF or
            // ENOENT-ish errors depending on the path of fd close.
            throw HostError.subprocessGone(exitStatus: exitStatus)
        }
    }

    // MARK: - Handshake reader

    private struct HandshakeResult {
        let line: String
    }

    /// Read one `\n`-terminated line from `stdout` within `deadline`.
    /// On timeout, closes the pipe's read fd to unblock the worker
    /// thread, then throws `.handshakeTimedOut`.
    private func readHandshake(
        from stdout: FileHandle, deadline: Duration
    ) throws -> HandshakeResult {
        let resultBox = HandshakeBox()
        let sem = DispatchSemaphore(value: 0)

        // Use a detached thread (not a `DispatchWorkItem`) — the
        // blocking `read(2)` inside `availableData` does not honor
        // `DispatchWorkItem.cancel()`. Closing the underlying fd is
        // what unblocks it.
        Thread.detachNewThread {
            var buffer = Data()
            // `availableData` blocks until at least one byte arrives;
            // we accumulate until we see `\n` or EOF.
            while true {
                let chunk = stdout.availableData
                if chunk.isEmpty {
                    // EOF — possibly because we closed the fd to
                    // implement the timeout.
                    resultBox.set(.eof(line: String(data: buffer, encoding: .utf8) ?? ""))
                    sem.signal()
                    return
                }
                buffer.append(chunk)
                if let newlineIdx = buffer.firstIndex(of: 0x0A) {
                    let lineBytes = buffer.prefix(through: newlineIdx)
                    let line = String(data: lineBytes, encoding: .utf8) ?? ""
                    resultBox.set(.line(line))
                    sem.signal()
                    return
                }
            }
        }

        let timeoutMs = millis(deadline)
        switch sem.wait(timeout: .now() + .milliseconds(timeoutMs)) {
        case .success:
            switch resultBox.value {
            case .line(let s): return HandshakeResult(line: s)
            case .eof:
                // EOF without a line — could be either a normal
                // subprocess exit (lock-held → exit 75) or our own
                // timeout-induced close. Distinguish by checking the
                // process's exit status if available; for the
                // caller's purposes both are "handshake failed", so
                // we surface `handshakeTimedOut` to keep one code
                // path. (A model-load failure would happen *after*
                // the handshake, so we can be conservative here.)
                if let exit = exitStatus, exit != 0 {
                    throw HostError.spawnFailed(
                        "subprocess exited \(exit) before handshake")
                }
                throw HostError.handshakeTimedOut
            case .none:
                throw HostError.handshakeTimedOut
            }
        case .timedOut:
            // Unblock the reader by closing the pipe's read end. The
            // reader thread will return on EOF and free its memory;
            // we don't wait for it (the semaphore wait was the wait).
            try? stdout.close()
            throw HostError.handshakeTimedOut
        }
    }

    private func cleanupSocketFile() {
        let path = lock.withLock { socketPath }
        if let path { unlink(path.path) }
    }

    /// Mirror of `SocketSource.connect(to:)` — open AF_UNIX SOCK_STREAM
    /// and connect to the path. Lifted here so the host doesn't need
    /// to reach into the (internal-typed) `SocketSource` namespace for
    /// its connect helper.
    private static func connect(to path: String) throws -> Int32 {
        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < sunPathCapacity else {
            throw SocketSource.SocketError.pathTooLong(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketSource.SocketError.connectFailed(errno: errno)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
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
            throw SocketSource.SocketError.connectFailed(errno: e)
        }
        return fd
    }

    /// Drain a subprocess's stderr `FileHandle` line-by-line into
    /// `logger.notice`. Each newline-terminated line is forwarded as
    /// one log call with a `[whisper-subprocess]` prefix; a trailing
    /// partial line (e.g. the subprocess was killed mid-write) is
    /// flushed at EOF.
    ///
    /// Before this drainer, the parent set
    /// `process.standardError = FileHandle.standardError`, which
    /// inherited the parent's stderr — for the engine subprocess
    /// that's the engine's own stderr (visible in `pulsartrace-engine`
    /// stdio capture), for the mac-app it's launchd's stderr (visible
    /// nowhere in the daily log file). When the subprocess crashed
    /// mid-decode (the 2026-05-27 12-second failure), the whisper.cpp
    /// / ggml death rattle on stderr was effectively lost. Routing
    /// stderr through this drainer puts those lines in the engine log
    /// the same as the parent's own log calls.
    ///
    /// Runs synchronously on the calling thread until EOF; callers
    /// invoke it via a detached `DispatchQueue.global` async so the
    /// drain happens off the main `startAndInitialize` path.
    internal static func drainStderrLines(
        from readFD: FileHandle, logger: Logger
    ) {
        var buffer = Data()
        while true {
            let chunk = readFD.availableData
            if chunk.isEmpty {
                // EOF — flush any unterminated trailing line so a
                // subprocess SIGKILLed mid-write still leaves a hint
                // (`whisper_full: assertion failed at line …` etc.).
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    logger.notice("[whisper-subprocess] \(line)")
                }
                return
            }
            buffer.append(chunk)
            // Emit every complete line in the accumulated buffer.
            while let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer[buffer.startIndex..<nl]
                let line = String(decoding: lineData, as: UTF8.self)
                if !line.isEmpty {
                    logger.notice("[whisper-subprocess] \(line)")
                }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
    }
}

// MARK: - Helpers

/// Lock-protected box holding the handshake reader thread's outcome,
/// since the thread closure cannot return a value directly.
private final class HandshakeBox: @unchecked Sendable {
    enum Value {
        case line(String)
        case eof(line: String)
    }
    private let lock = NSLock()
    private var _value: Value?
    var value: Value? { lock.withLock { _value } }
    func set(_ value: Value) { lock.withLock { _value = value } }
}

private extension WhisperSubprocessHost.HostError {
    /// Used inside `sendAndRead` when a frame-codec error needs to
    /// surface as one of two HostError shapes depending on context.
    /// Here it's always `subprocessGone` (mid-frame disconnect) but
    /// keeping the helper makes the intent legible at the call site.
    func orWrite(_ codec: WhisperFrameCodec.CodecError) -> Self {
        switch codec {
        case .readFailed, .truncatedHeader, .truncatedPayload, .payloadTooLarge:
            return self
        case .writeFailed(let e):
            return .writeFailed("codec write failed: errno \(e)")
        }
    }
}

/// Duration → whole milliseconds, clamped to `Int` range. Used to
/// translate spec-level `Duration` deadlines into the
/// `DispatchTime`/`select` numeric APIs.
private func millis(_ d: Duration) -> Int {
    let parts = d.components
    let secMs = Int(parts.seconds) &* 1000
    let attoMs = Int(parts.attoseconds / 1_000_000_000_000_000)
    return secMs &+ attoMs
}

// MARK: - fd_set helpers (Darwin doesn't expose FD_SET as a macro)

/// `FD_ZERO`/`FD_SET` are macros in `<sys/select.h>` that don't
/// import into Swift; reimplement them in terms of the underlying
/// bit-array layout.
private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

private func fdSet(_ fd: Int32, set: inout fd_set) {
    // fd_set on Darwin is a tuple of Int32s holding the bit array.
    // We compute the word index and bit offset and OR the bit in.
    // The `MemoryLayout.size` constant must be computed *before*
    // entering the `withUnsafeMutablePointer` closure — reading
    // `set.fds_bits` while it is exclusively borrowed by the pointer
    // closure is an exclusivity violation under Swift 6.
    let intBits = MemoryLayout<Int32>.size * 8
    let wordIndex = Int(fd) / intBits
    let bitIndex = Int(fd) % intBits
    let wordCount = MemoryLayout.size(ofValue: set.fds_bits) / MemoryLayout<Int32>.size
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: wordCount) { words in
            words[wordIndex] |= Int32(1 << bitIndex)
        }
    }
}

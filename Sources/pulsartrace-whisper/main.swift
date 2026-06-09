import Foundation
import Logging
import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `pulsartrace-whisper` — the whisper inference subprocess
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md`).
///
/// One subprocess per concurrent transcription workload (live engine, or
/// refinement). The parent picks the UDS path, spawns this binary,
/// connects, sends `init`, then a sequence of `decode_window` /
/// `decode_region` requests. A wedged decode is recovered by the parent
/// SIGKILLing this process and respawning — the model is loaded fresh
/// in the new instance. Recording is unaffected because audio capture +
/// WAV/live.md writers all live in `pulsartrace-engine`, not here.
///
/// Usage:
///   pulsartrace-whisper --socket-path <path> [--lock-path <path>] [--cpu]
///                       [--hang-on-sentinel]
///
/// `--hang-on-sentinel` is **test-only**: it makes every `decode_window` /
/// `decode_region` request block the (single) request-loop thread in a
/// long `Thread.sleep`, simulating an unrecoverable whisper wedge. Init
/// still completes normally so the parent's lifecycle code goes through
/// its usual `.ready` path; only the first decode hangs, exactly like
/// the production wedge we are testing recovery from. The flag exists
/// solely for the Phase 7 acceptance suite (`WhisperSubprocessAcceptanceTests`)
/// and is never set in production.
///
/// Exit codes (spec §5/§8):
///   0  — clean shutdown (peer disconnected or `.shutdown` request)
///   2  — usage error (bad flag, missing argument)
///   70 — model load failed (`EX_SOFTWARE`); parent surfaces, does not retry
///   75 — another `pulsartrace-whisper` holds the lock (`EX_TEMPFAIL`);
///        parent surfaces an error rather than loop-respawning
@main
struct WhisperSubprocessMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let parsed: ParsedArgs
        do {
            parsed = try ParsedArgs(args)
        } catch let e as UsageError {
            FileHandle.standardError.write(Data((e.message + "\n").utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
            exit(2)
        }

        // Pin the swift-log backend to stderr explicitly so the
        // `ready: …` stdout handshake (below) is structurally safe
        // against any future `LoggingSystem.bootstrap` ordering or
        // upstream default change. Must run before the first `Logger`
        // is constructed; bootstrap is one-shot per process.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
        let logger = Logger(label: LogSubsystem.whisperSubprocess)

        // Layer 2 of the single-instance invariant: structural backstop.
        // If another instance is alive, we exit 75 immediately rather
        // than running concurrently — the parent treats this as a
        // user-visible error, not something to loop-retry.
        let lock: WhisperLock
        do {
            try SecureFiles.ensurePrivateDirectory(
                at: parsed.lockPath.deletingLastPathComponent())
            lock = try WhisperLock(lockPath: parsed.lockPath)
        } catch WhisperLockError.held {
            FileHandle.standardError.write(Data(
                "ERROR: another pulsartrace-whisper is already running\n".utf8))
            exit(75)
        } catch {
            FileHandle.standardError.write(Data(
                "ERROR: could not acquire whisper lock at \(parsed.lockPath.path): \(error)\n".utf8))
            exit(75)
        }

        // SIGTERM handler — flip a process-wide shutdown flag. We can't
        // do real work inside a signal handler (no Swift runtime), so the
        // main loop polls the flag between accept/read calls.
        installShutdownHandler(logger: logger)

        // Run the listen loop in a function that *returns* an exit code,
        // so the listenFD/clientFD `defer`s actually fire (Swift `defer`
        // is scope-tied — `exit(2)` would skip it). `lock` is captured
        // by `runListener` so it outlives every code path inside.
        let exitCode = runListener(parsed: parsed, lock: lock, logger: logger)
        exit(exitCode)
    }

    /// Bind + listen + accept + run the request loop. Returns the exit
    /// code so `defer`s clean up the socket fds + unlink the socket
    /// path on every code path — including ones that would otherwise
    /// call `exit()` directly (Swift `defer` does not run across `exit`).
    private static func runListener(
        parsed: ParsedArgs, lock: WhisperLock, logger: Logger
    ) -> Int32 {
        let listenFD: Int32
        do {
            listenFD = try bindAndListen(socketPath: parsed.socketPath)
        } catch {
            FileHandle.standardError.write(Data(
                "ERROR: bind/listen on \(parsed.socketPath.path) failed: \(error)\n".utf8))
            return 1
        }
        defer {
            close(listenFD)
            unlink(parsed.socketPath.path)
        }

        // Handshake: tell the parent we're listening so it can `connect()`.
        // Stdout is line-buffered for this kind of handshake; flush
        // explicitly so the parent never sees a delayed handshake.
        print("ready: \(parsed.socketPath.path)")
        fflush(stdout)
        logger.notice("listening on \(parsed.socketPath.path), cpu=\(parsed.forceCPU)")

        // Single connection; backlog of 1 (set in `bindAndListen`).
        let clientFD = accept(listenFD, nil, nil)
        if clientFD < 0 {
            if whisperSubprocess_shutdownRequested.load() {
                logger.notice("SIGTERM during accept — exiting clean")
                return 0
            }
            FileHandle.standardError.write(Data(
                "ERROR: accept() failed: errno \(errno)\n".utf8))
            return 1
        }
        defer { close(clientFD) }

        // `SO_NOSIGPIPE`: a disappeared parent surfaces as `EPIPE` from
        // `write(2)` rather than killing this process with SIGPIPE.
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            clientFD, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        logger.notice("client connected")

        // Run the request/response loop until the peer disconnects,
        // shutdown is requested, or a fatal error occurs.
        var session = Session(
            forceCPU: parsed.forceCPU,
            hangOnSentinel: parsed.hangOnSentinel,
            logger: logger)
        let exitCode = session.run(fd: clientFD)
        // `lock` is held until the end of this function; the deinit
        // releases it as we return to `main` and exit.
        _ = lock
        return exitCode
    }

    // MARK: - SIGTERM

    private static func installShutdownHandler(logger: Logger) {
        // `signal(2)` is sufficient for our needs — we just want a flag
        // flip, not full sigaction semantics. The handler must not call
        // any non-async-signal-safe function (so no logger, no Swift
        // runtime alloc); it does a single atomic store via the
        // top-level `whisperSubprocess_handleSIGTERM` C-callable below.
        signal(SIGTERM, whisperSubprocess_handleSIGTERM)
        // Ignore SIGPIPE process-wide: we set `SO_NOSIGPIPE` on the
        // client socket too, but ignoring it at the signal level is the
        // belt-and-braces in case a future code path forgets the socket
        // option.
        signal(SIGPIPE, SIG_IGN)
        // `logger` is captured only for future use; suppress unused-arg
        // warning without dropping the parameter so callers can wire a
        // logger if they want one.
        _ = logger
    }

    // MARK: - Socket setup

    /// `socket(AF_UNIX, SOCK_STREAM)` + `bind` + `listen(1)`. Mirrors
    /// `CaptureSocketServer.start()`; the backlog is intentionally 1
    /// (exactly one parent per subprocess).
    private static func bindAndListen(socketPath: URL) throws -> Int32 {
        // Remove any stale socket file from a previous crashed instance.
        // Safe because the flock guarantees no other instance is alive.
        unlink(socketPath.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw SocketSetupError.socketFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.path.utf8.count < maxLen else {
            close(fd)
            throw SocketSetupError.pathTooLong(socketPath.path)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.path.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr, maxLen)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, size)
            }
        }
        if bindResult != 0 {
            let e = errno; close(fd)
            throw SocketSetupError.bindFailed(errno: e)
        }
        if listen(fd, 1) != 0 {
            let e = errno; close(fd)
            throw SocketSetupError.listenFailed(errno: e)
        }
        return fd
    }

    enum SocketSetupError: Error, CustomStringConvertible {
        case socketFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case pathTooLong(String)

        var description: String {
            switch self {
            case .socketFailed(let e): return "socket() failed: errno \(e)"
            case .bindFailed(let e):   return "bind() failed: errno \(e)"
            case .listenFailed(let e): return "listen() failed: errno \(e)"
            case .pathTooLong(let p):  return "socket path too long: \(p)"
            }
        }
    }
}

// MARK: - Arg parsing

private struct ParsedArgs {
    let socketPath: URL
    let lockPath: URL
    let forceCPU: Bool
    /// Test-only: when true, every decode request blocks indefinitely on
    /// `Thread.sleep`, simulating an unrecoverable whisper wedge so the
    /// parent's watchdog/SIGKILL/respawn path can be exercised end-to-end
    /// by `WhisperSubprocessAcceptanceTests`. Init still works normally;
    /// only `decode_window` / `decode_region` hang.
    let hangOnSentinel: Bool

    init(_ args: [String]) throws {
        var socketPath: String?
        var lockPath: String?
        var cpu = false
        var hangOnSentinel = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--socket-path":
                guard i + 1 < args.count else {
                    throw UsageError(message: usage + "\n--socket-path requires a value")
                }
                socketPath = args[i + 1]
                i += 2
            case "--lock-path":
                guard i + 1 < args.count else {
                    throw UsageError(message: usage + "\n--lock-path requires a value")
                }
                lockPath = args[i + 1]
                i += 2
            case "--cpu":
                cpu = true
                i += 1
            case "--hang-on-sentinel":
                hangOnSentinel = true
                i += 1
            case "--help", "-h":
                throw UsageError(message: usage)
            default:
                throw UsageError(message: usage + "\nunknown argument: \(arg)")
            }
        }
        guard let s = socketPath else {
            throw UsageError(message: usage + "\n--socket-path is required")
        }
        self.socketPath = URL(fileURLWithPath: s)
        self.lockPath = lockPath.map { URL(fileURLWithPath: $0) }
            ?? AppPaths.standard.applicationSupport
                .appendingPathComponent("whisper.lock", isDirectory: false)
        self.forceCPU = cpu
        self.hangOnSentinel = hangOnSentinel
    }
}

private struct UsageError: Error {
    let message: String
}

private let usage = """
usage: pulsartrace-whisper --socket-path <path> [--lock-path <path>] [--cpu]
                           [--hang-on-sentinel]

  --hang-on-sentinel    Test-only: hang inside every decode request to
                        simulate an unrecoverable whisper wedge. Used by
                        the Phase 7 acceptance suite.
"""

// MARK: - Session

/// Owns the per-connection state: the loaded `WhisperTranscriber` (after
/// init), plus the request/response loop bound to one client FD.
///
/// One session per process: this binary handles exactly one connection
/// and then exits. The parent kills + respawns to recover from wedges.
private struct Session {
    let forceCPU: Bool
    /// Test-only: when true, every decode request blocks on
    /// `Thread.sleep` forever (Phase 7 acceptance suite). The parent's
    /// watchdog SIGKILLs the wedged subprocess; the kernel reaps it.
    let hangOnSentinel: Bool
    let logger: Logger
    var transcriber: WhisperTranscriber?

    init(forceCPU: Bool, hangOnSentinel: Bool, logger: Logger) {
        self.forceCPU = forceCPU
        self.hangOnSentinel = hangOnSentinel
        self.logger = logger
        self.transcriber = nil
    }

    /// Drain requests from `fd`, dispatching each. Returns the process
    /// exit code. Spec §5/§8:
    ///   - clean EOF / `.shutdown` request → 0
    ///   - model load failed → 70
    ///   - non-recoverable IPC error → 1
    ///   - decode failure within the loop is a `.error` response, not
    ///     an exit — the parent decides whether to retry.
    mutating func run(fd: Int32) -> Int32 {
        while true {
            if whisperSubprocess_shutdownRequested.load() {
                logger.notice("SIGTERM observed — exiting clean")
                return 0
            }

            let frame: Data?
            do {
                frame = try WhisperFrameCodec.readFrame(from: fd)
            } catch {
                logger.error("read frame failed: \(error)")
                return 1
            }

            // Clean EOF — peer disconnected between frames. Spec §8:
            // treat as normal exit; the parent killed us or the request
            // sender went away.
            guard let frame else {
                logger.notice("peer closed; exiting clean")
                return 0
            }

            let request: WhisperIPCRequest
            do {
                request = try JSONDecoder().decode(WhisperIPCRequest.self, from: frame)
            } catch {
                logger.error("decode request failed: \(error)")
                let err = WhisperIPCError(
                    kind: "decode_internal",
                    message: "request JSON decode failed: \(error)")
                _ = sendResponse(.error(err), to: fd)
                continue
            }

            switch request {
            case .initSession(let model, let gpu):
                if let code = handleInit(modelPath: model, gpu: gpu, fd: fd) {
                    return code
                }
            case .decodeWindow(let w):
                handleDecodeWindow(w, fd: fd)
            case .decodeRegion(let r):
                handleDecodeRegion(r, fd: fd)
            case .shutdown:
                logger.notice("shutdown requested — exiting clean")
                return 0
            }
        }
    }

    /// Returns a non-nil exit code on a fatal init failure (model load),
    /// `nil` to continue the loop (init done or `init_twice` reported).
    private mutating func handleInit(
        modelPath: String, gpu: Bool, fd: Int32
    ) -> Int32? {
        if transcriber != nil {
            let err = WhisperIPCError(
                kind: "init_twice",
                message: "init received but a model is already loaded")
            _ = sendResponse(.error(err), to: fd)
            return nil
        }

        // `--cpu` overrides the request's `gpu: true` so an operator can
        // force the CPU backend without changing the parent. The other
        // direction (CPU request + no `--cpu`) is honored — the parent
        // picks the backend when it has the right context.
        let useGPU = forceCPU ? false : gpu

        let modelURL = URL(fileURLWithPath: modelPath)
        let startNs = DispatchTime.now().uptimeNanoseconds
        do {
            transcriber = try WhisperTranscriber(
                modelURL: modelURL,
                useGPU: useGPU,
                logger: logger)
        } catch let e as WhisperTranscribeError {
            let err = WhisperIPCError(from: e)
            logger.error("init failed: \(e)")
            _ = sendResponse(.error(err), to: fd)
            // Spec §8: model load failure is non-loopable.
            return 70
        } catch {
            let err = WhisperIPCError(
                kind: "decode_internal",
                message: "init threw: \(error)")
            logger.error("init failed (unknown): \(error)")
            _ = sendResponse(.error(err), to: fd)
            return 70
        }
        let elapsedMs = Int(
            (DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
        logger.notice("model loaded in \(elapsedMs) ms")
        _ = sendResponse(.ready(modelLoadMs: elapsedMs), to: fd)
        return nil
    }

    private func handleDecodeWindow(
        _ req: WhisperIPCDecodeWindow, fd: Int32
    ) {
        if hangOnSentinel {
            // Test mode: hang forever to simulate a wedged decode. The
            // parent's per-decode `select(2)` deadline expires, the
            // parent SIGKILLs us, the kernel reaps the zombie. Used by
            // the Phase 7 acceptance suite — never set in production.
            // `Thread.sleep` blocks the (only) request-loop thread,
            // matching the production wedge shape (a graph compute step
            // that ignores the cooperative abort token).
            logger.warning(
                "--hang-on-sentinel: blocking decode_window forever to simulate a wedge")
            Thread.sleep(forTimeInterval: 60 * 60 * 24)  // until SIGKILL
            return  // unreachable
        }
        guard let transcriber else {
            let err = WhisperIPCError(
                requestId: req.requestId,
                kind: "decode_internal",
                message: "decode_window before init")
            _ = sendResponse(.error(err), to: fd)
            return
        }

        let samples: [Float]
        do {
            samples = try WhisperIPCSamples.decode(req.samplesBase64)
        } catch {
            let err = WhisperIPCError(
                requestId: req.requestId,
                kind: "decode_internal",
                message: "samples decode failed: \(error)")
            _ = sendResponse(.error(err), to: fd)
            return
        }
        let opts = req.options.toWhisperOptions()
        // Spec §6: abort: nil — process death replaces the abort token.
        let windowStart = Duration.milliseconds(Int(req.windowStartMs))
        do {
            let result = try transcriber.transcribeWindow(
                samples,
                windowStart: windowStart,
                options: opts,
                abort: nil)
            let segments = result.segments.map { seg in
                WhisperIPCSegment(
                    text: seg.text,
                    startMs: durationToMs(seg.start),
                    endMs: durationToMs(seg.end))
            }
            let payload = WhisperIPCDecoded(
                requestId: req.requestId,
                segments: segments,
                language: result.language)
            _ = sendResponse(.decoded(payload), to: fd)
        } catch let e as WhisperTranscribeError {
            // Spec §8: decode failure is recoverable from the parent's
            // POV — surface as `.error`, do not exit.
            let err = WhisperIPCError(from: e, requestId: req.requestId)
            logger.warning("decode_window failed: \(e)")
            _ = sendResponse(.error(err), to: fd)
        } catch {
            let err = WhisperIPCError(
                requestId: req.requestId,
                kind: "decode_internal",
                message: "\(error)")
            logger.warning("decode_window threw: \(error)")
            _ = sendResponse(.error(err), to: fd)
        }
    }

    private func handleDecodeRegion(
        _ req: WhisperIPCDecodeRegion, fd: Int32
    ) {
        if hangOnSentinel {
            // See `handleDecodeWindow` — same test-only wedge.
            logger.warning(
                "--hang-on-sentinel: blocking decode_region forever to simulate a wedge")
            Thread.sleep(forTimeInterval: 60 * 60 * 24)  // until SIGKILL
            return  // unreachable
        }
        guard let transcriber else {
            let err = WhisperIPCError(
                requestId: req.requestId,
                kind: "decode_internal",
                message: "decode_region before init")
            _ = sendResponse(.error(err), to: fd)
            return
        }

        let samples: [Float]
        do {
            samples = try WhisperIPCSamples.decode(req.samplesBase64)
        } catch {
            let err = WhisperIPCError(
                requestId: req.requestId,
                kind: "decode_internal",
                message: "samples decode failed: \(error)")
            _ = sendResponse(.error(err), to: fd)
            return
        }
        let opts = req.options.toWhisperOptions()
        let region = SpeechRegion(
            start: .milliseconds(Int(req.regionStartMs)),
            end: .milliseconds(Int(req.regionEndMs)))
        do {
            let result = try transcriber.transcribeRegion(
                samples, region: region, options: opts)
            let segments = result.segments.map { seg in
                WhisperIPCSegment(
                    text: seg.text,
                    startMs: durationToMs(seg.start),
                    endMs: durationToMs(seg.end))
            }
            let payload = WhisperIPCDecoded(
                requestId: req.requestId,
                segments: segments,
                language: result.language)
            _ = sendResponse(.decoded(payload), to: fd)
        } catch let e as WhisperTranscribeError {
            let err = WhisperIPCError(from: e, requestId: req.requestId)
            logger.warning("decode_region failed: \(e)")
            _ = sendResponse(.error(err), to: fd)
        } catch {
            let err = WhisperIPCError(
                requestId: req.requestId,
                kind: "decode_internal",
                message: "\(error)")
            logger.warning("decode_region threw: \(error)")
            _ = sendResponse(.error(err), to: fd)
        }
    }

    /// Encode + write a response frame. Returns false if the write failed
    /// (peer gone) so a caller could exit, but the run loop currently
    /// keeps going — `readFrame` will surface the disconnect on the next
    /// iteration as a clean EOF.
    @discardableResult
    private func sendResponse(
        _ response: WhisperIPCResponse, to fd: Int32
    ) -> Bool {
        do {
            let json = try JSONEncoder().encode(response)
            let frame = try WhisperFrameCodec.encode(jsonBytes: json)
            try WhisperFrameCodec.writeFrame(frame, to: fd)
            return true
        } catch {
            logger.error("send response failed: \(error)")
            return false
        }
    }
}

/// Convert a `Duration` to whole milliseconds.
///
/// `Duration.components` exposes seconds + attoseconds (1e-18 s). Whisper
/// timestamps are 10 ms-granular so sub-ms precision loss is not a
/// concern.
private func durationToMs(_ d: Duration) -> Int64 {
    let parts = d.components
    let secMs = parts.seconds &* 1000
    let attoMs = parts.attoseconds / 1_000_000_000_000_000
    return secMs &+ attoMs
}

// MARK: - SIGTERM globals

/// Atomic shutdown flag, set by `whisperSubprocess_handleSIGTERM` and
/// polled by `Session.run` between requests. Lives at file scope because
/// `signal(2)` requires a `@convention(c)` callback that cannot capture
/// any Swift context — the handler must talk to a global, not an
/// instance.
///
/// The underlying `AtomicBool`'s single `Int32` store is safe to flip
/// from the signal handler (an aligned word-sized store on arm64 is
/// atomic-by-the-hardware) and the main loop only reads.
let whisperSubprocess_shutdownRequested = AtomicBool()

/// `@convention(c)` SIGTERM handler — the signal handler must not call
/// any non-async-signal-safe function (no logger, no allocator). All we
/// do here is flip the flag the main loop polls.
func whisperSubprocess_handleSIGTERM(_ signal: Int32) {
    whisperSubprocess_shutdownRequested.store(true)
}

/// Minimal atomic Bool flag for the SIGTERM handler. A plain `Int32`
/// with stores/loads through `withUnsafeMutablePointer` is fine for a
/// single-writer (the signal handler), single-reader (the main loop)
/// flag — the only guarantee we need is a non-torn write, which holds
/// for a word-sized aligned store.
final class AtomicBool: @unchecked Sendable {
    private var raw: Int32 = 0
    init() {}
    func store(_ value: Bool) {
        withUnsafeMutablePointer(to: &raw) { ptr in
            ptr.pointee = value ? 1 : 0
        }
    }
    func load() -> Bool {
        withUnsafeMutablePointer(to: &raw) { ptr in
            ptr.pointee != 0
        }
    }
}

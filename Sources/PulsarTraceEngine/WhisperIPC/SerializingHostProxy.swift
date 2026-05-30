import Foundation
import Logging

/// Parent-side serializing proxy that lets multiple
/// `RemoteWindowTranscriber` instances share **one**
/// `pulsartrace-whisper` subprocess.
///
/// ## Why this exists
///
/// The `pulsartrace-whisper` binary takes a process-wide `flock` (spec
/// `docs/specs/2026-05-26-whisper-subprocess-design.md` §4 Layer 2) so a
/// second concurrent subprocess would exit with code 75 (`EX_TEMPFAIL`).
/// Phase 4 of the whisper-subprocess project moved the live engine's
/// **system** stream to `RemoteWindowTranscriber`, but had to leave the
/// **mic** stream on the in-process `WhisperTranscriber` because two
/// independent `RemoteWindowTranscriber` instances would each spawn
/// their own host and trip the lock — leaving the mic path still
/// vulnerable to the in-graph wedge the project was built to eliminate.
///
/// `SerializingHostProxy` fixes that. It conforms to
/// `WhisperHostProtocol`, owns one inner `WhisperHostProtocol` (a real
/// `WhisperSubprocessHost` by default, a fake in tests), and **serializes
/// every method** behind a single `NSLock`. The engine builds one proxy
/// at boot, hands the **same** proxy to both `RemoteWindowTranscriber`
/// instances via `hostFactory: { _, _ in proxy }`, and both streams now
/// share one subprocess — honoring the binary-level flock by
/// construction.
///
/// ## Contract
///
/// 1. **`startAndInitialize(model:)`** — idempotent on the same model;
///    rejected with `.initRefused` on a different model. Latched-shutdown
///    proxies throw `.subprocessGone`. A dead inner is replaced.
/// 2. **`decode(_:deadline:)`** — forwarded to the inner under the lock.
///    Dead/missing inner → `.subprocessGone`; caller's `handleHostError`
///    will SIGKILL+respawn.
/// 3. **`terminate(grace:)`** — latches shutdown. Subsequent calls (and
///    any further decode/start) error out.
/// 4. **`sigkill()`** — drops the inner so the next call can build a
///    fresh one. Does **not** clear `lastInitModel` and does **not**
///    latch shutdown — this is the recovery path the caller uses after a
///    decode wedge.
/// 5. **`isAlive`** — reflects the inner.
///
/// ## Lock-around-decode is intentional
///
/// `decode` runs **inside** the lock, so a 10 s decode pins the lock for
/// the full 10 s. That's deliberate — it's the IPC equivalent of the
/// in-process `metalLock` the project has been relying on
/// (`WhisperTranscriber.metalLock`) and the same invariant the
/// per-process `flock` in the whisper binary enforces. Decodes through
/// the shared host are sequential by design; the second transcriber's
/// next decode queues behind the first's wedge-detection deadline, and
/// the deadline itself is the bound (default 10 s in the live engine).
/// Do **not** try to "optimize" the lock to allow concurrent decodes —
/// the underlying CoreML/Metal contexts cannot be shared across threads
/// without the very serialization this proxy provides.
public final class SerializingHostProxy: WhisperHostProtocol, @unchecked Sendable {

    /// Closure used to manufacture a real (or fake) inner host. The
    /// default returns a `WhisperSubprocessHost`; tests inject a closure
    /// returning a fake conforming to `WhisperHostProtocol`.
    public typealias InnerFactory = @Sendable (
        WhisperSubprocessHost.Configuration, Logger
    ) -> WhisperHostProtocol

    // MARK: - State

    private let configuration: WhisperSubprocessHost.Configuration
    private let logger: Logger
    private let innerFactory: InnerFactory

    /// Serializes every public method. See class-level doc comment for
    /// why decode runs inside the lock.
    private let lock = NSLock()
    /// The active inner host, or `nil` if not yet started / sigkilled /
    /// terminated.
    private var inner: WhisperHostProtocol?
    /// The model the inner was last initialized with. Preserved across
    /// `sigkill`/respawn so the proxy can reject a different-model
    /// `startAndInitialize` after recovery.
    private var lastInitModel: String?
    /// Latched on `terminate`; further start/decode/terminate calls
    /// short-circuit.
    private var shutdownLatched: Bool = false

    // MARK: - Init

    public init(
        configuration: WhisperSubprocessHost.Configuration,
        logger: Logger,
        innerFactory: @escaping InnerFactory = { config, logger in
            WhisperSubprocessHost(configuration: config, logger: logger)
        }
    ) {
        self.configuration = configuration
        self.logger = logger
        self.innerFactory = innerFactory
    }

    // MARK: - WhisperHostProtocol

    public func startAndInitialize(model: String) throws {
        // Held under the lock end-to-end, matching the
        // serialize-everything contract documented above. Spawn +
        // handshake time (≤ spawnTimeout + initTimeout, default 70 s)
        // therefore blocks any concurrent decode/start from the other
        // transcriber. That's intentional — at engine boot only one
        // transcriber actually starts the inner (the other's call
        // becomes the idempotent no-op below), and during a respawn the
        // wedged transcriber already owns the recovery; the second
        // transcriber's next decode legitimately needs to wait for the
        // fresh inner to be ready.
        lock.lock()
        defer { lock.unlock() }

        if shutdownLatched {
            throw WhisperSubprocessHost.HostError.subprocessGone(exitStatus: nil)
        }
        if let inner, inner.isAlive {
            if lastInitModel == model {
                return  // idempotent no-op
            }
            throw WhisperSubprocessHost.HostError.initRefused(
                "shared whisper host already initialized with a different model")
        }
        // No inner, or the existing one died — build + start a fresh
        // one. Any throw here leaves `self.inner` nil so the next
        // start attempt will retry from scratch.
        let newInner = innerFactory(configuration, logger)
        try newInner.startAndInitialize(model: model)
        self.inner = newInner
        self.lastInitModel = model
    }

    public func decode(
        _ request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse {
        // The whole decode runs under the lock — see class doc comment.
        // We can't use `lock.withLock` for the throws-with-return shape
        // and keep the explicit early-error contracts crisp, so unlock
        // manually.
        lock.lock()
        defer { lock.unlock() }

        if shutdownLatched {
            throw WhisperSubprocessHost.HostError.subprocessGone(exitStatus: nil)
        }
        guard let inner else {
            throw WhisperSubprocessHost.HostError.subprocessGone(exitStatus: nil)
        }
        if !inner.isAlive {
            throw WhisperSubprocessHost.HostError.subprocessGone(exitStatus: nil)
        }
        return try inner.decode(request, deadline: deadline)
    }

    public func terminate(grace: Duration) {
        let toTerminate: WhisperHostProtocol? = lock.withLock {
            if shutdownLatched { return nil }
            shutdownLatched = true
            let h = self.inner
            self.inner = nil
            return h
        }
        toTerminate?.terminate(grace: grace)
    }

    public func sigkill() {
        let toKill: WhisperHostProtocol? = lock.withLock {
            let h = self.inner
            self.inner = nil
            return h
            // NOTE: deliberately do NOT clear `lastInitModel` and do NOT
            // latch `shutdownLatched` — the next `startAndInitialize`
            // (called by whichever transcriber owns the recovery path)
            // must succeed and respawn the inner.
        }
        toKill?.sigkill()
    }

    public var isAlive: Bool {
        lock.withLock { inner?.isAlive ?? false }
    }
}

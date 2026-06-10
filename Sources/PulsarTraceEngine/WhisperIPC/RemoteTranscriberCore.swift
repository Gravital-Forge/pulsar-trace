import Foundation
import Logging

/// Shared host-lifecycle engine behind `RemoteWindowTranscriber` and
/// `RemoteRegionTranscriber`: lazy start, decode-deadline kill + respawn
/// with throttled backoff logging, latched shutdown. The wrappers own
/// their `Configuration` and request/response mapping; the Core owns the
/// host and every failure-mode policy, so a respawn bug is fixed once.
///
/// `@unchecked Sendable`: `host`/`shutdownLatched` are guarded by `lock`,
/// the same invariant the two wrappers documented individually.
///
/// State machine: `host` starts `nil`; `ensureHostStarted` lazily spawns
/// it; a decode-deadline breach (`handleHostError`) SIGKILLs and respawns
/// it (`respawnWithBackoffLog`); `sigkillCurrentHost` returns it to `nil`
/// without latching, so the next call respawns. `shutdown()` is the only
/// one-way door: it sets `shutdownLatched`, after which every start
/// attempt throws — a latched Core never spawns again.
final class RemoteTranscriberCore: @unchecked Sendable {

    /// Closure used to manufacture a new host. The default (supplied by
    /// the wrappers) returns a real `WhisperSubprocessHost`; tests pass
    /// a closure that returns a fake conforming to `WhisperHostProtocol`
    /// so the deadline / respawn paths can be exercised without spawning
    /// a real binary.
    typealias HostFactory = @Sendable (
        WhisperSubprocessHost.Configuration, Logger
    ) -> WhisperHostProtocol

    /// Everything that differed between the two wrappers, collapsed
    /// into data: the pre-built host configuration, the model path,
    /// the respawn/backoff budgets, and the one log line whose wording
    /// disambiguates live ("stream=remote") from refinement ("region").
    struct Policy {
        let hostConfiguration: WhisperSubprocessHost.Configuration
        let modelPath: String
        /// Bound on the parent-side spawn-and-init wait used for a
        /// respawn. Past this we surface a `.modelLoadFailed`-shaped
        /// error so the caller fails cleanly instead of looping.
        let respawnDeadline: Duration
        /// Initial backoff between throttled "still waiting for
        /// respawn" log lines. Spec §6: 5 s.
        let logBackoffInitial: Duration
        /// Cap on the backoff doubling. Spec §6: 600 s.
        let logBackoffCap: Duration
        /// Prefix of the deadline-kill warning — the one string that
        /// differed between the wrappers. The Core appends " (\(error))"
        /// with the concrete `HostError` variant. The wording is
        /// load-bearing for log greps (tests pin it): the live wrapper
        /// includes "stream=remote", the refinement wrapper says
        /// "region" — do not unify the two strings.
        let deadlineKillMessage: String
    }

    // MARK: - State

    private let policy: Policy
    private let logger: Logger
    private let hostFactory: HostFactory

    /// Guards `host` and `shutdownLatched`.
    private let lock = NSLock()
    private var host: WhisperHostProtocol?
    private var shutdownLatched = false

    // MARK: - Init

    init(
        policy: Policy,
        logger: Logger,
        hostFactory: @escaping HostFactory
    ) {
        self.policy = policy
        self.logger = logger
        self.hostFactory = hostFactory
    }

    // MARK: - Host lifecycle

    /// Cooperative shutdown — SIGTERM the host with a short grace.
    /// Idempotent: a second call is a no-op.
    func shutdown() {
        let host = lock.withLock {
            guard !shutdownLatched else { return WhisperHostProtocol?.none }
            shutdownLatched = true
            let h = self.host
            self.host = nil
            return h
        }
        host?.terminate(grace: .seconds(2))
    }

    func ensureHostStarted() throws {
        let needsStart = lock.withLock {
            if shutdownLatched { return false }
            if let host, host.isAlive { return false }
            return true
        }
        guard needsStart else {
            if lock.withLock({ shutdownLatched }) {
                throw WhisperTranscribeError.transcriptionFailed(-1)
            }
            return
        }
        try startHost()
    }

    private func startHost() throws {
        let newHost = hostFactory(policy.hostConfiguration, logger)
        do {
            try newHost.startAndInitialize(model: policy.modelPath)
        } catch let e as WhisperSubprocessHost.HostError {
            // Non-recoverable from the caller's POV: surface as a
            // model-load failure so the run/job fails cleanly.
            throw Self.toModelLoadFailed(e)
        } catch {
            throw WhisperTranscribeError.modelLoadFailed("\(error)")
        }
        lock.withLock { self.host = newHost }
    }

    func currentHostOrThrow() throws -> WhisperHostProtocol {
        guard let h = (lock.withLock { host }) else {
            throw WhisperTranscribeError.transcriptionFailed(-1)
        }
        return h
    }

    func sigkillCurrentHost() {
        let h = lock.withLock {
            let host = self.host
            self.host = nil
            return host
        }
        h?.sigkill()
    }

    /// React to a host error from `decode`. On a recoverable wedge
    /// (timeout / EOF / writeFailed / subprocessGone) we SIGKILL the
    /// host, spawn a fresh one with throttled-log backoff, and re-Init
    /// — then return normally so the caller can throw the
    /// `transcriptionFailed` for this wedged window/region. On a
    /// non-recoverable spawn failure during the respawn, we re-throw
    /// as `.modelLoadFailed`.
    func handleHostError(
        _ error: WhisperSubprocessHost.HostError
    ) throws {
        switch error {
        case .readTimedOut, .readEOF, .writeFailed, .subprocessGone:
            // Interpolate the actual `HostError` variant — a hardcoded
            // "exceeded deadline" message claimed a timeout even when
            // the subprocess crashed within seconds of a 120-second
            // budget (the 2026-05-27 incident). The variant identifies
            // whether it was a true deadline (`readTimedOut`), a peer
            // crash (`readEOF` / `subprocessGone`), or a write failure
            // (`writeFailed`). The policy prefix keeps "exceeded
            // deadline" so existing log-greps still match.
            logger.warning("\(policy.deadlineKillMessage) (\(error))")
            sigkillCurrentHost()
            try respawnWithBackoffLog()
        case .binaryNotFound, .spawnFailed, .initRefused,
             .handshakeTimedOut, .handshakeMalformed, .connectFailed:
            // We shouldn't see these from a steady-state `decode` (they
            // surface only from `startAndInitialize`). Defensively
            // map to model-load-failed so a buggy subprocess doesn't
            // wedge the caller indefinitely.
            sigkillCurrentHost()
            throw Self.toModelLoadFailed(error)
        }
    }

    /// Spawn a replacement host. While the spawn is in flight, kick
    /// off a `Task` that emits the throttled-backoff log line — if the
    /// respawn finishes quickly (the normal case) the task is
    /// cancelled before the first emission and no extra log appears.
    private func respawnWithBackoffLog() throws {
        var throttle = RespawnLogThrottle(
            initial: policy.logBackoffInitial,
            cap: policy.logBackoffCap)
        // Sendable-safe snapshot of values the backoff task needs.
        let log = logger

        // Bound the total respawn wait by `respawnDeadline`; past
        // that we give up and let the caller fail with
        // `.modelLoadFailed`. The backoff task is also bounded by
        // this deadline.
        let respawnStart = ContinuousClock.now
        let respawnDeadline = policy.respawnDeadline

        let backoffTask = Task<Void, Never> {
            while !Task.isCancelled {
                let delay = throttle.nextDelay()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                let elapsed = ContinuousClock.now - respawnStart
                log.warning(
                    "still waiting for whisper subprocess respawn (elapsed≈\(secondsString(elapsed))s)")
                if elapsed >= respawnDeadline { return }
            }
        }
        defer { backoffTask.cancel() }

        do {
            try startHost()
        } catch {
            // Log the actual spawn failure before propagating. Without
            // this, the caller's catch surfaces only a coarse failure
            // class with no further context — the live-transcription
            // wedge of 2026-05-27 hid every respawn error this way.
            logger.error("whisper subprocess respawn failed: \(error)")
            throw error
        }
    }

    /// Convert a host-side error into the `WhisperTranscribeError`
    /// shape the engine/refiner surfaces for non-recoverable failures.
    static func toModelLoadFailed(
        _ e: WhisperSubprocessHost.HostError
    ) -> WhisperTranscribeError {
        switch e {
        case .binaryNotFound(let p):
            return .modelLoadFailed("pulsartrace-whisper not found: \(p)")
        case .spawnFailed(let m):
            return .modelLoadFailed("spawn failed: \(m)")
        case .initRefused(let m):
            return .modelLoadFailed("init refused: \(m)")
        case .handshakeTimedOut:
            return .modelLoadFailed("handshake timed out")
        case .handshakeMalformed(let s):
            return .modelLoadFailed("handshake malformed: \(s)")
        case .connectFailed(let errnoVal):
            return .modelLoadFailed("UDS connect failed: errno \(errnoVal)")
        case .readTimedOut, .readEOF, .writeFailed, .subprocessGone:
            return .modelLoadFailed("subprocess unhealthy: \(e)")
        }
    }
}

// MARK: - Helpers

private func secondsString(_ d: Duration) -> String {
    let parts = d.components
    return "\(parts.seconds)"
}

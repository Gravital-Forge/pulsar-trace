import Foundation
import Logging

/// Spawns and supervises one diarizer worker incarnation. Abstracted so tests
/// substitute an in-process fake (D43).
public protocol DiarWorkerLaunching: Sendable {
    func launch() async throws -> DiarWorkerHandle
}

/// A live worker incarnation: its connection, the model digest from its `hello`,
/// and handles to kill it (SIGKILL) and await its exit.
public struct DiarWorkerHandle: Sendable {
    public let connection: any DiarWorkerConnecting
    public let modelRevision: String
    public let kill: @Sendable () -> Void
    public let awaitExit: @Sendable () async -> Void
    public init(connection: any DiarWorkerConnecting, modelRevision: String,
                kill: @escaping @Sendable () -> Void, awaitExit: @escaping @Sendable () async -> Void) {
        self.connection = connection; self.modelRevision = modelRevision
        self.kill = kill; self.awaitExit = awaitExit
    }
}

/// Supervisor + RPC proxy. Conforms to `RawWindowDiarizing`: `diarizeRawWindow`
/// ships the window to the worker and awaits the reply under a deadline; on
/// timeout (or EOF) it kills + respawns the worker and returns `nil` for that
/// window. A killed worker's wedged ANE call dies with the process.
public actor DiarWorkerClient: RawWindowDiarizing {
    private let launcher: any DiarWorkerLaunching
    private let deadline: Duration
    private let restartBackoff: Duration
    private let backoffCap: Duration
    private let logger: Logger

    private var handle: DiarWorkerHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [UInt64: CheckedContinuation<DiarWindowResult?, Never>] = [:]
    private var nextId: UInt64 = 0
    private var revision = ""
    private var consecutiveRestarts = 0
    private var restarting = false
    private var shuttingDown = false
    /// Bumped on every successful launch. A reader task carries the generation
    /// it was started for; a superseded incarnation's EOF is ignored structurally
    /// rather than relying on scheduling timing (I4).
    private var generation: Int = 0

    public init(
        launcher: any DiarWorkerLaunching,
        deadline: Duration = .seconds(2),
        restartBackoff: Duration = .milliseconds(250),
        backoffCap: Duration = .seconds(10),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.launcher = launcher
        self.deadline = deadline
        self.restartBackoff = restartBackoff
        self.backoffCap = backoffCap
        self.logger = logger
    }

    public func start() async { await bringUp() }

    public func modelRevision() async -> String { revision }

    public func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        guard !shuttingDown, let handle, !restarting else { return nil }
        let id = nextId; nextId &+= 1

        let frame = DiarWorkerProtocol.encodeRequest(requestId: id, samples: samples)
        do { try handle.connection.send(frame) }
        catch { await restart(reason: "send failed: \(error)"); return nil }

        // Resolve via the reader OR the deadline — whichever first. No task group
        // awaits the reply, so an un-resumed reply can never wedge this call.
        let result: DiarWindowResult? = await withCheckedContinuation { cont in
            pending[id] = cont
            scheduleDeadline(for: id)
        }
        if result != nil { consecutiveRestarts = 0 }   // a real success resets backoff
        return result
    }

    public func shutdown() async {
        shuttingDown = true
        readerTask?.cancel()
        handle?.kill()
        await handle?.awaitExit()
        handle?.connection.close()      // C1: release the engine-side fd
        failAllPending()
        handle = nil
    }

    // MARK: - Internals

    private func scheduleDeadline(for id: UInt64) {
        Task { [deadline] in
            try? await Task.sleep(for: deadline)
            await self.deadlineFired(id: id)
        }
    }

    private func deadlineFired(id: UInt64) async {
        guard let cont = pending.removeValue(forKey: id) else { return }  // reply already won
        cont.resume(returning: nil)
        logger.notice("diar worker: window deadline exceeded — killing + respawning")
        await restart(reason: "deadline")
    }

    private func bringUp() async {
        guard !shuttingDown else { return }
        // Bump the generation BEFORE the launch `await`: a superseded reader's
        // EOF arriving *during* the relaunch must see a newer generation and be
        // ignored. Incrementing only after launch() returns leaves a window
        // (zero backoff) where the stale EOF passes the guard and re-enters
        // restart, which could overwrite `handle` and leak a worker (I4).
        generation += 1
        let gen = generation
        do {
            let h = try await launcher.launch()
            handle = h
            revision = h.modelRevision
            startReader(for: h, generation: gen)
        } catch {
            logger.error("diar worker: launch failed: \(PathRedactor.redactHome("\(error)"))")
        }
    }

    private func startReader(for h: DiarWorkerHandle, generation gen: Int) {
        readerTask = Task {
            for await body in h.connection.inboundBodies {
                guard let msg = try? DiarWorkerProtocol.decodeMessage(body) else { continue }
                if case let .result(requestId, window) = msg {
                    self.deliver(requestId: requestId, window: window)
                }
                // `hello` is consumed by the launcher before handing us the handle.
            }
            await self.readerEnded(generation: gen)   // EOF / worker exited unexpectedly
        }
    }

    private func deliver(requestId: UInt64, window: DiarWindowResult) {
        if let cont = pending.removeValue(forKey: requestId) { cont.resume(returning: window) }
    }

    private func readerEnded(generation gen: Int) async {
        // A superseded incarnation's EOF must not restart a healthy worker (I4).
        guard gen == generation else { return }
        guard !shuttingDown, !restarting else { return }
        await restart(reason: "worker connection closed")
    }

    private func restart(reason: String) async {
        guard !shuttingDown, !restarting else { return }
        restarting = true
        logger.notice("diar worker: restarting (\(reason))")
        readerTask?.cancel()
        handle?.kill()
        await handle?.awaitExit()
        handle?.connection.close()      // C1: release the engine-side fd
        handle = nil
        failAllPending()

        consecutiveRestarts += 1
        let delay = backoff(consecutiveRestarts)
        if delay > .zero { try? await Task.sleep(for: delay) }

        restarting = false
        await bringUp()
    }

    private func failAllPending() {
        let conts = pending.values
        pending.removeAll()
        for c in conts { c.resume(returning: nil) }
    }

    private func backoff(_ n: Int) -> Duration {
        // base * 2^(n-1), capped. n starts at 1.
        let capMs = backoffCap.milliseconds
        let baseMs = restartBackoff.milliseconds
        guard baseMs > 0 else { return .zero }
        let shifted = baseMs * (1 << min(n - 1, 20))
        return .milliseconds(min(shifted, capMs))
    }
}

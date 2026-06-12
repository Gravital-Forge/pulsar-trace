import Foundation

/// Drives one `pulsartrace record` session: spawns `pulsartrace-capture`,
/// waits for its `ready` handshake, spawns `pulsartrace-engine --live`, and
/// tears the pair down cleanly (R47).
///
/// The capture daemon must be a separate process — it is the only TCC-gated
/// PulsarTrace process (R4) — and the engine is spawned separately so the
/// menubar can detect its death. This orchestrator is the reusable code
/// path: `RecordCommand` (CLI) and the menubar both drive it.
///
/// It is binary-agnostic — the caller passes the two executables and their
/// argv (built by `RecordPlan`) — so it is testable against stand-in scripts
/// with no real audio.
public actor RecordOrchestrator {

    /// What to launch.
    public struct Configuration: Sendable {
        public let captureBinary: URL
        public let captureArguments: [String]
        public let engineBinary: URL
        public let engineArguments: [String]
        /// Extra environment variables merged onto the parent process's
        /// environment before the engine subprocess is spawned (caller wins
        /// on duplicate keys). `nil` leaves the engine with the unmodified
        /// inherited environment.
        ///
        /// No production caller sets this today (the engine subprocess
        /// resolves everything it needs itself); kept as the generic
        /// subprocess-environment seam, exercised by RecordOrchestratorTests.
        public let engineEnvironment: [String: String]?

        public init(
            captureBinary: URL,
            captureArguments: [String],
            engineBinary: URL,
            engineArguments: [String],
            engineEnvironment: [String: String]? = nil
        ) {
            self.captureBinary = captureBinary
            self.captureArguments = captureArguments
            self.engineBinary = engineBinary
            self.engineArguments = engineArguments
            self.engineEnvironment = engineEnvironment
        }
    }

    /// A start-up failure — each carries enough to print an actionable message.
    public enum StartError: Error, CustomStringConvertible, Equatable {
        /// The capture binary could not be launched at all.
        case captureLaunchFailed(String)
        /// Capture exited before printing `ready` — typically a missing TCC
        /// permission (its stderr explains which).
        case captureExitedBeforeReady(code: Int32, stderr: String)
        /// `ready` did not arrive within the timeout.
        case readyTimedOut
        /// The engine binary could not be launched.
        case engineLaunchFailed(String)

        public var description: String {
            switch self {
            case .captureLaunchFailed(let m):
                return "could not launch pulsartrace-capture: \(m)"
            case .captureExitedBeforeReady(let code, let stderr):
                let detail = stderr.isEmpty ? "" : " — \(stderr)"
                return "pulsartrace-capture exited (code \(code)) before "
                    + "it was ready\(detail)"
            case .readyTimedOut:
                return "pulsartrace-capture did not become ready in time"
            case .engineLaunchFailed(let m):
                return "could not launch pulsartrace-engine: \(m)"
            }
        }
    }

    /// The result of a completed session.
    public struct Outcome: Sendable {
        /// The engine's exit status (`0` on a clean live pass).
        public let engineExitCode: Int32
        /// The engine's stdout — its one-line live-pass summary.
        public let engineSummary: String
        /// The capture daemon's exit status.
        public let captureExitCode: Int32
    }

    private let configuration: Configuration

    private var capture: Process?
    private var engine: Process?
    private var captureExit: Task<Int32, Never>?
    private var engineExit: Task<Int32, Never>?
    /// Background collector for the engine's stdout (its summary line).
    private var engineStdout: Task<String, Never>?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Start

    /// Launch capture, wait for `ready`, then launch the engine.
    ///
    /// - Parameter readyTimeout: how long to wait for capture's `ready` line.
    public func start(readyTimeout: Duration) async throws {
        let capture = Process()
        capture.executableURL = configuration.captureBinary
        capture.arguments = configuration.captureArguments
        let captureOut = Pipe()
        let captureErr = Pipe()
        capture.standardOutput = captureOut
        capture.standardError = captureErr

        let captureWaiter = ProcessExitWaiter()
        capture.terminationHandler = { proc in
            captureWaiter.complete(proc.terminationStatus)
        }
        do {
            try capture.run()
        } catch {
            throw StartError.captureLaunchFailed("\(error)")
        }
        self.capture = capture
        let captureExitTask = Task { await captureWaiter.value() }
        self.captureExit = captureExitTask

        // Wait for `ready`, racing capture exit and the timeout.
        try await waitForReady(
            stdout: captureOut.fileHandleForReading,
            stderr: captureErr.fileHandleForReading,
            captureExit: captureExitTask,
            timeout: readyTimeout)

        // Capture is up — drain its remaining stdout/stderr so its pipes
        // cannot fill and block it.
        drainToVoid(captureOut.fileHandleForReading)
        drainToVoid(captureErr.fileHandleForReading)

        // Launch the engine.
        let engine = Process()
        engine.executableURL = configuration.engineBinary
        engine.arguments = configuration.engineArguments
        // If the caller supplied extra env vars, merge them onto the parent's
        // environment so the engine subprocess still inherits HOME, PATH, USER,
        // etc. Assigning `engine.environment` to a bare dict REPLACES the
        // parent env wholesale, which would strip out essentials. Leaving
        // `engine.environment = nil` (no extras supplied) inherits everything.
        if let extra = configuration.engineEnvironment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in extra { merged[key] = value }
            engine.environment = merged
        }
        let engineOut = Pipe()
        let engineErr = Pipe()
        engine.standardOutput = engineOut
        engine.standardError = engineErr

        let engineWaiter = ProcessExitWaiter()
        engine.terminationHandler = { proc in
            engineWaiter.complete(proc.terminationStatus)
        }
        do {
            try engine.run()
        } catch {
            capture.terminate()
            throw StartError.engineLaunchFailed("\(error)")
        }
        self.engine = engine
        self.engineExit = Task { await engineWaiter.value() }
        // Collect the engine's one-line summary; discard its stderr (the
        // decode stack can be chatty — an undrained pipe would block the engine).
        self.engineStdout = Task { await Self.readAll(engineOut.fileHandleForReading) }
        drainToVoid(engineErr.fileHandleForReading)
    }

    // MARK: - Run / stop

    /// Suspend until the engine process exits on its own.
    public func waitForEngineExit() async {
        _ = await engineExit?.value
    }

    /// Whether the engine process is still running — for a poll loop that also
    /// watches a duration deadline and a Ctrl-C latch.
    public func isEngineRunning() -> Bool {
        engine?.isRunning ?? false
    }

    /// Stop the session: SIGTERM the capture daemon (it flushes its streams
    /// and closes the sockets), let the engine finish its live pass off the
    /// closed sockets, and collect the outcome.
    ///
    /// - Parameter engineGrace: how long to wait for the engine to finish
    ///   after capture stops before it is force-terminated.
    public func stop(engineGrace: Duration = .seconds(60)) async -> Outcome {
        if let capture, capture.isRunning {
            capture.terminate()   // SIGTERM — capture stops cleanly
        }
        let captureCode = await captureExit?.value ?? -1

        // The engine ends when its sockets reach EOF. Bound the wait so a
        // wedged engine cannot hang `record` forever.
        let engineCode = await withTaskGroup(of: Int32?.self) { group -> Int32 in
            group.addTask { [engineExit] in await engineExit?.value }
            group.addTask {
                try? await Task.sleep(for: engineGrace)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            // Grace expired — force the engine down.
            if let engine = self.engine, engine.isRunning {
                engine.terminate()
            }
            return await self.engineExit?.value ?? -1
        }

        let summary = await engineStdout?.value ?? ""
        return Outcome(
            engineExitCode: engineCode,
            engineSummary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            captureExitCode: captureCode)
    }

    // MARK: - Helpers

    /// What the `ready` race resolved to.
    private enum ReadyRace: Sendable, Equatable {
        /// `ready` was read from capture's stdout.
        case ready
        /// Capture's stdout closed before `ready` — capture is exiting.
        case streamClosed
        /// The timeout elapsed.
        case timedOut
    }

    /// Read capture's stdout line-by-line until `ready`, failing fast if
    /// capture exits first or the timeout elapses.
    ///
    /// `FileHandle.AsyncBytes` iteration does not honor task cancellation, so
    /// the reader task cannot simply be cancelled out of a blocked read. The
    /// only reliable way to unblock it is to close capture's stdout — which
    /// the timeout branch does by terminating capture before the group's
    /// implicit await of its children.
    private func waitForReady(
        stdout: FileHandle,
        stderr: FileHandle,
        captureExit: Task<Int32, Never>,
        timeout: Duration
    ) async throws {
        let outcome = await withTaskGroup(of: ReadyRace.self) { group -> ReadyRace in
            group.addTask {
                do {
                    for try await line in stdout.bytes.lines {
                        if line.trimmingCharacters(in: .whitespaces) == "ready" {
                            return .ready
                        }
                    }
                } catch {}
                return .streamClosed   // stdout reached EOF without `ready`
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .streamClosed
            if first == .timedOut {
                // Unblock the reader task so the group's implicit await of it
                // can finish. `AsyncBytes` ignores cancellation, so the read
                // only ends when its file descriptor closes — terminating
                // capture eventually closes stdout, but a daemon slow to honor
                // SIGTERM would stall the timeout; closing the read end here
                // ends the iteration immediately, regardless of capture.
                capture?.terminate()
                try? stdout.close()
            }
            group.cancelAll()
            return first
        }

        switch outcome {
        case .ready:
            return
        case .streamClosed:
            // Capture's stdout closed without `ready` — it exited. Its exit
            // code and stderr say why (typically a missing TCC permission).
            let code = await captureExit.value
            let stderrText = await Self.readAll(stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StartError.captureExitedBeforeReady(code: code, stderr: stderrText)
        case .timedOut:
            throw StartError.readyTimedOut
        }
    }

    /// Read a file handle to EOF as a UTF-8 string.
    private static func readAll(_ handle: FileHandle) async -> String {
        var data = Data()
        do {
            for try await byte in handle.bytes { data.append(byte) }
        } catch {}
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Drain a handle in the background so its pipe never fills.
    private func drainToVoid(_ handle: FileHandle) {
        Task.detached {
            do {
                for try await _ in handle.bytes {}
            } catch {}
        }
    }
}

/// A one-shot, multi-reader bridge from `Process.terminationHandler` to
/// `async`. The exit code is latched on completion so a `value()` call after
/// the process has already exited still returns immediately.
private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// Called from the process's termination handler.
    func complete(_ exitCode: Int32) {
        let pending = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            guard code == nil else { return [] }
            code = exitCode
            let w = waiters
            waiters.removeAll()
            return w
        }
        for continuation in pending { continuation.resume(returning: exitCode) }
    }

    /// Await the exit code; returns immediately if the process already exited.
    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            let latched = lock.withLock { () -> Int32? in
                if let code { return code }
                waiters.append(continuation)
                return nil
            }
            if let latched { continuation.resume(returning: latched) }
        }
    }
}

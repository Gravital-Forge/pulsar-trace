import Foundation
import Logging

/// Runs offline speaker diarization by invoking the captive Python layer.
///
/// Architecture (PRD §17, `pulsartrace-execution` skill):
/// - pyannote runs in the embedded Python layer (`python/pulsartrace-ai/`),
///   never mixed into Swift. whisper.cpp stays in Swift; pyannote stays in
///   Python.
/// - For the offline epic the `Diarizer` spawns the Python diarization as a
///   **one-shot subprocess** per refine: it is handed a WAV path and gets back
///   JSON (speaker spans + per-speaker embeddings) on stdout. The long-lived
///   live `diart` runtime is a separate Epic 6 concern and is not built here.
/// - **R17**: the entry point only ever receives the *system-stream* WAV. The
///   mic stream is never diarized — "You" is always "You". This is structural:
///   `Diarizer` has a single `diarizeSystemStream(wavPath:)` method and no
///   other diarization surface.
/// - **R60**: the subprocess's stderr is captured and piped, line by line,
///   into the operational log tagged `[python]`, so one grep finds Python
///   failures alongside Swift ones.
///
/// `Diarizer` is an `actor`: a diarization run is long-lived (model load plus
/// inference) and the timeout machinery touches mutable process state, so
/// serializing access keeps two refinements from racing on one instance.
public actor Diarizer {

    /// How to reach the captive Python diarization layer.
    ///
    /// In development (DECISIONS.md D3) this points at the venv built by
    /// `python/build-venv.sh`. Epic 10 swaps these for the bundled
    /// `python-build-standalone` runtime inside the `.app`; the IPC boundary
    /// is identical, so only this configuration changes.
    public struct Configuration: Sendable {
        /// Absolute path to the Python interpreter (the venv's `python`).
        public let pythonExecutable: URL
        /// Working directory the subprocess runs in — must be the directory
        /// from which `pulsartrace_ai` is importable (the `python/pulsartrace-ai`
        /// dir, or anywhere the package is installed).
        public let workingDirectory: URL
        /// The module to run: `pulsartrace_ai.diarize`.
        public let moduleName: String
        /// Extra environment for the subprocess. The Hugging Face token
        /// (`HF_TOKEN`, required for the gated community-1 model) and
        /// `HF_HOME` (cache redirect) are passed through here. Production
        /// (Epic 10) sources the token from the macOS Keychain; development
        /// loads it from the repo `.env`.
        public let environment: [String: String]
        /// Hard wall-clock ceiling for one diarization run. The pyannote model
        /// load alone is ~10–30s and a long recording adds inference time;
        /// 600s is generous for an offline refine while still bounding a hang.
        public let timeout: Duration

        public init(
            pythonExecutable: URL,
            workingDirectory: URL,
            moduleName: String = "pulsartrace_ai.diarize",
            environment: [String: String] = [:],
            timeout: Duration = .seconds(600)
        ) {
            self.pythonExecutable = pythonExecutable
            self.workingDirectory = workingDirectory
            self.moduleName = moduleName
            self.environment = environment
            self.timeout = timeout
        }
    }

    public enum DiarizeError: Error, CustomStringConvertible, Equatable {
        case wavNotFound(String)
        case pythonNotFound(String)
        case launchFailed(String)
        case nonZeroExit(code: Int32, stderrTail: String)
        case timedOut(seconds: Int)
        case emptyOutput
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .wavNotFound(let p): return "diarization WAV not found: \(p)"
            case .pythonNotFound(let p):
                return "python interpreter not found: \(p)"
            case .launchFailed(let m):
                return "diarization subprocess failed to launch: \(m)"
            case .nonZeroExit(let code, let tail):
                return "diarization subprocess exited \(code): \(tail)"
            case .timedOut(let s):
                return "diarization subprocess timed out after \(s)s"
            case .emptyOutput:
                return "diarization subprocess produced no JSON on stdout"
            case .decodeFailed(let m):
                return "diarization output decode failed: \(m)"
            }
        }
    }

    /// How long to wait for a clean SIGTERM shutdown after a timeout before
    /// escalating to SIGKILL. Bounded so a Python process that ignores
    /// SIGTERM cannot wedge the actor's `waitUntilExit` indefinitely.
    private static let terminationGracePeriod: Duration = .seconds(10)

    private let configuration: Configuration
    private let logger: Logger
    /// Logger used only for `[python]`-tagged subprocess stderr (R60).
    private let pythonLogger: Logger

    public init(
        configuration: Configuration,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.configuration = configuration
        self.logger = logger
        self.pythonLogger = Logger(label: LogSubsystem.engine)
    }

    /// Diarize the **system-stream** WAV of a recording (R17).
    ///
    /// This is the only diarization entry point: the mic stream is never
    /// passed here. Spawns `python -m pulsartrace_ai.diarize <wav>`, enforces
    /// the configured timeout, pipes stderr into the log tagged `[python]`,
    /// and decodes the stdout JSON into a `DiarizationResult`.
    ///
    /// - Parameter wavPath: the system-stream WAV. The engine already owns
    ///   this file (it was written via `WAVWriter` / handed in by the refine
    ///   command) — this is not a new audio-API bypass, just a file path.
    public func diarizeSystemStream(wavPath: URL) async throws -> DiarizationResult {
        guard FileManager.default.fileExists(atPath: wavPath.path) else {
            throw DiarizeError.wavNotFound(wavPath.path)
        }
        guard FileManager.default.isExecutableFile(
            atPath: configuration.pythonExecutable.path) else {
            throw DiarizeError.pythonNotFound(configuration.pythonExecutable.path)
        }

        logger.notice("offline diarization: launching python diarization subprocess")
        let captured = try await runSubprocess(wavPath: wavPath)

        // Forward every stderr line into the operational log, tagged [python]
        // (R60) — a single grep finds Python errors alongside Swift ones.
        // Defensively basename any absolute-path-looking token first: the
        // operational log must never carry a full user file path (PRD §11 /
        // R59, Hard Invariant #7). diarize.py already emits basenames (P1);
        // this is a second line of defence against a stray path in a stack
        // trace or a future diagnostic.
        let stderrText = String(decoding: captured.stderr, as: UTF8.self)
        for line in stderrText.split(separator: "\n", omittingEmptySubsequences: true) {
            pythonLogger.notice("[python] \(Self.redactingPaths(in: String(line)))")
        }

        guard captured.exitCode == 0 else {
            let tail = String(stderrText.suffix(500))
            throw DiarizeError.nonZeroExit(code: captured.exitCode, stderrTail: tail)
        }
        guard !captured.stdout.isEmpty else {
            throw DiarizeError.emptyOutput
        }

        do {
            let result = try DiarizationDecoder.decode(captured.stdout)
            let speakerCount = result.speakers.count
            let spanCount = result.spans.count
            let version = result.modelVersion
            logger.notice(
                "offline diarization complete: \(speakerCount) speaker(s), \(spanCount) span(s), model \(version)")
            return result
        } catch {
            throw DiarizeError.decodeFailed(String(describing: error))
        }
    }

    // MARK: - Subprocess

    /// stdout/stderr/exit-code of one subprocess run.
    private struct Captured {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    /// Launch the Python subprocess, drain both pipes concurrently (so a large
    /// stdout cannot deadlock against a full stderr buffer), and enforce the
    /// timeout.
    private func runSubprocess(wavPath: URL) async throws -> Captured {
        let process = Process()
        process.executableURL = configuration.pythonExecutable
        process.arguments = [
            "-m", configuration.moduleName,
            wavPath.path,
            "--output", "json",
        ]
        process.currentDirectoryURL = configuration.workingDirectory

        var env = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environment {
            env[key] = value
        }
        // Defence in depth (Hard Invariant #1 / DECISIONS.md D12): pyannote
        // 4.0.4 ships default-on OpenTelemetry that phones home. diarize.py
        // already disables it before importing pyannote; we also force the
        // disable env var here so the captive subprocess can never phone home
        // regardless of how it is launched. Caller-supplied environment does
        // not get to override this.
        env["PYANNOTE_METRICS_ENABLED"] = "false"
        // Determinism (PRD §12): PYTHONHASHSEED only takes effect if set
        // *before* the interpreter starts, so it must be exported here rather
        // than from inside diarize.py. Fixed seed → reproducible diarization.
        if env["PYTHONHASHSEED"] == nil {
            env["PYTHONHASHSEED"] = "1729"
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw DiarizeError.launchFailed(String(describing: error))
        }

        // Drain both pipes on background tasks before waiting on the process:
        // `readDataToEndOfFile` blocks until EOF, which only happens once the
        // child closes the fd, so reading concurrently avoids a pipe-buffer
        // deadlock on large output.
        async let stdoutData = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.readToEnd(stderrPipe.fileHandleForReading)

        // Timeout watchdog: if the process outlives the budget, terminate it
        // so the `waitUntilExit` below returns. `firedTimeout` records whether
        // the watchdog actually killed the process — set before `terminate()`
        // so a real timeout is never confused with an ordinary failure exit.
        //
        // Escalation: `terminate()` sends only SIGTERM, which Python (or a
        // wedged native extension under it) can ignore — leaving `waitUntilExit`
        // blocked forever and the actor unable to make progress. So after a
        // grace period we escalate to SIGKILL, which the kernel always honours.
        let timeoutSeconds = Int(configuration.timeout.components.seconds)
        let firedTimeout = TimeoutFlag()
        let watchdog = Task {
            try await Task.sleep(for: configuration.timeout)
            guard process.isRunning else { return }
            await firedTimeout.set()
            process.terminate()  // SIGTERM — ask politely first.

            // Grace period for a clean SIGTERM shutdown, then SIGKILL.
            try? await Task.sleep(for: Self.terminationGracePeriod)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        await Self.waitForExit(process)
        watchdog.cancel()

        let out = await stdoutData
        let err = await stderrData

        if await firedTimeout.value {
            throw DiarizeError.timedOut(seconds: timeoutSeconds)
        }

        return Captured(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    /// One-shot flag toggled by the timeout watchdog. An `actor` so the
    /// watchdog task and the awaiting caller observe it without a data race.
    private actor TimeoutFlag {
        private(set) var value = false
        func set() { value = true }
    }

    /// Replace any absolute-path-looking token (a whitespace-delimited run
    /// starting with `/`) with just its last path component, so a full user
    /// file path can never reach the operational log (PRD §11 / R59, Hard
    /// Invariant #7). A bare `/` or a token with no `/` after the first is
    /// left untouched.
    static func redactingPaths(in line: String) -> String {
        line
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> Substring in
                guard token.hasPrefix("/"), token.count > 1 else { return token }
                // Keep trailing punctuation (e.g. a path at end of a sentence)
                // out of the basename by splitting on the last "/".
                if let lastSlash = token.lastIndex(of: "/") {
                    let base = token[token.index(after: lastSlash)...]
                    return base.isEmpty ? token : base
                }
                return token
            }
            .joined(separator: " ")
    }

    /// Read a file handle to EOF off the actor, on a detached task so the
    /// blocking read never stalls the actor's executor.
    ///
    /// Uses the Swift-throwing `FileHandle.readToEnd()` rather than the legacy
    /// `readDataToEndOfFile()`. The legacy method reports a failure (e.g. the
    /// fd was closed/invalidated because the child was SIGKILL'd, or fd churn
    /// under a heavily parallel test run) by raising an Objective-C
    /// `NSFileHandleOperationException` — which Swift cannot catch, so it
    /// reaches `std::terminate` and aborts the whole process. `readToEnd()`
    /// surfaces the same failure as a catchable Swift error; on failure the
    /// pipe simply yields no more bytes (`Data()`), which the caller already
    /// tolerates (a missing-stdout/empty-stderr child is handled downstream).
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // `try?` flattens `readToEnd()`'s `Data?` and the throw into
                // `Data??`; `?? nil ?? Data()` collapses both to `Data`.
                let data = (try? handle.readToEnd()) ?? nil ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// Await process exit without blocking the actor's executor.
    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

import Foundation
import Logging

/// Runs offline speaker diarization in-process on the ANE (D40).
///
/// Architecture:
/// - FluidAudio's offline pipeline (pyannote community-1 ported to CoreML —
///   `DiarizerEngine`) replaces the captive Python subprocess (D9, retired).
///   No venv, no HF token, no IPC: the WAV is handed to CoreML directly.
/// - **R17**: the entry point only ever receives the *system-stream* WAV. The
///   mic stream is never diarized — "You" is always "You". This is structural:
///   `Diarizer` has a single `diarizeSystemStream(wavPath:)` method and no
///   other diarization surface.
/// - **Cancellation** (queue pause, D-Q7): `cancel()` cancels the in-flight
///   `Task`; FluidAudio's pipeline checks `Task.checkCancellation()` between
///   chunks, so compute genuinely stops. The caller sees `.cancelled`, retries
///   when the pause gate reopens.
/// - **Timeout**: a watchdog cancels the work at max(configured floor, the
///   audio's real-time length) — the same budget rule the subprocess had.
///
/// An `actor`: the engine load slot, the in-flight task, and the cancel flag
/// are mutable state shared across calls.
public actor Diarizer {

    public struct Configuration: Sendable {
        /// Model cache root (D10) — models live in
        /// `<cacheRoot>/speaker-diarization/`.
        public let cacheRoot: URL
        /// Minimum wall-clock budget for one diarization run. Used as a
        /// *floor*: the actual budget is at least the input WAV's real-time
        /// duration. At 60×+ real-time on the ANE this only trips when
        /// something is genuinely wedged.
        public let timeout: Duration

        public init(
            cacheRoot: URL = AppPaths.standard.modelsCacheDirectory,
            timeout: Duration = .seconds(600)
        ) {
            self.cacheRoot = cacheRoot
            self.timeout = timeout
        }
    }

    public enum DiarizeError: Error, CustomStringConvertible, Equatable {
        case wavNotFound(String)
        case modelLoadFailed(String)
        case processingFailed(String)
        case timedOut(seconds: Int)
        /// The run was terminated by a `cancel()` call (queue pause). Distinct
        /// from `.processingFailed` so the refiner can distinguish a pause
        /// from a real failure and retry when the gate reopens.
        case cancelled

        public var description: String {
            switch self {
            case .wavNotFound(let p): return "diarization WAV not found: \(p)"
            case .modelLoadFailed(let m):
                return "diarization model load failed: \(m)"
            case .processingFailed(let m): return "diarization failed: \(m)"
            case .timedOut(let s): return "diarization timed out after \(s)s"
            case .cancelled: return "diarization cancelled (paused by queue)"
            }
        }
    }

    /// Test seam: replaces the engine-backed diarize call so cancellation and
    /// timeout semantics are testable without CoreML models.
    typealias Operation = @Sendable (URL) async throws -> DiarizationResult

    private let configuration: Configuration
    private let events: EventWriter?
    private let logger: Logger
    private let operationOverride: Operation?
    /// Memoized engine load — cleared on failure so a retry can reload
    /// (same pattern as `FluidVADRegionDetector.ensureManager`).
    private var engineTask: Task<DiarizerEngine, Error>?
    private var inflight: Task<DiarizationResult, Error>?
    private var cancelledFlag = false
    private var timedOutFlag = false

    public init(
        configuration: Configuration,
        events: EventWriter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.configuration = configuration
        self.events = events
        self.logger = logger
        self.operationOverride = nil
    }

    /// Test-seam initializer.
    init(
        configuration: Configuration,
        events: EventWriter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine),
        operation: @escaping Operation
    ) {
        self.configuration = configuration
        self.events = events
        self.logger = logger
        self.operationOverride = operation
    }

    /// Cancel the in-flight diarization. A no-op when nothing is running.
    /// The run currently in flight throws `DiarizeError.cancelled`.
    public func cancel() {
        cancelledFlag = true
        inflight?.cancel()
    }

    /// Diarize the **system-stream** WAV of a recording (R17).
    public func diarizeSystemStream(wavPath: URL) async throws -> DiarizationResult {
        guard FileManager.default.fileExists(atPath: wavPath.path) else {
            throw DiarizeError.wavNotFound(wavPath.path)
        }
        cancelledFlag = false
        timedOutFlag = false

        let timeout = effectiveTimeout(for: wavPath)
        let timeoutSeconds = Int(timeout.components.seconds)
        logger.notice(
            "offline diarization: FluidAudio community-1 on ANE (budget \(timeoutSeconds)s)")

        let operation = try await resolveOperation()
        let work = Task { try await operation(wavPath) }
        inflight = work
        defer { inflight = nil }

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            await self.noteTimeout()
        }
        defer { watchdog.cancel() }

        do {
            let result = try await work.value
            let speakerCount = result.speakers.count
            let spanCount = result.spans.count
            logger.notice(
                "offline diarization complete: \(speakerCount) speaker(s), \(spanCount) span(s)")
            return result
        } catch is CancellationError {
            if cancelledFlag { throw DiarizeError.cancelled }
            if timedOutFlag { throw DiarizeError.timedOut(seconds: timeoutSeconds) }
            throw DiarizeError.cancelled
        } catch let e as DiarizeError {
            throw e
        } catch {
            if cancelledFlag { throw DiarizeError.cancelled }
            if timedOutFlag { throw DiarizeError.timedOut(seconds: timeoutSeconds) }
            throw DiarizeError.processingFailed(String(describing: error))
        }
    }

    /// The engine-backed operation, or the test seam.
    private func resolveOperation() async throws -> Operation {
        if let operationOverride { return operationOverride }
        let engine = try await ensureEngine()
        return { wavPath in try await engine.diarize(wavPath: wavPath) }
    }

    private func ensureEngine() async throws -> DiarizerEngine {
        if let engineTask {
            do { return try await engineTask.value }
            catch {
                if self.engineTask == engineTask { self.engineTask = nil }
                throw DiarizeError.modelLoadFailed(String(describing: error))
            }
        }
        let configuration = self.configuration
        let events = self.events
        let logger = self.logger
        let task = Task {
            try await DiarizerEngine.load(
                cacheRoot: configuration.cacheRoot, events: events, logger: logger)
        }
        engineTask = task
        do { return try await task.value }
        catch {
            if self.engineTask == task { self.engineTask = nil }
            throw DiarizeError.modelLoadFailed(String(describing: error))
        }
    }

    private func noteTimeout() {
        timedOutFlag = true
        inflight?.cancel()
    }

    /// Expand `configuration.timeout` to at least the audio's real-time
    /// length, so an 80-minute meeting is not killed by a 10-minute ceiling.
    private func effectiveTimeout(for wavPath: URL) -> Duration {
        let configured = configuration.timeout
        guard let audioSeconds = WAVReader.probeDurationSeconds(at: wavPath),
              audioSeconds.isFinite, audioSeconds > 0 else {
            return configured
        }
        let configuredSeconds = Double(configured.components.seconds)
        guard audioSeconds > configuredSeconds else { return configured }
        return .seconds(Int(audioSeconds.rounded(.up)))
    }
}

// MARK: - RefinementCancellable

extension Diarizer: RefinementCancellable {}
// `cancel()` is sync on `Diarizer`; async protocol methods accept sync
// implementations, so no wrapper is needed.

// MARK: - Transitional

extension Diarizer {
    /// Transitional — only `LiveDiarizer` (rewritten in the next task) still
    /// calls this. Deleted with it.
    ///
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
}

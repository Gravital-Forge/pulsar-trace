import Foundation
@testable import PulsarTraceEngine

/// A process-wide serialization gate for tests that construct a
/// `WhisperTranscriber`.
///
/// `@Suite(.serialized)` only serializes tests *within* one suite — Swift
/// Testing still runs separate suites in parallel. whisper.cpp's Metal backend
/// keeps a per-device residency set that corrupts if two `whisper_context`s are
/// alive at once in one process (see `WhisperTranscriber` / DECISIONS.md D8):
/// it manifests as a low-confidence language detection and garbled segments.
///
/// `TranscriptionPipelineTests` and `RefinementPipelineTests` both load whisper,
/// so without a cross-suite gate they can race. Every whisper-using test body
/// runs inside `WhisperTestGate.run { … }`, which serializes them across the
/// whole process — mirroring the engine's real "one transcriber at a time"
/// usage and keeping the deterministic snapshots stable (PRD §12).
actor WhisperTestGate {
    static let shared = WhisperTestGate()

    /// Run `body` with exclusive process-wide access to whisper.
    ///
    /// `body` and its result are `sending` so a non-`Sendable` test value
    /// (e.g. a pipeline `Output`) can cross the actor boundary safely — the
    /// caller hands off sole ownership for the duration of the call.
    static func run<T>(_ body: sending () async throws -> sending T) async rethrows -> sending T {
        try await shared.locked(body)
    }

    private func locked<T>(_ body: sending () async throws -> sending T) async rethrows -> sending T {
        // Actor isolation already serializes calls to this method, so the body
        // runs one at a time across every suite.
        try await body()
    }

    /// In-flight (or finished) model-resolution task per model name.
    private var modelTasks: [String: Task<URL, Error>] = [:]

    /// Resolve a verified whisper model URL, fetching it at most once across
    /// every test suite.
    ///
    /// `ModelStore` is an actor, but each call site builds its *own*
    /// `ModelStore()` instance — two separate instances do not serialize, so
    /// two suites resolving the same model in parallel race on the shared
    /// `~/Library/Caches/PulsarTrace/models/` cache files (one truncates and
    /// rewrites `ggml-base.bin` while the other reads it → whisper "bad magic"
    /// or a garbled transcript).
    ///
    /// Memoizing the *`Task`* (not the finished URL) is what makes this
    /// race-free: a `URL`-only cache would still let a second caller slip in
    /// while the first is `await`-suspended inside `ensureAvailable` (actor
    /// reentrancy) and start a second download. With a task cache the second
    /// caller finds the in-flight task and `await`s its single result.
    static func model(_ model: WhisperModel) async throws -> URL {
        try await shared.resolveModel(model)
    }

    private func resolveModel(_ model: WhisperModel) async throws -> URL {
        if let existing = modelTasks[model.name] {
            return try await existing.value
        }
        let task = Task { try await ModelStore().ensureAvailable(model) }
        modelTasks[model.name] = task
        return try await task.value
    }
}

/// Test-only `WhisperTranscriber` construction.
///
/// Every transcriber the test suite loads uses whisper's **CPU backend**
/// (`useGPU: false`). The Metal backend's `ggml_metal_device_free` asserts at
/// process exit (`GGML_ASSERT([rsets->data count] == 0)`, signal 6) on this M1
/// host once several `whisper_context`s have been created/freed in one
/// process — an upstream whisper.cpp/ggml-metal residency-set bug. A test
/// suite that crashes on exit is unacceptable (PRD §12). The CPU backend never
/// touches the ggml-metal device, so it cannot trip that assertion; `base`
/// over the short fixtures is plenty fast on CPU. Production keeps Metal
/// (`useGPU` defaults to `true`). See DECISIONS.md D15.
enum WhisperTestTranscriber {
    /// Build a CPU-backend `WhisperTranscriber` for the test/CI path.
    static func make(modelURL: URL) throws -> WhisperTranscriber {
        try WhisperTranscriber(modelURL: modelURL, useGPU: false)
    }
}

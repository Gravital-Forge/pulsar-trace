// Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift
import Foundation

/// Holds at most one `T` for the lifetime of the box; `get()` builds the
/// instance lazily on the first call and returns the same instance for every
/// later call.
///
/// Used by `RefinementJobQueue.makeStandard` to reuse one `WhisperTranscriber`
/// across every VAD region of a refinement job (D36, reopened) — building a
/// fresh `WhisperTranscriber` per region was the dominant cost of a
/// refinement pass on Apple Silicon because `whisper_init_from_file_with_params`
/// rebuilds the Metal pipeline state on every call.
///
/// Generic over `T` rather than hard-coded to `WhisperTranscriber` so the
/// type can be tested without an on-disk model file.
public final class SharedTranscriberBox<T>: @unchecked Sendable {

    private let factory: () throws -> T
    private let lock = NSLock()
    private var cached: T?

    public init(_ factory: @escaping () throws -> T) {
        self.factory = factory
    }

    /// Return the cached instance, building it on the first call. A factory
    /// throw on the first call is propagated and leaves the cache empty, so a
    /// retry on the next `get()` re-runs the factory.
    public func get() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = try factory()
        cached = made
        return made
    }

    /// Drop the cached instance. ARC plus the type's `deinit` do the
    /// cleanup — e.g. `RemoteRegionTranscriber.deinit` calls `shutdown()`,
    /// which terminates the `pulsartrace-whisper` subprocess and releases
    /// the binary-level `whisper.lock`. A subsequent `get()` rebuilds the
    /// instance via the factory.
    ///
    /// Used by `RefinementJobQueue.pauseForRecording` (Phase 6) to make
    /// the refinement-whisper subprocess release the lock *before* the
    /// engine's whisper subprocess tries to acquire it. Without this hook
    /// the in-flight region decode would complete normally, the engine
    /// subprocess would race the `flock`, and recording-start would fail
    /// with the silent `exit 75` (`EX_TEMPFAIL`) mode (spec §4 Layer 2).
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}

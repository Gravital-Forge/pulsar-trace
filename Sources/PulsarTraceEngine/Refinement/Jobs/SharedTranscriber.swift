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
}

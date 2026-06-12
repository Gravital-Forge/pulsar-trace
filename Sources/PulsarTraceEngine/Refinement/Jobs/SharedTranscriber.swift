// Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift
import Foundation

/// Holds at most one `T` for the lifetime of the box; `get()` builds the
/// instance lazily on the first call and returns the same instance for every
/// later call.
///
/// Used by `RefinementJobQueue.makeStandard` to reuse one
/// `WhisperKitRegionTranscriber` across every VAD region of a refinement job:
/// the CoreML models load once on the first region decode and stay resident
/// for the rest of the job rather than reloading per region.
///
/// Generic over `T` rather than hard-coded to a concrete transcriber so the
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

    /// Drop the cached instance. ARC frees it — e.g. dropping a
    /// `WhisperKitRegionTranscriber` actor releases its resident CoreML
    /// models. A subsequent `get()` rebuilds the instance via the factory.
    ///
    /// Used by `RefinementJobQueue.pauseForRecording` to free the resident
    /// WhisperKit models *before* the live pass loads its own model, so the
    /// two passes don't contend for ANE/memory at recording start.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}

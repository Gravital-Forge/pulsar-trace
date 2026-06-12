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
/// **Release is terminal.** `release()` drops the cached instance *and* poisons
/// the box: any later `get()` throws `CancellationError` instead of rebuilding.
/// The box is scoped to a single job — `makeStandard`'s `runJob` builds a fresh
/// box per invocation — and the only thing that releases is `pauseForRecording`,
/// which fires precisely when the in-flight decode is being cancelled and the
/// worker is about to exit. A rebuild after release would be a paused job
/// silently reloading the model mid-recording (reviewer finding I2), contending
/// for the ANE/memory the live pass just claimed; throwing instead lets that
/// `get()` join the same unwind the decode-cancel started.
///
/// Generic over `T` rather than hard-coded to a concrete transcriber so the
/// type can be tested without an on-disk model file.
public final class SharedTranscriberBox<T>: @unchecked Sendable {

    private let factory: () throws -> T
    private let lock = NSLock()
    private var cached: T?
    private var released = false

    public init(_ factory: @escaping () throws -> T) {
        self.factory = factory
    }

    /// Return the cached instance, building it on the first call. A factory
    /// throw on the first call is propagated and leaves the cache empty, so a
    /// retry on the next `get()` re-runs the factory.
    ///
    /// After `release()`, this throws `CancellationError` and never rebuilds —
    /// see the type doc for why a post-release rebuild is always a bug.
    public func get() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if released { throw CancellationError() }
        if let cached { return cached }
        let made = try factory()
        cached = made
        return made
    }

    /// Return the cached instance *without building it* — `nil` if nothing has
    /// been built yet (or after `release()`). Lets the release hook reach the
    /// live transcriber to call `cancelPending()` on it before dropping the
    /// reference, without forcing a model load on a box that never decoded.
    public func peek() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Drop the cached instance and mark the box terminal. ARC frees the
    /// instance — e.g. dropping a `WhisperKitRegionTranscriber` actor releases
    /// its resident CoreML models. Unlike a plain reset, a subsequent `get()`
    /// does **not** rebuild: it throws `CancellationError` (see the type doc).
    ///
    /// Used by `RefinementJobQueue.pauseForRecording` to free the resident
    /// WhisperKit models *before* the live pass loads its own model, so the
    /// two passes don't contend for ANE/memory at recording start.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        released = true
    }
}

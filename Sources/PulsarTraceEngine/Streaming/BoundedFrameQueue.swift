import Foundation

/// A bounded hand-off buffer from the recording-safe drain (producer) to the
/// whisper worker (consumer), one instance per stream.
///
/// `enqueue` never blocks the producer: when the buffer is full it drops the
/// **oldest** frame so the live transcript tracks *now* rather than replaying
/// stale audio (the dropped span is recovered by the offline post-pass). The
/// consumer `await`s `dequeue`, which suspends while empty and returns `nil`
/// once `finish()` has been called and the buffer is drained.
///
/// Lock-protected (not an actor) so `enqueue` is synchronous and can be called
/// from the drain's per-frame hot path without suspension. A single waiting
/// consumer is supported (the design uses one worker).
public final class BoundedFrameQueue: @unchecked Sendable {

    private let lock = NSLock()
    private var buffer: [AudioFrame] = []
    private let capacityFrames: Int
    private var finished = false
    private var waiter: CheckedContinuation<AudioFrame?, Never>?

    private var _droppedFrameCount = 0
    private var dropping = false           // currently in a drop episode
    private var dropEpisodeStartedEdge = false
    private var caughtUpEdge = false

    public init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        self.capacityFrames = capacityFrames
    }

    /// Total frames dropped over the queue's lifetime.
    public var droppedFrameCount: Int { lock.withLock { _droppedFrameCount } }

    /// Non-blocking. Hands the frame to a waiting consumer if one is parked,
    /// else buffers it, dropping the oldest frame when at capacity.
    public func enqueue(_ frame: AudioFrame) {
        var toResume: CheckedContinuation<AudioFrame?, Never>?
        var handoff: AudioFrame?
        lock.withLock {
            if let w = waiter {
                waiter = nil
                toResume = w
                handoff = frame           // hand straight to the parked consumer
                return
            }
            if buffer.count >= capacityFrames {
                buffer.removeFirst()
                _droppedFrameCount += 1
                if !dropping { dropping = true; dropEpisodeStartedEdge = true }
            }
            buffer.append(frame)
        }
        toResume?.resume(returning: handoff)
    }

    /// Suspends until a frame is available or the queue is finished+empty.
    public func dequeue() async -> AudioFrame? {
        await withCheckedContinuation { (cont: CheckedContinuation<AudioFrame?, Never>) in
            var immediate: AudioFrame??
            lock.withLock {
                if !buffer.isEmpty {
                    let f = buffer.removeFirst()
                    if buffer.isEmpty && dropping { dropping = false; caughtUpEdge = true }
                    immediate = .some(f)       // resume now with a frame
                    return
                }
                if finished {
                    immediate = .some(nil)     // resume now with nil
                    return
                }
                waiter = cont                  // park
            }
            if let immediate { cont.resume(returning: immediate) }
        }
    }

    /// Mark end-of-stream. A parked consumer is resumed with `nil` (the buffer is
    /// empty whenever a consumer is parked); otherwise the next `dequeue` drains
    /// the remainder and then returns `nil`.
    public func finish() {
        var toResume: CheckedContinuation<AudioFrame?, Never>?
        lock.withLock {
            finished = true
            if buffer.isEmpty, let w = waiter { waiter = nil; toResume = w }
        }
        toResume?.resume(returning: nil)
    }

    /// One-shot read of "a drop episode just began" (true at most once until a
    /// matching `consumeCaughtUp`). Lets the worker emit the live.md note once.
    public func consumeDropEpisodeStarted() -> Bool {
        lock.withLock {
            defer { dropEpisodeStartedEdge = false }
            return dropEpisodeStartedEdge
        }
    }

    /// One-shot read of "the buffer drained back to empty after dropping".
    public func consumeCaughtUp() -> Bool {
        lock.withLock {
            defer { caughtUpEdge = false }
            return caughtUpEdge
        }
    }
}

import Foundation

/// A one-way cancellation flag handed to a whisper decode so a watchdog on
/// another task can interrupt it. Lock-protected (not an actor) so the
/// decode's `abort_callback` can read it synchronously from whisper's compute
/// thread without suspending. Once cancelled it stays cancelled.
public final class AbortToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { _cancelled } }

    public func cancel() { lock.withLock { _cancelled = true } }
}

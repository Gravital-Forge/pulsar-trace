import Foundation

/// A non-reentrant async serial lock: only one `run` body executes at a time,
/// even across `await` suspensions inside the body (unlike a plain actor, which
/// is reentrant). FIFO fairness via a `CheckedContinuation` waiter queue.
/// Used to serialize the speaker-edit mutate→rewrite→emit sequence process-wide
/// so concurrent edits cannot interleave and lose a `final.md` rewrite (PT-P6-D1).
public actor AsyncSerialLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Run `body` with exclusive access; other `run` calls wait their turn.
    public func run<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

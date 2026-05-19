// Sources/PulsarTraceEngine/Refinement/Jobs/PauseGate.swift
import Foundation

/// A one-flag pause/resume primitive. `waitOpen()` returns immediately when
/// the gate is open; when closed it suspends every caller until `open()`.
///
/// Used by `ResumableRefiner`: every checkpoint (between VAD regions and
/// between stages) awaits the gate before continuing, so the queue can stall
/// a refine mid-pipeline by calling `close()` and resume it with `open()`.
public actor PauseGate {

    private var isGateOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(initiallyOpen: Bool = true) {
        self.isGateOpen = initiallyOpen
    }

    /// Suspend until the gate is open. Returns immediately when already open.
    public func waitOpen() async {
        if isGateOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Open the gate and release every suspended waiter.
    public func open() {
        guard !isGateOpen else { return }
        isGateOpen = true
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }

    /// Close the gate. New `waitOpen()` calls will suspend; already-resumed
    /// continuations are not affected.
    public func close() {
        isGateOpen = false
    }

    /// Read-only snapshot. Used by tests and by status reporting.
    public var isOpen: Bool { isGateOpen }
}

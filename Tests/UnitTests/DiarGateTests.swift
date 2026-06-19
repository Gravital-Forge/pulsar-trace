import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `DiarGate` — the single-window-in-flight bound that keeps
/// a slow/wedged live diarizer off the run loop's critical path (Fix B), plus
/// the wedge-reclaim that stops one hung window from freezing diarization for
/// the rest of the recording (D42).
@Suite("DiarGate (live-diarizer decoupling bound)")
struct DiarGateTests {

    @Test("a second acquire is refused while a window is in flight")
    func secondAcquireRefused() async {
        // Long reclaim so this test exercises only the in-flight bound, not the
        // wedge reclaim.
        let gate = DiarGate(reclaimAfter: .seconds(60))
        let a = await gate.tryAcquire()
        #expect(a == .granted(1))
        // A window is now in flight — the next window must be skipped.
        #expect(await gate.tryAcquire() == .busy)
        #expect(await gate.tryAcquire() == .busy)
        // Once released, the slot is free again (next holder gets a new token).
        await gate.release(a.token!)
        #expect(await gate.tryAcquire() == .granted(2))
    }

    @Test("a wedged slot is force-reclaimed once held past the deadline")
    func reclaimsWedgedSlot() async {
        let gate = DiarGate(reclaimAfter: .milliseconds(100))
        let a = await gate.tryAcquire()
        #expect(a == .granted(1))
        // Before the deadline the slot is still busy — no premature reclaim.
        #expect(await gate.tryAcquire() == .busy)

        try? await Task.sleep(for: .milliseconds(150))

        // Past the deadline the wedged slot is force-reclaimed for a new window.
        let b = await gate.tryAcquire()
        #expect(b == .reclaimed(2))
    }

    @Test("a reclaimed window's stale release cannot free the new holder's slot")
    func staleReleaseIsIgnoredAfterReclaim() async {
        let gate = DiarGate(reclaimAfter: .milliseconds(100))
        let a = await gate.tryAcquire()            // window 1
        #expect(a == .granted(1))
        try? await Task.sleep(for: .milliseconds(150))
        let b = await gate.tryAcquire()            // window 2 reclaims the slot
        #expect(b == .reclaimed(2))

        // The abandoned window 1 finally returns and releases — with its stale
        // token. It must NOT free the slot window 2 now holds.
        await gate.release(a.token!)
        #expect(await gate.tryAcquire() == .busy)

        // Window 2's own release frees it normally.
        await gate.release(b.token!)
        #expect(await gate.tryAcquire() == .granted(3))
    }

    @Test("drain returns promptly once the in-flight window is released")
    func drainReturnsAfterRelease() async {
        let gate = DiarGate(reclaimAfter: .seconds(60))
        let a = await gate.tryAcquire()
        #expect(a.token != nil)

        // Release shortly after starting the drain — drain must then return.
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            await gate.release(a.token!)
        }
        let start = ContinuousClock.now
        await gate.drain(timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start
        // Returned because the slot was released, well before the 5 s timeout.
        #expect(elapsed < .seconds(2))
    }

    @Test("drain is bounded by its timeout when the window never releases")
    func drainIsBoundedByTimeout() async {
        let gate = DiarGate(reclaimAfter: .seconds(60))
        _ = await gate.tryAcquire()
        // The window is never released — simulating a wedged diarizer. drain
        // must still return, bounded by the timeout, so the run can finish.
        let start = ContinuousClock.now
        await gate.drain(timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
    }

    @Test("drain exits promptly on task cancellation instead of spinning to the deadline")
    func drainIsCancellationAware() async {
        let gate = DiarGate(reclaimAfter: .seconds(60))
        _ = await gate.tryAcquire()

        // A long timeout the window never releases — without cancellation
        // awareness drain would spin the full 10 s. Run it in a task and
        // cancel that task shortly after; drain must then return well before
        // the deadline.
        let start = ContinuousClock.now
        let drainTask = Task {
            await gate.drain(timeout: .seconds(10))
        }
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            drainTask.cancel()
        }
        await drainTask.value
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(2))
    }
}

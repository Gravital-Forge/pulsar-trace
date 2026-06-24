import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `DiarGate` — the single-window-in-flight bound that keeps
/// a slow/wedged live diarizer off the run loop's critical path (Fix B): at
/// most one diarization window runs at a time and a window that cannot acquire
/// the slot is skipped.
@Suite("DiarGate (live-diarizer decoupling bound)")
struct DiarGateTests {

    @Test("a second acquire is refused while a window is in flight")
    func secondAcquireRefused() async {
        let gate = DiarGate()
        #expect(await gate.tryAcquire() == true)
        // A window is now in flight — the next windows must be skipped.
        #expect(await gate.tryAcquire() == false)
        #expect(await gate.tryAcquire() == false)
        // Once released, the slot is free again.
        await gate.release()
        #expect(await gate.tryAcquire() == true)
    }

    @Test("drain returns promptly once the in-flight window is released")
    func drainReturnsAfterRelease() async {
        let gate = DiarGate()
        _ = await gate.tryAcquire()

        // Release shortly after starting the drain — drain must then return.
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            await gate.release()
        }
        let start = ContinuousClock.now
        await gate.drain(timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start
        // Returned because the slot was released, well before the 5 s timeout.
        #expect(elapsed < .seconds(2))
    }

    @Test("drain is bounded by its timeout when the window never releases")
    func drainIsBoundedByTimeout() async {
        let gate = DiarGate()
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
        let gate = DiarGate()
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

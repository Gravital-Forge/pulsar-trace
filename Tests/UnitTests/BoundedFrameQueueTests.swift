import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("BoundedFrameQueue")
struct BoundedFrameQueueTests {

    private func frame(_ i: Int) -> AudioFrame { .silence(sequenceIndex: i) }

    @Test("FIFO delivery in order while under capacity")
    func fifoUnderCapacity() async {
        let q = BoundedFrameQueue(capacityFrames: 8)
        q.enqueue(frame(0)); q.enqueue(frame(1)); q.enqueue(frame(2))
        q.finish()
        var got: [Int] = []
        while let f = await q.dequeue() { got.append(f.sequenceIndex) }
        #expect(got == [0, 1, 2])
    }

    @Test("drops the oldest when full, keeping the newest, and counts the drop")
    func dropOldestWhenFull() async {
        let q = BoundedFrameQueue(capacityFrames: 2)
        q.enqueue(frame(0))   // [0]
        q.enqueue(frame(1))   // [0,1]
        q.enqueue(frame(2))   // full → drop 0 → [1,2]
        q.enqueue(frame(3))   // full → drop 1 → [2,3]
        q.finish()
        var got: [Int] = []
        while let f = await q.dequeue() { got.append(f.sequenceIndex) }
        #expect(got == [2, 3])
        #expect(q.droppedFrameCount == 2)
    }

    @Test("dequeue suspends until a frame arrives, then resumes")
    func dequeueSuspendsThenResumes() async {
        let q = BoundedFrameQueue(capacityFrames: 4)
        let consumer = Task { () -> Int? in
            await q.dequeue()?.sequenceIndex
        }
        try? await Task.sleep(for: .milliseconds(50))
        q.enqueue(frame(42))
        #expect(await consumer.value == 42)
    }

    @Test("finish unblocks a waiting consumer with nil")
    func finishUnblocksConsumer() async {
        let q = BoundedFrameQueue(capacityFrames: 4)
        let consumer = Task { await q.dequeue()?.sequenceIndex }
        try? await Task.sleep(for: .milliseconds(50))
        q.finish()
        #expect(await consumer.value == nil)
    }

    @Test("the dropped->recovered edge fires once per episode")
    func droppedEdgeFiresOncePerEpisode() async {
        let q = BoundedFrameQueue(capacityFrames: 1)
        q.enqueue(frame(0)); q.enqueue(frame(1))   // drops 0
        #expect(q.consumeDropEpisodeStarted() == true)   // edge: dropping began
        #expect(q.consumeDropEpisodeStarted() == false)  // not re-reported
        _ = await q.dequeue()                            // drain to empty -> caught up
        #expect(q.consumeCaughtUp() == true)
        #expect(q.consumeCaughtUp() == false)
    }
}

import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("AsyncSerialLock")
struct AsyncSerialLockTests {
    @Test("run executes bodies one at a time (no interleaving)")
    func serializes() async {
        let lock = AsyncSerialLock()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await lock.run {
                        await counter.enterCheckExit()
                    }
                }
            }
        }
        #expect(await counter.maxConcurrent == 1)
        #expect(await counter.entries == 50)
    }

    actor Counter {
        private(set) var current = 0
        private(set) var maxConcurrent = 0
        private(set) var entries = 0
        func enterCheckExit() async {
            current += 1; entries += 1
            maxConcurrent = max(maxConcurrent, current)
            // yield to give any (incorrectly) concurrent body a chance to overlap
            await Task.yield()
            current -= 1
        }
    }
}

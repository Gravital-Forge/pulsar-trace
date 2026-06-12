// Tests/UnitTests/SharedTranscriberTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("SharedTranscriber")
struct SharedTranscriberTests {

    /// A bare object with reference identity so the test can check that two
    /// `.get()` calls return the same instance without depending on a real
    /// `WhisperTranscriber` (which needs an on-disk model).
    private final class Sentinel: @unchecked Sendable {
        let id = UUID()
    }

    @Test("first get() invokes the factory; later get()s do not")
    func factoryRunsOnce() throws {
        let counter = Counter()
        let shared = SharedTranscriberBox<Sentinel> {
            counter.bump()
            return Sentinel()
        }
        let a = try shared.get()
        let b = try shared.get()
        let c = try shared.get()
        #expect(a.id == b.id)
        #expect(b.id == c.id)
        #expect(counter.value == 1, "factory must run exactly once")
    }

    @Test("a thrown factory error propagates and is retried on the next get()")
    func factoryRetriesAfterThrow() throws {
        struct Boom: Error {}
        let counter = Counter()
        let shared = SharedTranscriberBox<Sentinel> {
            counter.bump()
            if counter.value == 1 { throw Boom() }
            return Sentinel()
        }
        #expect(throws: Boom.self) { _ = try shared.get() }
        let ok = try shared.get()
        _ = ok
        #expect(counter.value == 2, "first get threw, second get re-ran the factory")
    }

    @Test("release is terminal: get() throws CancellationError and does not rebuild")
    func releaseIsTerminal() throws {
        let counter = Counter()
        let shared = SharedTranscriberBox<Sentinel> {
            counter.bump()
            return Sentinel()
        }
        _ = try shared.get()
        #expect(counter.value == 1)

        shared.release()

        // A post-release get() must throw rather than rebuild — a paused job
        // silently reloading the model mid-recording is the bug this prevents.
        #expect(throws: CancellationError.self) { _ = try shared.get() }
        #expect(counter.value == 1, "release must NOT re-run the factory")
    }

    @Test("peek() returns the built instance without building; nil before build / after release")
    func peekDoesNotBuild() throws {
        let counter = Counter()
        let shared = SharedTranscriberBox<Sentinel> {
            counter.bump()
            return Sentinel()
        }

        // Before any get(): peek() must not trigger the factory.
        #expect(shared.peek() == nil)
        #expect(counter.value == 0, "peek must not build")

        let built = try shared.get()
        let peeked = shared.peek()
        #expect(peeked?.id == built.id, "peek returns the same instance get built")
        #expect(counter.value == 1, "peek after get must not re-run the factory")

        // After release(): peek() returns nil (the box is drained + terminal).
        shared.release()
        #expect(shared.peek() == nil)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}

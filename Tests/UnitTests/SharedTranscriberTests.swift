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

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}

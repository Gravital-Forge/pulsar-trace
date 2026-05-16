import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of ULID generation (event-ID infrastructure, R80).
@Suite("ULID")
struct ULIDTests {

    @Test("ULID renders as 26 Crockford-base32 characters")
    func ulidLength() {
        var rng = SeededRandomNumberGenerator(seed: 1)
        let ulid = ULID(timestamp: Date(timeIntervalSince1970: 0), using: &rng)
        #expect(ulid.value.count == 26)
    }

    @Test("ULID alphabet excludes I, L, O, U")
    func ulidAlphabet() {
        var rng = SeededRandomNumberGenerator(seed: 99)
        let ulid = ULID(timestamp: Date(), using: &rng)
        let forbidden = Set("ILOU")
        #expect(ulid.value.allSatisfy { !forbidden.contains($0) })
    }

    @Test("Same seed and timestamp produce the same ULID (determinism)")
    func ulidDeterministic() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        var a = SeededRandomNumberGenerator(seed: 42)
        var b = SeededRandomNumberGenerator(seed: 42)
        #expect(ULID(timestamp: ts, using: &a) == ULID(timestamp: ts, using: &b))
    }

    @Test("Later timestamps sort lexicographically after earlier ones")
    func ulidSortable() {
        var rng = SeededRandomNumberGenerator(seed: 7)
        let early = ULID(timestamp: Date(timeIntervalSince1970: 1_000_000), using: &rng)
        let late = ULID(timestamp: Date(timeIntervalSince1970: 2_000_000), using: &rng)
        #expect(early.value < late.value)
    }

    @Test("Different seeds produce different randomness")
    func ulidDistinct() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        var a = SeededRandomNumberGenerator(seed: 1)
        var b = SeededRandomNumberGenerator(seed: 2)
        #expect(ULID(timestamp: ts, using: &a) != ULID(timestamp: ts, using: &b))
    }
}

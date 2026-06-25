import Foundation

/// A Universally Unique Lexicographically Sortable Identifier.
///
/// 128 bits = 48-bit millisecond timestamp + 80 bits of randomness, rendered
/// as 26 Crockford-base32 characters. Lexicographic string order matches
/// creation order, which is why event IDs use it (§8.13, PT-R80).
///
/// Used for event IDs (`evt_<ulid>`) and speaker IDs (`spk_<ulid>`).
public struct ULID: Hashable, Sendable, CustomStringConvertible {
    /// Crockford base32 alphabet (no I, L, O, U).
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The 26-character canonical string.
    public let value: String

    public var description: String { value }

    /// Create a ULID from its canonical 26-character string. Does not validate.
    public init(value: String) {
        self.value = value
    }

    /// Generate a new ULID for the given timestamp using the provided RNG.
    ///
    /// The RNG is injectable so tests can seed it for determinism.
    public init(timestamp: Date = Date(), using rng: inout some RandomNumberGenerator) {
        let millis = UInt64((timestamp.timeIntervalSince1970 * 1000).rounded(.down))
        var bytes = [UInt8](repeating: 0, count: 16)
        // 48-bit timestamp, big-endian, in the first 6 bytes.
        for i in 0..<6 {
            bytes[i] = UInt8((millis >> (8 * (5 - i))) & 0xFF)
        }
        // 80 bits of randomness in the remaining 10 bytes.
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        self.value = Self.encode(bytes)
    }

    /// Generate a ULID using the system RNG.
    public static func generate(timestamp: Date = Date()) -> ULID {
        var rng = SystemRandomNumberGenerator()
        return ULID(timestamp: timestamp, using: &rng)
    }

    /// Encode 16 bytes as 26 Crockford-base32 characters (130 bits, top 2 zero).
    private static func encode(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        // Treat the 128 bits as a big integer and emit 26 5-bit groups.
        var bits = 0
        var accumulator: UInt32 = 0
        var output = [Character]()
        output.reserveCapacity(26)
        // Prepend 2 zero bits so 130 bits divide into 26 groups of 5.
        accumulator = 0
        bits = 2
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((accumulator >> UInt32(bits)) & 0x1F)
                output.append(alphabet[index])
            }
        }
        return String(output)
    }
}

/// A small, deterministic, seedable PRNG (SplitMix64) for test determinism.
///
/// The determinism rule requires all RNG to be seeded in tests. This is
/// the seam: tests pass a `SeededRandomNumberGenerator(seed:)` wherever a
/// `RandomNumberGenerator` is accepted.
public struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A thread-safe, deterministic ULID factory for tests.
///
/// `EventWriter.ulidFactory` is a `@Sendable` closure; a bare seeded RNG cannot
/// be captured by one because it is a mutating value type. This wrapper guards
/// a seeded RNG behind a lock so a deterministic factory closure is `Sendable`.
public final class DeterministicULIDFactory: @unchecked Sendable {
    private var rng: SeededRandomNumberGenerator
    private let lock = NSLock()

    public init(seed: UInt64) {
        self.rng = SeededRandomNumberGenerator(seed: seed)
    }

    /// Generate the next ULID for `timestamp`. Thread-safe.
    public func make(_ timestamp: Date) -> ULID {
        lock.lock()
        defer { lock.unlock() }
        return ULID(timestamp: timestamp, using: &rng)
    }
}

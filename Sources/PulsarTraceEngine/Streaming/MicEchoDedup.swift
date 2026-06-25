import Foundation

/// Mic-echo deduplication for the live pass (PT-R19).
///
/// When the user listens to a call on **speakers** (not headphones), the
/// system audio is played out loud and the **microphone picks it up too**. The
/// same words then arrive on both streams: once on the system stream (the real
/// source) and again, slightly delayed and degraded, on the mic stream. Left
/// alone, `live.md` would show every remote utterance twice — once as `Them`,
/// once as `You`.
///
/// PT-R19's rule: when a mic utterance's text is **more than 0.5 similar** to a
/// system utterance within a **±5 s window**, the utterance is an echo and the
/// **mic-side** copy is dropped (the system stream is the authoritative source
/// of remote speech). This carries over the `transcribe-md` heuristic.
///
/// This type is the pure decision core: it remembers recent system utterances
/// and answers "is this mic utterance an echo?". `StreamingPipeline` consults
/// it before appending a mic line to `live.md`. Deterministic, no I/O.
public struct MicEchoDedup {

    /// A recent system-stream utterance, kept as an echo candidate.
    private struct SystemUtterance {
        let normalizedText: String
        let start: Duration
        let end: Duration
    }

    /// Similarity above which a mic utterance counts as an echo (PT-R19: > 0.5).
    public let similarityThreshold: Double
    /// Half-width of the time window an echo may be offset by (PT-R19: ±5 s).
    public let window: Duration

    /// Recent system utterances, pruned to the window as time advances.
    private var recentSystem: [SystemUtterance] = []

    public init(
        similarityThreshold: Double = 0.5,
        window: Duration = .seconds(5)
    ) {
        self.similarityThreshold = similarityThreshold
        self.window = window
    }

    /// Record a system-stream utterance so later mic utterances can be checked
    /// against it. Old utterances outside the window of `start` are pruned.
    public mutating func noteSystemUtterance(
        text: String,
        start: Duration,
        end: Duration
    ) {
        recentSystem.append(SystemUtterance(
            normalizedText: Self.normalize(text), start: start, end: end))
        prune(now: end)
    }

    /// Decide whether a mic utterance is an echo of a recent system utterance.
    ///
    /// - Returns: `true` when a system utterance within ±`window` of this mic
    ///   utterance has text similarity strictly greater than the threshold —
    ///   meaning the caller should **drop this mic line** (PT-R19).
    public func isMicEcho(text: String, start: Duration, end: Duration) -> Bool {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return false }
        for sys in recentSystem {
            // Time-overlap test: the mic utterance may lag the system one, so
            // check whether the spans are within `window` of each other.
            guard Self.withinWindow(
                micStart: start, micEnd: end,
                sysStart: sys.start, sysEnd: sys.end,
                window: window) else { continue }
            if Self.similarity(normalized, sys.normalizedText) > similarityThreshold {
                return true
            }
        }
        return false
    }

    /// Drop system utterances whose end is more than `window` before `now`,
    /// so the candidate set stays bounded over a long recording.
    private mutating func prune(now: Duration) {
        let cutoff = now - window - window
        recentSystem.removeAll { $0.end < cutoff }
    }

    // MARK: - Pure helpers

    /// True when a mic span and a system span are within `window` of each other
    /// (echo can be offset in either direction by playback/transcription lag).
    static func withinWindow(
        micStart: Duration, micEnd: Duration,
        sysStart: Duration, sysEnd: Duration,
        window: Duration
    ) -> Bool {
        // The spans are "close" if neither starts more than `window` after the
        // other ends.
        if micStart > sysEnd + window { return false }
        if sysStart > micEnd + window { return false }
        return true
    }

    /// Normalize utterance text for comparison: lowercased, punctuation
    /// stripped, whitespace collapsed.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Word-level similarity in `[0, 1]` — the size of the shared word
    /// multiset over the larger word count (a token-level Jaccard-ish ratio).
    ///
    /// Robust to the small word-level differences a degraded echo introduces
    /// (a dropped article, a mis-heard word) while still scoring two unrelated
    /// utterances near zero. Two empty strings score 0 (nothing to dedup).
    static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = a.split(separator: " ").map(String.init)
        let wordsB = b.split(separator: " ").map(String.init)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }

        // Multiset intersection: count shared words honoring repetition.
        var countsA: [String: Int] = [:]
        for w in wordsA { countsA[w, default: 0] += 1 }
        var shared = 0
        for w in wordsB {
            if let c = countsA[w], c > 0 {
                shared += 1
                countsA[w] = c - 1
            }
        }
        return Double(shared) / Double(max(wordsA.count, wordsB.count))
    }
}

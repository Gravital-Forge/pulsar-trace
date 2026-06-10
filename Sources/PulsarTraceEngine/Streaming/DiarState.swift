import Foundation

/// Accumulates the live diarizer's provisional spans and answers
/// "which provisional speaker dominates this time range?".
actor DiarState {
    private var spans: [LiveSpeakerSpan] = []

    func merge(_ newSpans: [LiveSpeakerSpan]) {
        spans.append(contentsOf: newSpans)
    }

    /// The provisional key whose spans overlap `[start, end]` the most.
    func dominantKey(start: Duration, end: Duration) -> String? {
        let range = start.seconds...max(start.seconds, end.seconds)
        var overlapByKey: [String: Double] = [:]
        for span in spans {
            let lo = max(span.start.seconds, range.lowerBound)
            let hi = min(span.end.seconds, range.upperBound)
            let overlap = max(0, hi - lo)
            if overlap > 0 {
                overlapByKey[span.provisionalKey, default: 0] += overlap
            }
        }
        return overlapByKey.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }?.key
    }
}

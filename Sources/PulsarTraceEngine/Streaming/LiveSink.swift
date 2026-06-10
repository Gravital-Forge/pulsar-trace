import Foundation

/// Serializes all writes to `live.md` and owns the mic-echo dedup state.
///
/// Both streams append through this one actor, so the append-only `live.md`
/// (R36) never sees a half-line from an interleaved write and the dedup state
/// is consistent.
actor LiveSink {
    private let writer: LiveMarkdownWriter
    private let recordingStart: Date
    private var dedup = MicEchoDedup()
    private var utteranceLines = 0
    private var micEchoesDropped = 0
    /// Lag samples for mid-stream commits only (the end-of-stream flush is
    /// excluded — R10 is about live consumption, and the flush decodes the
    /// whole tail at once which is not representative of in-call latency).
    private var lagSamples: [Double] = []
    private var systemLanguage = "en"

    struct Stats: Sendable {
        let utteranceLines: Int
        let micEchoesDropped: Int
        /// Median live lag in seconds across mid-stream commits (R10).
        let medianLagSeconds: Double
        /// Worst mid-stream lag observed.
        let maxLagSeconds: Double
        let systemLanguage: String
    }

    init(writer: LiveMarkdownWriter, recordingStart: Date) {
        self.writer = writer
        self.recordingStart = recordingStart
    }

    /// Append a system-stream utterance with its provisional label (R14, R16).
    ///
    /// `isFlush` marks the end-of-stream flush — its lag is not counted toward
    /// the R10 median (it decodes the whole tail at once).
    func appendSystemUtterance(
        _ utterance: CommittedUtterance,
        label: String,
        realElapsed: Duration,
        isFlush: Bool = false
    ) async {
        dedup.noteSystemUtterance(
            text: utterance.text, start: utterance.start, end: utterance.end)
        await append(
            utterance, label: label, realElapsed: realElapsed, isFlush: isFlush)
    }

    /// Append a mic-stream utterance — always `You` (R17). Dropped when it is a
    /// mic-echo of a recent system utterance (R19).
    func appendMicUtterance(
        _ utterance: CommittedUtterance,
        realElapsed: Duration,
        isFlush: Bool = false
    ) async {
        if dedup.isMicEcho(
            text: utterance.text,
            start: utterance.start,
            end: utterance.end) {
            micEchoesDropped += 1
            return
        }
        await append(
            utterance, label: "You", realElapsed: realElapsed, isFlush: isFlush)
    }

    /// Append a capture pause/resume gap annotation to `live.md` (R7). A
    /// failed append must not crash the live pass.
    func appendGap(_ kind: LiveMarkdownWriter.GapKind) async {
        do {
            try await writer.appendGapAnnotation(kind)
        } catch {
            // An annotation failure is non-fatal — the live pass continues.
        }
    }

    func noteSystemLanguage(_ language: String) {
        systemLanguage = language
    }

    func stats() -> Stats {
        let median: Double
        if lagSamples.isEmpty {
            median = 0
        } else {
            let sorted = lagSamples.sorted()
            median = sorted[sorted.count / 2]
        }
        return Stats(
            utteranceLines: utteranceLines,
            micEchoesDropped: micEchoesDropped,
            medianLagSeconds: median,
            maxLagSeconds: lagSamples.max() ?? 0,
            systemLanguage: systemLanguage)
    }

    private func append(
        _ utterance: CommittedUtterance,
        label: String,
        realElapsed: Duration,
        isFlush: Bool
    ) async {
        // R10 lag: how far behind real time the utterance's end is at commit.
        // The end-of-stream flush is excluded — it is not live latency.
        if !isFlush {
            let lag = max(0, realElapsed.seconds - utterance.end.seconds)
            lagSamples.append(lag)
        }
        do {
            try await writer.appendUtterance(
                offset: utterance.start,
                speakerLabel: label,
                text: utterance.text)
            utteranceLines += 1
        } catch {
            // A failed append must not crash the live pass.
        }
    }
}

import Foundation

/// Renders a transcript to the R13 markdown format.
///
/// The format (PRD §8.3 R13, Appendix):
///
/// ```
/// <!-- pulsartrace:final -->
/// ## Transcript — 2026-04-30 14:30
///
/// **[00:00:05] Speaker:** So the main issue is the auth flow.
/// **[00:00:12] Speaker:** Right, the redirect URI isn't handled.
/// ```
///
/// - The header carries the local wall-clock at which recording *started*,
///   captured once. This renderer only writes the header; the wall-clock is
///   also stored in `metadata.json` by the recording pipeline.
/// - Each utterance line's `[HH:MM:SS]` is **seconds-since-recording-start**,
///   not wall-clock — this is the R13 wording and it sidesteps DST / timezone
///   shifts mid-recording.
/// - When no speaker labels are supplied, every line uses the single
///   placeholder speaker label `Speaker`; callers with diarization pass
///   per-segment labels instead.
///
/// `live.md` / `final.md` is a public API surface; treat this format as
/// SemVer-stable (see `docs/file-format.md`).
public struct TranscriptDocument: Sendable, Equatable {

    /// The file marker. The offline path produces a finished transcript.
    public enum Marker: String, Sendable {
        case live = "<!-- pulsartrace:live -->"
        case final = "<!-- pulsartrace:final -->"
    }

    /// The placeholder speaker label used when no diarized labels are supplied.
    public static let placeholderSpeaker = "Speaker"

    /// Wall-clock at which recording started (header line).
    public let recordingStart: Date
    /// The utterances, in time order.
    public let segments: [TranscriptSegment]
    /// Speaker label per segment; defaults to the placeholder for every line.
    public let speakerLabels: [String]
    /// File marker to emit.
    public let marker: Marker

    /// - Parameters:
    ///   - recordingStart: wall-clock recording-start instant (header).
    ///   - segments: utterances with start/end relative to `recordingStart`.
    ///   - speakerLabels: one label per segment; when `nil` every line gets the
    ///     placeholder `Speaker`.
    ///   - marker: `.final` for the offline path (default).
    public init(
        recordingStart: Date,
        segments: [TranscriptSegment],
        speakerLabels: [String]? = nil,
        marker: Marker = .final
    ) {
        self.recordingStart = recordingStart
        self.segments = segments
        self.marker = marker
        if let labels = speakerLabels, labels.count == segments.count {
            self.speakerLabels = labels
        } else {
            self.speakerLabels = Array(
                repeating: Self.placeholderSpeaker, count: segments.count)
        }
    }

    /// Render the full R13 markdown document.
    public func render() -> String {
        var lines: [String] = []
        lines.append(marker.rawValue)
        lines.append("## Transcript — \(Self.headerFormatter.string(from: recordingStart))")
        lines.append("")
        for (i, segment) in segments.enumerated() {
            let stamp = Self.offsetStamp(segment.start)
            let speaker = speakerLabels[i]
            lines.append("**[\(stamp)] \(speaker):** \(segment.text)")
        }
        // Trailing newline so the file is POSIX-clean and `tail -f`-friendly.
        return lines.joined(separator: "\n") + "\n"
    }

    /// Format a Duration as `HH:MM:SS` seconds-since-start (R13).
    ///
    /// Handles long recordings: a 4-hour+ recording renders as `04:12:33`, the
    /// hours field simply grows (no wraparound, no day rollover).
    public static func offsetStamp(_ offset: Duration) -> String {
        let totalSeconds = max(0, Int(offset.components.seconds))
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// `YYYY-MM-DD HH:MM` in the host's local timezone — the header stamp.
    /// Captured once at recording start; never recomputed mid-recording.
    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

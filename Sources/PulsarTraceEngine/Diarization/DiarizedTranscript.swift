import Foundation

/// Merges whisper transcript utterances with pyannote speaker spans by
/// timestamp overlap, producing the per-segment `Speaker_N` labels that the
/// PT-R13 transcript format renders (in place of a single placeholder `Speaker`
/// when diarization is unavailable).
///
/// Attribution rule: each utterance is
/// assigned to the speaker whose spans overlap it the **most** in time
/// ("dominant overlap"). This is robust to the inevitable slack between
/// whisper's segment boundaries and pyannote's turn boundaries.
///
/// Overlapping speech (edge case): when an utterance overlaps two
/// speakers and the *second*-most-overlapping speaker still covers a
/// meaningful share of the utterance, **both** attributions are surfaced — the
/// label becomes `Speaker_0+Speaker_1`. A short incidental overlap does not
/// trigger this; only a co-attribution above `overlapShareThreshold` does.
///
/// An utterance that overlaps no span at all (whisper found speech where
/// pyannote found none) keeps the unknown-speaker label so no text is lost.
public enum DiarizationMerge {

    /// The label used when no speaker span overlaps an utterance at all.
    ///
    /// Semantically equivalent to a delisted speaker — there is no library
    /// row to enroll (no raw pyannote label exists for the
    /// no-overlap case), so the utterance is rendered with the same
    /// `Unrecognized` sentinel the delist feature uses. The Speakers list
    /// never has a row to show for these lines.
    public static let unknownSpeaker = "Unrecognized"

    /// Minimum share of an utterance's duration a *secondary* speaker must
    /// cover before it is co-attributed (`Speaker_0+Speaker_1`). 0.30 keeps a
    /// brief cross-talk syllable from cluttering every line while still
    /// surfacing genuine talked-over utterances.
    public static let overlapShareThreshold = 0.30

    /// Compute a `Speaker_N` label for each transcript segment.
    ///
    /// - Parameters:
    ///   - segments: whisper utterances, in time order, offsets relative to
    ///     recording start.
    ///   - diarization: the diarization result for the *system stream* (PT-R17).
    /// - Returns: one label per segment, index-aligned with `segments`.
    public static func speakerLabels(
        for segments: [TranscriptSegment],
        diarization: DiarizationResult
    ) -> [String] {
        segments.map { segment in
            label(for: segment, diarization: diarization)
        }
    }

    /// Merge `segments` + `diarization` into a `TranscriptDocument` whose
    /// utterance lines carry real `Speaker_N` labels.
    public static func diarizedDocument(
        recordingStart: Date,
        segments: [TranscriptSegment],
        diarization: DiarizationResult,
        marker: TranscriptDocument.Marker = .final
    ) -> TranscriptDocument {
        TranscriptDocument(
            recordingStart: recordingStart,
            segments: segments,
            speakerLabels: speakerLabels(for: segments, diarization: diarization),
            marker: marker
        )
    }

    // MARK: - Private

    /// The label for a single utterance: dominant-overlap speaker, with a
    /// co-attribution when a second speaker also covers a meaningful share.
    private static func label(
        for segment: TranscriptSegment,
        diarization: DiarizationResult
    ) -> String {
        let range = segment.start.seconds...max(segment.start.seconds, segment.end.seconds)
        let utteranceLength = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)

        // Total overlap each raw pyannote speaker has with this utterance.
        var overlapBySpeaker: [String: Double] = [:]
        for span in diarization.spans {
            let overlap = span.overlapSeconds(with: range)
            if overlap > 0 {
                overlapBySpeaker[span.speaker, default: 0] += overlap
            }
        }

        guard !overlapBySpeaker.isEmpty else {
            return unknownSpeaker
        }

        // Rank speakers by overlap; ties broken by raw label for determinism.
        let ranked = overlapBySpeaker
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }

        let primary = ranked[0].key
        var labels = [diarization.displayLabel(for: primary)]

        // Co-attribute a secondary speaker only when it covers a meaningful
        // share of the utterance (overlap edge case).
        if ranked.count > 1 {
            let secondary = ranked[1]
            if secondary.value / utteranceLength >= overlapShareThreshold {
                labels.append(diarization.displayLabel(for: secondary.key))
            }
        }

        // Stable ordering for the co-attributed label (`Speaker_0+Speaker_1`).
        return labels.sorted().joined(separator: "+")
    }
}

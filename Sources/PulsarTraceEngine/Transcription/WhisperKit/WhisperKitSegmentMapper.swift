import Foundation

/// Maps WhisperKit's per-segment output onto PulsarTrace `TranscriptSegment`s,
/// applying the same offline-path filters the whisper.cpp transcriber applied
/// in `collectSegments` (BlankTokenFilter + the D31 hallucination double-gate).
///
/// Pure: takes its own `InputSegment` (mirroring the fields we consume from
/// `WhisperKit.TranscriptionSegment`) so unit tests fabricate inputs without
/// the SDK. `WhisperKitRegionTranscriber` adapts the real type in one line.
enum WhisperKitSegmentMapper {

    /// The WhisperKit segment fields the mapper consumes. Times are seconds
    /// relative to the audio slice that was decoded.
    struct InputSegment: Equatable {
        let text: String
        let start: Float
        let end: Float
        let noSpeechProb: Float
        let avgLogprob: Float
    }

    /// - Parameters:
    ///   - shiftedBy: offset of the decoded slice on the recording timeline
    ///     (the region's start; `.zero` for a whole-buffer decode).
    ///   - dropHallucinations: apply the D31 double-gate. Always `true` on
    ///     the refine path; the flag exists so a future caller can opt out,
    ///     mirroring the old `collectSegments(dropHallucinations:)`.
    static func segments(
        from inputs: [InputSegment],
        shiftedBy offset: Duration,
        dropHallucinations: Bool
    ) -> [TranscriptSegment] {
        inputs.compactMap { input in
            let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !BlankTokenFilter.isBlank(text) else { return nil }
            if dropHallucinations {
                let confidence = HallucinationFilter.SegmentConfidence(
                    noSpeechProb: input.noSpeechProb,
                    avgLogProb: input.avgLogprob)
                if HallucinationFilter.shouldDrop(text: text, confidence: confidence) {
                    return nil
                }
            }
            return TranscriptSegment(
                start: offset + .milliseconds(Int((Double(input.start) * 1000).rounded())),
                end: offset + .milliseconds(Int((Double(input.end) * 1000).rounded())),
                text: text)
        }
    }
}

> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 08: WhisperKitSegmentMapper (pure)

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitSegmentMapper.swift`
- Test: `Tests/UnitTests/WhisperKitSegmentMapperTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/UnitTests/WhisperKitSegmentMapperTests.swift`:

```swift
import Testing
@testable import PulsarTraceEngine

@Suite("WhisperKitSegmentMapper")
struct WhisperKitSegmentMapperTests {

    private func seg(
        _ text: String, _ start: Float, _ end: Float,
        noSpeech: Float = 0.05, avgLogprob: Float = -0.2
    ) -> WhisperKitSegmentMapper.InputSegment {
        .init(text: text, start: start, end: end,
              noSpeechProb: noSpeech, avgLogprob: avgLogprob)
    }

    @Test func shiftsOntoRecordingTimeline() {
        let out = WhisperKitSegmentMapper.segments(
            from: [seg(" Hello there.", 1.0, 2.5)],
            shiftedBy: .seconds(100),
            dropHallucinations: true)
        #expect(out == [TranscriptSegment(
            start: .milliseconds(101_000),
            end: .milliseconds(102_500),
            text: "Hello there.")])
    }

    @Test func dropsBlankAndEmptySegments() {
        let out = WhisperKitSegmentMapper.segments(
            from: [seg("[BLANK_AUDIO]", 0, 1), seg("   ", 1, 2), seg("Real words", 2, 3)],
            shiftedBy: .zero,
            dropHallucinations: true)
        #expect(out.map(\.text) == ["Real words"])
    }

    @Test func hallucinationDoubleGateMirrorsD31() {
        // Stock phrase + silence signal → dropped.
        let hallucinated = seg("Thank you.", 0, 1, noSpeech: 0.45, avgLogprob: -0.3)
        // Same phrase, confident decode → kept (a real person said it).
        let genuine = seg("Thank you.", 1, 2, noSpeech: 0.05, avgLogprob: -0.2)
        // Non-stock text, terrible confidence → kept (gate needs BOTH).
        let lowConfidence = seg("quarterly revenue numbers", 2, 3,
                                noSpeech: 0.5, avgLogprob: -1.5)
        let out = WhisperKitSegmentMapper.segments(
            from: [hallucinated, genuine, lowConfidence],
            shiftedBy: .zero,
            dropHallucinations: true)
        #expect(out.map(\.text) == ["Thank you.", "quarterly revenue numbers"])
    }

    @Test func gateOffKeepsEverythingNonBlank() {
        let out = WhisperKitSegmentMapper.segments(
            from: [seg("Thank you.", 0, 1, noSpeech: 0.45, avgLogprob: -0.9)],
            shiftedBy: .zero,
            dropHallucinations: false)
        #expect(out.count == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WhisperKitSegmentMapper` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — type not found.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitSegmentMapper.swift`:

```swift
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
```

(If `BlankTokenFilter.isBlank`'s or `HallucinationFilter`'s actual signatures differ — check `Sources/PulsarTraceEngine/Transcription/BlankTokenFilter.swift` and `HallucinationFilter.swift` — match them; they are used identically in `StreamingTranscriber.runWindow` and the old `WhisperTranscriber.collectSegments`.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WhisperKitSegmentMapper`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitSegmentMapper.swift Tests/UnitTests/WhisperKitSegmentMapperTests.swift
git commit -m "feat(refine): WhisperKitSegmentMapper — segment mapping with D31 hallucination gate"
```

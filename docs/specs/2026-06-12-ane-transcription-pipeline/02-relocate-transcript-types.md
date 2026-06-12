> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 02: Relocate the shared transcript types out of WhisperTranscriber.swift

`TranscriptSegment`, `TranscriptionResult`, and `SpeechRegion` are currently defined at the top of `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift` (lines 5–52), and the 800 ms region coalescer is `WhisperTranscriber.coalesceRegions(_:minGap:)` (internal static, line ~591, unit-tested in `Tests/UnitTests/SpeechRegionTests.swift`). Task 16 deletes `WhisperTranscriber.swift` wholesale; these four things are backend-independent and must survive. This is a **pure move** — no behaviour change.

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/TranscriptTypes.swift`
- Modify: `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift` (remove the moved code; update one call site)
- Modify: `Tests/UnitTests/SpeechRegionTests.swift` (call-site rename)

- [ ] **Step 1: Create `TranscriptTypes.swift` with the moved types + coalescer**

Create `Sources/PulsarTraceEngine/Transcription/TranscriptTypes.swift`. Move lines 5–52 of `WhisperTranscriber.swift` (the three type definitions, from `/// A transcribed utterance…` through the closing brace of `SpeechRegion`) into it **unchanged**, under a plain `import Foundation`, then append the coalescer as a `SpeechRegion` extension — its body is lines 595–608 of `WhisperTranscriber.swift`, moved verbatim:

```swift
import Foundation

// <lines 5–52 of WhisperTranscriber.swift, moved unchanged:
//  TranscriptSegment, TranscriptionResult, SpeechRegion>

extension SpeechRegion {
    /// Merge speech regions separated by less than `minGap` so the transcript
    /// breaks at genuine turn pauses, not at every short breath. `regions` must
    /// be in ascending start order; the result is too.
    static func coalesced(
        _ regions: [SpeechRegion],
        minGap: Duration
    ) -> [SpeechRegion] {
        guard var current = regions.first else { return [] }
        var out: [SpeechRegion] = []
        for region in regions.dropFirst() {
            if region.start - current.end < minGap {
                current = SpeechRegion(
                    start: current.start,
                    end: max(current.end, region.end))
            } else {
                out.append(current)
                current = region
            }
        }
        out.append(current)
        return out
    }
}
```

(Access level stays internal, same as the old `coalesceRegions` — every consumer is inside `PulsarTraceEngine`, tests use `@testable`. One doc-comment tweak is allowed in the moved `SpeechRegion` type: its header references `WhisperTranscriber.detectSpeechRegions`; leave it as-is for now — task 16 deletes the producer and the comment is corrected by task 18's doc sweep if it survives that long. Do not edit anything else.)

- [ ] **Step 2: Strip the moved code from `WhisperTranscriber.swift`**

In `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift`:
1. Delete lines 5–52 (the three moved type definitions). Keep the file's imports (`Foundation`, `CWhisper`, `Logging`) and everything else.
2. Delete the `static func coalesceRegions(_:minGap:)` method (lines ~588–609, including its doc comment).
3. In `detectSpeechRegions` (line ~375), change the call:

```swift
        let coalesced = SpeechRegion.coalesced(raw, minGap: minTurnGap)
```

- [ ] **Step 3: Update the unit tests**

In `Tests/UnitTests/SpeechRegionTests.swift`, replace every `WhisperTranscriber.coalesceRegions(` with `SpeechRegion.coalesced(` (6 occurrences) and update the suite doc comment's first line to name the new home:

```swift
/// Unit coverage of `SpeechRegion.coalesced(_:minGap:)` — the gap-merge step
```

- [ ] **Step 4: Build and run the unit suite**

Run: `swift build` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: compiles — the compiler flags any reference to the moved symbols you missed.
Run: `swift test --filter UnitTests` (bare; `dangerouslyDisableSandbox: true`)
Expected: PASS — including the renamed `SpeechRegion coalescing` suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/TranscriptTypes.swift Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift Tests/UnitTests/SpeechRegionTests.swift
git commit -m "refactor(transcription): move transcript types + region coalescer to TranscriptTypes.swift"
```

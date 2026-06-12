> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 17: Rename sweep — TranscriptionOptions, TranscriptionError, drop AbortToken

Mechanical, compiler-guided. The shared option/error types lose their `Whisper` names and their whisper.cpp-only fields; the dead `AbortToken` plumbing goes. (The `LanguageCatalog` replacement the spec listed for this task was folded into task 16 — stated there — so the build never carried a non-compiling CWhisper dependency. Nothing of it remains to do here.)

**Deliberately NOT renamed:** `whisperModelName:`/`whisperModelSHA256:` parameters on `RefinementPipeline.run` and `RefinementMetadata.whisperModel` — they name the frozen `metadata.json` schema field `whisper_model` (public API). D39 documents this (task 18).

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/TranscriptionOptions.swift` (replaces `WhisperOptions.swift`)
- Delete: `Sources/PulsarTraceEngine/Transcription/WhisperOptions.swift`, `Sources/PulsarTraceEngine/Transcription/AbortToken.swift`, `Tests/UnitTests/AbortTokenTests.swift`
- Modify: every reference — `WindowTranscribing.swift`, `StreamingTranscriber.swift`, `ParakeetWindowTranscriber.swift`, `WhisperKitRegionTranscriber.swift`, `ResumableRefiner.swift`, `RefinementTranscriber.swift`, `RefinementPipeline.swift`, `RefinementJobQueue.swift`, `RefinementJobError.swift`, `OfflineRefiner.swift`, `Sources/pulsartrace-engine/main.swift`, `AppEnvironment.swift`, and tests

- [ ] **Step 1: Create `TranscriptionOptions.swift`; delete `WhisperOptions.swift`**

Create `Sources/PulsarTraceEngine/Transcription/TranscriptionOptions.swift`. This is `WhisperOptions` renamed and trimmed: `threadCount`, `temperature`, `temperatureFallbackStep`, `vadModelURL`, and `defaultGPUEnabled` are deleted — all were whisper.cpp knobs with no remaining reader (verified by task 16's grep; the new backends fix their own decode strategy: Parakeet is greedy TDT, WhisperKit's fallback ladder is set inside `WhisperKitRegionTranscriber`).

```swift
import Foundation

/// Tunables for a transcription run, shared by the live (Parakeet) and
/// refine (WhisperKit) passes — the option carrier through every seam
/// (`WindowTranscribing`, `ResumableRefiner`, `RefinementTranscriber`).
public struct TranscriptionOptions: Sendable, Equatable {
    /// `nil` → auto-detect / allowed-languages policy. A two-letter
    /// ISO-639-1 code hard-pins the refine decode (`refine --language`,
    /// `WhisperKitLanguagePolicy` rule 1). The live pass ignores it —
    /// Parakeet has no language pinning.
    public var language: String?
    /// Optional allow-list of ISO-639-1 codes (the Settings "Restrict to
    /// languages" selector). Live: exactly one code becomes FluidAudio's
    /// script hint (`ParakeetEngine.languageHint`). Refine: one code pins;
    /// several → per-region detect-among (`WhisperKitLanguagePolicy`).
    public var allowedLanguages: [String]
    /// The no-speech threshold — segments above this probability of being
    /// non-speech are dropped by the decoder before they reach us. Guards
    /// against silence hallucinations ("thanks for watching").
    public var noSpeechThreshold: Float

    public init(
        language: String? = nil,
        allowedLanguages: [String] = [],
        noSpeechThreshold: Float = 0.6
    ) {
        self.language = language
        self.allowedLanguages = allowedLanguages
        self.noSpeechThreshold = noSpeechThreshold
    }
}

/// Errors thrown by transcription paths (live or refine) and test doubles.
/// (Previously `WhisperTranscribeError`; same cases — `RefinementJobError.
/// classify` and `ResumableRefiner.transcribeRegionWithRetry` key off them.)
public enum TranscriptionError: Error, CustomStringConvertible, Equatable {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case transcriptionFailed(Int)
    case emptyAudio

    public var description: String {
        switch self {
        case .modelNotFound(let p): return "model not found: \(p)"
        case .modelLoadFailed(let p): return "model failed to load: \(p)"
        case .transcriptionFailed(let c): return "transcription failed with code \(c)"
        case .emptyAudio: return "no audio samples to transcribe"
        }
    }
}
```

Then: `git rm Sources/PulsarTraceEngine/Transcription/WhisperOptions.swift`

- [ ] **Step 2: Mechanical rename across the tree**

Apply, then let the compiler find stragglers:

1. `WhisperOptions` → `TranscriptionOptions` everywhere (Sources + Tests). Sites the plan itself introduced: `ParakeetWindowTranscriber.transcribeWindow`, `WhisperKitRegionTranscriber` (3 methods), `RefinementTranscriber.TranscribeRegions`, `ResumableRefiner.TranscribeRegion` + its `whisperOptions` property/param, `RefinementPipeline.run/refine/transcribe`, `RefinementJobQueue.makeStandard`, `OfflineRefiner.refine`, `StreamingTranscriber`, `WindowTranscribing`, `AppEnvironment`, plus test fakes.
2. `WhisperTranscribeError` → `TranscriptionError` everywhere. Known catchers (verified): `ResumableRefiner.transcribeRegionWithRetry` (lines ~227–251), `RefinementJobError.classify` (`RefinementJobError.swift:137` `if error is WhisperTranscribeError`), the throw sites in `ParakeetWindowTranscriber` and `WhisperKitRegionTranscriber`, and test fakes.
3. Rename the `whisperOptions` **labels** to `options`: `StreamingTranscriber.Configuration.whisperOptions` (property, init param, and the read at line ~269) — update its one production construction site in `Sources/pulsartrace-engine/main.swift` (`StreamingTranscriber.Configuration(whisperOptions:` → `(options:`); `ResumableRefiner`'s `whisperOptions` property + init label; `RefinementJobQueue.makeStandard(whisperOptions:)` → `makeStandard(options:)` and its `AppEnvironment` caller (rename the local `refineWhisperOptions` → `refineOptions`); `RefinementPipeline.run(whisperOptions:)` → `run(options:)` and its callers (`OfflineRefiner`, `RefinementPipelineTests`, `SpeakerLibraryPipelineTests`).
4. Doc-comment sweep: the renamed declarations' comments must not say "whisper tunables" — the new texts are in step 1's file; for `ResumableRefiner`'s property comment use: "Decode tunables threaded into every region decode (`allowedLanguages` drives the language policy; a forced `language` pins it)."

Run: `swift build` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: iterate until clean — every error is a missed rename.

- [ ] **Step 3: Remove the AbortToken plumbing**

Verified current state: after task 16, **no production caller passes a non-nil token** — `LiveRunner` never referenced `AbortToken` (grep-verified), the only remaining references are `WindowTranscribing` (protocol param), `StreamingTranscriber.ingest/drainWindows/runWindow/finish` (plumbing, always handed `nil` by `LiveRunner`), `ParakeetWindowTranscriber` (ignores it), and test fakes. The mechanism existed for whisper.cpp's `abort_callback`; CoreML decodes can't be interrupted mid-graph and the deadline mechanisms replaced it. Remove it:

1. `Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift` — the new protocol, in full:

```swift
import Foundation

/// The single decode operation the live streaming path depends on.
///
/// Extracted as a protocol so the live pipeline can be driven by a test
/// double (a slow or hanging stub) without a real model.
/// `ParakeetWindowTranscriber` is the production conformer.
///
/// Not `Sendable`: a conformer is driven from one task/queue at a time.
public protocol WindowTranscribing: AnyObject {
    /// Decode one streaming window. Implementations bound their own decode
    /// time (e.g. `ParakeetWindowTranscriber`'s 30 s deadline) — a wedged
    /// window throws and is skipped; the post-pass recovers the audio.
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: TranscriptionOptions
    ) throws -> TranscriptionResult
}
```

2. `StreamingTranscriber.swift`: delete the `abort: AbortToken? = nil` parameter from `ingest(frame:realTimeElapsed:abort:)` and the `abort: AbortToken?` parameters from `drainWindows`/`runWindow`; delete the abort-forwarding arguments inside `finish()` and the doc-comment sentences describing the watchdog token. The `transcribeWindow` call inside `runWindow` loses its `abort:` argument.
3. `ParakeetWindowTranscriber.transcribeWindow`: drop the `abort: AbortToken?` parameter (and the `/// abort is ignored…` paragraph becomes a sentence noting the 30 s deadline is the only bound — already documented).
4. `git rm Sources/PulsarTraceEngine/Transcription/AbortToken.swift Tests/UnitTests/AbortTokenTests.swift`
5. Tests: `grep -rn "abort" Tests/ --include="*.swift"` — update every fake `WindowTranscribing` conformer (verified locations: `Tests/UnitTests/WindowTranscribingTests.swift`, `Tests/UnitTests/StreamingTranscriberUnitTests.swift`, `Tests/PipelineTests/LiveRunnerResilienceTests.swift`, plus task 06/07's `ParakeetTranscriberTests` call sites passing `abort: nil`) to the new three-parameter signature, and delete `ingest(..., abort:)` arguments. A test whose *purpose* was abort-token forwarding (e.g. an "abort is threaded through" case inside `WindowTranscribingTests`/`StreamingTranscriberUnitTests`) is deleted, not adapted — the contract no longer exists.

Run: `swift build`
Expected: iterate until clean.

- [ ] **Step 4: Confirm nothing Whisper-named leaks outside the WhisperKit adapters**

Run: `grep -rn "WhisperOptions\|WhisperTranscribeError\|AbortToken" Sources/ Tests/`
Expected: zero hits.
Run: `grep -rin "whisper" Sources/PulsarTraceEngine/Streaming/ Sources/PulsarTraceEngine/Refinement/`
Expected: only `WhisperKit*` type names, `whisperkit` cache paths, and the frozen `whisperModelName`/`whisperModelSHA256`/`whisperModel` metadata names. Fix anything else.

- [ ] **Step 5: Full narrow-filter sweep**

Run each, bare, sandbox-disabled — all must pass:

```
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter IPC
swift test --filter RecordOrchestrator
swift test --filter LiveRunner
swift test --filter Streaming
swift test --filter Speaker
swift test --filter Source
swift test --filter Lifecycle
swift test --filter FinalMarkdownRewriter
swift test --filter Parakeet
swift test --filter WhisperKitRefine
swift test --filter FluidVAD
swift test --filter MenuBar
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor!: TranscriptionOptions/TranscriptionError replace Whisper-named shared types; AbortToken removed"
```

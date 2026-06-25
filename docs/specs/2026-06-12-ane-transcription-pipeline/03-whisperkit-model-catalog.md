> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 03: WhisperKitModelCatalog — the refine model namespace

The refine pass has exactly two models, both WhisperKit/ANE. There is no live model knob and no legacy backend, so no per-pass "selection" enum is needed — just this catalog. SDK-managed CoreML bundles carry no pinned SHA-256 (D39): everywhere a `modelSHA256` is recorded for these models, the value is `""` (the `RefinementJob`/`metadata.json` fields themselves survive unchanged).

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitModelCatalog.swift`
- Test: `Tests/UnitTests/WhisperKitModelCatalogTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/UnitTests/WhisperKitModelCatalogTests.swift`:

```swift
import Testing
@testable import PulsarTraceEngine

@Suite("WhisperKitModelCatalog")
struct WhisperKitModelCatalogTests {

    @Test func hasExactlyTheTwoANEModels() {
        #expect(WhisperKitModelCatalog.all.count == 2)
        #expect(WhisperKitModelCatalog.largeV3Turbo.name == "large-v3-turbo")
        #expect(WhisperKitModelCatalog.largeV3Turbo.variant
            == "openai_whisper-large-v3-v20240930_626MB")
        #expect(WhisperKitModelCatalog.largeV3.name == "large-v3-whisperkit")
        #expect(WhisperKitModelCatalog.largeV3.variant
            == "openai_whisper-large-v3_947MB")
    }

    @Test func lookupByName() {
        #expect(WhisperKitModelCatalog.model(named: "large-v3-turbo")
            == WhisperKitModelCatalog.largeV3Turbo)
        #expect(WhisperKitModelCatalog.model(named: "large-v3-whisperkit")
            == WhisperKitModelCatalog.largeV3)
        // Unknown names (including the retired whisper.cpp ones) → nil;
        // callers fall back to `defaultModel`.
        #expect(WhisperKitModelCatalog.model(named: "base") == nil)
        #expect(WhisperKitModelCatalog.model(named: "large-v3") == nil)
        #expect(WhisperKitModelCatalog.model(named: "parakeet-v3") == nil)
        #expect(WhisperKitModelCatalog.model(named: "") == nil)
    }

    @Test func turboIsTheDefaultAndListedFirst() {
        #expect(WhisperKitModelCatalog.defaultModel == WhisperKitModelCatalog.largeV3Turbo)
        // Picker/usage orderings read `all` — default first.
        #expect(WhisperKitModelCatalog.all.first == WhisperKitModelCatalog.largeV3Turbo)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WhisperKitModelCatalog` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md — same for every test/build step below)
Expected: FAIL — `cannot find 'WhisperKitModelCatalog' in scope`.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitModelCatalog.swift`:

```swift
import Foundation

/// A WhisperKit CoreML model variant the refine pass can load.
///
/// `name` is the PulsarTrace-facing string (settings / `refine --model` /
/// `record --refine-model`); `variant` is the folder name inside the
/// `argmaxinc/whisperkit-coreml` Hugging Face repo. No pinned SHA-256:
/// WhisperKit manages the multi-file CoreML bundle itself (DECISIONS D39) —
/// `model_downloaded` carries a computed `DirectoryDigest` instead, and
/// `RefinementJob.modelSHA256` / `metadata.json` record `""`.
public struct WhisperKitModel: Sendable, Equatable {
    public let name: String
    public let variant: String
    /// Approximate download size, for the Settings caption.
    public let approximateDownloadMB: Int

    public init(name: String, variant: String, approximateDownloadMB: Int) {
        self.name = name
        self.variant = variant
        self.approximateDownloadMB = approximateDownloadMB
    }
}

/// The refine-pass model namespace — the only model knob PulsarTrace has.
/// (The live pass is fixed to Parakeet v3; see `ParakeetEngine`.)
public enum WhisperKitModelCatalog {

    /// Whisper large-v3-turbo, mixed-bit palettized (~626 MB). The
    /// production refinement default: near-large-v3 accuracy at a fraction
    /// of the decode cost, encoder + decoder on the ANE.
    public static let largeV3Turbo = WhisperKitModel(
        name: "large-v3-turbo",
        variant: "openai_whisper-large-v3-v20240930_626MB",
        approximateDownloadMB: 626)

    /// Full Whisper large-v3, quantized (~947 MB) — the accuracy fallback
    /// if turbo hallucinates on real audio (the D39 fallback rule: a
    /// Settings change, not a code change). Slower (32 decoder layers vs
    /// turbo's 4) but still on the ANE, off the GPU.
    public static let largeV3 = WhisperKitModel(
        name: "large-v3-whisperkit",
        variant: "openai_whisper-large-v3_947MB",
        approximateDownloadMB: 947)

    /// Picker/usage ordering — default first.
    public static let all: [WhisperKitModel] = [largeV3Turbo, largeV3]

    /// Production refine default.
    public static let defaultModel = largeV3Turbo

    /// `nil` for unknown names (including retired whisper.cpp names from
    /// old persisted settings) — callers fall back to `defaultModel`.
    public static func model(named name: String) -> WhisperKitModel? {
        all.first { $0.name == name }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WhisperKitModelCatalog`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitModelCatalog.swift Tests/UnitTests/WhisperKitModelCatalogTests.swift
git commit -m "feat(refine): WhisperKitModelCatalog — the two ANE refine models"
```

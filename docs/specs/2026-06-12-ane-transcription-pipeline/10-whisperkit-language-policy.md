> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 10: WhisperKitLanguagePolicy (pure)

The refine pass reproduces the existing "Restrict to languages" semantics on the new backend, per region decode, plus an explicit override (the `refine --language` flag, task 14):

1. explicit language → hard pin;
2. exactly one allowed code → pin it;
3. several allowed codes → detect on the region slice, pin the highest-probability code **within** the allowed set;
4. nothing → full auto-detect.

This task builds the pure decision; the detection call itself lives in `WhisperKitRegionTranscriber` (task 11).

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitLanguagePolicy.swift`
- Test: `Tests/UnitTests/WhisperKitLanguagePolicyTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/UnitTests/WhisperKitLanguagePolicyTests.swift`:

```swift
import Testing
@testable import PulsarTraceEngine

@Suite("WhisperKitLanguagePolicy")
struct WhisperKitLanguagePolicyTests {

    @Test func explicitLanguageBeatsTheAllowList() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: "pl", allowed: ["en", "de"])
            == .pin("pl"))
    }

    @Test func explicitPassesThroughEvenWhenNotInTheAllowedList() {
        // `refine --language` is an operator override — it wins outright,
        // it is not filtered through the Settings allow-list.
        #expect(WhisperKitLanguagePolicy.resolve(explicit: "ja", allowed: ["en", "pl"])
            == .pin("ja"))
    }

    @Test func singleAllowedCodePins() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["pl"])
            == .pin("pl"))
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["EN"])
            == .pin("en"))   // normalized
    }

    @Test func multipleAllowedCodesDetectAmong() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["en", "pl"])
            == .detectAmong(["en", "pl"]))
    }

    @Test func nothingMeansAuto() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: []) == .auto)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WhisperKitLanguagePolicy` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — type not found.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitLanguagePolicy.swift`:

```swift
import Foundation

/// The refine pass's language decision, applied **per region decode**
/// (reproducing the old whisper.cpp per-decode `allowedLanguages`
/// semantics on the WhisperKit backend):
///
/// 1. an explicit language (`refine --language`) pins outright — operator
///    override, not filtered through the allow-list;
/// 2. exactly one allowed code pins;
/// 3. several allowed codes → detect on the region's audio and pin the
///    highest-probability **allowed** code (`WhisperKitRegionTranscriber`
///    runs the actual detection);
/// 4. nothing → full auto-detect.
public enum WhisperKitLanguagePolicy {

    public enum Resolution: Equatable, Sendable {
        case pin(String)
        case detectAmong([String])
        case auto
    }

    public static func resolve(explicit: String?, allowed: [String]) -> Resolution {
        if let explicit, !explicit.isEmpty {
            return .pin(explicit.lowercased())
        }
        let codes = allowed.map { $0.lowercased() }
        switch codes.count {
        case 0: return .auto
        case 1: return .pin(codes[0])
        default: return .detectAmong(codes)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WhisperKitLanguagePolicy`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitLanguagePolicy.swift Tests/UnitTests/WhisperKitLanguagePolicyTests.swift
git commit -m "feat(refine): WhisperKitLanguagePolicy — pin/detect-among/auto language resolution"
```

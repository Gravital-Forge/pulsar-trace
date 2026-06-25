> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 16: whisper.cpp source removal

Production no longer calls any whisper.cpp code (tasks 12–15). This task deletes it — sources, the subprocess, the system library, the vendor build script, and the whisper-coupled tests — with **the compiler as the checklist**: delete, run `swift build`, fix every error site with the edits specified below. Two pieces of preparation come first so the deletions can't strand anything: `AppPaths.modelsCacheDirectory` (replaces `ModelStore.defaultCacheDirectory()`) and `LanguageCatalog` (replaces the CWhisper-backed `WhisperLanguageCatalog`; the spec offered task 17 this job — it is folded **here** so the build never holds a non-compiling catalog).

**Verified before writing this task:** `SHA256Verifier.swift` is **kept** — its consumers beyond `ModelStore` are `Sources/PulsarTraceEngine/Support/AtomicFile.swift:76` and `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerLibrary.swift:194` (that is how `TranscriptAssembly`'s final.md hashing keeps working). `Tests/PipelineTests/IPCTwoDaemonTests.swift` tests **capture-socket** daemons (`FixtureSocketServer` → `SocketSource` → `StreamingPipeline`), not the whisper subprocess — it is **kept and adapted** below.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Support/AppPaths.swift` (+`modelsCacheDirectory`, comment fix)
- Create: `Sources/PulsarTraceEngine/Transcription/LanguageCatalog.swift`; Test: `Tests/UnitTests/LanguageCatalogTests.swift` (replaces `WhisperLanguageCatalogTests.swift`)
- Delete: `Sources/PulsarTraceEngine/WhisperIPC/` (11 files), `Sources/pulsartrace-whisper/`, `Sources/CWhisper/`, `Sources/PulsarTraceEngine/Transcription/{WhisperTranscriber,ModelCatalog,ModelStore,WhisperLanguageCatalog,RegionTranscribing}.swift`, `scripts/build-whisper.sh`
- Modify: `Package.swift`, `.gitignore`, `Sources/pulsartrace-engine/main.swift`, `Sources/PulsarTraceEngine/Transcription/OfflineTranscriptionPipeline.swift`, `Sources/PulsarTraceEngine/Logging/Logging.swift`, `Sources/PulsarTraceEngine/Support/Doctor.swift`, `Sources/pulsartrace/DoctorCommand.swift`, `Sources/pulsartrace/RefineCommand.swift`, `Sources/pulsartrace-mac/SettingsView.swift`, `Sources/PulsarTraceMenuBar/{RecordingViewModel,AppEnvironment}.swift`, `Sources/PulsarTraceEngine/Refinement/Jobs/{RefinementJobQueue,SharedTranscriber}.swift` (cache-root swap / comments)
- Delete tests: `Tests/UnitTests/WhisperIPC/` (11 files), `Tests/UnitTests/{WhisperLanguageAllowListTests,WhisperRegionTests,ModelStoreTests,WhisperLanguageCatalogTests}.swift`, `Tests/PipelineTests/{WhisperAbortTests,WhisperSubprocessAcceptanceTests,TranscriptionPipelineTests,WhisperTestGate}.swift`, `Tests/PipelineTests/__Snapshots__/TranscriptionPipelineTests/`
- Adapt tests: `Tests/PipelineTests/{IPCTwoDaemonTests,LiveRunnerResilienceTests,RecordOrchestratorTests}.swift`, `Tests/UnitTests/DoctorTests.swift`, `Tests/MenuBarTests/RecordingViewModelTests.swift`

## Part A — preparation (everything still compiles with whisper present)

- [ ] **Step A1: Add `AppPaths.modelsCacheDirectory`**

In `Sources/PulsarTraceEngine/Support/AppPaths.swift`, after `applicationSupport`, add (same value `ModelStore.defaultCacheDirectory()` returns for the standard home, but derived from `home` like every other `AppPaths` member so tests can inject a temp root):

```swift
    /// Model cache root: `~/Library/Caches/PulsarTrace/models/` (D10). The
    /// CoreML bundles (Parakeet `parakeet-tdt-0.6b-v3-coreml/`, WhisperKit
    /// `whisperkit/`) live in SDK-managed subdirectories beneath it (D39).
    public var modelsCacheDirectory: URL {
        home.appendingPathComponent(
            "Library/Caches/PulsarTrace/models", isDirectory: true)
    }
```

While in the file: the `socketDirectory` doc comment cites whisper artifacts; in that comment replace `(capture's `<recordingId>-system.sock` ≈ 33 bytes; whisper's `w-<8hex>.sock` = 15 bytes)` with `(capture's `<recordingId>-system.sock` ≈ 33 bytes)` and replace `(events, speakers DB, whisper.lock, etc.)` with `(events, speakers DB, etc.)`.

- [ ] **Step A2: Swap every `ModelStore.defaultCacheDirectory()` call site**

Run: `grep -rn "ModelStore.defaultCacheDirectory" Sources/ Tests/`
Expected sites and replacements:
- `Sources/pulsartrace-engine/main.swift` (live, task 12's block) → `AppPaths.standard.modelsCacheDirectory` — also delete the "until task 16 replaces it" comment sentence there.
- `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift` (`makeStandard`'s `downloadBase`) → `paths.modelsCacheDirectory` (the `paths` parameter is in scope).
- `Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift` (`refine`'s `downloadBase`) → `paths.modelsCacheDirectory` (the stored property).
- `Sources/pulsartrace/DoctorCommand.swift` → leave; deleted in step C3.
- Tests (`Tests/PipelineTests/ParakeetTestEngine.swift`, `WhisperKitRefineTests.swift`, `RefinementPipelineTests.swift`, `SpeakerLibraryPipelineTests.swift`) → `AppPaths.standard.modelsCacheDirectory`.

Run: `swift build` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md — same for every build/test step below)
Expected: compiles.

- [ ] **Step A3: Create `LanguageCatalog` + tests; retire `WhisperLanguageCatalog`**

Create `Sources/PulsarTraceEngine/Transcription/LanguageCatalog.swift`:

```swift
import Foundation
import WhisperKit

/// The languages the transcription stack can decode/detect, surfaced for
/// the Settings UI's "Restrict to languages" multi-select and
/// `refine --language` validation.
///
/// Built from WhisperKit's language table (verified public, v1.0.0
/// `Models.swift:1327`: `@frozen public enum Constants { public static let
/// languages: [String: String] }`, display name → ISO-639-1 code, 99
/// entries) — the same fixed table whisper.cpp embedded, with no model
/// load required. Replaces the CWhisper-backed `WhisperLanguageCatalog`.
public enum LanguageCatalog {

    /// One known language. `code` is the ISO-639-1 short form the rest of
    /// the engine speaks (`WhisperOptions.allowedLanguages`,
    /// `--allowed-languages`, `refine --language`); `displayName` is
    /// capitalised for the picker.
    public struct Language: Sendable, Equatable, Hashable, Identifiable {
        public let code: String
        public let displayName: String
        public var id: String { code }

        public init(code: String, displayName: String) {
            self.code = code
            self.displayName = displayName
        }
    }

    /// Every language, sorted alphabetically by display name (the order
    /// the user reads them in the dropdown). Built once — static table.
    public static let all: [Language] = {
        WhisperKit.Constants.languages
            .map { Language(code: $0.value, displayName: $0.key.capitalized) }
            .sorted { $0.displayName < $1.displayName }
    }()

    /// Look up a language by its short code (`"en"`, `"pl"`). `nil` when
    /// the code isn't in the table.
    public static func language(forCode code: String) -> Language? {
        let needle = code.lowercased()
        return all.first { $0.code == needle }
    }
}
```

Create `Tests/UnitTests/LanguageCatalogTests.swift` (carries `WhisperLanguageCatalogTests`' assertions onto the new type — then `git rm Tests/UnitTests/WhisperLanguageCatalogTests.swift`):

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

/// Coverage of `LanguageCatalog` — the catalog the Settings UI's
/// "Restrict to languages" picker and `refine --language` validation read.
/// Values come from WhisperKit's static language table; we assert shape,
/// sort order, and that the codes the user typically picks are present.
@Suite("Language catalog")
struct LanguageCatalogTests {

    @Test("the catalog is non-empty and covers whisper's full table")
    func nonEmpty() {
        // Whisper ships ≈99 languages; assert a generous floor so a
        // truncation regression is loud without pinning the vendor's count.
        #expect(LanguageCatalog.all.count >= 90)
    }

    @Test("every entry has a non-empty lowercase code and a non-empty display name")
    func wellFormedEntries() {
        for lang in LanguageCatalog.all {
            #expect(!lang.code.isEmpty, "empty code in \(lang)")
            #expect(lang.code == lang.code.lowercased(),
                    "code should be lowercase: \(lang.code)")
            #expect(!lang.displayName.isEmpty, "empty display name for \(lang.code)")
        }
    }

    @Test("entries are sorted by display name")
    func sortedByDisplayName() {
        let names = LanguageCatalog.all.map(\.displayName)
        #expect(names == names.sorted())
    }

    @Test("the user's languages are present and look up by code")
    func commonLookups() {
        #expect(LanguageCatalog.language(forCode: "en")?.displayName == "English")
        #expect(LanguageCatalog.language(forCode: "pl")?.displayName == "Polish")
        #expect(LanguageCatalog.language(forCode: "PL")?.code == "pl")  // case-folded
        #expect(LanguageCatalog.language(forCode: "zz") == nil)
    }
}
```

(If `WhisperLanguageCatalogTests.swift` has assertions beyond these — read it first — carry them over with the type name swapped.)

Swap the two consumers:
- `Sources/pulsartrace-mac/SettingsView.swift`: replace every `WhisperLanguageCatalog` with `LanguageCatalog` (verified 3 sites: the popover's `ForEach`, the toggle-binding's catalog-order write at line ~193, and the summary lookup).
- `Sources/pulsartrace/RefineCommand.swift`: in `parse`, replace `WhisperLanguageCatalog.language(forCode: language) == nil` with `LanguageCatalog.language(forCode: language) == nil` and delete the "until task 17" NOTE comment from task 14.

Then: `git rm Sources/PulsarTraceEngine/Transcription/WhisperLanguageCatalog.swift Tests/UnitTests/WhisperLanguageCatalogTests.swift`

Run: `swift build`
Run: `swift test --filter LanguageCatalog`
Expected: PASS (4 tests).

- [ ] **Step A4: Commit the preparation**

```bash
git add -A
git commit -m "refactor: AppPaths.modelsCacheDirectory + WhisperKit-backed LanguageCatalog (pre-removal prep)"
```

## Part B — delete the whisper sources

- [ ] **Step B1: Delete the source trees and the build script**

```bash
git rm -r Sources/PulsarTraceEngine/WhisperIPC Sources/pulsartrace-whisper Sources/CWhisper
git rm Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift Sources/PulsarTraceEngine/Transcription/ModelCatalog.swift Sources/PulsarTraceEngine/Transcription/ModelStore.swift Sources/PulsarTraceEngine/Transcription/RegionTranscribing.swift scripts/build-whisper.sh
```

(`RegionTranscribing.swift` — verify first: `grep -rn "RegionTranscribing" Sources/ Tests/`; expected consumers are only `WhisperTranscriber`/`RemoteRegionTranscriber` (being deleted) and the old `makeStandard` shape task 13 already rewrote. If anything else conforms, keep the file and note why in the commit message.)

- [ ] **Step B2: Rewrite Package.swift (no CWhisper, no pulsartrace-whisper, no unsafeFlags)**

Replace the entire manifest with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulsarTrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PulsarTraceEngine", targets: ["PulsarTraceEngine"]),
        .library(name: "PulsarTraceMenuBar", targets: ["PulsarTraceMenuBar"]),
        .executable(name: "pulsartrace-engine", targets: ["pulsartrace-engine"]),
        .executable(name: "pulsartrace", targets: ["pulsartrace"]),
        .executable(name: "pulsartrace-capture", targets: ["pulsartrace-capture"]),
        .executable(name: "pulsartrace-mac", targets: ["pulsartrace-mac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        // ANE transcription backends (D39). Pinned exact: both projects
        // churn their APIs release-to-release. Bump deliberately, with the
        // release notes open.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
    ],
    targets: [
        // Core library: the engine, all AudioFrameSources, transcription
        // (Parakeet live / WhisperKit refine, both ANE — D39), logging,
        // events log, IPC.
        .target(
            name: "PulsarTraceEngine",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        // The streaming engine binary. Consumes an AudioFrameSource; runs
        // the live pass.
        .executableTarget(
            name: "pulsartrace-engine",
            dependencies: ["PulsarTraceEngine"]
        ),
        // The user-facing CLI. `refine`/`speakers`, plus `record`, `doctor`,
        // and `events tail`. Depends on PulsarTraceCapture so `doctor` can
        // read TCC permission state and `doctor --capture-test` can drive
        // the real capture path (R68).
        .executableTarget(
            name: "pulsartrace",
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // Real device capture. Owns AVFoundation (mic) and
        // ScreenCaptureKit (system audio) — the only code that needs TCC
        // grants — and writes 16 kHz mono Float32 frames to Unix domain
        // sockets the engine reads via `SocketSource`. Depends on
        // PulsarTraceEngine for the shared `FrameProtocol`/`AudioFrame` wire
        // types and the events log; it does not use the transcription stack.
        .target(
            name: "PulsarTraceCapture",
            dependencies: ["PulsarTraceEngine"]
        ),
        // The capture daemon binary. Thin wrapper over `DeviceCaptureSource`.
        .executableTarget(
            name: "pulsartrace-capture",
            dependencies: ["PulsarTraceCapture"]
        ),
        // The menubar UI logic. All ViewModels, settings persistence,
        // the recordings scanner, the live-transcript watcher, the speaker
        // editor — everything testable. No SwiftUI. `PulsarTraceCapture`
        // already depends on `PulsarTraceEngine`, so depending on both here
        // introduces no diamond (D27).
        .target(
            name: "PulsarTraceMenuBar",
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // The thin SwiftUI executable — `MenuBarExtra` + `Settings`
        // scenes bound to `PulsarTraceMenuBar`'s ViewModels. No logic, no
        // unit tests; exercised only by manual smoke test (D27).
        // `PulsarTraceEngine` is declared honestly: a few views name engine
        // types — static catalogs (`WhisperKitModelCatalog`,
        // `LanguageCatalog`, `AudioInputDevices`) and display types
        // (`RefinementJob`, `Speaker`, `EventWriter`) — but never construct
        // engine objects.
        .executableTarget(
            name: "pulsartrace-mac",
            dependencies: ["PulsarTraceMenuBar", "PulsarTraceEngine"]
        ),
        // Layer 1: unit tests — pure logic, <5s, no devices.
        .testTarget(
            name: "UnitTests",
            dependencies: [
                "PulsarTraceEngine",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            // Recorded snapshots are read by swift-snapshot-testing directly
            // from the source tree, not as bundle resources.
            exclude: ["__Snapshots__"]
        ),
        // Layer 2 + 4: pipeline + IPC integration tests, fixture-fed, no devices.
        // Audio fixtures live at the repo's `Tests/Fixtures/audio/` (PRD §12, project-docs/DECISIONS.md D6)
        // and are resolved by path relative to the test source file (#filePath)
        // rather than copied as bundle resources, so they are not duplicated.
        .testTarget(
            name: "PipelineTests",
            dependencies: [
                "PulsarTraceEngine",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
        // Layer 3: capture tests — require BlackHole; skip gracefully when absent.
        .testTarget(
            name: "CaptureTests",
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // Menubar UI logic tests — pure logic + temp-folder fixtures,
        // no devices, no real subprocesses (orchestration is behind an
        // injected seam).
        .testTarget(
            name: "MenuBarTests",
            dependencies: ["PulsarTraceMenuBar"]
        ),
    ]
)
```

Also remove the `vendor/` line from `.gitignore` (verified line 10).

- [ ] **Step B3: Build and fix every compile error with these edits**

Run: `swift build`
Fix, in whatever order the compiler surfaces them:

1. **`Sources/pulsartrace-engine/main.swift` — delete the `--transcribe` mode.** Remove the `} else if args.contains("--transcribe") { … }` branch in `main()`, the whole `static func transcribe(args:lifecycle:)`, the header doc-comment lines mentioning `--transcribe`/`--model`, and the usage examples for it. (One-shot offline transcription is `pulsartrace refine`'s job; this mode existed to exercise `WhisperTranscriber` directly.)
2. **`Sources/PulsarTraceEngine/Transcription/OfflineTranscriptionPipeline.swift`** — delete `run(source:transcriber:…)` and its `Output` struct (its only consumers were the engine's `--transcribe` mode and `TranscriptionPipelineTests`, both deleted). **Keep `accumulate(_:)`** — `RefinementPipeline` and tests use it. Verify: `grep -rn "OfflineTranscriptionPipeline" Sources/ Tests/` → remaining hits use `accumulate` only.
3. **`Sources/PulsarTraceEngine/Logging/Logging.swift`** — delete the `whisperSubprocess` label (and its doc comment) from `LogSubsystem`. Verify no consumers: `grep -rn "whisperSubprocess" Sources/ Tests/` → none.
4. **`Sources/PulsarTraceEngine/Support/Doctor.swift`** — delete `EnvironmentDoctor.modelCheck(name:present:)` (the pinned-ggml cache check; CoreML bundles are SDK-managed, presence-checking them is the SDKs' job).
5. **`Sources/pulsartrace/DoctorCommand.swift`** — delete the `// --- whisper model cache ---` block (the `ModelStore.defaultCacheDirectory()` + `ModelCatalog.all` loop, ~lines 54–61) and the `modelFilePresent` helper if now unused.
6. **`Sources/PulsarTraceMenuBar/RecordingViewModel.swift` — remove the whisper-lock probe seam.** Delete: the `waitForWhisperLockFree` stored property (~line 134), its init parameter + doc-comment entry (~lines 167, 188), the `self.waitForWhisperLockFree = waitForWhisperLockFree ?? {}` assignment (~line 202), and the whole `do { try await waitForWhisperLockFree() } catch { … }` block in `startRecording()` (~lines 272–290, including its "Phase 6 / Layer B" comment — the error-path UI it produced goes with it; there is no lock left to race).
7. **`Sources/PulsarTraceMenuBar/AppEnvironment.swift`** — delete the `lockProbePath` computation (~line 96) and the `waitForWhisperLockFree: { try await WhisperLockProbe.waitUntilFree(…) }` argument (~lines 108–111) from the `RecordingViewModel` construction.
8. **`Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift`** — the doc comment (~line 40) describes terminating the `pulsartrace-whisper` subprocess; reword that sentence to "which drops the cached transcriber so ARC frees its resources (for the WhisperKit actor: the resident CoreML models)".

Re-run `swift build` until clean.

## Part C — delete/adapt the whisper-coupled tests

(`SpeakerLibraryPipelineTests.swift` and `RefinementPipelineTests.swift` were already migrated off whisper in task 14 — nothing left to do for them here beyond step C6's grep confirming it. `Sources/pulsartrace/CLIMain.swift` was grep-verified to contain no whisper references — no edit needed.)

- [ ] **Step C1: Delete the dead test files**

```bash
git rm -r Tests/UnitTests/WhisperIPC Tests/PipelineTests/__Snapshots__/TranscriptionPipelineTests
git rm Tests/PipelineTests/WhisperAbortTests.swift Tests/PipelineTests/WhisperSubprocessAcceptanceTests.swift Tests/PipelineTests/TranscriptionPipelineTests.swift Tests/PipelineTests/WhisperTestGate.swift Tests/UnitTests/WhisperLanguageAllowListTests.swift Tests/UnitTests/WhisperRegionTests.swift Tests/UnitTests/ModelStoreTests.swift
```

Why each: `WhisperIPC/` tests the deleted IPC layer; `WhisperAbortTests`/`WhisperSubprocessAcceptanceTests` test the deleted subprocess; `TranscriptionPipelineTests` tested `WhisperTranscriber` whole-buffer decode + snapshot (superseded by `WhisperKitRefineTests` + the migrated `RefinementPipelineTests`); `WhisperTestGate` was the whisper.cpp single-context serializer + ggml model fetcher; `WhisperLanguageAllowListTests` tested `WhisperTranscriber.pickAllowedLanguage` (superseded by task 10's policy tests + task 06's hint tests); `WhisperRegionTests` was a manually-gated `WhisperTranscriber` region test; `ModelStoreTests` tested the deleted store.

- [ ] **Step C2: Adapt `IPCTwoDaemonTests.swift` (keep — capture-socket coverage)**

1. Suite doc comment: replace the `.serialized` rationale line ("whisper.cpp is single-context per process (D8)") with "`.serialized`: one resident ANE model serves the whole process (`ParakeetTestEngine`)".
2. In `twoSocketLivePass`: delete `let modelURL = try await WhisperTestGate.model(ModelCatalog.base)`; replace the gated run:

```swift
        let engine = try await ParakeetTestEngine.shared()
        let output = try await StreamingPipeline().run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_ipc-two-socket",
                liveDiarizerConfig: nil),
            systemTranscriber: ParakeetWindowTranscriber(engine: engine),
            micTranscriber: ParakeetWindowTranscriber(engine: engine),
            systemSource: systemSource,
            micSource: micSource,
            library: nil)
```

   Assertions unchanged.
3. In `pauseResumeGapAnnotation`: same pattern — delete the `modelURL` line and replace the gated run:

```swift
        let engine = try await ParakeetTestEngine.shared()
        let output = try await StreamingPipeline().run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_ipc-pause-resume",
                liveDiarizerConfig: nil),
            systemTranscriber: ParakeetWindowTranscriber(engine: engine),
            systemSource: ScriptedSource(events),
            library: nil)
```

   (The stream is pure silence + control events; the transcriber is VAD-gated upstream and barely runs.) Assertions unchanged.

- [ ] **Step C3: Adapt `LiveRunnerResilienceTests.swift` (keep — fakes stay fakes)**

Its whisper coupling (verified by grep): the `baseModelURL()` helper (line ~21), and six call sites of the pattern `try await WhisperTestGate.run { let t = try WhisperTestTranscriber.make(modelURL: modelURL) … }` (lines ~94, ~148–150, ~198, ~253–255, ~315, ~365). The wedge/fake transcribers in the file are local test doubles — leave them alone. Recipe, applied at each site:

1. Delete the `baseModelURL()` helper and every `let modelURL = try await baseModelURL()` line.
2. At each call site, hoist `let engine = try await ParakeetTestEngine.shared()` above the closure, replace each `try WhisperTestTranscriber.make(modelURL: modelURL)` with `ParakeetWindowTranscriber(engine: engine)`, and unwrap the `WhisperTestGate.run { … }` wrapper (keep the body verbatim; the suite stays `.serialized`).
3. Suite doc comment: replace the final paragraph ("each test constructs a `WhisperTranscriber` … `WhisperTestGate` serializes them") with "`.serialized`: tests share the process-wide resident `ParakeetEngine` (`ParakeetTestEngine`); serializing keeps the decode interleaving deterministic enough for the timing-shaped assertions."
4. Comment sweep inside the file: the remaining "whisper" mentions describe *the live transcriber* generically (e.g. "a wedged whisper decode never stalls the WAV recording") — reword "whisper" → "transcriber"/"decode" where it names the old backend; test names may keep their behaviour-shaped wording. Assertions unchanged.

- [ ] **Step C4: Adapt `RecordOrchestratorTests.swift` (comment only)**

The suite drives shell-script stand-ins, not whisper (verified). Update the comment block at ~lines 90–97: replace "The orchestrator's `engineEnvironment` field — added with the `PULSARTRACE_WHISPER_BINARY` thread-through fix — must merge…" with "The orchestrator's `engineEnvironment` field (the generic subprocess-environment seam; no production caller sets it today) must merge…". No code changes.

- [ ] **Step C5: Adapt `DoctorTests.swift` and `RecordingViewModelTests.swift`**

1. `Tests/UnitTests/DoctorTests.swift` (~lines 36–39): delete the `EnvironmentDoctor.modelCheck(...)` assertions (the API is gone).
2. `Tests/MenuBarTests/RecordingViewModelTests.swift`: the `waitForWhisperLockFree` seam is gone — delete the two tests that inject a throwing probe (`waitForWhisperLockFree: { throw ProbeTimeoutError() }`, ~lines 412 and 453, plus the `ProbeTimeoutError` helper and its doc comment ~line 391) and drop the no-op `waitForWhisperLockFree: { … }` argument at ~line 480 from the remaining test's constructor call.

- [ ] **Step C6: Build + grep sweep**

Run: `swift build`
Expected: clean. Then:

Run: `grep -rin "whisper" Sources/`
Enumerate the hits — every remaining one must be on this allowed list (anything else gets fixed now):
- `WhisperKit` SDK usage: `import WhisperKit`, `WhisperKitConfig`, `WhisperKit.Constants`, `DecodingOptions`, etc.
- Our `WhisperKit*` types: `WhisperKitModelCatalog`, `WhisperKitModel`, `WhisperKitRegionTranscriber`, `WhisperKitSegmentMapper`, `WhisperKitLanguagePolicy`, the `whisperkit` cache-folder path component, and comments naming them.
- `WhisperOptions` / `WhisperTranscribeError` and `whisperOptions:` parameter labels — renamed in task 17.
- `whisperModelName:` / `whisperModelSHA256:` parameters and `RefinementMetadata.whisperModel` — named for the frozen `metadata.json` schema field `whisper_model`; they stay (documented in D39).
- The `recording_started.model_live` event field docs in `Event.swift`/`ControlProtocol.swift` (they say "whisper model" — reword those two doc comments to "live model" while here).

Run: `grep -rn "PULSARTRACE_WHISPER_CPU" Sources/ Tests/`
Expected: only `WhisperOptions.defaultGPUEnabled` (its sole reader; the property is now consumer-less and task 17 deletes it). Anything else: delete it now.

- [ ] **Step C7: Full narrow-filter sweep**

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

(`--filter Transcription` is retired with `TranscriptionPipelineTests`; task 18 updates CLAUDE.md.) Any failure is handled per the CLAUDE.md test posture — fix, gate explicitly, or escalate; never move on red.

- [ ] **Step C8: Commit**

```bash
git add -A
git commit -m "feat!: remove whisper.cpp — CWhisper, pulsartrace-whisper, WhisperIPC, ModelStore/Catalog (D39)"
```

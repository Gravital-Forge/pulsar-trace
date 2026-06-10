# Maintainability Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the highest-carry-cost duplication and layering leaks identified in the 2026-06-09 maintainability review: the ~85%-duplicated Remote{Window,Region}Transcriber pair (+~600 lines of duplicated test fixtures), the dual-entry-point `RefinementPipeline`, the five-responsibility `LiveRunner.swift`, the `pulsartrace-mac` views reaching into engine internals, two silent production failure modes, and the Python private-import coupling.

**Architecture:** Pure refactors — no behavior changes, no public-API-surface changes (live.md/final.md/events are untouched). Each task is independently shippable and verified by the existing suites plus a few new unit tests where a seam becomes newly testable.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing, swift-log, Python 3.12 + pytest.

---

## Build/test commands (CLAUDE.md rules — read before running anything)

- `swift build` / `swift test --filter <X>` run BARE (no pipes, `;`, `&&`, redirects) with `dangerouslyDisableSandbox: true`. Everything else plain.
- Narrow filters only; never the broad `PipelineTests`. Relevant: `UnitTests`, `Refinement`, `Streaming`, `LiveRunner`, `Transcription`, `Speaker`, `IPC`, `MenuBar`, `FinalMarkdownRewriter`, `RecordOrchestrator`.
- Python: run `python/pulsartrace-ai/.venv/bin/pytest python/pulsartrace-ai/tests` (plain sandbox is fine — conftest forces HF offline mode).
- No failing tests, ever. Snapshot diffs = contract change = stop and justify.

## Locked decisions (from research; do not re-litigate)

1. **Boxes don't dissolve by moving.** The `EnqueueBox`/`AsyncCallBox`/`QueueReadyGate` indirection in `AppEnvironment` exists because of Swift definite-initialization (the `RecordingViewModel` closures need `self.queue`/`self.settings` before `self` is fully initialized), NOT because of module placement. Task 7 moves `AppEnvironment` AND replaces the three ad-hoc boxes with one named coordinator (`RefinementQueueHandle`) constructed *before* `RecordingViewModel`, which closures can capture directly.
2. **`assembleAndWrite` moves to a third home, not into `ResumableRefiner`.** Its three static helpers (`mergeStreams`/`writeFinalMarkdown`/`buildMetadata`) are also used by `RefinementPipeline.refine()` (the CLI path); moving them into `ResumableRefiner` would invert the dependency. They go to a new `TranscriptAssembly` enum; both callers delegate to it; `assembleAndWrite` drops from `public` to `internal` (no cross-module callers exist — verified).
3. **Hotkey stays AppKit-side.** `NSEvent.addGlobalMonitorForEvents` remains in `pulsartrace-mac` (a small `HotkeyController`); `PulsarTraceMenuBar` stays AppKit-monitor-free.
4. **`pulsartrace-mac` gains an explicit `PulsarTraceEngine` dependency** in Package.swift. Today it compiles via transitive leakage; views that legitimately enumerate static catalogs (`SettingsView`: `ModelCatalog.all`, `WhisperLanguageCatalog`; `RefinementsListView`: `RefinementJob` display) keep their imports honestly declared. The *constructing/deciding* leaks (SpeakerLibrary opening, model resolution for enqueue, `RecordingFolder.FileName` path-building) move behind the VM layer.
5. The `SerializingHostProxyTests.FakeWhisperHost` is structurally different (DecodeBehavior enum) — leave it alone in Task 4.

---

### Task 1: Silent-failure logging (two sites)

**Files:**
- Modify: `Sources/pulsartrace-engine/main.swift:259-262`
- Modify: `Sources/PulsarTraceCapture/SampleBufferConverter.swift`
- Test: none new (logging-only; no behavior change — verify by reading + suites stay green)

- [ ] **Step 1: main.swift — log the discarded SpeakerLibrary failure**

Current (lines 259–262):
```swift
// --- speaker library, READ-ONLY (R18/R32) ---------------------------
// The live pass only ever reads the library; only the post-pass writes.
let library = try? await SpeakerLibrary(
    databaseURL: AppPaths.standard.speakersDatabaseURL)
```
Replace with (the `logger` at line ~245 is in scope):
```swift
// --- speaker library, READ-ONLY (R18/R32) ---------------------------
// The live pass only ever reads the library; only the post-pass writes.
let library: SpeakerLibrary?
do {
    library = try await SpeakerLibrary(
        databaseURL: AppPaths.standard.speakersDatabaseURL)
} catch {
    // Live continues without name lookups, but a corrupt library must be
    // diagnosable — this was previously a silent `try?`.
    logger.error("speaker library unavailable for live pass — continuing without name lookups: \(PathRedactor.redactHome("\(error)"))")
    library = nil
}
```

- [ ] **Step 2: SampleBufferConverter — log once, not per frame**

Read the file (88 lines). The target has NO swift-log; `DeviceCaptureSource` logs via `FileHandle.standardError.write(Data("pulsartrace-capture: \(message)\n".utf8))`. Apply the same pattern, throttled to one line per failure kind per converter instance (this runs per audio frame — unbounded stderr spam is worse than silence):

```swift
    /// One-shot stderr breadcrumbs: conversion failures repeat per frame,
    /// so each failure kind logs once per converter instance.
    private var loggedInitFailure = false
    private var loggedConvertFailure = false
```
At the `converter = try? AudioConverter(inputFormat: pcm.format)` site: on nil, if `!loggedInitFailure` set it and write `"pulsartrace-capture: audio converter init failed — dropping frames for this format\n"` to standardError. At the `return (try? converter.convert(pcm)) ?? []` site: rework to a `do/catch` that, on first failure, sets `loggedConvertFailure` and writes `"pulsartrace-capture: audio conversion failed — frame dropped\n"`, returning `[]`. Adapt to the actual struct/class mutability (if it's a struct used by value, make the flags work — e.g. the type may need to become a small final class or the flags `private var` with `mutating` methods; read the call sites in DeviceCaptureSource first and keep the call shape unchanged). NEVER include format details that could stall the audio path; strings stay static.

- [ ] **Step 3: Build + run capture-adjacent suites**

Bare with dangerouslyDisableSandbox: `swift build`, then `swift test --filter UnitTests`, `swift test --filter Source`, `swift test --filter RecordOrchestrator`.

- [ ] **Step 4: Commit**
```bash
git add Sources/pulsartrace-engine/main.swift Sources/PulsarTraceCapture/SampleBufferConverter.swift
git commit -m "fix: log silent failures in live speaker-library open and audio sample conversion"
```

---

### Task 2: Extract `TranscriptAssembly`; retire the static/instance duplication

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/TranscriptAssembly.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift` (remove `assembleAndWrite` lines ~777-866, statics `mergeStreams` ~519-615, `writeFinalMarkdown` ~647-680, `buildMetadata` ~712-749; keep thin instance methods delegating to TranscriptAssembly)
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift:342` (call site)
- Test: existing `Refinement` + `FinalMarkdownRewriter` suites (no new tests — pure move; the suites cover both paths)

- [ ] **Step 1: Create TranscriptAssembly.swift**

New `enum TranscriptAssembly` (internal) receiving, verbatim, the moved static implementations:
- `static func mergeStreams(systemSegments:diarization:reconciliation:micSegments:recordingStart:) -> MergedTranscript` (was `RefinementPipeline` private static, lines 519–615)
- `static func writeFinalMarkdown(_:folder:) throws -> FinalWriteResult` (was lines 647–680)
- `static func buildMetadata(folder:speakers:speakerIdByLabel:language:diarization:recordingStart:refinedAt:whisperModelName:whisperModelSHA256:sourceBasename:audioDurationSeconds:) -> RefinementMetadata` (was lines 712–749)
- `static func assembleAndWrite(folder:systemSegments:micSegments:diarization:language:whisperModelName:whisperModelSHA256:recordingStart:sourceBasename:library:refinedAt:events:) async throws -> AssembleResult` (was `public static` on RefinementPipeline, lines 777–866) — **access drops to `internal`**; keep its doc comment but delete the "NOT a stable public API" disclaimer sentence (internal now says it).

Move the result types ONLY if they were private to RefinementPipeline and used solely by the moved code (`MergedTranscript`, `FinalWriteResult`, `AssembleResult` — check each: if `refine()` still touches them, leave them where the compiler is happiest; prefer moving them next to their only producers). `RefinementMetadata` stays where it is (broader use).

- [ ] **Step 2: Rewire the two consumers**

In `RefinementPipeline`: the instance methods `mergeStreams`/`writeFinalMarkdown`/`buildMetadata` (lines ~507-515, ~639-644, ~684-709) now delegate to `TranscriptAssembly.…` instead of `Self.…`; delete the moved statics. Delete `assembleAndWrite` entirely from this file.
In `ResumableRefiner.swift:342`: `RefinementPipeline.assembleAndWrite(` → `TranscriptAssembly.assembleAndWrite(` (argument list unchanged).
Update the doc-comment references in `OfflineRefiner.swift` and `RefinementJobError.swift` that mention `RefinementPipeline.assembleAndWrite` (comment-only, grep for `assembleAndWrite`).

- [ ] **Step 3: Verify**

Bare with dangerouslyDisableSandbox: `swift build`, `swift test --filter Refinement` (70 tests — covers ResumableRefiner incl. the "library passes through to assembleAndWrite" test), `swift test --filter FinalMarkdownRewriter`, `swift test --filter UnitTests`.

- [ ] **Step 4: Commit**
```bash
git add Sources/PulsarTraceEngine/Refinement
git commit -m "refactor: extract TranscriptAssembly; single home for merge/write/metadata used by CLI and resumable paths"
```

---

### Task 3: LiveRunner decomposition (file moves + DiarBufferManager)

**Files:**
- Create: `Sources/PulsarTraceEngine/Streaming/LiveSupportActors.swift` (or one file per actor — implementer's call; prefer `DiarGate.swift`, `DiarState.swift`, `LiveSink.swift`, `WorkerLanguageResult.swift` for findability)
- Create: `Sources/PulsarTraceEngine/Streaming/DiarBufferManager.swift`
- Create: `Tests/UnitTests/DiarBufferManagerTests.swift`
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift`

- [ ] **Step 1: Move the four support actors out (mechanical)**

Move, unchanged, from `LiveRunner.swift` to their own files in `Streaming/`: `WorkerLanguageResult` (lines 832–851), `DiarGate` (864–891), `DiarState` (895–918), `LiveSink` (925–1038). All are already `internal`-compatible (DiarGateTests / LiveRunnerLibraryLookupTests / StreamingPipelineTests use `@testable import`). Keep doc comments. `StreamerBox`/`UncheckedSendableBox` STAY in LiveRunner.swift (single-file details).

Run bare: `swift build`, `swift test --filter UnitTests`, `swift test --filter LiveRunner`. Commit:
```bash
git add Sources/PulsarTraceEngine/Streaming Tests
git commit -m "refactor: move DiarGate/DiarState/LiveSink/WorkerLanguageResult out of LiveRunner.swift"
```

- [ ] **Step 2: Write failing DiarBufferManager tests**

`Tests/UnitTests/DiarBufferManagerTests.swift`:
```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// The live diarization sliding-window buffer (Fix B/C): cadence-gated
/// window emission and bounded memory via trim.
@Suite("DiarBufferManager")
struct DiarBufferManagerTests {

    // 16 kHz mono — windows in samples for readable tests.
    private let step = 16_000      // 1 s cadence
    private let window = 48_000    // 3 s window

    @Test("no window until the buffer reaches one full window")
    func noWindowBeforeFill() {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        #expect(mgr.append([Float](repeating: 0, count: window - 1)) == nil)
    }

    @Test("first window emits at fill, covering the last `window` samples")
    func firstWindowAtFill() {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        let req = mgr.append([Float](repeating: 0, count: window))
        let unwrapped = try? #require(req)
        #expect(unwrapped?.samples.count == window)
        #expect(unwrapped?.startSampleIndex == 0)
    }

    @Test("next window only after a full step of new audio")
    func cadenceGating() {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        _ = mgr.append([Float](repeating: 0, count: window))
        #expect(mgr.append([Float](repeating: 0, count: step - 1)) == nil)
        let req = mgr.append([Float](repeating: 0, count: 1))
        #expect(req != nil)
        #expect(req?.startSampleIndex == step)
    }

    @Test("buffer is trimmed to 2x window; absolute indexing survives the trim")
    func trimKeepsAbsoluteIndexing() {
        var mgr = DiarBufferManager(stepSamples: step, windowSamples: window)
        var last: DiarBufferManager.WindowRequest?
        for _ in 0..<20 {                       // 20 s of audio
            if let req = mgr.append([Float](repeating: 0, count: step)) {
                last = req
            }
        }
        #expect(mgr.bufferedSampleCount <= 2 * window)
        // 20 steps of 16k = 320k total samples; the last window starts at
        // total - window.
        #expect(last?.startSampleIndex == 20 * step - window)
        #expect(last?.samples.count == window)
    }
}
```
Run bare: `swift test --filter DiarBufferManager` — expect compile failure (type missing).

- [ ] **Step 3: Implement DiarBufferManager and rewire LiveRunner**

`Sources/PulsarTraceEngine/Streaming/DiarBufferManager.swift`:
```swift
/// Sliding-window sample buffer for live diarization (Fix B/C extracted
/// from LiveRunner.run()):
///  - emits a `WindowRequest` only when ≥ `stepSamples` of new audio have
///    arrived since the previous emission AND at least one full window is
///    buffered (cadence gating);
///  - trims the buffer to 2× the window so memory stays bounded over an
///    arbitrarily long meeting, tracking the recording-absolute base index
///    so window start positions survive the trim.
///
/// Synchronous and unaware of DiarGate/Tasks: the single-in-flight bound
/// stays at the call site (it awaits an actor).
struct DiarBufferManager {
    struct WindowRequest {
        let samples: [Float]
        /// Recording-absolute index of `samples[0]`.
        let startSampleIndex: Int
    }

    private var buffer: [Float] = []
    private var base = 0          // recording-absolute index of buffer[0]
    private var lastWindowEnd = 0 // absolute index when the last window emitted
    private let stepSamples: Int
    private let windowSamples: Int

    var bufferedSampleCount: Int { buffer.count }

    init(stepSamples: Int, windowSamples: Int) {
        self.stepSamples = stepSamples
        self.windowSamples = windowSamples
    }

    mutating func append(_ samples: [Float]) -> WindowRequest? {
        buffer.append(contentsOf: samples)
        let total = base + buffer.count

        var request: WindowRequest?
        if total - lastWindowEnd >= stepSamples, total >= windowSamples {
            let loAbs = max(0, total - windowSamples)
            let lo = loAbs - base
            lastWindowEnd = total
            if lo >= 0, lo <= buffer.count {
                request = WindowRequest(
                    samples: Array(buffer[lo...]),
                    startSampleIndex: loAbs)
            }
        }

        // Trim on every append, not only on emission (Fix C).
        let keep = 2 * windowSamples
        if buffer.count > keep {
            let trim = buffer.count - keep
            buffer.removeFirst(trim)
            base += trim
        }
        return request
    }
}
```
Rewire `LiveRunner.run()`'s `case .frame(.system, …)` block (lines ~417-485): replace `diarBuffer`/`diarBufferBase`/`lastDiarEnd` and the inline window/trim logic with one `var diarBuffers = DiarBufferManager(stepSamples: diarStep, windowSamples: diarWindow)` and:
```swift
if let liveDiarizer, let req = diarBuffers.append(frame.samples) {
    phase.set("await-diarGate-tryAcquire")
    if await diarGate.tryAcquire() {
        let windowStart = samplesToDuration(req.startSampleIndex)
        Task.detached {
            let spans = await liveDiarizer.diarizeWindow(
                samples: req.samples, windowStart: windowStart)
            await diarState.merge(spans)
            await diarGate.release()
        }
    }
} else if liveDiarizer == nil {
    _ = diarBuffers.append(frame.samples)   // keep trim behavior identical
}
```
CAREFUL — semantic parity notes: (a) in the old code the cadence marker `lastDiarEnd = diarTotalSamples` advanced even when `tryAcquire()` failed; the manager emits the request BEFORE the gate check, so parity holds. (b) The old code appended to the buffer regardless of `liveDiarizer` presence — preserve that (the `else if` arm). (c) `diarBufferProbe?(diarBuffer.count)` becomes `diarBufferProbe?(diarBuffers.bufferedSampleCount)` — keep its position at the end of the frame case. Read the original block carefully and keep ordering identical; if any subtlety contradicts these notes, STOP and report rather than guessing.

- [ ] **Step 4: Verify**

Bare with dangerouslyDisableSandbox: `swift test --filter DiarBufferManager`, `swift test --filter UnitTests`, `swift test --filter LiveRunner`, `swift test --filter Streaming`, `swift test --filter DiarizationE2E`.

- [ ] **Step 5: Commit**
```bash
git add Sources/PulsarTraceEngine/Streaming Tests/UnitTests/DiarBufferManagerTests.swift
git commit -m "refactor: extract DiarBufferManager from LiveRunner.run() with unit coverage"
```

---

### Task 4: Shared test support (kills 5x CapturingLogHandler + IPC fake duplication + deprecation warnings)

**Files:**
- Create: `Tests/UnitTests/TestSupport/CapturingLogHandler.swift`
- Create: `Tests/UnitTests/WhisperIPC/WhisperIPCTestSupport.swift`
- Modify (delete private copies, switch to shared): `Tests/UnitTests/LiveRunnerPhaseTrackerTests.swift` (187–213), `Tests/UnitTests/StreamingTranscriberUnitTests.swift` (219–233), `Tests/UnitTests/WhisperIPC/RemoteWindowTranscriberTests.swift` (FakeHost 469–530, millis 532, SingleHostFactory 539–553, SequencedHostFactory 558–594, ThrowingStartHost 598–612, CapturingLogHandler 616–630, decodedResponse 459–464), `Tests/UnitTests/WhisperIPC/RemoteRegionTranscriberTests.swift` (same family, 615–790), `Tests/UnitTests/WhisperIPC/WhisperSubprocessHostTests.swift` (CapturingDrainLogHandler 222–236)

- [ ] **Step 1: Shared CapturingLogHandler — implementing `log(event:)` directly**

`Tests/UnitTests/TestSupport/CapturingLogHandler.swift`:
```swift
import Foundation
import Logging

/// Lock-protected log sink shared by every suite that asserts on log
/// content. Implements the current `log(event:)` requirement directly —
/// the per-file copies this replaces all leaned on swift-log's deprecated
/// forwarding shim and warned on every build.
final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    var messages: [String] { lock.withLock { _messages } }

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        lock.withLock { _messages.append(event.message.description) }
    }
}
```
Check the vendored swift-log's `LogEvent` member names (`.build/checkouts/swift-log/Sources/Logging/LogHandler.swift`) and adjust `event.message` access if needed. If the old flat `log(level:message:…)` is still a hard protocol requirement (not defaulted in terms of `log(event:)`), implement it as a one-line forward into the same sink — the goal is zero deprecation warnings; verify with a clean `swift build` (no `DeprecatedDeclaration` warnings from these files).

- [ ] **Step 2: Shared IPC fakes**

`Tests/UnitTests/WhisperIPC/WhisperIPCTestSupport.swift` containing, consolidated from the Window/Region copies (take the Region variants as the superset):
- `final class FakeHost: WhisperHostProtocol, @unchecked Sendable` — WITH the `lastRequest: WhisperIPCRequest?` recording (Region's version; Window tests simply won't read it)
- `final class SingleHostFactory` / `final class SequencedHostFactory` / `final class ThrowingStartHost` — using the underlying function type or `RemoteWindowTranscriber.HostFactory` (both typealiases resolve to `@Sendable (WhisperSubprocessHost.Configuration, Logger) -> WhisperHostProtocol`; pick the concrete function type to avoid favoring either transcriber)
- `func millis(_ d: Duration) -> Int` (test-side helper)
- `func decodedResponse() -> WhisperIPCDecoded` (the canned "ok" payload)
Copy implementations verbatim from `RemoteRegionTranscriberTests.swift` (627–773) — they are the superset — then delete BOTH files' private copies and the Window file's, fix references. Delete the `CapturingLogHandler`/`CapturingDrainLogHandler` private copies in all five files, switching to the shared one (rename uses of `CapturingDrainLogHandler` accordingly; LiveRunnerPhaseTracker's copy used `_messages` — same shape).
DO NOT touch `SerializingHostProxyTests.FakeWhisperHost` (different design, locked decision #5).

- [ ] **Step 3: Verify — including the warning count**

Bare with dangerouslyDisableSandbox: `swift build` (confirm the five `DeprecatedDeclaration` LogHandler warnings are GONE and no new warnings appear), then `swift test --filter UnitTests`, `swift test --filter LiveRunner`, `swift test --filter Transcription`.

- [ ] **Step 4: Commit**
```bash
git add Tests/UnitTests
git commit -m "test: shared CapturingLogHandler + WhisperIPC fakes; drop five duplicated copies and the LogHandler deprecation warnings"
```

---

### Task 5: Extract `RemoteTranscriberCore`

**Files:**
- Create: `Sources/PulsarTraceEngine/WhisperIPC/RemoteTranscriberCore.swift`
- Modify: `Sources/PulsarTraceEngine/WhisperIPC/RemoteWindowTranscriber.swift`, `Sources/PulsarTraceEngine/WhisperIPC/RemoteRegionTranscriber.swift`
- Test: existing `RemoteWindowTranscriberTests` / `RemoteRegionTranscriberTests` / `SerializingHostProxyTests` must pass UNCHANGED (they pin the public behavior); no public API change.

The shared-member map (from research — IDENTICAL byte-for-byte unless noted):
`lock`/`host`/`shutdownLatched` state; `shutdown()`; `ensureHostStarted()`; `currentHostOrThrow()`; `sigkillCurrentHost()`; `handleHostError(_:)` (differs only in one log-message string); `respawnWithBackoffLog()` (Window wraps the deadline read in a pointless `respawnDeadline_()` helper — drop it); `toModelLoadFailed(_:)` (identical private static); `HostFactory` typealias (identical). Differences that stay in the wrappers: Configuration structs (Window has `lockPath`/`spawnTimeout` fields; Region hard-codes them), `startHost()`'s host-config construction, the transcribe entry points (decodeWindow vs decodeRegion + Region's slice/shift logic), `makeResult` variants, Region's `sampleIndex`.

- [ ] **Step 1: Create the Core**

```swift
/// Shared host-lifecycle engine behind RemoteWindowTranscriber and
/// RemoteRegionTranscriber: lazy start, decode-deadline kill + respawn
/// with throttled backoff logging, latched shutdown. The wrappers own
/// their Configuration and request/response mapping; the Core owns the
/// host and every failure-mode policy, so a respawn bug is fixed once.
///
/// `@unchecked Sendable`: `host`/`shutdownLatched` are guarded by `lock`,
/// same invariant the two wrappers documented individually.
final class RemoteTranscriberCore: @unchecked Sendable {
    typealias HostFactory = @Sendable (
        WhisperSubprocessHost.Configuration, Logger
    ) -> WhisperHostProtocol

    struct Policy {
        let hostConfiguration: WhisperSubprocessHost.Configuration
        let modelPath: String
        let respawnDeadline: Duration
        let logBackoffInitial: Duration
        let logBackoffCap: Duration
        /// Log line emitted when a decode deadline forces a kill+respawn —
        /// the one string that differed between the two transcribers.
        let deadlineKillMessage: String
    }

    private let policy: Policy
    private let logger: Logger
    private let hostFactory: HostFactory
    private let lock = NSLock()
    private var host: WhisperHostProtocol?
    private var shutdownLatched = false

    init(policy: Policy, logger: Logger, hostFactory: @escaping HostFactory) { … }

    func ensureHostStarted() throws { … }          // moved verbatim
    func currentHostOrThrow() throws -> WhisperHostProtocol { … }
    func handleHostError(_ error: WhisperSubprocessHost.HostError) throws { … }
    func shutdown() { … }
    static func toModelLoadFailed(_ e: WhisperSubprocessHost.HostError) -> WhisperTranscribeError { … }
    private func startHost() throws { … }          // uses policy.hostConfiguration + policy.modelPath
    private func sigkillCurrentHost() { … }
    private func respawnWithBackoffLog() throws { … }  // uses policy.respawnDeadline directly
}
```
Move the bodies verbatim from `RemoteWindowTranscriber` (the de-duplicated reference copy), substituting `configuration.X` reads with `policy.X` and the hard-coded log string with `policy.deadlineKillMessage`. Read both originals first; if any body differs beyond the documented two points (log string, `respawnDeadline_()` wrapper), STOP and report the difference instead of picking one silently.

- [ ] **Step 2: Gut the wrappers**

Each transcriber keeps: its `public struct Configuration` (UNCHANGED — public API), its protocol conformance and transcribe entry point, its `makeResult` (+ Region's `sampleIndex`), its `public init` (UNCHANGED signature — builds the Core internally):
```swift
public init(configuration: Configuration, logger: Logger = …, hostFactory: @escaping HostFactory = …) {
    self.configuration = configuration
    self.core = RemoteTranscriberCore(
        policy: .init(
            hostConfiguration: WhisperSubprocessHost.Configuration(
                binaryURL: configuration.binaryURL,
                socketDirectory: configuration.socketDirectory,
                lockPath: configuration.lockPath,          // Region: nil
                forceCPU: configuration.forceCPU,
                spawnTimeout: configuration.spawnTimeout), // Region: .seconds(10)
            modelPath: configuration.modelURL.path,
            respawnDeadline: configuration.respawnDeadline,
            logBackoffInitial: configuration.logBackoffInitial,
            logBackoffCap: configuration.logBackoffCap,
            deadlineKillMessage: "whisper decode exceeded deadline; killing subprocess for respawn stream=remote"),
        logger: logger,
        hostFactory: hostFactory)
}
```
(Match the EXACT current `WhisperSubprocessHost.Configuration` construction each transcriber performs today, including `initTimeout`/`extraArgs` if set — read `startHost()` in both before writing this.) The public `HostFactory` typealiases stay on the wrappers (public API) and convert trivially to the Core's. `shutdown()`/`deinit` delegate to `core.shutdown()`. The transcribe entry points keep their existing request/decode/catch structure but call `core.ensureHostStarted()` / `core.currentHostOrThrow()` / `core.handleHostError(_:)` / `Self`→`RemoteTranscriberCore.toModelLoadFailed`.

- [ ] **Step 3: Verify — the tests are the contract**

Bare with dangerouslyDisableSandbox: `swift build` (no new warnings), `swift test --filter RemoteWindowTranscriber`, `swift test --filter RemoteRegionTranscriber`, `swift test --filter SerializingHostProxy`, `swift test --filter UnitTests`, `swift test --filter Refinement`, `swift test --filter LiveRunner`. ALL must pass with ZERO test-file changes (if a test needs changing, the refactor changed behavior — stop and fix the refactor).

- [ ] **Step 4: Commit**
```bash
git add Sources/PulsarTraceEngine/WhisperIPC
git commit -m "refactor: extract RemoteTranscriberCore; respawn/backoff/shutdown policy now has one home"
```

---

### Task 6: Python `_common.py` + typed live request validation

**Files:**
- Create: `python/pulsartrace-ai/pulsartrace_ai/_common.py`
- Modify: `python/pulsartrace-ai/pulsartrace_ai/diarize.py`, `python/pulsartrace-ai/pulsartrace_ai/live_diarize.py`
- Test: `python/pulsartrace-ai/tests/` (existing must pass; add one test for the missing-field error path)

- [ ] **Step 1: Create `_common.py`**

Move from `diarize.py` into `_common.py` (verbatim, with their imports): `DiarizationError`, `Span`, `_seed_everything`, `_model_revision`, `_annotation_to_spans`, `_wav_duration_seconds`. In `diarize.py`, re-export for the public names so existing imports keep working (`tests/test_diarize.py` imports `DiarizationError` from `diarize`; `conftest.py` imports `load_pipeline`):
```python
from pulsartrace_ai._common import (  # noqa: F401 — public re-exports
    DiarizationError,
    Span,
    _annotation_to_spans,
    _model_revision,
    _seed_everything,
    _wav_duration_seconds,
)
```
(Plain re-import is enough; keep `load_pipeline` in `diarize.py`.) In `live_diarize.py`: change the `from pulsartrace_ai.diarize import …` block (lines 83–90) to import the private helpers from `pulsartrace_ai._common` (keep `load_pipeline` from `diarize`), and DELETE the dead local `_wav_duration_seconds` copy (lines 93–98 — verified never called in that file).

- [ ] **Step 2: Typed request validation in the live loop**

In `live_diarize.py`'s stdin loop (~lines 196–216), replace the bare `request["window_wav"]` with explicit validation that still degrades to an `{"error": …}` response (the broad except stays as the outer safety net):
```python
        request = json.loads(line)
        if "window_wav" not in request:
            raise DiarizationError("request missing required field: window_wav")
        window_wav = Path(request["window_wav"])
```

- [ ] **Step 3: Add the error-path test**

In `tests/test_live_diarize.py`, add a test that feeds the loop-level helper (or, if the loop isn't directly callable, tests the validation by invoking whatever unit the file exposes — read the existing test's structure first; if only `diarize_window` is importable, refactor the request-validation into a small `def _parse_request(request: dict) -> tuple[Path, float]` so it's unit-testable, and test THAT):
```python
def test_parse_request_missing_window_wav() -> None:
    with pytest.raises(DiarizationError, match="window_wav"):
        _parse_request({})
```

- [ ] **Step 4: Verify**

Run `python/pulsartrace-ai/.venv/bin/pytest python/pulsartrace-ai/tests` (plain). All green. Also run bare `swift test --filter DiarizationE2E` with dangerouslyDisableSandbox (the Swift side spawns the real Python — proves the import re-wiring didn't break the subprocess).

- [ ] **Step 5: Commit**
```bash
git add python/pulsartrace-ai
git commit -m "refactor(python): shared _common module ends private cross-imports; validate live request fields"
```

---

### Task 7: Move `AppEnvironment` into PulsarTraceMenuBar; coordinator replaces the boxes; views stop constructing engine objects

**Files:**
- Create: `Sources/PulsarTraceMenuBar/AppEnvironment.swift`
- Create: `Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift`
- Create: `Sources/pulsartrace-mac/HotkeyController.swift`
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift` (shrinks to App struct + scenes + HotkeyController wiring + menuBarSymbol extension)
- Modify: `Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift` (+ static `load` factory), `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift` (model-resolving enqueue), `Sources/PulsarTraceMenuBar/RecordingEntry.swift` (finalURL/liveURL)
- Modify: `Sources/pulsartrace-mac/SpeakerEditorView.swift`, `Sources/pulsartrace-mac/RecordingsListView.swift`
- Modify: `Package.swift` (pulsartrace-mac deps += "PulsarTraceEngine")
- Test: `Tests/MenuBarTests` (existing green; add `RefinementQueueHandleTests`)

- [ ] **Step 1: `RefinementQueueHandle` (replaces EnqueueBox + 2×AsyncCallBox + QueueReadyGate)**

`Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift` — a single `final class RefinementQueueHandle: @unchecked Sendable` constructed BEFORE `RecordingViewModel` (so closures capture IT, not `self`):
```swift
/// Hands the recording flow a queue that doesn't exist yet.
///
/// `RecordingViewModel` needs enqueue/pause/resume closures at init time,
/// but the real `RefinementJobQueue` is built asynchronously during
/// bootstrap. This handle is created first, captured by those closures,
/// and later `install(_:)`-ed with the real queue; callers arriving
/// before that suspend in `awaitReady()` (CheckedContinuation queue —
/// the same gate the old QueueReadyGate provided, now with the enqueue
/// plumbing in one named type instead of three anonymous boxes).
@MainActor public final class RefinementQueueHandle {
    private var queue: RefinementJobQueue?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReady = false

    public init() {}

    public func install(_ queue: RefinementJobQueue) {
        self.queue = queue
        isReady = true
        let waiters = readyWaiters
        readyWaiters = []
        for w in waiters { w.resume() }
    }

    public func awaitReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    public func enqueueAutoRefine(folderURL: URL, recordingId: String, modelName: String) async {
        await awaitReady()
        guard let queue else { return }
        // (mirror the exact enqueue call the old EnqueueBox impl made —
        // read PulsarTraceMacApp.swift:248-276 and reproduce it, including
        // the ModelCatalog resolution currently done with settings.refineModelName)
    }

    public func pauseForRecording() async { await awaitReady(); await queue?.pauseForRecording() }
    public func resumeAfterRecording() async { await awaitReady(); await queue?.resumeAfterRecording() }
}
```
NOTE the old boxes were `@unchecked Sendable` classes with NSLock; this version is `@MainActor` instead — simpler and correct IF all callers tolerate main-actor hops (the closures are called from `RecordingViewModel` which is `@MainActor`). Verify the old `enqueueBox.impl` body (PulsarTraceMacApp.swift:248-276): it ran off-main (`@Sendable`) and hopped via `MainActor.run`. Reproduce the SAME external behavior; if the closure types passed to `RecordingViewModel.init` are `@Sendable () async -> Void`, a `@MainActor` handle works (`await` hops). Pause/resume previously did NOT await readiness (they read `self?.queue` and no-opped when nil — preserve that: a pause arriving pre-bootstrap should no-op, not suspend; adjust `pauseForRecording`/`resumeAfterRecording` to `guard isReady else { return }` instead of awaiting). Write `Tests/MenuBarTests/RefinementQueueHandleTests.swift` first: (1) enqueue before install suspends and completes after install; (2) pause before install is a no-op that returns immediately; (3) install resumes all pending waiters.

- [ ] **Step 2: Move `AppEnvironment`**

Create `Sources/PulsarTraceMenuBar/AppEnvironment.swift`: move the class (PulsarTraceMacApp.swift lines 137–426) minus the AppKit pieces. It becomes `public` (`@MainActor @Observable public final class AppEnvironment`) with `public` accessors for the properties the App struct injects (`settings`, `recording`, `scanner`, `liveWatcher`, `onboarding`, `navigation`, `events`, `queueVM`). Replace the three boxes with one `RefinementQueueHandle` created at the top of `init()` (before `RecordingViewModel`), closures referencing it directly — the box classes and `queueReady` are deleted. `bootstrap()` ends with `queueHandle.install(q)` instead of `queueReady.signal()`. `installHotkeyMonitor`/`hotkeyMonitor`/`hotkeyToggleTask`/`toggleRecording` DO NOT move (Step 3). `startLiveWatcherWiring()` moves as-is. `AppNavigation`/`WindowID`/`AppSection`: move `AppNavigation` + `AppSection` to PulsarTraceMenuBar if `WindowID` references untangle cleanly (WindowID strings used by App scenes can stay in pulsartrace-mac); if they don't untangle in 15 minutes, leave navigation where it is and note it — NOT worth a yak-shave.

- [ ] **Step 3: `HotkeyController` in pulsartrace-mac**

`Sources/pulsartrace-mac/HotkeyController.swift`: `@MainActor final class HotkeyController` holding `hotkeyMonitor: Any?` + `toggleTask: Task<Void, Never>?`, with `install(settings: MenuBarSettings, recording: RecordingViewModel)` containing the moved `NSEvent.addGlobalMonitorForEvents` body and the moved `toggleRecording()` switch. `PulsarTraceMacApp` owns one instance (`@State`) and calls `install` where `installHotkeyMonitor()` was called. Behavior identical (same keyCode/modifier matching, same debounce task handling).

- [ ] **Step 4: Views stop constructing engine objects**

(a) `SpeakerEditorViewModel` gains the factory the view currently inlines (move the body of `SpeakerEditorView.loadLibrary()`, lines 376–389):
```swift
    /// Opens the speaker library at the standard path and returns a ready
    /// VM — the one place the editor flow touches AppPaths/SpeakerLibrary.
    public static func load(
        events: EventWriter?, settings: MenuBarSettings
    ) async throws -> SpeakerEditorViewModel {
        let library = try await SpeakerLibrary(
            databaseURL: AppPaths.standard.speakersDatabaseURL, events: events)
        let vm = SpeakerEditorViewModel(library: library, events: events, settings: settings)
        await vm.reload()
        return vm
    }
```
`SpeakerEditorView.loadLibrary()` becomes a thin `do { viewModel = try await SpeakerEditorViewModel.load(events: events, settings: settings) } catch { loadError = PathRedactor.redactHome("\(error)") }` — note the redaction, fixing the raw `"\(error)"` while we're here. Remove `import PulsarTraceEngine` from SpeakerEditorView IF nothing else in the file needs it (grep the file; `EventWriter` in the view's stored property still needs the import — if so, keep the import but the construction leak is still gone; report which).
(b) `RefinementJobQueueViewModel` gains:
```swift
    /// Resolve the refine model by settings name and enqueue — moves the
    /// ModelCatalog lookup out of RecordingsListView.
    public func enqueueManual(folderURL: URL, recordingId: String, refineModelName: String) async {
        let model = ModelCatalog.model(named: refineModelName) ?? ModelCatalog.base
        await enqueueManual(folderURL: folderURL, recordingId: recordingId,
                            modelName: model.name, modelSHA256: model.sha256)
    }
```
`RecordingsListView` (lines 103–109) calls the new overload with `settings.refineModelName`; its `ModelCatalog` use disappears.
(c) `RecordingEntry` (PulsarTraceMenuBar) gains `public var finalURL: URL` / `public var liveURL: URL` computed off `folderURL` + `RecordingFolder.FileName`; `RecordedTranscriptSheet.load()` (RecordingsListView.swift:225-228) uses them. Remove RecordingsListView's `import PulsarTraceEngine` if now unused (check; `RefineStatusIcon` may pattern-match engine types — report).

- [ ] **Step 5: Package.swift honesty + app struct rewire**

`Package.swift`: `pulsartrace-mac` dependencies become `["PulsarTraceMenuBar", "PulsarTraceEngine"]` (SettingsView/RefinementsListView/MainWindowView legitimately import engine types for static catalogs and job display). `PulsarTraceMacApp.swift` shrinks to: `@main` struct + scenes (now reading `environment.…` from the moved class — add `import PulsarTraceEngine` only if the file still references engine types directly) + `HotkeyController` wiring + `RecordingStatus.menuBarSymbol` extension (stays; the UI plan reworks it next).

- [ ] **Step 6: Verify**

Bare with dangerouslyDisableSandbox: `swift build` (zero warnings tolerated beyond pre-existing ones), `swift test --filter MenuBar` (existing 60+ tests green + new RefinementQueueHandleTests), `swift test --filter UnitTests`, `swift test --filter Refinement`. Then run `scripts/make-dev-app.sh` ONLY IF it is listed in allowed commands — otherwise skip and note that manual app smoke is deferred to the branch-finishing step.

- [ ] **Step 7: Commit**
```bash
git add Package.swift Sources Tests
git commit -m "refactor: AppEnvironment moves to PulsarTraceMenuBar; RefinementQueueHandle replaces 3 init-order boxes; views stop constructing engine objects"
```

---

### Task 8: Full verification sweep

- [ ] Run, in order, each bare with dangerouslyDisableSandbox — all green: `UnitTests`, `Refinement`, `IPC`, `RecordOrchestrator`, `LiveRunner`, `Streaming`, `Transcription`, `Speaker`, `Source`, `Lifecycle`, `FinalMarkdownRewriter`, `MenuBar`, `DiarizationE2E`; plus `python/pulsartrace-ai/.venv/bin/pytest python/pulsartrace-ai/tests`.
- [ ] `swift build` — confirm the build is WARNING-FREE for the files this plan touched (the five LogHandler deprecation warnings must be gone; no new ones).
- [ ] `git log --oneline main..HEAD` + `git status --short` — clean tracked tree.

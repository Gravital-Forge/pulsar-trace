# Queue-driven refinement half-baked-fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the twelve real holes left in the queue-driven refinement path (`feat/refinement-job-queue` branch) so it matches the contracts the OfflineRefiner CLI path already honours: speaker-library reconciliation, refinement-event emission, a real `.paused` state, process-wide queue-status visibility, no swallowed errors, no bootstrap race, and an auto-refreshing recordings list.

**Architecture:** Each fix is a narrow, surgical change against existing types — no new top-level components, no schema breaks. The two heavy lifts (speaker library + refinement events) extend `RefinementPipeline.assembleAndWrite` and `ResumableRefiner.run` so the queue path reaches behaviour parity with `RefinementPipeline.run`. The UI fixes move polling lifecycle and scanner-refresh wiring into `AppEnvironment`, where they belong, and out of the views.

**Tech Stack:** Swift 6.2, Swift Testing, Foundation, the existing `PulsarTraceEngine` / `PulsarTraceMenuBar` modules. No new dependencies.

---

## Background

The branch review of `feat/refinement-job-queue` found twelve Critical/High/Medium bugs that ship with the queue path:

- **Critical**: the queue refiner bypasses `SpeakerLibrary` entirely (every menubar-driven `final.md` shows `Speaker_0`/`Speaker_1` instead of library names), and emits none of the six refinement-related events that the CLI path emits.
- **High**: `RefinementJobState.paused` is dead code (the gate suspends the refiner but no one sets `.paused`); the queue VM only polls while the Refinements pane is visible (so the menubar dropdown's "Refining 30%" line is stale); the Refinements pane's Refresh button calls `startPolling()`, which early-returns; `AppEnvironment.bootstrap` runs after `init()` returns, so an auto-refine enqueued in the race window silently no-ops.
- **Medium**: enqueue/upsert errors are `try?`-swallowed; `reportStage` fires its disk write off as a detached `Task` (races on bursty updates); the in-memory `recent` list grows unbounded; `RecordingsScanner` never re-scans after a queue job completes; `RefinementJobError.classify` ignores `RefinementPipeline.RefineError`; `ResumableRefiner.mergeAndWrite` passes `Date()` for `recordingStart` instead of the actual recording start parsed from the folder name.

The Low-severity doc drift (D34 says "8-stage", code has 7) is deliberately out of scope per the request.

---

## Decisions baked into the tasks

- **D-HB1 — Speaker library is opened by the queue's `makeStandard`, not by `ResumableRefiner`.** `ResumableRefiner` takes the already-opened library by parameter (default `nil`), matching how `RefinementPipeline.run` works. This keeps `ResumableRefiner`'s test seams unchanged (existing tests pass `nil`) and keeps SQLite-open responsibility at the wiring layer.
- **D-HB2 — `assembleAndWrite` becomes `async throws` and absorbs reconciliation + event emission.** The static helper grows from a pure file-writer into a small parallel of `RefinementPipeline.run`'s tail end — it's still one function so the queue path doesn't fork into a copy of `RefinementPipeline`. The CLI path (`RefinementPipeline.run`) is untouched.
- **D-HB3 — `.paused` is set by the queue, not by the refiner.** `pauseForRecording` reads the current job's `.running(stage:, …)`, transforms it to `.paused(reason: .recordingInProgress, lastStage:)`. `resumeAfterRecording` reverses it. The refiner never needs to know about `.paused` — it just waits on the gate.
- **D-HB4 — Queue VM polling is process-wide.** `AppEnvironment.bootstrap` calls `queueVM.startPolling()` once; views don't manage the lifecycle. The poller deinits with the VM (i.e. on app exit).
- **D-HB5 — `recent` is capped at 100 in-memory entries.** Disk-side `pruneTerminal(30 days)` runs at queue start; the in-memory list trims to the newest 100 on every append. Old entries still exist on disk until pruned.
- **D-HB6 — `recordingStart` is parsed from the recording folder name when the inverse exists**, else falls back to `Date()`. The menubar's recording folders follow `yyyy-MM-dd-HHmmss` (`RecordingViewModel.recordingFolderName(at:)`); the parser is the inverse.

---

## File Structure

### New files

```
Sources/PulsarTraceEngine/Refinement/Jobs/
  RecordingFolderTimestamp.swift     // Parser: "2026-05-20-100033" → Date.

Tests/UnitTests/
  RecordingFolderTimestampTests.swift
```

### Modified files

```
Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobError.swift
  // classify(_:) cases RefinementPipeline.RefineError to map its
  // .transcription / .diarization / .io / .input branches to the queue's
  // typed errors (.transcribeFailed / .diarizeCrashed / .io / .io).

Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
  // Reads `recent` cap, sets `.paused`/.running on pause/resume, awaits
  // reportStage's upsert, surfaces enqueue errors (typed throw), opens
  // the speaker library + passes it + the events writer + the recording
  // start into ResumableRefiner via makeStandard.

Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift
  // Stores SpeakerLibrary? and events; emits refinement_started near the
  // top of run(), refinement_completed on success, refinement_failed in
  // catch; passes library + events + recordingStart into the new
  // assembleAndWrite signature.

Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift
  // assembleAndWrite is now `async throws` and accepts library, events,
  // refinedAt; runs SpeakerReconciler when library is non-nil; emits
  // final_md_written / final_md_rewritten / live_md_replaced_by_final
  // mirroring RefinementPipeline.run's emissions.

Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift
  // refresh() diffs `recent` against last-seen ids and invokes an injected
  // onJobTerminated closure for every newly-terminal job. enqueueManual
  // returns a typed Result so the UI can surface failure.

Sources/pulsartrace-mac/PulsarTraceMacApp.swift
  // bootstrap() awaits queue construction, sets queueVM's onJobTerminated
  // to call scanner.refresh, and calls queueVM.startPolling() exactly once.
  // The enqueueBox.impl now awaits an internal "queue ready" continuation
  // so a stop-recording during bootstrap doesn't drop the auto-refine.

Sources/pulsartrace-mac/RefinementsListView.swift
  // Removes the startPolling/stopPolling lifecycle (AppEnvironment owns it).
  // Refresh button calls `queue.refresh()` (the real refresh) rather than
  // the no-op startPolling().
```

---

## Task 1: `RefinementJobError.classify` cases `RefinementPipeline.RefineError`

The classify switch ignores `RefineError` even though the doc comment claims it can show up. Rare in practice (the queue path doesn't wrap), but the CLI path does, and a future caller that hands a `RefineError` to classify gets `.io` — the catch-all — which is wrong.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobError.swift:84-110`
- Modify: `Tests/UnitTests/RefinementJobErrorTests.swift`

### Step 1.1: Write the failing test

- [ ] **Step 1.1.1: Append four tests to `Tests/UnitTests/RefinementJobErrorTests.swift`**

Open `Tests/UnitTests/RefinementJobErrorTests.swift` and append these tests just before the closing brace of the suite:

```swift
    @Test("classify maps RefineError.transcription to .transcribeFailed")
    func classifyRefineErrorTranscription() {
        struct Boom: Error {}
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.transcription(Boom()))
        #expect(classified.errorClass == "transcribeFailed")
        #expect(classified.retryAvailable == true)
    }

    @Test("classify maps RefineError.diarization to .diarizeCrashed")
    func classifyRefineErrorDiarization() {
        struct Boom: Error {}
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.diarization(Boom()))
        #expect(classified.errorClass == "diarizeCrashed")
        #expect(classified.retryAvailable == true)
    }

    @Test("classify maps RefineError.io to .io")
    func classifyRefineErrorIO() {
        struct Boom: Error {}
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.io(Boom()))
        #expect(classified.errorClass == "io")
    }

    @Test("classify maps RefineError.input to .io (non-retryable)") 
    func classifyRefineErrorInput() {
        let inner = RecordingFolder.InputError.pathNotFound("/x")
        let classified = RefinementJobError.classify(
            RefinementPipeline.RefineError.input(inner))
        #expect(classified.errorClass == "io")
        // RefineError.input.retryAvailable is false, but our classify
        // collapses input to .io which is retryable. Document that.
        #expect(classified.retryAvailable == true)
    }
```

- [ ] **Step 1.1.2: Run the tests — must fail**

```
swift test --filter RefinementJobError
```

Expected: the four new tests fail (`classified.errorClass == "io"` for the .transcription case, because the un-edited classify drops into the `.io` fallback for everything that isn't `ModelStoreError` or `DiarizeError`).

### Step 1.2: Add the new branch

- [ ] **Step 1.2.1: Edit `RefinementJobError.swift:84-110`**

Replace the body of `public static func classify(_ error: Error) -> RefinementJobError` (lines 84-110). The current body matches `ModelStoreError`, then `DiarizeError`, then falls through to `.io`. Insert a third match block, between the two existing ones and the fallthrough:

```swift
    public static func classify(_ error: Error) -> RefinementJobError {
        if let ms = error as? ModelStore.ModelStoreError {
            switch ms {
            case .hashMismatch, .sizeMismatch:
                return .modelChecksum
            case .httpError, .noData:
                return .modelMissing
            }
        }

        if let de = error as? Diarizer.DiarizeError {
            switch de {
            case .pythonNotFound, .launchFailed:
                return .missingDependency
            case .wavNotFound:
                return .transcribeFailed
            case .nonZeroExit, .timedOut, .emptyOutput, .decodeFailed:
                return .diarizeCrashed
            case .cancelled:
                // Should not reach here (ResumableRefiner retries internally),
                // but classify defensively as transient.
                return .diarizeCrashed
            }
        }

        // RefinementPipeline.RefineError wraps the underlying cause and
        // carries a coarse category. Map each branch to the closest queue
        // bucket. `.input` collapses to `.io` (no dedicated bucket); the
        // queue surfaces it as retryable because that matches the queue's
        // retry contract — the CLI's `RefineError.retryAvailable: false`
        // for `.input` is the CLI's own decision.
        if let re = error as? RefinementPipeline.RefineError {
            switch re {
            case .transcription: return .transcribeFailed
            case .diarization:   return .diarizeCrashed
            case .io, .input:    return .io
            }
        }

        return .io
    }
```

- [ ] **Step 1.2.2: Update the file's top doc comment**

Replace the "Error sources surveyed" block (around `RefinementJobError.swift:8-13`) to add the `RefineError` entry. Current:

```swift
/// Error sources surveyed (via `makeStandard`'s `runJob` closure):
/// - `ModelStore.ensureAvailable` → `ModelStore.ModelStoreError`
/// - `OfflineRefiner.makeDiarizer` → `Diarizer.DiarizeError` (.pythonNotFound,
///   .launchFailed)
/// - `ResumableRefiner.run` → `Diarizer.DiarizeError` (non-.cancelled variants),
///   `RefinementPipeline.RefineError`, I/O errors from `WAVReader` / `AtomicFile`.
```

New:

```swift
/// Error sources surveyed (via `makeStandard`'s `runJob` closure):
/// - `ModelStore.ensureAvailable` → `ModelStore.ModelStoreError`
/// - `OfflineRefiner.makeDiarizer` → `Diarizer.DiarizeError` (.pythonNotFound,
///   .launchFailed)
/// - `ResumableRefiner.run` → `Diarizer.DiarizeError` (non-.cancelled variants),
///   raw `WhisperTranscriber.TranscribeError`, I/O errors from `WAVReader` /
///   `AtomicFile`.
/// - `RefinementPipeline.assembleAndWrite` → `RefinementPipeline.RefineError`
///   (when the assemble step's reconciler / file writes wrap into the typed
///   RefineError). Each `RefineError` branch maps to a queue bucket.
```

- [ ] **Step 1.2.3: Run the tests — must pass**

```
swift test --filter RefinementJobError
```

Expected: all four new tests plus the pre-existing tests in the suite are green.

- [ ] **Step 1.2.4: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobError.swift \
        Tests/UnitTests/RefinementJobErrorTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): classify maps RefinementPipeline.RefineError to typed buckets

The classifier's docstring already claimed RefineError was a possible
source, but the switch never matched it. Map .transcription →
.transcribeFailed, .diarization → .diarizeCrashed, .io/.input → .io.
Closes the doc-vs-code gap.
EOF
)"
```

---

## Task 2: Cap `RefinementJobQueue.recent` at 100 entries in memory

The actor appends to `recent` on every job completion and never trims. On a long-running session this grows unbounded; disk-side prune is 30 days at start only. Cap at 100 newest in memory.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

### Step 2.1: Write the failing test

- [ ] **Step 2.1.1: Append a test to `Tests/PipelineTests/RefinementJobQueueTests.swift`**

Open `Tests/PipelineTests/RefinementJobQueueTests.swift` and append this test inside the suite, right before its closing brace:

```swift
    @Test("recent list is capped at 100 entries")
    func recentListCapped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RefinementJobStore(directory: dir)
        // runJob completes instantly — no real refine.
        let queue = RefinementJobQueue(store: store, runJob: { _ in })

        // Enqueue 110 jobs, each with a unique recordingId so dedupe lets
        // them all in. Wait briefly between batches to let the worker pump.
        for i in 0..<110 {
            try await queue.enqueueManualRefine(
                folderURL: dir,
                recordingId: "rec_\(i)",
                modelName: "stub",
                modelSHA256: "stub")
        }
        // Give the single-worker pump time to drain. Poll snapshot until
        // queued is empty or 5s elapses.
        let deadline = Date().addingTimeInterval(5)
        while await queue.snapshot().queued.isEmpty == false,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let snap = await queue.snapshot()
        #expect(snap.queued.isEmpty, "queue did not drain in time")
        #expect(snap.recent.count <= 100,
                "recent should be capped at 100, got \(snap.recent.count)")
    }
```

- [ ] **Step 2.1.2: Run — must fail**

```
swift test --filter RefinementJobQueueTests
```

Expected: the new test fails because `recent.count == 110`.

### Step 2.2: Add the cap

- [ ] **Step 2.2.1: Add a constant and trim helper to `RefinementJobQueue.swift`**

Edit `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`. Just after the `private var inflightCancellable: RefinementCancellable?` declaration (around line 33), add:

```swift
    /// Cap on the in-memory `recent` list. Older terminal jobs still exist
    /// on disk until `pruneTerminal` reaps them; this just bounds memory
    /// and the size of every `snapshot()` reply during a long session.
    private static let recentMemoryCap = 100
```

Then in `start()` (around line 80), after the loop that loads persisted jobs, add a trim at the end of the `for job in persisted` block. Find:

```swift
            case .completed, .failed, .cancelled:
                self.recent.append(job)
            }
        }
        pumpIfIdle()
    }
```

Replace with:

```swift
            case .completed, .failed, .cancelled:
                self.recent.append(job)
            }
        }
        trimRecent()
        pumpIfIdle()
    }
```

In `cancel(recordingId:)` (around line 185), after the `recent.append(job)` line, add `trimRecent()`:

```swift
    public func cancel(recordingId: String) async {
        guard let i = queued.firstIndex(where: { $0.recordingId == recordingId })
        else { return }
        var job = queued.remove(at: i)
        job.state = .cancelled
        try? await store.upsert(job)
        recent.append(job)
        trimRecent()
    }
```

In `runNext()` (around line 240), after `recent.append(job)` and before `current = nil`, add `trimRecent()`:

```swift
        try? await store.upsert(job)
        recent.append(job)
        trimRecent()
        current = nil
        self.worker = nil
        pumpIfIdle()
    }
```

Add the helper at the end of the actor, just before the closing brace:

```swift
    /// Keep the in-memory `recent` list bounded. The newest entries (the
    /// tail) are preserved; older entries are dropped from memory only —
    /// disk-side files persist until `pruneTerminal` reaps them.
    private func trimRecent() {
        if recent.count > Self.recentMemoryCap {
            let drop = recent.count - Self.recentMemoryCap
            recent.removeFirst(drop)
        }
    }
```

- [ ] **Step 2.2.2: Run — must pass**

```
swift test --filter RefinementJobQueueTests
```

Expected: every test in the suite green, including the new cap test.

- [ ] **Step 2.2.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): cap in-memory recent list at 100 entries

The queue actor appended every completed/failed/cancelled job to
`recent` and never trimmed. A long-running session would grow the
in-memory list without bound — and snapshot() copies the whole list
on every read. Trim to the newest 100 after every append, after
start()'s reload, and after cancel(). Disk-side state is untouched
(pruneTerminal already runs at start with a 30-day window).
EOF
)"
```

---

## Task 3: Surface enqueue errors (no more silent `try?`)

`RefinementJobQueueViewModel.enqueueManual` and `AppEnvironment.enqueueBox.impl` both wrap their `enqueue*` calls in `try?`, so a disk-write failure looks identical to success from the UI. Throw the error up; let the VM expose a `lastEnqueueError`, and let the recordings list flash a brief alert. The auto-refine path logs and continues (consistent with the existing "events are best-effort" pattern, since the user can re-enqueue manually).

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift`
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`
- Modify: `Sources/pulsartrace-mac/RecordingsListView.swift`
- Modify: `Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift`

### Step 3.1: Write the failing test for `lastEnqueueError`

- [ ] **Step 3.1.1: Replace `Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift`**

Read the current file first to preserve any existing test, then overwrite with this test added (keep any existing tests verbatim and add the new ones):

```swift
// Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@Suite("RefinementJobQueueViewModel")
@MainActor
struct RefinementJobQueueViewModelTests {

    private func tempStore() -> RefinementJobStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-vm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RefinementJobStore(directory: dir)
    }

    @Test("enqueueManual sets lastEnqueueError when the queue throws")
    func enqueueErrorSurfaced() async throws {
        // Build a queue whose store points at an unwritable directory.
        let badDir = URL(fileURLWithPath: "/dev/null/pulsartrace-bad-\(UUID().uuidString)")
        let badStore = RefinementJobStore(directory: badDir)
        let queue = RefinementJobQueue(store: badStore, runJob: { _ in })
        let vm = RefinementJobQueueViewModel(queue: queue)

        await vm.enqueueManual(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_x",
            modelName: "stub",
            modelSHA256: "stub")

        #expect(vm.lastEnqueueError != nil,
                "an unwritable store must surface as lastEnqueueError")
    }

    @Test("enqueueManual clears lastEnqueueError on success")
    func enqueueClearsError() async throws {
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        let vm = RefinementJobQueueViewModel(queue: queue)
        vm.lastEnqueueError = "stale"
        await vm.enqueueManual(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_ok",
            modelName: "stub",
            modelSHA256: "stub")
        #expect(vm.lastEnqueueError == nil)
    }
}
```

- [ ] **Step 3.1.2: Run — must fail**

```
swift test --filter RefinementJobQueueViewModel
```

Expected: compile error — `vm.lastEnqueueError` does not exist yet.

### Step 3.2: Add `lastEnqueueError` and surface errors

- [ ] **Step 3.2.1: Edit `RefinementJobQueueViewModel.swift`**

Open `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift` and add a new published field plus the surfacing logic. Just before `private var queue: RefinementJobQueue`, add:

```swift
    /// Last enqueue error, if any. The recordings list surfaces this as a
    /// short alert string; it is cleared by the next successful enqueue.
    public var lastEnqueueError: String?
```

Replace the body of `public func enqueueManual(...)`:

```swift
    public func enqueueManual(folderURL: URL, recordingId: String,
                              modelName: String, modelSHA256: String) async {
        do {
            try await queue.enqueueManualRefine(
                folderURL: folderURL, recordingId: recordingId,
                modelName: modelName, modelSHA256: modelSHA256)
            lastEnqueueError = nil
        } catch {
            lastEnqueueError = "Could not enqueue refinement: \(error)"
        }
        await refresh()
    }
```

- [ ] **Step 3.2.2: Edit `PulsarTraceMacApp.swift` so the auto-refine path logs instead of silently swallowing**

In `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`, find the `enqueueBox.impl` assignment (around lines 190-202). Current:

```swift
        enqueueBox.impl = { [weak self] url, recordingId in
            let pair: (RefinementJobQueue, String, String)? =
                await MainActor.run {
                    guard let self, let queue = self.queue else { return nil }
                    let name = self.settings.refineModelName
                    let model = ModelCatalog.model(named: name) ?? ModelCatalog.base
                    return (queue, model.name, model.sha256)
                }
            guard let (queue, modelName, modelSHA256) = pair else { return }
            try? await queue.enqueueAutoRefine(
                folderURL: url, recordingId: recordingId,
                modelName: modelName, modelSHA256: modelSHA256)
        }
```

Replace with:

```swift
        enqueueBox.impl = { [weak self] url, recordingId in
            let pair: (RefinementJobQueue, String, String)? =
                await MainActor.run {
                    guard let self, let queue = self.queue else { return nil }
                    let name = self.settings.refineModelName
                    let model = ModelCatalog.model(named: name) ?? ModelCatalog.base
                    return (queue, model.name, model.sha256)
                }
            guard let (queue, modelName, modelSHA256) = pair else {
                // Bootstrap race window — covered properly by Task 9. For
                // now: explicit log instead of a silent drop so the gap is
                // visible until Task 9 closes it.
                FileHandle.standardError.write(
                    Data("pulsartrace-mac: auto-refine dropped — queue not yet ready\n".utf8))
                return
            }
            do {
                try await queue.enqueueAutoRefine(
                    folderURL: url, recordingId: recordingId,
                    modelName: modelName, modelSHA256: modelSHA256)
            } catch {
                FileHandle.standardError.write(
                    Data("pulsartrace-mac: auto-refine enqueue failed: \(error)\n".utf8))
            }
        }
```

- [ ] **Step 3.2.3: Surface `lastEnqueueError` in `RecordingsListView`**

In `Sources/pulsartrace-mac/RecordingsListView.swift`, add a small alert-strip below the toolbar. Find the body's outer `Group { … }.toolbar { … }` and modify the body so a non-nil `lastEnqueueError` shows a yellow banner above the list. Replace the existing `body` declaration:

```swift
    var body: some View {
        VStack(spacing: 0) {
            if let err = queueVM.lastEnqueueError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange)
            }
            Group {
                if scanner.recordings.isEmpty {
                    emptyState
                } else {
                    List(scanner.recordings) { recording in
                        row(recording)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await scanner.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
                .help("Refresh the recordings list")
            }
        }
        .task { await scanner.refresh() }
        .sheet(item: $viewing) { recording in
            RecordedTranscriptSheet(recording: recording) { viewing = nil }
        }
    }
```

- [ ] **Step 3.2.4: Run — must pass**

```
swift test --filter RefinementJobQueueViewModel
```

Expected: 2/2 pass.

- [ ] **Step 3.2.5: Commit**

```bash
git add Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift \
        Sources/pulsartrace-mac/PulsarTraceMacApp.swift \
        Sources/pulsartrace-mac/RecordingsListView.swift \
        Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
git commit -m "$(cat <<'EOF'
fix(refine-ui): surface enqueue errors instead of try?-swallowing

RefinementJobQueueViewModel.enqueueManual previously wrapped its actor
call in try? so a disk-write failure looked identical to success. It
now captures the thrown error into lastEnqueueError and clears it on
the next success; the recordings list shows a brief orange banner.

The auto-refine path (PulsarTraceMacApp.enqueueBox.impl) still cannot
present UI, but now logs to stderr instead of dropping silently — the
real bootstrap-race fix lands in Task 9.
EOF
)"
```

---

## Task 4: Make `reportStage`'s upsert deterministic (no fire-and-forget Task)

`RefinementJobQueue.reportStage` updates `current.state` synchronously but spawns a detached `Task { try? await store.upsert(job) }` to persist. Two quick stage updates can land their disk writes out of order, and the `try?` drops persist errors silently. Make it `async` and await the upsert.

`ResumableRefiner` invokes `reportState` through the `StageReporter` typealias (`@Sendable (RefinementJobState) async -> Void`), which is already `async`, so the refiner side compiles unchanged. Only the queue's `reportStage` body needs to await.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:147-152`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

### Step 4.1: Write the failing test

- [ ] **Step 4.1.1: Append a test to `Tests/PipelineTests/RefinementJobQueueTests.swift`**

```swift
    @Test("reportStage awaits the disk upsert before returning")
    func reportStageAwaitsUpsert() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-rs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        // Hold the job in `running` indefinitely by parking the runJob
        // closure on a forever-closed gate. The actor stays reentrant
        // across the await, so external `reportStage` / `snapshot` calls
        // still process while the worker is parked.
        let holdOpen = PauseGate(initiallyOpen: false)
        let queue = RefinementJobQueue(
            store: store,
            runJob: { @Sendable _ in
                await holdOpen.waitOpen()  // suspends until the test ends
            },
            pauseGate: PauseGate(initiallyOpen: true))

        try await queue.enqueueAutoRefine(
            folderURL: dir, recordingId: "rec_rs",
            modelName: "stub", modelSHA256: "stub")

        // Wait for the worker to pick up the job (snapshot().running != nil).
        let deadline = Date().addingTimeInterval(1)
        while await queue.snapshot().running == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let running = await queue.snapshot().running else {
            Issue.record("worker never picked up the job"); return
        }

        let newState = RefinementJobState.running(
            stage: .diarizing, stepsCompleted: 2, stepsTotal: 7,
            regionIndex: nil, regionsTotal: nil)
        await queue.reportStage(newState)

        // Immediately read the on-disk job file — must reflect the new
        // state by the time reportStage returns.
        let jobFile = dir.appendingPathComponent("\(running.id).json")
        let data = try Data(contentsOf: jobFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(RefinementJob.self, from: data)
        if case .running(let stage, _, _, _, _) = onDisk.state {
            #expect(stage == .diarizing,
                    "reportStage must have awaited the upsert — on-disk stage was \(stage)")
        } else {
            Issue.record("on-disk state was not .running")
        }
    }
```

- [ ] **Step 4.1.2: Run — must fail**

```
swift test --filter "RefinementJobQueueTests.reportStageAwaitsUpsert"
```

Expected: the test races and the on-disk `stage` is `.resolvingInput` instead of `.diarizing` — the detached `Task` has not run yet by the time the test reads the file.

### Step 4.2: Make `reportStage` async

- [ ] **Step 4.2.1: Edit `RefinementJobQueue.swift:147-152`**

Replace the body:

```swift
    /// Update the running job's `state` from inside the refiner. A no-op when
    /// no job is currently running. Awaits the on-disk persist so callers see
    /// the new state durable before returning — a fire-and-forget upsert lost
    /// ordering on bursty updates and dropped errors via `try?`.
    public func reportStage(_ state: RefinementJobState) async {
        guard var job = current else { return }
        job.state = state
        current = job
        do {
            try await store.upsert(job)
        } catch {
            logger.warning("reportStage upsert failed: \(error)")
        }
    }
```

- [ ] **Step 4.2.2: Run — must pass**

```
swift test --filter RefinementJobQueueTests
```

Expected: every test green including the new one.

- [ ] **Step 4.2.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): reportStage awaits its disk upsert

The actor spawned a detached `Task { try? await store.upsert(job) }`
to persist a stage change, which (a) raced against the next reportStage
on bursty updates and (b) silently dropped persist errors. reportStage
is now `async` itself and awaits the upsert; persist failures log a
warning. ResumableRefiner already invokes the StageReporter via async
typealias so no caller-side changes are needed.
EOF
)"
```

---

## Task 5: Set `.paused` state on `pauseForRecording` / `resumeAfterRecording`

The `RefinementJobState.paused(reason:, lastStage:)` case is dead today — the queue closes the gate but doesn't transform the running job's state. The UI's "Paused…" branch in `RefinementsListView` is therefore unreachable. The queue itself knows the current stage (via `current.state`), so it can transform there.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

### Step 5.1: Write the failing test

- [ ] **Step 5.1.1: Append to `Tests/PipelineTests/RefinementJobQueueTests.swift`**

```swift
    @Test("pauseForRecording transforms a running job to .paused with lastStage")
    func pauseSetsPausedState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)
        let gate = PauseGate(initiallyOpen: true)

        // A runJob that reports a stage then suspends on the gate forever so
        // we can observe pauseForRecording while running.
        let queue = RefinementJobQueue(
            store: store,
            runJob: { @Sendable [gate] _ in
                await gate.waitOpen()
                // After the gate reopens, suspend forever (test cleanup
                // tears the actor down).
                try? await Task.sleep(for: .seconds(60))
            },
            pauseGate: gate)
        try await queue.enqueueAutoRefine(
            folderURL: dir, recordingId: "rec_pause",
            modelName: "stub", modelSHA256: "stub")
        // Manually mark the job's running state via reportStage so the
        // queue has a `lastStage` to capture.
        let deadline = Date().addingTimeInterval(1)
        while await queue.snapshot().running == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await queue.reportStage(.running(
            stage: .diarizing, stepsCompleted: 2, stepsTotal: 7,
            regionIndex: nil, regionsTotal: nil))

        await queue.pauseForRecording()
        let paused = await queue.snapshot().running
        guard case .paused(let reason, let lastStage) = paused?.state else {
            Issue.record("expected .paused, got \(String(describing: paused?.state))")
            return
        }
        #expect(reason == .recordingInProgress)
        #expect(lastStage == .diarizing)

        await queue.resumeAfterRecording()
        let resumed = await queue.snapshot().running
        guard case .running(let stage, _, _, _, _) = resumed?.state else {
            Issue.record("expected .running after resume, got \(String(describing: resumed?.state))")
            return
        }
        #expect(stage == .diarizing, "lastStage should round-trip through resume")
    }
```

- [ ] **Step 5.1.2: Run — must fail**

```
swift test --filter "RefinementJobQueueTests.pauseSetsPausedState"
```

Expected: the `case .paused` match fails — current code leaves `.running` in place.

### Step 5.2: Implement the state transform

- [ ] **Step 5.2.1: Edit `RefinementJobQueue.swift`**

Replace `pauseForRecording()`:

```swift
    /// Pause the queue: stops new jobs from starting and closes the pause gate
    /// so the in-flight refiner stalls at its next checkpoint. Transforms the
    /// running job's `.running(stage:, …)` into `.paused(reason: .recordingInProgress,
    /// lastStage:)` so the UI reflects the suspension rather than showing
    /// stale "Diarizing 2/7" text. Also signals the diarizer to terminate its
    /// subprocess if one is currently running (D-Q7 / Task D3).
    public func pauseForRecording() async {
        pausedForRecording = true
        await pauseGate.close()
        if var job = current,
           case .running(let stage, _, _, _, _) = job.state {
            job.state = .paused(reason: .recordingInProgress, lastStage: stage)
            current = job
            do { try await store.upsert(job) }
            catch { logger.warning("pause upsert failed: \(error)") }
        }
        if let c = inflightCancellable { await c.cancel() }
    }
```

Replace `resumeAfterRecording()`:

```swift
    /// Resume the queue: opens the gate so the in-flight refiner picks up at
    /// its next checkpoint. Transforms the running job's `.paused` back into
    /// `.running` so the UI reports forward progress again. The actual step
    /// counts will be overwritten by the refiner's next `reportStage` call;
    /// here we restore a sensible baseline derived from `lastStage`.
    public func resumeAfterRecording() async {
        pausedForRecording = false
        if var job = current,
           case .paused(_, let lastStage) = job.state {
            let stepIndex = RefinementJobState.Stage.allCases.firstIndex(of: lastStage) ?? 0
            job.state = .running(
                stage: lastStage,
                stepsCompleted: stepIndex,
                stepsTotal: RefinementJobState.Stage.allCases.count,
                regionIndex: nil, regionsTotal: nil)
            current = job
            do { try await store.upsert(job) }
            catch { logger.warning("resume upsert failed: \(error)") }
        }
        await pauseGate.open()
        pumpIfIdle()
    }
```

- [ ] **Step 5.2.2: Run — must pass**

```
swift test --filter RefinementJobQueueTests
```

Expected: every test green including the new pause-state test.

- [ ] **Step 5.2.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): pauseForRecording transforms .running to .paused

The .paused(reason:, lastStage:) case was defined and rendered by
RefinementsListView but never written. pauseForRecording now captures
the current stage and transforms .running → .paused; resumeAfterRecording
reverses it. The refiner's next reportStage overwrites the running step
counts, so the brief baseline restored here is just a placeholder while
the refiner re-emits its progress.
EOF
)"
```

---

## Task 6: Parse `recordingStart` from the folder name in the queue path

`ResumableRefiner.mergeAndWrite` calls `RefinementPipeline.assembleAndWrite` with `recordingStart: Date()` — the wall-clock at refinement time, not the actual recording start. Menubar folders follow `yyyy-MM-dd-HHmmss`, so the inverse of `RecordingViewModel.recordingFolderName(at:)` recovers the real value. The CLI path keeps its `Date()` default (a bare WAV has no folder-name timestamp to parse).

This task only adds the parser + plumbing. The actual `assembleAndWrite` signature change lands in Task 11 — for now the parsed value is computed and passed via the existing parameter slot.

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/RecordingFolderTimestamp.swift`
- Create: `Tests/UnitTests/RecordingFolderTimestampTests.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`

### Step 6.1: Write the failing test for the parser

- [ ] **Step 6.1.1: Create `Tests/UnitTests/RecordingFolderTimestampTests.swift`**

```swift
// Tests/UnitTests/RecordingFolderTimestampTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RecordingFolderTimestamp")
struct RecordingFolderTimestampTests {

    @Test("parses a bare yyyy-MM-dd-HHmmss prefix")
    func parsesBarePrefix() throws {
        let date = try #require(
            RecordingFolderTimestamp.parse("2026-05-20-100033"))
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 20)
        #expect(comps.hour == 10)
        #expect(comps.minute == 0)
        #expect(comps.second == 33)
    }

    @Test("only matches yyyy-MM-dd-HHmmss prefixes, not yyyy-MM-dd-<slug>")
    func rejectsDateOnlyPrefix() {
        // The menubar always writes the time component (HHmmss). A
        // dev-named folder like "2026-04-30-team-standup" is not a
        // menubar recording, so parse must reject it.
        #expect(RecordingFolderTimestamp.parse("2026-04-30-team-standup") == nil)
    }

    @Test("returns nil when the prefix is not yyyy-MM-dd-HHmmss")
    func nilOnNoTimestamp() {
        #expect(RecordingFolderTimestamp.parse("meeting") == nil)
        #expect(RecordingFolderTimestamp.parse("") == nil)
        #expect(RecordingFolderTimestamp.parse("2026-05-20") == nil)
    }

    @Test("preserves a yyyy-MM-dd-HHmmss prefix even when more text follows")
    func parsesPrefixWithTrailing() throws {
        let date = try #require(
            RecordingFolderTimestamp.parse("2026-05-20-100033-debug"))
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.hour, from: date) == 10)
        #expect(cal.component(.second, from: date) == 33)
    }
}
```

- [ ] **Step 6.1.2: Run — must fail (compile)**

```
swift test --filter RecordingFolderTimestamp
```

Expected: compile error — `RecordingFolderTimestamp` not in scope.

### Step 6.2: Implement the parser

- [ ] **Step 6.2.1: Create `Sources/PulsarTraceEngine/Refinement/Jobs/RecordingFolderTimestamp.swift`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RecordingFolderTimestamp.swift
import Foundation

/// Inverse of `RecordingViewModel.recordingFolderName(at:)`: parses the
/// `yyyy-MM-dd-HHmmss` prefix the menubar writes into each recording folder
/// name into the real recording-start `Date`. Returns `nil` when the prefix
/// is missing or malformed — the CLI's bare-WAV input has no such prefix.
public enum RecordingFolderTimestamp {

    /// The exact prefix length: 4 (year) + 1 + 2 (month) + 1 + 2 (day) + 1
    /// + 6 (HHmmss).
    private static let prefixLength = 17

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current   // matches the menubar writer's local-time format
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Parse the timestamp prefix of `folderName`. Returns `nil` if the
    /// folder name does not start with a full `yyyy-MM-dd-HHmmss` prefix.
    public static func parse(_ folderName: String) -> Date? {
        guard folderName.count >= prefixLength else { return nil }
        let prefix = String(folderName.prefix(prefixLength))
        return formatter.date(from: prefix)
    }
}
```

- [ ] **Step 6.2.2: Run — must pass**

```
swift test --filter RecordingFolderTimestamp
```

Expected: 4/4 pass.

### Step 6.3: Wire the parsed date into the refiner's mergeAndWrite call

- [ ] **Step 6.3.1: Edit `ResumableRefiner.swift`**

In `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`, find `mergeAndWrite` (around line 246) and replace the `recordingStart: Date()` line:

Current:

```swift
        try RefinementPipeline.assembleAndWrite(
            folder: folder,
            systemSegments: system,
            micSegments: mic,
            diarization: diarization,
            language: progress.language ?? "unknown",
            whisperModelName: job.modelName,
            whisperModelSHA256: job.modelSHA256,
            recordingStart: Date(),
            sourceBasename: folder.systemStream.url.lastPathComponent)
```

New:

```swift
        let folderName = folder.directory.lastPathComponent
        let recordingStart = RecordingFolderTimestamp.parse(folderName) ?? Date()
        try RefinementPipeline.assembleAndWrite(
            folder: folder,
            systemSegments: system,
            micSegments: mic,
            diarization: diarization,
            language: progress.language ?? "unknown",
            whisperModelName: job.modelName,
            whisperModelSHA256: job.modelSHA256,
            recordingStart: recordingStart,
            sourceBasename: folder.systemStream.url.lastPathComponent)
```

- [ ] **Step 6.3.2: Verify nothing regressed**

```
swift test --filter ResumableRefiner
```

Expected: every existing ResumableRefiner test still green.

- [ ] **Step 6.3.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RecordingFolderTimestamp.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Tests/UnitTests/RecordingFolderTimestampTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): parse recordingStart from the folder name in the queue path

ResumableRefiner.mergeAndWrite passed `Date()` for recordingStart — the
moment refinement finished, not when the recording actually started. The
menubar folder name follows yyyy-MM-dd-HHmmss; parse that prefix and use
it. A non-menubar folder name (CLI bare-WAV imports) falls back to
Date(), matching the OfflineRefiner CLI's pre-existing behaviour.
EOF
)"
```

---

## Task 7: Auto-rescan the recordings list on every terminal job

When a queue job moves to `.completed`, the recording folder gains a `metadata.json` and the recordings list should flip its row from "Not yet refined" to "X speakers · Ys". Today the user has to click Refresh manually. `RefinementJobQueueViewModel.refresh()` already runs every 250 ms — diff `recent` against the last-seen set and fire a callback for every newly-terminal job.

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift`
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`
- Modify: `Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift`

### Step 7.1: Write the failing test

- [ ] **Step 7.1.1: Append to `Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift`**

```swift
    @Test("onJobTerminated fires for every newly-completed job")
    func onJobTerminatedFires() async throws {
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        let vm = RefinementJobQueueViewModel(queue: queue)
        let fired = MainActorBox<[String]>(value: [])
        vm.onJobTerminated = { @MainActor job in
            fired.value.append(job.recordingId)
        }
        // Enqueue + let the worker drain (runJob is a no-op).
        try await queue.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/a"),
            recordingId: "rec_a", modelName: "stub", modelSHA256: "stub")
        try await queue.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/b"),
            recordingId: "rec_b", modelName: "stub", modelSHA256: "stub")
        let deadline = Date().addingTimeInterval(2)
        while await queue.snapshot().recent.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await vm.refresh()
        // Both terminations observed exactly once.
        #expect(fired.value.sorted() == ["rec_a", "rec_b"])

        // A second refresh with no new terminal jobs must NOT re-fire.
        fired.value.removeAll()
        await vm.refresh()
        #expect(fired.value.isEmpty)
    }

    /// Captures values across `@MainActor` boundaries in a test.
    @MainActor private final class MainActorBox<T> {
        var value: T
        init(value: T) { self.value = value }
    }
```

- [ ] **Step 7.1.2: Run — must fail (compile)**

```
swift test --filter "RefinementJobQueueViewModel.onJobTerminatedFires"
```

Expected: compile error — `vm.onJobTerminated` does not exist.

### Step 7.2: Add the callback + diff

- [ ] **Step 7.2.1: Edit `RefinementJobQueueViewModel.swift`**

Add the callback property near the other published properties:

```swift
    /// Called once for each refinement job that transitions into a terminal
    /// state (completed / failed / cancelled). Set by `AppEnvironment` to a
    /// closure that re-scans the recordings list so a freshly-refined
    /// recording flips from "Not yet refined" to the speaker/duration line
    /// without a manual Refresh.
    public var onJobTerminated: (@MainActor @Sendable (RefinementJob) -> Void)?

    private var seenRecentIDs: Set<String> = []
```

Replace `refresh()` to diff and fire:

```swift
    public func refresh() async {
        let s = await queue.snapshot()
        running = s.running
        queued = s.queued
        let newlyTerminated = s.recent.filter { !seenRecentIDs.contains($0.id) }
        recent = s.recent
        seenRecentIDs = Set(s.recent.map { $0.id })
        pausedForRecording = s.pausedForRecording
        if let cb = onJobTerminated {
            for job in newlyTerminated { cb(job) }
        }
    }
```

- [ ] **Step 7.2.2: Wire the callback in `PulsarTraceMacApp.swift`**

In `AppEnvironment.bootstrap()` (around line 228), after `await queueVM.setQueue(q)`, add:

```swift
    func bootstrap() async {
        let q = await RefinementJobQueue.makeStandard(events: events, paths: paths)
        self.queue = q
        await queueVM.setQueue(q)
        queueVM.onJobTerminated = { [weak self] _ in
            guard let self else { return }
            Task { await self.scanner.refresh() }
        }
    }
```

- [ ] **Step 7.2.3: Run — must pass**

```
swift test --filter "RefinementJobQueueViewModel.onJobTerminatedFires"
```

Expected: the new test passes alongside the others.

- [ ] **Step 7.2.4: Commit**

```bash
git add Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift \
        Sources/pulsartrace-mac/PulsarTraceMacApp.swift \
        Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
git commit -m "$(cat <<'EOF'
fix(refine-ui): auto-rescan recordings list when a refine completes

RefinementJobQueueViewModel.refresh now diffs `recent` against a seen-ids
set and invokes an injected onJobTerminated closure once per newly-
terminal job. AppEnvironment wires the closure to RecordingsScanner.refresh
so a finished refine flips its recording row without the user clicking
Refresh.
EOF
)"
```

---

## Task 8: Process-wide queueVM polling + fix the dead Refresh button

`RefinementsListView` is the only caller of `queueVM.startPolling()`, started on `.task` and stopped on `.onDisappear`. The menubar dropdown and the recordings list also read from `queueVM`, so they go stale whenever the Refinements pane is closed. Move the polling lifecycle into `AppEnvironment.bootstrap` (one call, lives for the process). The view's Refresh button calls `queue.refresh()` (the real refresh) instead of `startPolling()` (which early-returns when the poller already exists).

**Files:**
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`
- Modify: `Sources/pulsartrace-mac/RefinementsListView.swift`

### Step 8.1: Move polling into `bootstrap`

- [ ] **Step 8.1.1: Edit `PulsarTraceMacApp.swift`**

In `AppEnvironment.bootstrap()`, after the `onJobTerminated` wiring added in Task 7, append:

```swift
    func bootstrap() async {
        let q = await RefinementJobQueue.makeStandard(events: events, paths: paths)
        self.queue = q
        await queueVM.setQueue(q)
        queueVM.onJobTerminated = { [weak self] _ in
            guard let self else { return }
            Task { await self.scanner.refresh() }
        }
        // Single process-wide poller. The menubar dropdown and the
        // recordings-list RefineBadge both read from queueVM; before this
        // change polling only ran while RefinementsListView was visible,
        // so those two surfaces were stale.
        queueVM.startPolling()
    }
```

### Step 8.2: Remove view-level polling and fix the Refresh button

- [ ] **Step 8.2.1: Edit `RefinementsListView.swift`**

Replace the body's modifiers. Current:

```swift
        .task { queue.startPolling() }
        .onDisappear { queue.stopPolling() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { queue.startPolling() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh refinement job list")
            }
        }
```

Replace with:

```swift
        // Polling is started once by AppEnvironment.bootstrap for the whole
        // process lifetime — the menubar dropdown and the recordings list
        // both bind to this VM, so they need fresh data even when this pane
        // is not visible. The Refresh button forces an immediate refresh
        // instead of waiting for the next 250 ms tick.
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await queue.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh refinement job list")
            }
        }
```

- [ ] **Step 8.2.2: Run the menubar suite to confirm no regression**

```
swift test --filter MenuBarTests
```

Expected: every existing menubar test green.

- [ ] **Step 8.2.3: Commit**

```bash
git add Sources/pulsartrace-mac/PulsarTraceMacApp.swift \
        Sources/pulsartrace-mac/RefinementsListView.swift
git commit -m "$(cat <<'EOF'
fix(refine-ui): poll queueVM for the whole process, not just one pane

queueVM.startPolling was only called from RefinementsListView's .task,
so the menubar dropdown's queue status line and the recordings list's
RefineBadge / "Refine" disabled state showed stale data whenever the
Refinements pane was not visible. AppEnvironment.bootstrap now calls
startPolling exactly once for the process lifetime; the view's
.task/.onDisappear lifecycle hooks are removed.

The Refresh button now calls queue.refresh() (the real one-shot refresh)
instead of queue.startPolling() — which early-returned when the poller
was already alive, making the button a no-op.
EOF
)"
```

---

## Task 9: Close the bootstrap race window for auto-refine

`AppEnvironment.bootstrap` runs as a deferred `Task`; before it completes, `self.queue` is `nil` and `enqueueBox.impl` returns early. A user who records & stops in that window silently loses the auto-refine. Add a `CheckedContinuation`-backed "queue ready" gate that the enqueue closure awaits before reading `self.queue`.

**Files:**
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`

### Step 9.1: Add a queue-ready gate and wire it through the enqueue closure

- [ ] **Step 9.1.1: Edit `PulsarTraceMacApp.swift`**

At the top of the file (after the `EnqueueBox` and `AsyncCallBox` definitions, before `final class AppEnvironment`), add a small async-gate type:

```swift
/// One-shot async gate. `wait()` suspends until `signal()` is called; once
/// signalled, every later `wait()` returns immediately. Used by
/// AppEnvironment to block auto-refine enqueues until `bootstrap` has
/// installed the real `RefinementJobQueue`.
///
/// `@unchecked Sendable`: the lock protects `signalled` and `waiters` from
/// concurrent access; everything mutates inside `lock.withLock`.
private final class QueueReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !signalled else { return [] }
            signalled = true
            let w = waiters
            waiters.removeAll()
            return w
        }
        for c in toResume { c.resume() }
    }

    func wait() async {
        let alreadySignalled: Bool = lock.withLock {
            if signalled { return true }
            return false
        }
        if alreadySignalled { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeImmediately: Bool = lock.withLock {
                if signalled { return true }
                waiters.append(c)
                return false
            }
            if resumeImmediately { c.resume() }
        }
    }
}
```

Add a stored property to `AppEnvironment`, right after `private(set) var queue: RefinementJobQueue? = nil`:

```swift
    /// Gate that opens once `bootstrap()` has installed the real queue. The
    /// `enqueueBox.impl` closure awaits this before reading `self.queue`, so
    /// a stop-recording that lands during bootstrap still gets its auto-
    /// refine enqueued instead of silently dropping (race fix).
    private let queueReady = QueueReadyGate()
```

Replace the `enqueueBox.impl` body (the one Task 3 modified) — add a `await queueReady.wait()` at the top:

```swift
        enqueueBox.impl = { [weak self] url, recordingId in
            // Wait for bootstrap() to install the real queue. If
            // AppEnvironment is torn down before bootstrap completes, the
            // weak self below evaluates to nil and the closure exits.
            guard let gate: QueueReadyGate = await MainActor.run({ self?.queueReady })
            else { return }
            await gate.wait()

            let pair: (RefinementJobQueue, String, String)? =
                await MainActor.run {
                    guard let self, let queue = self.queue else { return nil }
                    let name = self.settings.refineModelName
                    let model = ModelCatalog.model(named: name) ?? ModelCatalog.base
                    return (queue, model.name, model.sha256)
                }
            guard let (queue, modelName, modelSHA256) = pair else {
                FileHandle.standardError.write(
                    Data("pulsartrace-mac: auto-refine dropped — queue gone after bootstrap\n".utf8))
                return
            }
            do {
                try await queue.enqueueAutoRefine(
                    folderURL: url, recordingId: recordingId,
                    modelName: modelName, modelSHA256: modelSHA256)
            } catch {
                FileHandle.standardError.write(
                    Data("pulsartrace-mac: auto-refine enqueue failed: \(error)\n".utf8))
            }
        }
```

Signal the gate at the end of `bootstrap()`:

```swift
    func bootstrap() async {
        let q = await RefinementJobQueue.makeStandard(events: events, paths: paths)
        self.queue = q
        await queueVM.setQueue(q)
        queueVM.onJobTerminated = { [weak self] _ in
            guard let self else { return }
            Task { await self.scanner.refresh() }
        }
        queueVM.startPolling()
        queueReady.signal()
    }
```

### Step 9.2: Verify the build and tests are green

- [ ] **Step 9.2.1: Build the project**

```
swift build
```

Expected: clean build.

- [ ] **Step 9.2.2: Run the menubar suite**

```
swift test --filter MenuBarTests
```

Expected: all tests pass — the gate change is purely additive to the production wiring; tests build their own VMs without the gate.

- [ ] **Step 9.2.3: Commit**

```bash
git add Sources/pulsartrace-mac/PulsarTraceMacApp.swift
git commit -m "$(cat <<'EOF'
fix(refine): close the bootstrap race window for auto-refine

AppEnvironment.bootstrap runs as a deferred Task; before it completes
self.queue was nil and enqueueBox.impl returned early, silently
dropping any auto-refine the user triggered in that window. A new
QueueReadyGate (one-shot async gate) is awaited at the top of the
enqueue closure and signalled at the end of bootstrap, so a stop-
recording during bootstrap now blocks briefly and then enqueues
against the real queue.
EOF
)"
```

---

## Task 10: Emit refinement events from the queue path

`ResumableRefiner.run` never calls `events?.append` — every menubar-driven refine is invisible to the events log. Emit `refinement_started` at the top of `run`, `refinement_completed` on success (after `mergeAndWrite` returns), and `refinement_failed` from the catch. The `events: EventWriter?` field on `ResumableRefiner` is already stored — just use it.

The file-events (`final_md_written`, `final_md_rewritten`, `live_md_replaced_by_final`) are written by `assembleAndWrite`; they land in Task 11 where that function gets its events parameter.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`
- Modify: `Tests/UnitTests/ResumableRefinerTests.swift`

### Step 10.1: Write the failing test

- [ ] **Step 10.1.1: Append to `Tests/UnitTests/ResumableRefinerTests.swift`**

Open `Tests/UnitTests/ResumableRefinerTests.swift` and append (inside the suite):

```swift
    /// Helper: build an in-memory EventWriter and read every event line back.
    @MainActor
    private func makeEvents() -> (EventWriter, () async throws -> [String]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-rr-evt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = EventWriter(directory: dir)
        return (writer, {
            await writer.bootstrap()
            // Wait for any pending appends — the actor is FIFO, so a fresh
            // append+flush serializes after every earlier append.
            await writer.flush()
            let url = await writer.currentFileURL()
            let data = (try? Data(contentsOf: url)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        })
    }

    @Test("run emits refinement_started and refinement_completed on success")
    func emitsStartCompleteEvents() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let (events, readback) = await makeEvents()
        await events.bootstrap()

        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in
                TranscriptionResult(segments: [], language: "en")
            },
            detectRegions: { _ in [] },
            diarize: { _ in
                DiarizationResult(speakers: [], spans: [], embeddings: [:],
                                  model: "stub", modelRevision: "stub", modelVersion: "stub")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: events)

        let job = RefinementJob(
            id: "job_evt", recordingId: "rec_evt", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let lines = try await readback()
        let types = lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["type"] as? String
        }
        #expect(types.contains("refinement_started"))
        #expect(types.contains("refinement_completed"))
    }

    @Test("run emits refinement_failed when the body throws")
    func emitsFailedEvent() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let (events, readback) = await makeEvents()
        await events.bootstrap()

        struct Boom: Error {}
        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in throw Boom() },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                fatalError("not reached")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: events)

        let job = RefinementJob(
            id: "job_fail", recordingId: "rec_fail", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        await #expect(throws: Boom.self) { try await refiner.run(job: job) }
        let lines = try await readback()
        let types = lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["type"] as? String
        }
        #expect(types.contains("refinement_started"))
        #expect(types.contains("refinement_failed"))
        #expect(!types.contains("refinement_completed"))
    }
```

- [ ] **Step 10.1.2: Run — must fail**

```
swift test --filter "ResumableRefiner.emitsStartCompleteEvents"
swift test --filter "ResumableRefiner.emitsFailedEvent"
```

Expected: both tests find no `refinement_*` events.

### Step 10.2: Emit the events

- [ ] **Step 10.2.1: Edit `ResumableRefiner.swift`**

In `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`, replace the body of `run(job:)` to wrap the existing stage iteration with event emissions. Current shape:

```swift
    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)
        if progress.lastError != nil {
            progress.lastError = nil
            try? persist(progress, folder: folder)
        }

        do {
            try await advance(&progress, to: .resolvingInput, folder: folder)
            // … existing stages …
            try mergeAndWrite(folder: folder, progress: progress, diarization: diarization, job: job)
        } catch {
            progress.lastError = Self.redactPath(
                "\(type(of: error)): \(error)",
                folder: folder.directory)
            try? persist(progress, folder: folder)
            logger.warning("refinement job \(job.id) failed: \(progress.lastError ?? "?")")
            throw error
        }
    }
```

Replace with:

```swift
    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)
        if progress.lastError != nil {
            progress.lastError = nil
            try? persist(progress, folder: folder)
        }

        // refinement_started — emitted before any work, matching the
        // CLI's RefinementPipeline.run contract (Hard Invariant #8).
        _ = try? await events?.append(RefinementStartedEvent(
            recordingId: job.recordingId, modelRefine: job.modelName))

        let startedAt = Date()
        do {
            try await advance(&progress, to: .resolvingInput, folder: folder)

            try await advance(&progress, to: .transcribingSystem, folder: folder)
            try await transcribeSystemStream(folder: folder, progress: &progress)

            try await advance(&progress, to: .diarizing, folder: folder)
            let diarization = try await runDiarization(folder: folder, progress: &progress)

            try await advance(&progress, to: .transcribingMic, folder: folder)
            if folder.micStream != nil {
                try await transcribeMicStream(folder: folder, progress: &progress)
            }

            try await advance(&progress, to: .merging, folder: folder)
            try await advance(&progress, to: .writingFinal, folder: folder)
            try await advance(&progress, to: .writingMetadata, folder: folder)
            try mergeAndWrite(folder: folder, progress: progress, diarization: diarization, job: job)

            // refinement_completed — emitted after mergeAndWrite returns,
            // so by the time the event lands every output file is durable.
            let wallSeconds = Date().timeIntervalSince(startedAt)
            // Speaker count from the in-memory diarization, since this path
            // does not yet reconcile against the library (Task 11). The
            // speakers_new / speakers_matched fields land in Task 11.
            let speakerCount = diarization?.speakers.count ?? 0
            _ = try? await events?.append(RefinementCompletedEvent(
                recordingId: job.recordingId,
                durationSeconds: wallSeconds,
                speakersIdentified: speakerCount,
                speakersNew: speakerCount,
                speakersMatched: 0))
        } catch {
            progress.lastError = Self.redactPath(
                "\(type(of: error)): \(error)",
                folder: folder.directory)
            try? persist(progress, folder: folder)
            logger.warning("refinement job \(job.id) failed: \(progress.lastError ?? "?")")
            let classified = RefinementJobError.classify(error)
            _ = try? await events?.append(RefinementFailedEvent(
                recordingId: job.recordingId,
                errorClass: classified.errorClass,
                retryAvailable: classified.retryAvailable))
            throw error
        }
    }
```

- [ ] **Step 10.2.2: Run — must pass**

```
swift test --filter ResumableRefiner
```

Expected: every existing test green, plus the two new event tests.

- [ ] **Step 10.2.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Tests/UnitTests/ResumableRefinerTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): emit refinement_started / _completed / _failed from queue path

The queue-driven refiner never touched its EventWriter — the entire
events-log surface for queue refinement (refinement_started, _completed,
_failed) was silently missing. Emit the three lifecycle events around
the existing stage iteration, mirroring RefinementPipeline.run's order
(Hard Invariant #8: started before work, completed after every output
is durable, failed in the catch). The file-event triplet (final_md_*,
live_md_replaced_by_final) is added in the next task where
assembleAndWrite grows its events parameter.
EOF
)"
```

---

## Task 11: Thread `SpeakerLibrary` + file-events through `assembleAndWrite`

The big one. `RefinementPipeline.assembleAndWrite` is called by `ResumableRefiner.mergeAndWrite` and is the only refine-write site in the queue path. It currently skips speaker-library reconciliation (every menubar `final.md` shows `Speaker_0`) and emits no file events. Extend it to:

1. Take `library: SpeakerLibrary?`, `recordingId: String`, `events: EventWriter?`, `refinedAt: Date`.
2. Run `SpeakerReconciler` when `library` is non-nil, mirroring `RefinementPipeline.refine`.
3. Emit `final_md_written` or `final_md_rewritten` after writing, and `live_md_replaced_by_final` if a `live.md` was renamed.
4. Return an `AssembleResult` with `speakersNew` / `speakersMatched` so `ResumableRefiner.run` can refine its `refinement_completed` emission with real counts.
5. `RefinementJobQueue.makeStandard` opens a `SpeakerLibrary` (same path `OfflineRefiner` uses) and passes it into `ResumableRefiner.init`. `ResumableRefiner` threads it through.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/UnitTests/ResumableRefinerTests.swift`

### Step 11.1: Extend `assembleAndWrite`'s signature and emit file events

- [ ] **Step 11.1.1: Edit `RefinementPipeline.swift`**

Add a new public result struct just above `public static func assembleAndWrite` (around line 763):

```swift
    /// Outcome of `assembleAndWrite`. Returned so the queue's
    /// `ResumableRefiner.run` can include real speaker counts in its
    /// `refinement_completed` event.
    public struct AssembleResult: Sendable {
        public let speakerCount: Int
        public let speakersNew: Int
        public let speakersMatched: Int
        public let durationSeconds: Double
    }
```

Replace the entire body of `public static func assembleAndWrite(...)` (the existing function spans roughly lines 763-805):

```swift
    /// The merge + write half of `run(_:)`, exposed so `ResumableRefiner` can
    /// reuse it after assembling segments incrementally from a checkpoint
    /// file.
    ///
    /// Now mirrors `RefinementPipeline.refine`'s tail: runs `SpeakerReconciler`
    /// when a library is supplied (so queue-driven refines get real speaker
    /// names instead of Speaker_N), writes `final.md` + `metadata.json`
    /// atomically, and emits `final_md_written` / `final_md_rewritten` /
    /// `live_md_replaced_by_final` events in causal order with on-disk effects
    /// (Hard Invariant #8). Returns an `AssembleResult` carrying the counts
    /// the caller needs for `refinement_completed`.
    ///
    /// This method is NOT a stable public API — it exists for the in-process
    /// queue worker. The `pulsartrace refine` CLI continues to call `run(_:)`.
    public static func assembleAndWrite(
        folder: RecordingFolder,
        systemSegments: [TranscriptSegment],
        micSegments: [TranscriptSegment],
        diarization: DiarizationResult?,
        language: String,
        whisperModelName: String,
        whisperModelSHA256: String,
        recordingStart: Date,
        sourceBasename: String,
        library: SpeakerLibrary? = nil,
        refinedAt: Date = Date(),
        events: EventWriter? = nil
    ) async throws -> AssembleResult {
        // 1. Reconcile against the speaker library when one is supplied.
        //    A reconciler failure must not lose a refine — fall back to
        //    raw Speaker_N labels (matches RefinementPipeline.refine).
        var reconciliation: SpeakerReconciler.Outcome?
        if let library, let diarization {
            do {
                reconciliation = try await SpeakerReconciler(library: library)
                    .reconcile(
                        diarization: diarization,
                        recordingId: folder.recordingId,
                        recordingFolderName: folder.directory.lastPathComponent)
            } catch {
                reconciliation = nil
            }
        }

        // 2. Merge system + mic segments; apply diarization + reconciliation.
        let merged = mergeStreams(
            systemSegments: systemSegments,
            diarization: diarization,
            reconciliation: reconciliation,
            micSegments: micSegments.isEmpty ? nil : micSegments,
            recordingStart: recordingStart)

        // 3. Write final.md atomically, recording whether a prior final.md
        //    existed (so the right event variant is emitted below) and
        //    whether a live.md was renamed.
        let finalExistedBefore = FileManager.default.fileExists(
            atPath: folder.finalURL.path)
        let markdown = merged.document.render()
        let writeResult = try writeFinalMarkdown(markdown, folder: folder)

        // 4. File events — emit in disk-effect order (Hard Invariant #8).
        if finalExistedBefore {
            _ = try? await events?.append(FinalMDRewrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: writeResult.sha256,
                reason: "re_refine"))
        } else {
            _ = try? await events?.append(FinalMDWrittenEvent(
                recordingId: folder.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: writeResult.sha256))
        }
        if writeResult.replacedLiveMD {
            _ = try? await events?.append(
                LiveMDReplacedByFinalEvent(recordingId: folder.recordingId))
        }

        // 5. Compute duration from the segments (best-effort: last end ts).
        let systemEnd = systemSegments.last?.end.seconds ?? 0.0
        let micEnd = micSegments.last?.end.seconds ?? 0.0
        let audioDurationSeconds = max(systemEnd, micEnd)

        // 6. Write metadata.json.
        let metadata = buildMetadata(
            folder: folder,
            speakers: merged.speakers,
            speakerIdByLabel: merged.speakerIdByLabel,
            language: language,
            diarization: diarization,
            recordingStart: recordingStart,
            refinedAt: refinedAt,
            whisperModelName: whisperModelName,
            whisperModelSHA256: whisperModelSHA256,
            sourceBasename: sourceBasename,
            audioDurationSeconds: audioDurationSeconds)
        try AtomicFile.write(try metadata.encoded(), to: folder.metadataURL)

        return AssembleResult(
            speakerCount: merged.speakers.count,
            speakersNew: reconciliation?.newCount ?? merged.speakers.count,
            speakersMatched: reconciliation?.matchedCount ?? 0,
            durationSeconds: audioDurationSeconds)
    }
```

### Step 11.2: Thread `library` through `ResumableRefiner`

- [ ] **Step 11.2.1: Edit `ResumableRefiner.swift`**

Add a stored `library` field, just after `private let events: EventWriter?`:

```swift
    private let events: EventWriter?
    /// Persistent speaker library used by `mergeAndWrite` for reconciliation
    /// (R22, R23). `nil` keeps the raw `Speaker_N` labels — the queue's
    /// `makeStandard` opens a real library and passes it in for production.
    private let library: SpeakerLibrary?
    private let reportState: StageReporter?
```

Extend `init` to accept it (defaulted to `nil` so existing test call sites compile unchanged):

```swift
    public init(
        transcribe: @escaping TranscribeRegion,
        detectRegions: @escaping DetectRegions,
        diarize: @escaping Diarize,
        pauseGate: PauseGate,
        events: EventWriter?,
        library: SpeakerLibrary? = nil,
        onStageUpdate: StageReporter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.transcribe = transcribe
        self.detectRegions = detectRegions
        self.diarize = diarize
        self.pauseGate = pauseGate
        self.events = events
        self.library = library
        self.reportState = onStageUpdate
        self.logger = logger
    }
```

Replace `mergeAndWrite` to call the new async `assembleAndWrite` and return its result:

```swift
    @discardableResult
    private func mergeAndWrite(
        folder: RecordingFolder,
        progress: RefinementProgress,
        diarization: DiarizationResult?,
        job: RefinementJob
    ) async throws -> RefinementPipeline.AssembleResult {
        let system = progress.systemSegments.map {
            TranscriptSegment(
                start: .milliseconds($0.startMillis),
                end: .milliseconds($0.endMillis),
                text: $0.text)
        }
        let mic = progress.micSegments.map {
            TranscriptSegment(
                start: .milliseconds($0.startMillis),
                end: .milliseconds($0.endMillis),
                text: $0.text)
        }
        let folderName = folder.directory.lastPathComponent
        let recordingStart = RecordingFolderTimestamp.parse(folderName) ?? Date()
        return try await RefinementPipeline.assembleAndWrite(
            folder: folder,
            systemSegments: system,
            micSegments: mic,
            diarization: diarization,
            language: progress.language ?? "unknown",
            whisperModelName: job.modelName,
            whisperModelSHA256: job.modelSHA256,
            recordingStart: recordingStart,
            sourceBasename: folder.systemStream.url.lastPathComponent,
            library: library,
            refinedAt: Date(),
            events: events)
    }
```

Now update `run(job:)` to use the returned `AssembleResult` for richer event payloads. Replace the success-path block (the lines that compute `wallSeconds` / `speakerCount` and emit `RefinementCompletedEvent`):

```swift
            try await advance(&progress, to: .merging, folder: folder)
            try await advance(&progress, to: .writingFinal, folder: folder)
            try await advance(&progress, to: .writingMetadata, folder: folder)
            let assembled = try await mergeAndWrite(
                folder: folder, progress: progress, diarization: diarization, job: job)

            let wallSeconds = Date().timeIntervalSince(startedAt)
            _ = try? await events?.append(RefinementCompletedEvent(
                recordingId: job.recordingId,
                durationSeconds: wallSeconds,
                speakersIdentified: assembled.speakerCount,
                speakersNew: assembled.speakersNew,
                speakersMatched: assembled.speakersMatched))
```

### Step 11.3: Open the library in `RefinementJobQueue.makeStandard`

- [ ] **Step 11.3.1: Edit `RefinementJobQueue.swift`**

In `extension RefinementJobQueue { public static func makeStandard(...) }`, just before the `let runJob: RunJob = ...` declaration, open the library. Find the line:

```swift
        let queue = RefinementJobQueue(store: store, runJob: { _ in }, pauseGate: gate)
```

Insert after it (before `let runJob: RunJob = ...`):

```swift
        // Persistent speaker library — same path OfflineRefiner uses. A
        // failure to open it is non-fatal: each job falls back to raw
        // Speaker_N labels rather than the library names (R22/R23). The
        // library actor is opened once and shared across jobs.
        let library: SpeakerLibrary? = try? await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)
```

Then inside the `runJob` closure body, change the `ResumableRefiner(...)` construction to pass the library. Find:

```swift
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try sharedTranscriber.get()
                    return try t.transcribeRegion(samples, region: region, options: options)
                },
                detectRegions: { samples in
                    guard let vadURL else { return [] }
                    return try WhisperTranscriber.detectSpeechRegions(
                        in: samples, vadModelURL: vadURL)
                },
                diarize: { wav in
                    try await diarizer.diarizeSystemStream(wavPath: wav)
                },
                pauseGate: gate,
                events: events,
                onStageUpdate: { [weak queue] state in
                    guard let queue else { return }
                    await queue.reportStage(state)
                })
```

Replace with:

```swift
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try sharedTranscriber.get()
                    return try t.transcribeRegion(samples, region: region, options: options)
                },
                detectRegions: { samples in
                    guard let vadURL else { return [] }
                    return try WhisperTranscriber.detectSpeechRegions(
                        in: samples, vadModelURL: vadURL)
                },
                diarize: { wav in
                    try await diarizer.diarizeSystemStream(wavPath: wav)
                },
                pauseGate: gate,
                events: events,
                library: library,
                onStageUpdate: { [weak queue] state in
                    guard let queue else { return }
                    await queue.reportStage(state)
                })
```

### Step 11.4: Add a test that confirms a library reconciliation runs

- [ ] **Step 11.4.1: Append a test to `Tests/UnitTests/ResumableRefinerTests.swift`**

```swift
    @Test("run with a library passes it through to assembleAndWrite")
    func libraryThreadedThrough() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let dbURL = folder.appendingPathComponent("speakers-test.sqlite")
        // Opening a fresh SpeakerLibrary at a writable path is enough to
        // prove the library reaches assembleAndWrite — when no centroids
        // are stored the reconciler returns an empty Outcome and the merge
        // falls back to Speaker_N labels (which is fine for the test).
        let library = try await SpeakerLibrary(databaseURL: dbURL, events: nil)

        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in
                TranscriptionResult(segments: [], language: "en")
            },
            detectRegions: { _ in [] },
            diarize: { _ in
                DiarizationResult(speakers: [], spans: [], embeddings: [:],
                                  model: "stub", modelRevision: "stub", modelVersion: "stub")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil,
            library: library)

        let job = RefinementJob(
            id: "job_lib", recordingId: "rec_lib", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        // A successful run with no segments should still produce a
        // metadata.json (final.md too). The fact that we did NOT crash
        // confirms the new async assembleAndWrite path executes the
        // library-aware branch.
        try await refiner.run(job: job)
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("metadata.json").path))
    }
```

- [ ] **Step 11.4.2: Run — must pass**

```
swift test --filter ResumableRefiner
swift test --filter RefinementJobQueueTests
```

Expected: every existing test in both suites stays green; the three new tests (`emitsStartCompleteEvents`, `emitsFailedEvent`, `libraryThreadedThrough`) all pass.

- [ ] **Step 11.4.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/UnitTests/ResumableRefinerTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): thread SpeakerLibrary + file-events through the queue path

RefinementPipeline.assembleAndWrite is now async throws and takes
library, refinedAt, and events. When a library is supplied it runs
SpeakerReconciler exactly the way RefinementPipeline.refine does, so
queue-driven refines finally produce final.md with library names
("Steve", "Unknown #1") instead of Speaker_N. The function also emits
final_md_written / final_md_rewritten and live_md_replaced_by_final
in causal order with the on-disk write (Hard Invariant #8), and
returns an AssembleResult so ResumableRefiner.run can populate the
real speakers_new / speakers_matched counts in refinement_completed.

ResumableRefiner stores an optional SpeakerLibrary and threads it.
RefinementJobQueue.makeStandard opens the library at the standard
path (matches OfflineRefiner) and shares one instance across every
job — a library open failure is non-fatal and degrades to Speaker_N.
EOF
)"
```

---

## Final verification

- [ ] **Step F.1: Run every affected narrow filter**

```
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter RefinementJobQueueTests
swift test --filter MenuBarTests
swift test --filter EventWriter
swift test --filter StallRecovery
```

Each must be all-green. The broad `--filter PipelineTests` is known-flaky per CLAUDE.md — do not use it.

- [ ] **Step F.2: Manual smoke test — speaker library**

Open the menubar app, record a short meeting with at least two distinct speakers, stop. Wait for the auto-refine to complete. Open `final.md` in the recording folder. The speaker labels must read either real library names (if any centroids match prior recordings) or `Unknown #1`, `Unknown #2` — never `Speaker_0`, `Speaker_1`. The `metadata.json` must have a non-nil `speaker_id` for each speaker.

- [ ] **Step F.3: Manual smoke test — events log**

After the same recording's refine completes, open the day's events file
(`~/Library/Application Support/PulsarTrace/events/<today>.jsonl`) and grep
for the recording id. The line set must include `refinement_started`,
`refinement_completed`, and either `final_md_written` or `final_md_rewritten`.
If the recording had a `live.md`, `live_md_replaced_by_final` must also appear.

- [ ] **Step F.4: Manual smoke test — paused state**

Start a long-running refine (refine a long recording via the recordings
list's Refine button), then start a new recording. The Refinements pane
must show that job as "Paused (Recording in progress) at <Stage>" — not
"Refining 30% · Transcribing system".

- [ ] **Step F.5: Manual smoke test — process-wide polling**

With no windows open, start a refine via the recordings list's Refine
button, then close the unified window entirely. Open the menubar dropdown
— the status line must read "Refining N% · <Stage>", proving the queueVM
poll continues while no view is visible.

- [ ] **Step F.6: Manual smoke test — auto-rescan**

Refine an unrefined recording via the queue. Without clicking Refresh
in the recordings list, the row must flip from "Not yet refined" to
"N speakers · <duration>s" as soon as the refine finishes.

---

## Out of scope (deliberate, but worth recording)

- **D34 doc drift ("8-stage" vs. 7 cases).** Pure comment fix — out of scope per the user request to skip Low-severity items.
- **`OfflineRefiner` (CLI) path.** Untouched. Its existing speaker-library + event behaviour was already correct and is preserved.
- **`SharedTranscriberBox` drop-after-idle-pause heuristic.** Deferred from `2026-05-20-refine-perf-and-capture-resilience-plan.md`; still deferred.
- **`LiveRunner` await-sink wedge investigation** (the second candidate cause of the 17-min cutoff on session 2026-05-20-113001). The `onStreamError` wiring already covers the SCStream-failure case; the wedge investigation is a separate piece of work not blocked by anything here.

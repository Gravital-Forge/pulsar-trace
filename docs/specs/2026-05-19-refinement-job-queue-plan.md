# Refinement Job Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three ad-hoc refine trigger sites with a single persistent, pause-resumable job queue that is observable from a dedicated "Refinements" pane, and decouple recording from refinement so a new recording can start immediately while a refine is in flight.

**Architecture:** A single-worker `RefinementJobQueue` actor owns every refine. Jobs are described by a `RefinementJob` value type, persisted as JSON under `~/Library/Application Support/PulsarTrace/refinement-queue/` so a crash or quit resumes them on next launch. The refine pass itself is split into eight stages with a JSON checkpoint file (`refine-progress.json`) written into the recording folder; the worker awaits a `PauseGate` between stages and between whisper VAD regions, and **kills the pyannote subprocess on pause** (it is re-run from scratch on resume — see D-Q7). When a recording starts, the queue is asked to pause; when the recording stops the queue resumes (and any post-recording refine is enqueued onto the existing queue rather than running inline).

**Tech Stack:** Swift 6.2 concurrency (actor + `@Observable`), JSON-on-disk persistence (`AtomicFile`), POSIX SIGSTOP/SIGCONT for the pyannote subprocess, SwiftUI for the Refinements pane. No new third-party dependencies.

---

## Decisions (defaults — flag before execution if you disagree)

These choices are baked into the tasks below. They match the prose in the request; flag any you want changed before execution starts.

- **D-Q1 — Queue UI placement.** A new sidebar section `Refinements` added to `MainWindowView`, alongside Recordings / Speakers / Settings. The Recordings list stays focused on recordings; per-recording state is summarised by a "Refining…" / "Queued" badge in the row, but the queue itself lives in its own pane. (User prompt: *"dedicated sub-page probably"*.)
- **D-Q2 — Recording vs. refine resource policy.** Auto-pause + auto-resume. Starting a recording calls `queue.pauseForRecording()` (which SIGSTOPs any in-flight pyannote subprocess and keeps whisper between VAD regions); stopping the recording enqueues the auto-refine and then calls `queue.resumeAfterRecording()`, which first finishes the previously-paused job before starting the newly-enqueued one. There is no user prompt to defer.
- **D-Q3 — `RecordingStatus.refining` is removed.** With the queue owning refine state, the recording state machine collapses to `.idle / .launching / .recording / .crashed / .error`. The menubar icon picks up refining state from the queue (a separate publisher), so a recording can be started from `.idle` even while the queue has a running job — exactly the back-to-back meetings case the request calls out.
- **D-Q4 — Per-recording at-most-one job.** Re-clicking "Refine" on a recording that is already queued or running is a no-op (the existing job is surfaced). The job's `model` is captured at enqueue time, so changing the model setting mid-queue affects only future enqueues.
- **D-Q5 — Checkpoint file is in-folder, not in the queue store.** `refine-progress.json` lives next to `metadata.json` in the recording folder, so a folder is portable: copying it to another machine carries its in-flight refine state. The queue store under `~/Library/Application Support/PulsarTrace/refinement-queue/` only holds the job descriptor + last-known stage; the recording folder holds the actual work.
- **D-Q6 — Re-do granularity.** Whisper transcription is checkpointed at VAD region boundaries (the loop already exists inside `WhisperTranscriber.transcribe(_:regions:)` and is lifted into `RefinementPipeline`). A pause mid-region completes that region (typically ≤ a few seconds of audio) before yielding. Diarization is single-shot pyannote and is restarted from scratch if interrupted — the user's budget ("re-processing the last 5 minutes is probably ok") accommodates this for typical recording lengths.
- **D-Q7 — Diarizer pause = kill + re-run.** When `pauseForRecording` fires mid-diarize, the queue calls `Diarizer.cancel()` which terminates the pyannote subprocess (no SIGSTOP/SIGCONT). When the gate reopens after the recording stops, the refiner re-enters the diarization stage and starts a fresh subprocess. Re-loading the pyannote model takes 10–30s — accepted cost over the complexity of keeping a SIGSTOPped subprocess alive across sleep/wake and FD churn. Whisper is still checkpointed at region boundaries, so only the diarize stage pays the re-run cost.

---

## File Structure

### New files

```
Sources/PulsarTraceEngine/Refinement/Jobs/
  RefinementJob.swift              // Value type — id, recordingId, folderURL, model, trigger, state.
  RefinementJobState.swift         // .queued / .running / .paused / .completed / .failed / .cancelled.
  RefinementProgress.swift         // Stage + completed-regions + partial-segments JSON model
                                   // (the `refine-progress.json` schema).
  RefinementJobStore.swift         // Actor — JSON-on-disk persistence under
                                   // ~/Library/Application Support/PulsarTrace/refinement-queue/.
  RefinementJobQueue.swift         // Actor — the single-worker queue. Owns one PauseGate;
                                   // dispatches one ResumableRefiner at a time; emits @Observable
                                   // snapshots for the UI.
  PauseGate.swift                  // One-shot pause/resume primitive (actor) the refiner awaits
                                   // between stages and between regions.
  ResumableRefiner.swift           // Replaces OfflineRefiner. Reads refine-progress.json if present,
                                   // runs stages; persists progress between regions and stages.

Sources/PulsarTraceMenuBar/
  RefinementJobQueueViewModel.swift  // Main-actor @Observable façade over RefinementJobQueue —
                                     // the SwiftUI views bind to this.

Sources/pulsartrace-mac/
  RefinementsListView.swift        // The new sidebar pane — Running / Queued / Recent sections.

Tests/UnitTests/
  RefinementJobTests.swift         // Job + state Codable round-trip.
  RefinementJobStoreTests.swift    // Store actor — persist, list, prune, recover.
  RefinementProgressTests.swift    // Progress file Codable round-trip + region-skip logic.
  PauseGateTests.swift             // Open/close/await semantics.
  ResumableRefinerTests.swift      // Resume-from-checkpoint with a stub transcriber/diarizer.

Tests/PipelineTests/
  RefinementJobQueueTests.swift    // End-to-end queue: enqueue, pause-for-recording,
                                   // auto-resume, cancel, failure-propagation.

Tests/MenuBarTests/
  RefinementJobQueueViewModelTests.swift
                                   // VM façade — exposes correct @Observable state.
```

### Modified files

```
Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift
  // Lift the whisper VAD-region loop out of WhisperTranscriber so the pipeline
  // can checkpoint and pause between regions. Accept an injected
  // RefinementProgress and a PauseGate. Existing whole-buffer path stays
  // for the no-VAD edge case.

Sources/PulsarTraceEngine/Diarization/Diarizer.swift
  // Add pause()/resume() that send SIGSTOP/SIGCONT to the in-flight Python
  // process. No-op when no process is running.

Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift
  // Mark deprecated. ResumableRefiner takes over; OfflineRefiner stays for
  // the `pulsartrace refine` CLI (which doesn't need the queue), but its
  // body delegates to ResumableRefiner with a no-op PauseGate + a
  // throwaway progress file.

Sources/PulsarTraceMenuBar/MenuBarState.swift
  // Remove .refining. RecordingStatus is now { .idle, .launching, .recording,
  // .crashed, .error }.

Sources/PulsarTraceMenuBar/RecordingViewModel.swift
  // stopRecording() and recoverFromCrash() enqueue onto the queue instead of
  // running OfflineRefiner inline. Status returns to .idle once stop has
  // flushed; the queue handles refine state independently.

Sources/PulsarTraceMenuBar/RecordingsScanner.swift
  // reRefine() enqueues onto the queue instead of calling OfflineRefiner.
  // isScanning still gates the scan itself; the refine status is read off
  // the queue VM.

Sources/pulsartrace-mac/AppNavigation.swift
  // AppSection adds .refinements.

Sources/pulsartrace-mac/MainWindowView.swift
  // detail switch adds the .refinements branch → RefinementsListView.

Sources/pulsartrace-mac/PulsarTraceMacApp.swift
  // AppEnvironment owns a RefinementJobQueue (+ ViewModel). recording.scanner
  // and the queue ViewModel are injected into the unified window's environment.
  // installHotkeyMonitor / .idle-only check broadens: a recording can now be
  // started while the queue is running.

Sources/pulsartrace-mac/MenuBarMenuView.swift
  // Status text picks up queue activity ("Refining 1/3 · 62%") instead of
  // .refining on the recording status. "Start Recording" enabled even when
  // the queue is busy (the queue auto-pauses).

Sources/pulsartrace-mac/RecordingsListView.swift
  // Each row's Refine button calls queue.enqueueManualRefine(folder). The
  // row shows a small badge ("Refining", "Queued", "Refined", "Failed")
  // computed from the latest job for that recordingId.
```

---

## Phase A — Job model and queue store

Pure data types and on-disk persistence. No integration. Every task in this phase ships independently green tests; nothing in the app calls into it yet.

### Task A1: `RefinementJob` value type

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJob.swift`
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobState.swift`
- Test:   `Tests/UnitTests/RefinementJobTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/UnitTests/RefinementJobTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementJob")
struct RefinementJobTests {

    @Test("a queued job round-trips through JSON")
    func roundTripQueued() throws {
        let job = RefinementJob(
            id: "job_01HZ",
            recordingId: "rec_2026-05-19-1430",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base",
            modelSHA256: "deadbeef",
            trigger: .autoPostRecording,
            enqueuedAt: Date(timeIntervalSince1970: 1_716_120_000),
            state: .queued)

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RefinementJob.self, from: data)
        #expect(decoded == job)
    }

    @Test("state .running carries a stage and a progress fraction")
    func runningCarriesProgress() {
        let state: RefinementJobState = .running(
            stage: .transcribingSystem,
            stepsCompleted: 3,
            stepsTotal: 6,
            regionIndex: 4,
            regionsTotal: 12)
        #expect(state.progressFraction != nil)
        #expect(state.progressFraction! > 0.0 && state.progressFraction! < 1.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobTests
```

Expected: compile error — `RefinementJob` / `RefinementJobState` not defined.

- [ ] **Step 3: Write `RefinementJobState`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobState.swift
import Foundation

/// One job's lifecycle in the queue.
///
/// Lifecycle: `.queued` → `.running` → (`.paused`?) → `.completed` | `.failed` | `.cancelled`.
/// A job can move from `.running` to `.paused` and back any number of times
/// (e.g. each time a recording starts mid-refine); `.cancelled` is terminal.
public enum RefinementJobState: Codable, Equatable, Sendable {

    /// One stage of the refine pipeline. Matches `RefinementPipeline.Stage`
    /// 1:1 so a progress reporter can map between them.
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case resolvingInput
        case transcribingSystem
        case diarizing
        case transcribingMic
        case merging
        case writingFinal
        case writingMetadata
    }

    /// Why the queue paused this job.
    public enum PauseReason: String, Codable, Sendable {
        case userRequested
        case recordingInProgress
    }

    case queued
    case running(stage: Stage, stepsCompleted: Int, stepsTotal: Int,
                 regionIndex: Int?, regionsTotal: Int?)
    case paused(reason: PauseReason, lastStage: Stage)
    case completed(durationSeconds: Double, speakerCount: Int)
    case failed(errorClass: String, retryAvailable: Bool)
    case cancelled

    /// Fraction in `0...1` if the queue can estimate progress, else `nil`.
    ///
    /// The estimate weights each completed stage as `1/stepsTotal` and within
    /// the running stage scales by `regionIndex/regionsTotal` when whisper
    /// is running, otherwise by 0.5 (single-shot stages like diarization
    /// report half-credit while in flight — not 0, not 1).
    public var progressFraction: Double? {
        switch self {
        case .queued, .cancelled, .failed: return nil
        case .completed: return 1.0
        case .paused: return nil
        case .running(_, let done, let total, let regionIdx, let regionsTotal):
            guard total > 0 else { return nil }
            let base = Double(done) / Double(total)
            let perStage = 1.0 / Double(total)
            if let regionIdx, let regionsTotal, regionsTotal > 0 {
                return base + perStage * Double(regionIdx) / Double(regionsTotal)
            }
            return base + perStage * 0.5
        }
    }
}
```

- [ ] **Step 4: Write `RefinementJob`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJob.swift
import Foundation

/// One queued refinement job. Persisted as JSON under
/// `~/Library/Application Support/PulsarTrace/refinement-queue/<id>.json`
/// (D-Q5) so a crash or quit resumes pending work on next launch.
///
/// The job descriptor is small and immutable apart from `state`. The actual
/// in-flight work — partial transcripts, completed VAD regions — lives in
/// `refine-progress.json` inside the recording folder, not here (D-Q5).
public struct RefinementJob: Codable, Equatable, Sendable, Identifiable {

    /// What triggered this job — informational, used by the UI badge.
    public enum Trigger: String, Codable, Sendable {
        case autoPostRecording      // RecordingViewModel.stopRecording → auto-enqueue
        case manual                 // Recordings list "Refine" button
        case crashRecovery          // RecordingViewModel.recoverFromCrash → auto-enqueue
    }

    public let id: String                  // ULID-derived (`job_<ulid>`).
    public let recordingId: String         // Stable id from RecordingFolder.recordingId.
    public let folderURL: URL              // The recording folder to refine.
    public let modelName: String           // Whisper model captured at enqueue (D-Q4).
    public let modelSHA256: String         // Captured for an audit-able metadata.json.
    public let trigger: Trigger
    public let enqueuedAt: Date
    public var state: RefinementJobState

    public init(
        id: String,
        recordingId: String,
        folderURL: URL,
        modelName: String,
        modelSHA256: String,
        trigger: Trigger,
        enqueuedAt: Date,
        state: RefinementJobState
    ) {
        self.id = id
        self.recordingId = recordingId
        self.folderURL = folderURL
        self.modelName = modelName
        self.modelSHA256 = modelSHA256
        self.trigger = trigger
        self.enqueuedAt = enqueuedAt
        self.state = state
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
swift test --filter RefinementJobTests
```

Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJob.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobState.swift \
        Tests/UnitTests/RefinementJobTests.swift
git commit -m "feat(refine): add RefinementJob + RefinementJobState value types"
```

---

### Task A2: `RefinementJobStore` actor — list + persist

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift`
- Test:   `Tests/UnitTests/RefinementJobStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/UnitTests/RefinementJobStoreTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementJobStore")
struct RefinementJobStoreTests {

    /// Fresh temp directory per test.
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-jobstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a persisted job is readable back through listAll()")
    func persistAndList() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        let job = RefinementJob(
            id: "job_01HZ",
            recordingId: "rec_x",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual,
            enqueuedAt: Date(timeIntervalSince1970: 1_716_120_000),
            state: .queued)

        try await store.upsert(job)
        let all = try await store.listAll()
        #expect(all.count == 1)
        #expect(all.first == job)
    }

    @Test("upsert overwrites a job with the same id")
    func upsertOverwrites() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        var job = RefinementJob(
            id: "job_01HZ", recordingId: "rec_x",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await store.upsert(job)

        job.state = .completed(durationSeconds: 42.0, speakerCount: 2)
        try await store.upsert(job)

        let all = try await store.listAll()
        #expect(all.count == 1)
        #expect(all.first?.state == .completed(durationSeconds: 42.0, speakerCount: 2))
    }

    @Test("delete removes the job's file")
    func deleteRemovesFile() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        let job = RefinementJob(
            id: "job_01HZ", recordingId: "rec_x",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await store.upsert(job)
        try await store.delete(id: job.id)
        let all = try await store.listAll()
        #expect(all.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobStoreTests
```

Expected: compile error — `RefinementJobStore` not defined.

- [ ] **Step 3: Write the store**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift
import Foundation

/// JSON-on-disk persistence for the refinement queue (D-Q5).
///
/// One file per job: `<id>.json`. Atomic writes via `AtomicFile` so a crash
/// mid-write cannot corrupt a job descriptor. The actor is the single writer
/// per process; readers see consistent file content (rename-into-place).
public actor RefinementJobStore {

    public enum StoreError: Error, CustomStringConvertible, Equatable {
        case directoryCreateFailed(String)
        case encodeFailed(String)
        case writeFailed(String)
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .directoryCreateFailed(let m): return "queue dir create failed: \(m)"
            case .encodeFailed(let m): return "job encode failed: \(m)"
            case .writeFailed(let m): return "job write failed: \(m)"
            case .decodeFailed(let m): return "job decode failed: \(m)"
            }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Standard location: `~/Library/Application Support/PulsarTrace/refinement-queue/`.
    public static func standard(paths: AppPaths) -> RefinementJobStore {
        let dir = paths.applicationSupport
            .appendingPathComponent("refinement-queue", isDirectory: true)
        return RefinementJobStore(directory: dir)
    }

    /// Write or overwrite one job.
    public func upsert(_ job: RefinementJob) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(job) }
        catch { throw StoreError.encodeFailed("\(error)") }
        do { _ = try AtomicFile.write(data, to: url(for: job.id)) }
        catch { throw StoreError.writeFailed("\(error)") }
    }

    /// Remove one job's file.
    public func delete(id: String) throws {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Every persisted job, sorted by `enqueuedAt` ascending.
    public func listAll() throws -> [RefinementJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var jobs: [RefinementJob] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry) else { continue }
            // One bad file must not fail the whole scan (parallel to
            // RecordingsScanner — see Sources/PulsarTraceMenuBar/RecordingsScanner.swift).
            guard let job = try? decoder.decode(RefinementJob.self, from: data)
            else { continue }
            jobs.append(job)
        }
        jobs.sort { $0.enqueuedAt < $1.enqueuedAt }
        return jobs
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StoreError.directoryCreateFailed("\(error)")
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobStoreTests
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift \
        Tests/UnitTests/RefinementJobStoreTests.swift
git commit -m "feat(refine): add RefinementJobStore for queue persistence"
```

---

### Task A3: prune terminal jobs older than N days

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift`
- Modify: `Tests/UnitTests/RefinementJobStoreTests.swift`

- [ ] **Step 1: Write the failing test (append)**

```swift
// Tests/UnitTests/RefinementJobStoreTests.swift — append inside the suite

@Test("pruneTerminal deletes completed/failed/cancelled jobs older than the cutoff")
func pruneTerminal() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RefinementJobStore(directory: dir)

    let old = Date(timeIntervalSinceNow: -8 * 86400)
    let now = Date()

    let stale = RefinementJob(
        id: "job_old", recordingId: "rec_a",
        folderURL: URL(fileURLWithPath: "/tmp/a"),
        modelName: "base", modelSHA256: "deadbeef",
        trigger: .manual, enqueuedAt: old,
        state: .completed(durationSeconds: 1.0, speakerCount: 1))
    let fresh = RefinementJob(
        id: "job_new", recordingId: "rec_b",
        folderURL: URL(fileURLWithPath: "/tmp/b"),
        modelName: "base", modelSHA256: "deadbeef",
        trigger: .manual, enqueuedAt: now,
        state: .completed(durationSeconds: 1.0, speakerCount: 1))
    let active = RefinementJob(
        id: "job_act", recordingId: "rec_c",
        folderURL: URL(fileURLWithPath: "/tmp/c"),
        modelName: "base", modelSHA256: "deadbeef",
        trigger: .manual, enqueuedAt: old,
        state: .queued)

    try await store.upsert(stale)
    try await store.upsert(fresh)
    try await store.upsert(active)

    try await store.pruneTerminal(olderThanDays: 7, now: { Date() })

    let ids = Set(try await store.listAll().map(\.id))
    #expect(ids == ["job_new", "job_act"])
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobStoreTests/pruneTerminal
```

Expected: compile error — `pruneTerminal` not defined.

- [ ] **Step 3: Add `pruneTerminal` to the store**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift
// Add inside the `RefinementJobStore` actor body.

/// Delete every terminal job (`.completed`, `.failed`, `.cancelled`) older
/// than `olderThanDays`. Active/paused/queued jobs are never pruned.
public func pruneTerminal(
    olderThanDays days: Int,
    now: @Sendable () -> Date = { Date() }
) throws {
    let cutoff = now().addingTimeInterval(-Double(days) * 86400)
    for job in try listAll() {
        let isTerminal: Bool
        switch job.state {
        case .completed, .failed, .cancelled: isTerminal = true
        case .queued, .running, .paused:      isTerminal = false
        }
        if isTerminal, job.enqueuedAt < cutoff {
            try delete(id: job.id)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobStoreTests
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift \
        Tests/UnitTests/RefinementJobStoreTests.swift
git commit -m "feat(refine): add pruneTerminal to RefinementJobStore"
```

---

### Task A4: `RefinementProgress` checkpoint schema

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift`
- Test:   `Tests/UnitTests/RefinementProgressTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/UnitTests/RefinementProgressTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementProgress")
struct RefinementProgressTests {

    @Test("an empty progress at .resolvingInput round-trips")
    func roundTripEmpty() throws {
        let progress = RefinementProgress(
            schemaVersion: 1,
            jobId: "job_x",
            recordingId: "rec_x",
            stage: .resolvingInput,
            systemRegions: [],
            completedSystemRegionIndices: [],
            systemSegments: [],
            micRegions: [],
            completedMicRegionIndices: [],
            micSegments: [],
            language: nil,
            lastCheckpointAt: Date(timeIntervalSince1970: 1_716_120_000))

        let data = try progress.encoded()
        let decoded = try RefinementProgress.decode(data)
        #expect(decoded == progress)
    }

    @Test("nextSystemRegionIndex returns the lowest index not yet completed")
    func nextSystemRegion() {
        var p = RefinementProgress.empty(jobId: "j", recordingId: "r")
        p.systemRegions = (0..<5).map {
            RefinementProgress.RegionWindow(
                startMillis: $0 * 1000, endMillis: ($0 + 1) * 1000)
        }
        p.completedSystemRegionIndices = [0, 1, 2]
        #expect(p.nextSystemRegionIndex == 3)

        p.completedSystemRegionIndices = [0, 2, 4]
        #expect(p.nextSystemRegionIndex == 1)  // index 1 still pending

        p.completedSystemRegionIndices = [0, 1, 2, 3, 4]
        #expect(p.nextSystemRegionIndex == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementProgressTests
```

Expected: compile error — `RefinementProgress` not defined.

- [ ] **Step 3: Write `RefinementProgress`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift
import Foundation

/// The `refine-progress.json` checkpoint file written into the recording
/// folder by `ResumableRefiner` (D-Q5/D-Q6).
///
/// Lives next to `metadata.json` so the recording folder is self-contained:
/// copying the folder to another machine carries the in-flight refine state.
/// The queue-side `RefinementJob` is just a pointer; this file is the work.
public struct RefinementProgress: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    /// One VAD region of one stream — `[startMillis, endMillis)` in recording
    /// time. Indices in `completed*RegionIndices` refer to positions in the
    /// matching `*Regions` array.
    public struct RegionWindow: Codable, Equatable, Sendable {
        public let startMillis: Int
        public let endMillis: Int

        private enum CodingKeys: String, CodingKey {
            case startMillis = "start_ms"
            case endMillis = "end_ms"
        }

        public init(startMillis: Int, endMillis: Int) {
            self.startMillis = startMillis
            self.endMillis = endMillis
        }
    }

    /// One transcript segment — same shape `TranscriptSegment` serializes to.
    /// Kept structurally identical so the merge step at the end can lift
    /// segments back into `TranscriptSegment`s with no schema translation.
    public struct PartialSegment: Codable, Equatable, Sendable {
        public let startMillis: Int
        public let endMillis: Int
        public let text: String
        public let regionIndex: Int  // which region produced this segment

        private enum CodingKeys: String, CodingKey {
            case startMillis = "start_ms"
            case endMillis = "end_ms"
            case text
            case regionIndex = "region_index"
        }

        public init(startMillis: Int, endMillis: Int, text: String, regionIndex: Int) {
            self.startMillis = startMillis
            self.endMillis = endMillis
            self.text = text
            self.regionIndex = regionIndex
        }
    }

    public var schemaVersion: Int
    public var jobId: String
    public var recordingId: String
    public var stage: RefinementJobState.Stage

    public var systemRegions: [RegionWindow]
    public var completedSystemRegionIndices: [Int]
    public var systemSegments: [PartialSegment]

    public var micRegions: [RegionWindow]
    public var completedMicRegionIndices: [Int]
    public var micSegments: [PartialSegment]

    /// Language detected on the first decoded region; reused for later regions
    /// so a quiet region's auto-detect can't disagree.
    public var language: String?

    public var lastCheckpointAt: Date

    public init(
        schemaVersion: Int,
        jobId: String,
        recordingId: String,
        stage: RefinementJobState.Stage,
        systemRegions: [RegionWindow],
        completedSystemRegionIndices: [Int],
        systemSegments: [PartialSegment],
        micRegions: [RegionWindow],
        completedMicRegionIndices: [Int],
        micSegments: [PartialSegment],
        language: String?,
        lastCheckpointAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.jobId = jobId
        self.recordingId = recordingId
        self.stage = stage
        self.systemRegions = systemRegions
        self.completedSystemRegionIndices = completedSystemRegionIndices
        self.systemSegments = systemSegments
        self.micRegions = micRegions
        self.completedMicRegionIndices = completedMicRegionIndices
        self.micSegments = micSegments
        self.language = language
        self.lastCheckpointAt = lastCheckpointAt
    }

    public static func empty(jobId: String, recordingId: String) -> RefinementProgress {
        RefinementProgress(
            schemaVersion: currentSchemaVersion,
            jobId: jobId,
            recordingId: recordingId,
            stage: .resolvingInput,
            systemRegions: [],
            completedSystemRegionIndices: [],
            systemSegments: [],
            micRegions: [],
            completedMicRegionIndices: [],
            micSegments: [],
            language: nil,
            lastCheckpointAt: Date(timeIntervalSince1970: 0))
    }

    /// The lowest system-stream region index not yet completed, or `nil` if
    /// every region in `systemRegions` has been processed.
    public var nextSystemRegionIndex: Int? {
        let done = Set(completedSystemRegionIndices)
        for i in systemRegions.indices where !done.contains(i) { return i }
        return nil
    }

    /// The lowest mic-stream region index not yet completed.
    public var nextMicRegionIndex: Int? {
        let done = Set(completedMicRegionIndices)
        for i in micRegions.indices where !done.contains(i) { return i }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobId = "job_id"
        case recordingId = "recording_id"
        case stage
        case systemRegions = "system_regions"
        case completedSystemRegionIndices = "completed_system_region_indices"
        case systemSegments = "system_segments"
        case micRegions = "mic_regions"
        case completedMicRegionIndices = "completed_mic_region_indices"
        case micSegments = "mic_segments"
        case language
        case lastCheckpointAt = "last_checkpoint_at"
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        var data = try e.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> RefinementProgress {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(RefinementProgress.self, from: data)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementProgressTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift \
        Tests/UnitTests/RefinementProgressTests.swift
git commit -m "feat(refine): add RefinementProgress checkpoint schema"
```

---

## Phase B — ResumableRefiner and pause primitive

### Task B1: `PauseGate` primitive

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/PauseGate.swift`
- Test:   `Tests/UnitTests/PauseGateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/UnitTests/PauseGateTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("PauseGate")
struct PauseGateTests {

    @Test("an open gate does not suspend")
    func openDoesNotSuspend() async {
        let gate = PauseGate(initiallyOpen: true)
        // No timeout needed: a passing call returns immediately. Wrap in a
        // task with a tight timeout to fail loudly if behaviour regresses.
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await gate.waitOpen() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(100))
                Issue.record("waitOpen blocked on an open gate")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @Test("a closed gate unblocks every waiter when reopened")
    func closedThenOpenUnblocks() async {
        let gate = PauseGate(initiallyOpen: false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { await gate.waitOpen() }
            }
            // Give the waiters a moment to suspend, then open.
            try? await Task.sleep(for: .milliseconds(20))
            await gate.open()
            // If `open()` did not release them, the implicit await will hang
            // and the test framework's per-test timeout will fail.
            await group.waitForAll()
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PauseGateTests
```

Expected: compile error — `PauseGate` not defined.

- [ ] **Step 3: Write `PauseGate`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/PauseGate.swift
import Foundation

/// A one-flag pause/resume primitive. `waitOpen()` returns immediately when
/// the gate is open; when closed it suspends every caller until `open()`.
///
/// Used by `ResumableRefiner`: every checkpoint (between VAD regions and
/// between stages) awaits the gate before continuing, so the queue can stall
/// a refine mid-pipeline by calling `close()` and resume it with `open()`.
public actor PauseGate {

    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(initiallyOpen: Bool = true) {
        self.open = initiallyOpen
    }

    /// Suspend until the gate is open. Returns immediately when already open.
    public func waitOpen() async {
        if open { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Open the gate and release every suspended waiter.
    public func open() {
        guard !open else { return }
        open = true
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.resume() }
    }

    /// Close the gate. New `waitOpen()` calls will suspend; already-resumed
    /// continuations are not affected.
    public func close() {
        open = false
    }

    /// Read-only snapshot. Used by tests and by status reporting.
    public var isOpen: Bool { open }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter PauseGateTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/PauseGate.swift \
        Tests/UnitTests/PauseGateTests.swift
git commit -m "feat(refine): add PauseGate primitive"
```

---

### Task B2: lift the whisper region loop out of `WhisperTranscriber`

This task changes the `transcribe(_:regions:options:)` shape so the refine pipeline can iterate regions one at a time, checkpointing between them. The existing single-call API stays for callers that don't checkpoint (the CLI's bare-WAV path via `OfflineRefiner`).

**Files:**
- Modify: `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift` (add `transcribeRegion(_:region:options:offset:)`)
- Test:   add `Tests/UnitTests/StreamingTranscriberUnitTests.swift` extension OR add a new file `Tests/UnitTests/WhisperRegionTests.swift` if you prefer isolation.

- [ ] **Step 1: Write the failing test (new file)**

```swift
// Tests/UnitTests/WhisperRegionTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("WhisperTranscriber per-region API")
struct WhisperRegionTests {

    /// Decoding the first 1.0s region of `audio-samples/short_silence.wav` via
    /// the new per-region API yields the same first segment the multi-region
    /// call produces — i.e. the loop has been lifted, not rewritten.
    ///
    /// Requires the whisper.cpp model fixture in `Tests/Fixtures/`. Skip when
    /// absent (matches the existing PipelineTests gating pattern).
    @Test("a single region decoded individually matches the multi-region call",
          .enabled(if: WhisperFixtureLocator.hasModel))
    func singleRegionMatchesMultiRegion() throws {
        let modelURL = try WhisperFixtureLocator.modelURL()
        let samples = try WhisperFixtureLocator.loadSamples("short_silence")
        let transcriber = try WhisperTranscriber(modelURL: modelURL)

        let regions: [SpeechRegion] = [
            SpeechRegion(start: .seconds(0), end: .seconds(1)),
            SpeechRegion(start: .seconds(1), end: .seconds(2)),
        ]
        let combined = try transcriber.transcribe(samples, regions: regions)

        // The new per-region API: decode each region individually and
        // concatenate.
        let r0 = try transcriber.transcribeRegion(
            samples, region: regions[0], options: .init())
        let r1 = try transcriber.transcribeRegion(
            samples, region: regions[1], options: .init())

        #expect(r0.segments + r1.segments == combined.segments)
    }
}

/// Locates the model + samples; reused by other transcribe tests.
enum WhisperFixtureLocator {
    static var hasModel: Bool { (try? modelURL()) != nil }

    static func modelURL() throws -> URL {
        // Resolve relative to the test source file so we don't ship a copy.
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()           // UnitTests
            .deletingLastPathComponent()           // Tests
            .deletingLastPathComponent()           // repo root
            .appendingPathComponent("Tests/Fixtures/whisper/ggml-base.bin")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw NSError(domain: "fixture", code: 1, userInfo: nil)
        }
        return candidate
    }

    static func loadSamples(_ name: String) throws -> [Float] {
        // Implementation detail: load a WAV via the existing WAVReader.
        // Stubbed here — copy from one of the existing PipelineTests
        // helpers that already does this.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/audio/\(name).wav")
        return try WAVReader.readMono16kHz(at: url)
    }
}
```

(If `WhisperFixtureLocator`/`WAVReader.readMono16kHz` doesn't exist — search `Tests/PipelineTests/` for the equivalent helper before duplicating. If `loadSamples` is non-trivial, replace with the smallest existing helper and only test the structural invariant.)

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter WhisperRegionTests
```

Expected: compile error — `transcribeRegion` not defined.

- [ ] **Step 3: Add `transcribeRegion` to `WhisperTranscriber`**

```swift
// Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift
// Add this public method next to the existing `transcribe(_:regions:options:)`
// (around line 288). The existing call is refactored to use it internally so
// behaviour cannot diverge.

/// Decode one VAD region as a single `whisper_full` call, with timestamps
/// shifted onto the recording timeline.
///
/// The caller iterates regions externally so it can persist progress and
/// honour a pause gate between regions (D-Q6). Same Metal-lock contract as
/// `transcribe(_:options:)` — one `whisper_full` runs at a time per process.
public func transcribeRegion(
    _ samples: [Float],
    region: SpeechRegion,
    options: Options = Options()
) throws -> TranscriptionResult {
    guard !samples.isEmpty else { throw TranscribeError.emptyAudio }
    warnIfEnglishOnlyModel()

    Self.metalLock.lock()
    defer { Self.metalLock.unlock() }

    let sampleCount = samples.count
    let lo = Self.sampleIndex(of: region.start, sampleCount: sampleCount)
    let hi = Self.sampleIndex(of: region.end, sampleCount: sampleCount)
    guard lo < hi else {
        return TranscriptionResult(
            segments: [],
            language: isEnglishOnlyModel ? "en" : "unknown")
    }

    let decoded = try decodeLocked(
        Array(samples[lo..<hi]), options: options, whisperVADModel: nil)
    let offset = Duration.milliseconds(lo * 1000 / AudioFormat.sampleRate)
    let shifted = decoded.segments.map { seg in
        TranscriptSegment(
            start: seg.start + offset,
            end: seg.end + offset,
            text: seg.text)
    }
    return TranscriptionResult(
        segments: shifted,
        language: decoded.language)
}
```

And refactor the existing `transcribe(_:regions:options:)` body to use the new method, so the two paths cannot diverge:

```swift
// Replace the existing per-region loop body (around lines 304-325) with:

let sampleCount = samples.count
var merged: [TranscriptSegment] = []
var language: String?
for region in regions {
    let lo = Self.sampleIndex(of: region.start, sampleCount: sampleCount)
    let hi = Self.sampleIndex(of: region.end, sampleCount: sampleCount)
    guard lo < hi else { continue }
    // Inline the per-region decode rather than calling `transcribeRegion`
    // — we already hold `metalLock` here, so we must not re-acquire it.
    let decoded = try decodeLocked(
        Array(samples[lo..<hi]), options: options, whisperVADModel: nil)
    let offset = Duration.milliseconds(lo * 1000 / AudioFormat.sampleRate)
    for seg in decoded.segments {
        merged.append(TranscriptSegment(
            start: seg.start + offset,
            end: seg.end + offset,
            text: seg.text))
    }
    if language == nil { language = decoded.language }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter WhisperRegionTests
```

Expected: PASS (1 test, when the fixture model is present; otherwise the test is skipped via `.enabled(if:)`).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift \
        Tests/UnitTests/WhisperRegionTests.swift
git commit -m "feat(refine): expose per-region whisper decode for checkpointing"
```

---

### Task B3: `Diarizer.cancel()`

D-Q7: pause = terminate the subprocess. No SIGSTOP/SIGCONT, no resume path —
when the queue later reopens the gate the refiner just calls `diarize` again
from scratch.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Diarization/Diarizer.swift`
- Create: `Tests/UnitTests/DiarizerCancelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/UnitTests/DiarizerCancelTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Diarizer cancel")
struct DiarizerCancelTests {

    /// `cancel()` is a no-op when no subprocess is running.
    @Test("cancel on an idle diarizer does not throw")
    func idleCancel() async {
        let diarizer = Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/false"),
            workingDirectory: URL(fileURLWithPath: "/tmp")))
        await diarizer.cancel()
    }

    /// When `cancel()` is called against an inflight subprocess, the
    /// in-flight `diarizeSystemStream` call throws `.cancelled` (not the
    /// generic `.nonZeroExit`) so the refiner can distinguish a pause from
    /// a real failure.
    ///
    /// Driven via a stand-in interpreter that sleeps — `/bin/sh -c "sleep 30"`
    /// — so the test does not need a real Python venv.
    @Test("cancel against an inflight diarize throws .cancelled")
    func cancelInflight() async throws {
        // Write a temp WAV the resolver accepts as input. (Empty file is
        // fine — the subprocess is fake.)
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-cancel-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let diarizer = Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            // Override the module arg path; the test config below uses a
            // separate flag the production Configuration does not expose.
            // If a `customArguments` seam is too invasive, alternative:
            // accept a fixture python script that sleeps + emits JSON.
            moduleName: "ignored"))

        // Launch the diarize and cancel after a beat.
        let task = Task {
            try await diarizer.diarizeSystemStream(wavPath: wav)
        }
        try await Task.sleep(for: .milliseconds(100))
        await diarizer.cancel()

        await #expect(throws: Diarizer.DiarizeError.self) {
            _ = try await task.value
        }
        // Specifically the .cancelled case, not .nonZeroExit:
        do {
            _ = try await task.value
        } catch let e as Diarizer.DiarizeError {
            if case .cancelled = e {} else { Issue.record("wrong case: \(e)") }
        }
    }
}
```

**Note for the engineer:** the second test depends on being able to point
`Diarizer` at `/bin/sh` so the launch succeeds without a real Python venv.
If `Configuration` doesn't already accept a custom argv (it currently only
exposes `moduleName`), add an additional `customArguments: [String]?`
field, defaulted to `nil`, used in `runSubprocess` when set. Keep that
helper non-public — it is for tests.

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter DiarizerCancelTests
```

Expected: compile error — `Diarizer.cancel`, `DiarizeError.cancelled` not defined.

- [ ] **Step 3: Add `cancel` + the new error case**

```swift
// Sources/PulsarTraceEngine/Diarization/Diarizer.swift
// 1. Add the error case (inside `DiarizeError`):

case cancelled

// And in description:
case .cancelled:
    return "diarization cancelled (paused by queue)"

// 2. Track the in-flight Process and a `cancelled` flag.

private var inflightProcess: Process?
private var cancelledFlag = false

/// Terminate the in-flight pyannote subprocess. A no-op when no subprocess
/// is running. The next `diarizeSystemStream` call after this returns —
/// or the one currently in flight — throws `DiarizeError.cancelled` rather
/// than `.nonZeroExit`, so the refiner can distinguish a pause from a
/// real failure.
public func cancel() {
    cancelledFlag = true
    guard let p = inflightProcess, p.isRunning else { return }
    p.terminate()                            // SIGTERM
    // Escalate to SIGKILL after a short grace, mirroring the timeout
    // watchdog. A cancel during a recording start must free the GPU
    // quickly; we cannot afford a 10s SIGTERM wait.
    let pid = p.processIdentifier
    Task {
        try? await Task.sleep(for: .milliseconds(500))
        if p.isRunning { kill(pid, SIGKILL) }
    }
}

// 3. In `runSubprocess`, before `try process.run()` (~line 217):

self.inflightProcess = process
self.cancelledFlag = false      // fresh run — clear any prior cancel

// 4. After `await Self.waitForExit(process)` (~line 263), check the flag
//    BEFORE the `firedTimeout` / `exitCode != 0` checks, so a cancel
//    takes precedence:

if self.cancelledFlag {
    self.inflightProcess = nil
    throw DiarizeError.cancelled
}

// 5. At the end of runSubprocess (and on every error path that returns
//    early), clear `inflightProcess`. The cleanest way is a `defer` at the
//    top of the function:

defer { self.inflightProcess = nil }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter DiarizerCancelTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/Diarizer.swift \
        Tests/UnitTests/DiarizerCancelTests.swift
git commit -m "feat(refine): add Diarizer.cancel — terminate inflight subprocess"
```

---

### Task B4: `ResumableRefiner` — stage iteration + checkpoint write

This is the core refactor. The new class drives the refine through eight stages, checkpointing after every region and every stage. The existing `RefinementPipeline` is kept as the low-level worker but is wrapped: per-stage progress is now persisted by `ResumableRefiner`, not by the pipeline.

Two iterations:
- **B4** (this task): the happy-path stage iteration, no pause yet. Output is byte-identical to the existing `OfflineRefiner` on the same input — a regression test in the next task pins that.
- **B5**: add the pause gate.

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`
- Test:   `Tests/UnitTests/ResumableRefinerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/UnitTests/ResumableRefinerTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("ResumableRefiner")
struct ResumableRefinerTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-resumable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// With a stub transcriber + stub diarizer, a fresh run produces a
    /// well-formed `refine-progress.json` showing `.writingMetadata` as the
    /// last stage before completion.
    @Test("a fresh run leaves a completed-stage checkpoint in the folder")
    func freshRunCheckpoint() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Write a minimal recording folder layout — system WAV + no mic.
        try FixtureRecording.minimal(at: folder)

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                // Stub: one segment per region, with the region's offset.
                TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "stub")],
                    language: "en")
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                // No speakers — diarization gets skipped (matches the
                // empty-segments edge case in RefinementPipeline).
                DiarizationResult(
                    speakers: ["speaker_0"],
                    spans: [SpeakerSpan(
                        start: .seconds(0), end: .seconds(1),
                        speaker: "speaker_0")],
                    embeddings: [:],
                    model: "stub",
                    modelRevision: "stub",
                    modelVersion: "stub")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_x", recordingId: "rec_x", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        // The progress file should exist and show the terminal stage.
        let progressURL = folder.appendingPathComponent("refine-progress.json")
        let data = try Data(contentsOf: progressURL)
        let progress = try RefinementProgress.decode(data)
        #expect(progress.stage == .writingMetadata)

        // The same recording folder now has the standard outputs.
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("final.md").path))
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("metadata.json").path))
    }
}

/// Minimal recording-folder helper. A real `audio-system.wav` is needed for
/// the pipeline's `RecordingFolder.resolve` to succeed; we generate a 1s
/// silent wav.
enum FixtureRecording {
    static func minimal(at folder: URL) throws {
        let wav = folder.appendingPathComponent("audio-system.wav")
        // Use the existing WAVWriter to write a 16 kHz mono 1s silence file.
        // If WAVWriter is internal/private to a module path, copy the
        // smallest test helper that does this from PipelineTests.
        try WAVWriter.write(samples: [Float](repeating: 0, count: 16_000), to: wav)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ResumableRefinerTests
```

Expected: compile error — `ResumableRefiner` not defined.

- [ ] **Step 3: Write `ResumableRefiner`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift
import Foundation
import Logging

/// The refine worker. Drives one `RefinementJob` through the same eight
/// stages `RefinementPipeline` knows, but with `refine-progress.json`
/// checkpointing between regions and stages (D-Q5/D-Q6) and a `PauseGate`
/// awaited at every boundary.
///
/// Constructor parameters are injected closures so the refiner is testable
/// without spawning whisper / pyannote / a model fetch. Production callers
/// build it via `ResumableRefiner.makeProduction(...)` (Task B5).
public actor ResumableRefiner {

    public typealias TranscribeRegion =
        @Sendable ([Float], SpeechRegion, WhisperTranscriber.Options) throws
        -> TranscriptionResult
    public typealias DetectRegions =
        @Sendable ([Float]) throws -> [SpeechRegion]
    public typealias Diarize =
        @Sendable (URL) async throws -> DiarizationResult

    private let transcribe: TranscribeRegion
    private let detectRegions: DetectRegions
    private let diarize: Diarize
    private let pauseGate: PauseGate
    private let events: EventWriter?
    private let logger: Logger

    public init(
        transcribe: @escaping TranscribeRegion,
        detectRegions: @escaping DetectRegions,
        diarize: @escaping Diarize,
        pauseGate: PauseGate,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.transcribe = transcribe
        self.detectRegions = detectRegions
        self.diarize = diarize
        self.pauseGate = pauseGate
        self.events = events
        self.logger = logger
    }

    /// Run one job to completion (or failure). Writes `final.md`,
    /// `metadata.json`, and `refine-progress.json` into the recording folder.
    ///
    /// Reads any existing `refine-progress.json` and skips stages already
    /// done. The progress file is rewritten on every checkpoint; a partial
    /// progress for a job that ultimately succeeds is overwritten by the
    /// final terminal-state file. Callers that wish to delete the checkpoint
    /// on success can do so externally — keeping it lets the UI show a
    /// "completed" badge with the final stage breakdown.
    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)

        // Stage 1: resolveInput (already done by RecordingFolder.resolve).
        try await advance(&progress, to: .resolvingInput, folder: folder)

        // Stage 2: transcribingSystem — per-region with checkpointing.
        try await advance(&progress, to: .transcribingSystem, folder: folder)
        try await transcribeSystemStream(folder: folder, progress: &progress)

        // Stage 3: diarizing.
        try await advance(&progress, to: .diarizing, folder: folder)
        let diarization = try await runDiarization(folder: folder, progress: &progress)

        // Stage 4: transcribingMic — only if mic stream present.
        try await advance(&progress, to: .transcribingMic, folder: folder)
        if folder.micStream != nil {
            try await transcribeMicStream(folder: folder, progress: &progress)
        }

        // Stage 5–7 reuse RefinementPipeline's merge + write paths.
        try await advance(&progress, to: .merging, folder: folder)
        try await advance(&progress, to: .writingFinal, folder: folder)
        try await advance(&progress, to: .writingMetadata, folder: folder)
        try mergeAndWrite(folder: folder, progress: progress, diarization: diarization, job: job)
    }

    // MARK: - Stage helpers

    private func loadOrInitProgress(
        folder: RecordingFolder, job: RefinementJob
    ) -> RefinementProgress {
        let url = folder.directory.appendingPathComponent("refine-progress.json")
        if let data = try? Data(contentsOf: url),
           let p = try? RefinementProgress.decode(data),
           p.jobId == job.id, p.recordingId == job.recordingId {
            return p
        }
        return RefinementProgress.empty(jobId: job.id, recordingId: job.recordingId)
    }

    private func advance(
        _ progress: inout RefinementProgress,
        to stage: RefinementJobState.Stage,
        folder: RecordingFolder
    ) async throws {
        await pauseGate.waitOpen()
        progress.stage = stage
        progress.lastCheckpointAt = Date()
        try persist(progress, folder: folder)
    }

    private func persist(_ progress: RefinementProgress, folder: RecordingFolder) throws {
        let url = folder.directory.appendingPathComponent("refine-progress.json")
        _ = try AtomicFile.write(try progress.encoded(), to: url)
    }

    // MARK: - Transcription with checkpointing

    private func transcribeSystemStream(
        folder: RecordingFolder, progress: inout RefinementProgress
    ) async throws {
        let samples = try loadSamples(at: folder.systemStream.url)
        if progress.systemRegions.isEmpty {
            let regions = try detectRegions(samples)
            progress.systemRegions = regions.map(Self.toWindow)
            try persist(progress, folder: folder)
        }
        try await iterateRegions(
            samples: samples,
            allRegions: progress.systemRegions.map(Self.toRegion),
            isMic: false,
            progress: &progress,
            folder: folder)
    }

    private func transcribeMicStream(
        folder: RecordingFolder, progress: inout RefinementProgress
    ) async throws {
        guard let mic = folder.micStream else { return }
        let samples = try loadSamples(at: mic.url)
        if progress.micRegions.isEmpty {
            let regions = try detectRegions(samples)
            progress.micRegions = regions.map(Self.toWindow)
            try persist(progress, folder: folder)
        }
        try await iterateRegions(
            samples: samples,
            allRegions: progress.micRegions.map(Self.toRegion),
            isMic: true,
            progress: &progress,
            folder: folder)
    }

    private func iterateRegions(
        samples: [Float],
        allRegions: [SpeechRegion],
        isMic: Bool,
        progress: inout RefinementProgress,
        folder: RecordingFolder
    ) async throws {
        // Resume from the lowest pending index.
        while let i = (isMic ? progress.nextMicRegionIndex : progress.nextSystemRegionIndex) {
            await pauseGate.waitOpen()
            let region = allRegions[i]
            let result = try transcribe(samples, region, .init())
            for seg in result.segments {
                let partial = RefinementProgress.PartialSegment(
                    startMillis: Int(seg.start.milliseconds),
                    endMillis: Int(seg.end.milliseconds),
                    text: seg.text,
                    regionIndex: i)
                if isMic {
                    progress.micSegments.append(partial)
                } else {
                    progress.systemSegments.append(partial)
                }
            }
            if progress.language == nil { progress.language = result.language }
            if isMic {
                progress.completedMicRegionIndices.append(i)
            } else {
                progress.completedSystemRegionIndices.append(i)
            }
            progress.lastCheckpointAt = Date()
            try persist(progress, folder: folder)
        }
    }

    private func runDiarization(
        folder: RecordingFolder, progress: inout RefinementProgress
    ) async throws -> DiarizationResult? {
        // No speech ⇒ no diarization (matches RefinementPipeline:281-283).
        guard !progress.systemSegments.isEmpty else { return nil }
        // D-Q7: if the queue cancels mid-diarize (because a recording
        // started), the diarize call throws `Diarizer.DiarizeError.cancelled`.
        // Wait for the gate to reopen (it does when the recording stops)
        // and retry from scratch — pyannote model load is the cost we pay
        // instead of carrying a SIGSTOPped subprocess across the recording.
        while true {
            await pauseGate.waitOpen()
            do {
                return try await diarize(folder.systemStream.url)
            } catch let e as Diarizer.DiarizeError {
                if case .cancelled = e { continue }
                throw e
            }
        }
    }

    // MARK: - Final assembly

    private func mergeAndWrite(
        folder: RecordingFolder,
        progress: RefinementProgress,
        diarization: DiarizationResult?,
        job: RefinementJob
    ) throws {
        // Delegate the merge + final.md + metadata.json writing back to
        // RefinementPipeline so behaviour stays identical to today's output.
        // Lift partial segments back into TranscriptSegments.
        let system = progress.systemSegments.map { p in
            TranscriptSegment(
                start: .milliseconds(p.startMillis),
                end: .milliseconds(p.endMillis),
                text: p.text)
        }
        let mic = progress.micSegments.map { p in
            TranscriptSegment(
                start: .milliseconds(p.startMillis),
                end: .milliseconds(p.endMillis),
                text: p.text)
        }
        // (RefinementPipeline.mergeStreams + write helpers are currently
        // private; expose them as `static` `internal` helpers in a follow-up
        // sub-step OR replicate the merge/write here. Prefer exposing —
        // duplicating the merge would risk drift.)
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
    }

    // MARK: - Conversions

    private static func toWindow(_ r: SpeechRegion) -> RefinementProgress.RegionWindow {
        .init(startMillis: Int(r.start.milliseconds), endMillis: Int(r.end.milliseconds))
    }

    private static func toRegion(_ w: RefinementProgress.RegionWindow) -> SpeechRegion {
        SpeechRegion(start: .milliseconds(w.startMillis), end: .milliseconds(w.endMillis))
    }

    private func loadSamples(at wav: URL) throws -> [Float] {
        let source = FixturePlaybackSource(file: wav, realtime: false)
        let pipeline = OfflineTranscriptionPipeline(logger: logger)
        // OfflineTranscriptionPipeline.accumulate is async — call it inside
        // the actor by awaiting; the call cannot suspend on whisper because
        // we don't pass a transcriber.
        return try awaitSync { try await pipeline.accumulate(source) }
    }

    /// Bridge an async call to a sync context — only safe here because the
    /// caller method is already async and we know `pipeline.accumulate`
    /// completes without recursion into this actor.
    private func awaitSync<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        // NOTE: A simpler refactor: make `loadSamples` itself `async throws`.
        // Pick that during implementation — left here intentionally vague so
        // the engineer takes one decision; the test does not depend on it.
        fatalError("Implement loadSamples as async OR add a proper bridge")
    }
}
```

**Implementation note for the engineer:** the `awaitSync` placeholder makes a deliberate decision visible. Change `loadSamples` to `async throws` and `await` it at the call site — the simpler path. The placeholder is the only spot in this plan where I am asking you to make a call rather than typing the code; resolve it before running tests.

Also add the new `assembleAndWrite` static method on `RefinementPipeline`:

```swift
// Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift
// Add as a public static method on the existing struct, so ResumableRefiner
// can call into the same merge + write code path.

/// The merge + write half of `run(_:)`, exposed so `ResumableRefiner` can
/// reuse it after assembling segments incrementally from a checkpoint file.
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
    sourceBasename: String
) throws {
    // Pull the bodies of mergeStreams + writeFinalMarkdown + buildMetadata
    // out of RefinementPipeline's private methods so they can be called from
    // here. Mechanical: change `private` → `internal static` and accept the
    // inputs as parameters instead of reading instance state.
    fatalError("Refactor mergeStreams/writeFinalMarkdown/buildMetadata to static helpers")
}
```

(Again, the `fatalError` is a hand-off — the engineer makes the obvious refactor.)

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ResumableRefinerTests
```

Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift \
        Tests/UnitTests/ResumableRefinerTests.swift
git commit -m "feat(refine): add ResumableRefiner with per-region checkpointing"
```

---

### Task B5: ResumableRefiner — resume from a partial checkpoint

**Files:**
- Modify: `Tests/UnitTests/ResumableRefinerTests.swift`

- [ ] **Step 1: Write the failing test (append to the suite)**

```swift
// Tests/UnitTests/ResumableRefinerTests.swift — append

/// A pre-written progress file with two of three regions completed makes the
/// refiner skip those two and decode only the third.
@Test("resume from checkpoint skips already-completed regions")
func resumeFromCheckpoint() async throws {
    let folder = tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FixtureRecording.minimal(at: folder)

    // Hand-write a progress file claiming regions 0+1 already decoded.
    var seed = RefinementProgress.empty(jobId: "job_r", recordingId: "rec_r")
    seed.stage = .transcribingSystem
    seed.systemRegions = [
        .init(startMillis: 0, endMillis: 1000),
        .init(startMillis: 1000, endMillis: 2000),
        .init(startMillis: 2000, endMillis: 3000),
    ]
    seed.completedSystemRegionIndices = [0, 1]
    seed.systemSegments = [
        .init(startMillis: 0, endMillis: 1000, text: "preexisting 0", regionIndex: 0),
        .init(startMillis: 1000, endMillis: 2000, text: "preexisting 1", regionIndex: 1),
    ]
    seed.language = "en"
    seed.lastCheckpointAt = Date()
    try seed.encoded().write(
        to: folder.appendingPathComponent("refine-progress.json"))

    // Track which region indices the transcribe stub is asked to decode.
    actor TranscribeLog {
        var indices: [Int] = []
        func record(_ i: Int) { indices.append(i) }
    }
    let log = TranscribeLog()

    let refiner = ResumableRefiner(
        transcribe: { _, region, _ in
            // Identify the region by its start time → index in the seed.
            let i = Int(region.start.milliseconds / 1000)
            Task { await log.record(i) }
            return TranscriptionResult(
                segments: [TranscriptSegment(
                    start: region.start, end: region.end, text: "fresh \(i)")],
                language: "en")
        },
        detectRegions: { _ in
            // Should not be called — regions are already in the checkpoint.
            Issue.record("detectRegions was called on resume")
            return []
        },
        diarize: { _ in
            DiarizationResult(
                speakers: [], spans: [], embeddings: [:],
                model: "stub", modelRevision: "stub", modelVersion: "stub")
        },
        pauseGate: PauseGate(initiallyOpen: true),
        events: nil)

    let job = RefinementJob(
        id: "job_r", recordingId: "rec_r", folderURL: folder,
        modelName: "stub", modelSHA256: "stub",
        trigger: .manual, enqueuedAt: Date(), state: .queued)
    try await refiner.run(job: job)

    let indices = await log.indices
    #expect(indices == [2])    // only region 2 decoded
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ResumableRefinerTests/resumeFromCheckpoint
```

Expected: FAIL — either `detectRegions` is called and `Issue.record` fires, or `indices != [2]`.

- [ ] **Step 3: Fix the iteration so a non-empty `systemRegions` short-circuits detection**

In `transcribeSystemStream` (and `transcribeMicStream`), the `if progress.systemRegions.isEmpty` guard already skips detection when regions are present. If your B4 implementation passes both tests already, this step is a no-op — move to commit. If the resume test fails, the bug is in `iterateRegions`: ensure it uses the existing `progress.systemRegions` value (not a freshly-detected one) and that the `nextSystemRegionIndex` accessor honours `completedSystemRegionIndices`.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ResumableRefinerTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Tests/UnitTests/ResumableRefinerTests.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift
git commit -m "test(refine): resume-from-checkpoint regression test"
```

---

### Task B6: ResumableRefiner — pause between regions

**Files:**
- Modify: `Tests/UnitTests/ResumableRefinerTests.swift`

- [ ] **Step 1: Write the failing test (append)**

```swift
// Tests/UnitTests/ResumableRefinerTests.swift — append

/// Closing the pause gate between regions stalls the refiner. Opening it
/// again resumes the loop and the rest of the regions decode.
@Test("a closed pause gate suspends the region loop")
func pauseStallsLoop() async throws {
    let folder = tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FixtureRecording.minimal(at: folder)

    let gate = PauseGate(initiallyOpen: true)
    actor Counter { var value = 0; func incr() -> Int { value += 1; return value } }
    let counter = Counter()

    let refiner = ResumableRefiner(
        transcribe: { _, region, _ in
            Task { _ = await counter.incr() }
            // After region 0, close the gate so region 1 cannot start.
            if region.start == .seconds(0) {
                Task { await gate.close() }
            }
            return TranscriptionResult(
                segments: [TranscriptSegment(
                    start: region.start, end: region.end, text: "x")],
                language: "en")
        },
        detectRegions: { _ in
            [
                SpeechRegion(start: .seconds(0), end: .seconds(1)),
                SpeechRegion(start: .seconds(1), end: .seconds(2)),
            ]
        },
        diarize: { _ in
            DiarizationResult(speakers: [], spans: [], embeddings: [:],
                model: "stub", modelRevision: "stub", modelVersion: "stub")
        },
        pauseGate: gate,
        events: nil)

    let job = RefinementJob(
        id: "j", recordingId: "r", folderURL: folder,
        modelName: "stub", modelSHA256: "stub",
        trigger: .manual, enqueuedAt: Date(), state: .queued)

    let runTask = Task { try await refiner.run(job: job) }

    // Give the refiner time to process region 0 and stall on region 1.
    try await Task.sleep(for: .milliseconds(200))
    let stalled = await counter.value
    #expect(stalled == 1)    // only region 0 decoded so far

    await gate.open()
    try await runTask.value

    let finalCount = await counter.value
    #expect(finalCount == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ResumableRefinerTests/pauseStallsLoop
```

Expected: PASS if your B4 implementation already awaits the gate inside `iterateRegions` (the plan code does — `await pauseGate.waitOpen()`). If FAIL, add the `await` at the loop head and re-run.

- [ ] **Step 3: (no implementation change expected — verify pass)**

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ResumableRefinerTests
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Tests/UnitTests/ResumableRefinerTests.swift
git commit -m "test(refine): pause gate stalls the region loop"
```

---

### Task B7: ResumableRefiner — diarize cancel-retry on resume

D-Q7: a cancelled diarize is not a failure. The refiner waits for the gate
to reopen and retries from scratch.

**Files:**
- Modify: `Tests/UnitTests/ResumableRefinerTests.swift`

- [ ] **Step 1: Write the failing test (append)**

```swift
// Tests/UnitTests/ResumableRefinerTests.swift — append

@Test("a cancelled diarize retries when the gate reopens")
func diarizeCancelRetries() async throws {
    let folder = tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FixtureRecording.minimal(at: folder)

    let gate = PauseGate(initiallyOpen: true)
    actor Calls { var n = 0; func incr() -> Int { n += 1; return n } }
    let calls = Calls()

    let refiner = ResumableRefiner(
        transcribe: { _, region, _ in
            TranscriptionResult(
                segments: [TranscriptSegment(
                    start: region.start, end: region.end, text: "x")],
                language: "en")
        },
        detectRegions: { _ in
            [SpeechRegion(start: .seconds(0), end: .seconds(1))]
        },
        diarize: { _ in
            let n = await calls.incr()
            if n == 1 {
                // First call: queue paused us. Close the gate (so the
                // retry blocks) and throw the cancel error.
                await gate.close()
                throw Diarizer.DiarizeError.cancelled
            }
            // Second call (after gate reopens): succeed.
            return DiarizationResult(
                speakers: ["speaker_0"],
                spans: [SpeakerSpan(
                    start: .seconds(0), end: .seconds(1),
                    speaker: "speaker_0")],
                embeddings: [:],
                model: "stub", modelRevision: "stub", modelVersion: "stub")
        },
        pauseGate: gate,
        events: nil)

    let job = RefinementJob(
        id: "j", recordingId: "r", folderURL: folder,
        modelName: "stub", modelSHA256: "stub",
        trigger: .manual, enqueuedAt: Date(), state: .queued)

    let runTask = Task { try await refiner.run(job: job) }

    // Give it time to throw the first cancel and block on the gate.
    try await Task.sleep(for: .milliseconds(200))
    let stalled = await calls.n
    #expect(stalled == 1)

    // Reopen the gate — the retry succeeds.
    await gate.open()
    try await runTask.value
    let total = await calls.n
    #expect(total == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ResumableRefinerTests/diarizeCancelRetries
```

Expected: FAIL if the cancel-retry loop in `runDiarization` is absent; PASS
if Task B4's implementation already includes it (the plan body does — verify).

- [ ] **Step 3: (no implementation change if B4 was implemented as written)**

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ResumableRefinerTests
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Tests/UnitTests/ResumableRefinerTests.swift
git commit -m "test(refine): diarize cancel-retry on gate reopen"
```

---

## Phase C — `RefinementJobQueue` orchestrator

### Task C1: queue actor skeleton + `enqueue`

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Test:   `Tests/PipelineTests/RefinementJobQueueTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PipelineTests/RefinementJobQueueTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementJobQueue")
struct RefinementJobQueueTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Enqueueing a job runs it through the injected refiner closure to
    /// completion; the queue then becomes idle.
    @Test("one enqueued job runs and the queue ends idle")
    func runsOneJob() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let ran = expectation()
        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in ran.fulfill() })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_x",
            modelName: "base",
            modelSHA256: "deadbeef")

        await ran.wait(timeout: .seconds(2))
        let snapshot = await queue.snapshot()
        #expect(snapshot.running == nil)
        #expect(snapshot.queued.isEmpty)
        #expect(snapshot.recent.count == 1)
    }
}

// (Implement a small `expectation()` helper — or use the existing
// `Gate` actor pattern from RecordingViewModelTests.)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobQueueTests
```

Expected: compile error — `RefinementJobQueue` not defined.

- [ ] **Step 3: Write the queue actor**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
import Foundation
import Logging

/// The single-worker refinement queue. Drives exactly one
/// `ResumableRefiner.run` at a time; queues the rest in FIFO order.
///
/// State exposed via `snapshot()` (a value type the UI re-reads). The
/// menubar layer wraps this actor in a `@MainActor @Observable` façade
/// (`RefinementJobQueueViewModel`).
public actor RefinementJobQueue {

    /// One snapshot of the queue's state — what the UI binds to.
    public struct Snapshot: Sendable, Equatable {
        public let running: RefinementJob?
        public let queued: [RefinementJob]
        public let recent: [RefinementJob]   // terminal jobs, newest first
        public let pausedForRecording: Bool
    }

    public typealias RunJob = @Sendable (RefinementJob) async throws -> Void

    private let store: RefinementJobStore
    private let runJob: RunJob
    private let logger: Logger

    private var current: RefinementJob?
    private var queued: [RefinementJob] = []
    private var recent: [RefinementJob] = []
    private var pausedForRecording = false
    private var worker: Task<Void, Never>?

    public init(
        store: RefinementJobStore,
        runJob: @escaping RunJob,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.store = store
        self.runJob = runJob
        self.logger = logger
    }

    /// Restore persisted jobs and kick the worker.
    public func start() async throws {
        let persisted = try await store.listAll()
        for job in persisted {
            switch job.state {
            case .queued, .running, .paused:
                // Treat any non-terminal restore as queued — the in-flight
                // checkpoint inside the recording folder lets the refiner
                // pick up where it left off.
                var requeued = job
                requeued.state = .queued
                self.queued.append(requeued)
                try? await store.upsert(requeued)
            case .completed, .failed, .cancelled:
                self.recent.append(job)
            }
        }
        pumpIfIdle()
    }

    /// Enqueue a manual refine (recordings list "Refine" button).
    public func enqueueManualRefine(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String
    ) async throws {
        try await enqueue(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256,
            trigger: .manual)
    }

    /// Enqueue a post-recording auto refine.
    public func enqueueAutoRefine(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String
    ) async throws {
        try await enqueue(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256,
            trigger: .autoPostRecording)
    }

    /// Enqueue a crash-recovery refine.
    public func enqueueCrashRecovery(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String
    ) async throws {
        try await enqueue(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256,
            trigger: .crashRecovery)
    }

    private func enqueue(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String,
        trigger: RefinementJob.Trigger
    ) async throws {
        // D-Q4: at most one job per recording. If one already exists
        // (queued or running), the new request is a no-op.
        if current?.recordingId == recordingId
            || queued.contains(where: { $0.recordingId == recordingId }) {
            return
        }

        let job = RefinementJob(
            id: "job_\(ULID().description)",
            recordingId: recordingId,
            folderURL: folderURL,
            modelName: modelName,
            modelSHA256: modelSHA256,
            trigger: trigger,
            enqueuedAt: Date(),
            state: .queued)
        try await store.upsert(job)
        queued.append(job)
        pumpIfIdle()
    }

    /// Read-only state snapshot for the UI.
    public func snapshot() -> Snapshot {
        Snapshot(
            running: current,
            queued: queued,
            recent: recent.reversed(),
            pausedForRecording: pausedForRecording)
    }

    // MARK: - Worker

    private func pumpIfIdle() {
        guard current == nil, !queued.isEmpty, worker == nil,
              !pausedForRecording else { return }
        worker = Task { await self.runNext() }
    }

    private func runNext() async {
        defer { self.worker = nil }
        guard !queued.isEmpty else { return }
        var job = queued.removeFirst()
        job.state = .running(
            stage: .resolvingInput,
            stepsCompleted: 0,
            stepsTotal: RefinementJobState.Stage.allCases.count,
            regionIndex: nil, regionsTotal: nil)
        try? await store.upsert(job)
        current = job

        do {
            try await runJob(job)
            job.state = .completed(durationSeconds: 0.0, speakerCount: 0)
        } catch {
            // TODO Task C3: extract a typed error class + retry flag.
            job.state = .failed(errorClass: "io", retryAvailable: true)
        }
        try? await store.upsert(job)
        recent.append(job)
        current = nil
        pumpIfIdle()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobQueueTests
```

Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "feat(refine): add RefinementJobQueue single-worker orchestrator"
```

---

### Task C2: queue — `pauseForRecording` / `resumeAfterRecording`

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

- [ ] **Step 1: Write the failing test (append)**

```swift
// Tests/PipelineTests/RefinementJobQueueTests.swift — append

/// `pauseForRecording()` stalls a job mid-run; `resumeAfterRecording()`
/// finishes it. The in-flight job is the same one before and after.
@Test("pauseForRecording stalls in-flight; resume continues the same job")
func pauseAndResume() async throws {
    let store = RefinementJobStore(directory: tempDir())
    let gate = PauseGate(initiallyOpen: true)
    let started = expectation()
    let finished = expectation()

    let queue = RefinementJobQueue(
        store: store,
        runJob: { _ in
            started.fulfill()
            await gate.waitOpen()
            finished.fulfill()
        },
        pauseGate: gate)
    try await queue.start()

    try await queue.enqueueManualRefine(
        folderURL: URL(fileURLWithPath: "/tmp/x"),
        recordingId: "rec_x",
        modelName: "base", modelSHA256: "deadbeef")

    await started.wait(timeout: .seconds(2))
    // Pause: the worker should stall because runJob is awaiting the gate.
    await queue.pauseForRecording()
    // Resume by opening the gate — the original job finishes.
    await queue.resumeAfterRecording()
    await finished.wait(timeout: .seconds(2))

    let snapshot = await queue.snapshot()
    #expect(snapshot.running == nil)
    #expect(snapshot.recent.count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobQueueTests/pauseAndResume
```

Expected: compile error — `pauseForRecording` not defined, and the queue init signature does not yet accept `pauseGate`.

- [ ] **Step 3: Add pause/resume**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
// Change the init to accept an optional `pauseGate` the queue owns and
// can close/open. Pass the same gate to runJob via a closure injection or
// by making the gate `public` on the queue actor (cleaner: store it).
// Then add:

private let pauseGate: PauseGate

// Updated init (replace the old one):
public init(
    store: RefinementJobStore,
    runJob: @escaping RunJob,
    pauseGate: PauseGate = PauseGate(initiallyOpen: true),
    logger: Logger = Logger(label: LogSubsystem.engine)
) {
    self.store = store
    self.runJob = runJob
    self.pauseGate = pauseGate
    self.logger = logger
}

/// Pause the queue: stops new jobs from starting and closes the pause gate
/// so the in-flight refiner stalls at its next checkpoint. Also signals
/// the diarizer to SIGSTOP its subprocess (Task D1 wires that in).
public func pauseForRecording() async {
    pausedForRecording = true
    await pauseGate.close()
}

/// Resume the queue: opens the gate (the in-flight refiner picks up at its
/// next checkpoint) and lets the worker pump again.
public func resumeAfterRecording() async {
    pausedForRecording = false
    await pauseGate.open()
    pumpIfIdle()
}
```

And — important — modify `pumpIfIdle` to refuse to start a *new* job while paused, but allow the *existing* worker (the runJob closure that's already running) to continue once the gate reopens. The current `pumpIfIdle` already checks `pausedForRecording` (see Task C1), so no change needed there.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobQueueTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "feat(refine): pauseForRecording/resumeAfterRecording on queue"
```

---

### Task C3: queue — `cancel(jobId:)`

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

- [ ] **Step 1: Write the failing test (append)**

```swift
// Tests/PipelineTests/RefinementJobQueueTests.swift — append

@Test("cancel removes a queued (not-yet-running) job")
func cancelQueued() async throws {
    let store = RefinementJobStore(directory: tempDir())
    let neverFinishes = PauseGate(initiallyOpen: false)
    let queue = RefinementJobQueue(
        store: store,
        runJob: { _ in await neverFinishes.waitOpen() })
    try await queue.start()

    try await queue.enqueueManualRefine(
        folderURL: URL(fileURLWithPath: "/tmp/a"), recordingId: "rec_a",
        modelName: "base", modelSHA256: "deadbeef")
    try await queue.enqueueManualRefine(
        folderURL: URL(fileURLWithPath: "/tmp/b"), recordingId: "rec_b",
        modelName: "base", modelSHA256: "deadbeef")

    // Give the worker a beat to claim rec_a as `running`.
    try await Task.sleep(for: .milliseconds(50))

    let queuedIds = (await queue.snapshot()).queued.map(\.recordingId)
    let toCancel = queuedIds.first ?? ""
    await queue.cancel(recordingId: toCancel)

    let s = await queue.snapshot()
    #expect(s.queued.allSatisfy { $0.recordingId != toCancel })
    #expect(s.recent.contains { $0.recordingId == toCancel && $0.state == .cancelled })
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobQueueTests/cancelQueued
```

Expected: compile error — `cancel` not defined.

- [ ] **Step 3: Add `cancel`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
// Inside the actor:

/// Cancel a queued job. A no-op if no queued job with that recording id
/// exists. Running and terminal jobs are not affected here — for those,
/// the caller must wait (running can finish naturally) or delete the
/// terminal record via the store directly.
public func cancel(recordingId: String) async {
    guard let i = queued.firstIndex(where: { $0.recordingId == recordingId })
    else { return }
    var job = queued.remove(at: i)
    job.state = .cancelled
    try? await store.upsert(job)
    recent.append(job)
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobQueueTests
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "feat(refine): add RefinementJobQueue.cancel(recordingId:)"
```

---

### Task C4: queue — running-stage updates (`reportStage`)

This is the hook the refiner uses to push stage / region progress into the queue so the UI can show a fraction. The refiner takes a closure `onStageUpdate: (RefinementJobState) -> Void` and the queue threads it through.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

- [ ] **Step 1: Write the failing test (append)**

```swift
// Tests/PipelineTests/RefinementJobQueueTests.swift — append

@Test("a running job's snapshot reflects the latest stage update")
func runningStageUpdates() async throws {
    let store = RefinementJobStore(directory: tempDir())
    let gate = PauseGate(initiallyOpen: false)
    let queue = RefinementJobQueue(
        store: store,
        runJob: { _ in await gate.waitOpen() })  // blocks forever this test
    try await queue.start()

    try await queue.enqueueManualRefine(
        folderURL: URL(fileURLWithPath: "/tmp/x"), recordingId: "rec_x",
        modelName: "base", modelSHA256: "deadbeef")

    // Wait until the queue claims the job as running.
    try await Task.sleep(for: .milliseconds(50))
    var running = await queue.snapshot().running
    #expect(running != nil)

    // The refiner would normally call reportStage; here we drive it directly.
    await queue.reportStage(.running(
        stage: .transcribingSystem,
        stepsCompleted: 1, stepsTotal: 7,
        regionIndex: 3, regionsTotal: 10))
    running = await queue.snapshot().running
    if case .running(let stage, _, _, let r, let rt) = running?.state {
        #expect(stage == .transcribingSystem)
        #expect(r == 3 && rt == 10)
    } else {
        Issue.record("expected running state")
    }

    await gate.open()
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RefinementJobQueueTests/runningStageUpdates
```

Expected: compile error — `reportStage` not defined.

- [ ] **Step 3: Add `reportStage` + thread it into `ResumableRefiner`**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
// Inside the actor:

/// Update the running job's `state` from inside the refiner. A no-op when
/// no job is currently running.
public func reportStage(_ state: RefinementJobState) {
    guard var job = current else { return }
    job.state = state
    current = job
    Task { try? await self.store.upsert(job) }
}
```

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift
// Extend the actor with a stage reporter:

public typealias StageReporter = @Sendable (RefinementJobState) -> Void
private let reportState: StageReporter?

public init(
    transcribe: @escaping TranscribeRegion,
    detectRegions: @escaping DetectRegions,
    diarize: @escaping Diarize,
    pauseGate: PauseGate,
    events: EventWriter?,
    onStageUpdate: StageReporter? = nil,
    logger: Logger = Logger(label: LogSubsystem.engine)
) {
    /* … existing assignments … */
    self.reportState = onStageUpdate
}
```

Then update `advance(_:to:folder:)` and `iterateRegions(_:_:_:_:_:)` so each call invokes the reporter:

```swift
// In advance():
let totalStages = RefinementJobState.Stage.allCases.count
let stepIndex = RefinementJobState.Stage.allCases.firstIndex(of: stage) ?? 0
reportState?(.running(
    stage: stage, stepsCompleted: stepIndex, stepsTotal: totalStages,
    regionIndex: nil, regionsTotal: nil))

// At the head of iterateRegions's body, before the while loop:
let total = isMic ? progress.micRegions.count : progress.systemRegions.count
let baseStage: RefinementJobState.Stage =
    isMic ? .transcribingMic : .transcribingSystem
let stepIndex = RefinementJobState.Stage.allCases.firstIndex(of: baseStage) ?? 0

// And inside the while loop, after each region completes:
let completed = isMic ? progress.completedMicRegionIndices.count
                      : progress.completedSystemRegionIndices.count
reportState?(.running(
    stage: baseStage,
    stepsCompleted: stepIndex,
    stepsTotal: RefinementJobState.Stage.allCases.count,
    regionIndex: completed,
    regionsTotal: total))
```

Wire the queue's `reportStage` in C5 (the integration task).

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobQueueTests
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "feat(refine): queue snapshots reflect refiner stage updates"
```

---

### Task C5: production queue assembly — `makeStandard`

A factory that wires up the production refiner with a real whisper transcriber, the production diarizer, the events writer, and a `PauseGate` shared with the queue.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`

- [ ] **Step 1: Add the factory**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
// Add as an extension at the bottom of the file (keeps the actor's body
// focused on orchestration, not wiring).

extension RefinementJobQueue {
    /// Production wiring: real `WhisperTranscriber` + production
    /// `Diarizer` + the process-wide `EventWriter`.
    ///
    /// Used by `AppEnvironment` in `pulsartrace-mac`. The CLI's
    /// `OfflineRefiner` path stays unchanged (one-shot, no queue).
    public static func makeStandard(
        events: EventWriter,
        paths: AppPaths = .standard,
        settings: @escaping @Sendable () -> (model: WhisperModel, sha256: String)
    ) async -> RefinementJobQueue {
        let store = RefinementJobStore.standard(paths: paths)
        let gate = PauseGate(initiallyOpen: true)

        // The closure captures `gate` so the queue and the refiner share it.
        let runJob: RunJob = { job in
            let modelStore = ModelStore(events: events)
            let modelURL = try await modelStore.ensureAvailable(
                ModelCatalog.model(named: job.modelName) ?? ModelCatalog.base)
            let vadURL = try? await modelStore.ensureAvailable(ModelCatalog.sileroVAD)
            let diarizer = try OfflineRefiner.makeDiarizer()
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try WhisperTranscriber(modelURL: modelURL)
                    return try t.transcribeRegion(
                        samples, region: region, options: options)
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
                events: events)
            try await refiner.run(job: job)
        }

        let queue = RefinementJobQueue(store: store, runJob: runJob, pauseGate: gate)
        try? await queue.start()
        return queue
    }
}
```

- [ ] **Step 2: Run a quick build to verify it compiles**

```bash
swift build
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
git commit -m "feat(refine): RefinementJobQueue.makeStandard production factory"
```

---

## Phase D — RecordingViewModel integration

### Task D1: remove `.refining`; recording no longer blocks on refine

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/MenuBarState.swift`
- Modify: `Sources/PulsarTraceMenuBar/RecordingViewModel.swift`
- Modify: `Tests/MenuBarTests/RecordingViewModelTests.swift` (update tests that asserted `.refining`)

- [ ] **Step 1: Update / write the failing test**

The existing `happyPathTransitions` test in `RecordingViewModelTests.swift` asserts the `.refining` state. Update it to assert the new shape: a successful stop goes idle immediately, and the queue's auto-enqueue is observable via an injected closure.

```swift
// Tests/MenuBarTests/RecordingViewModelTests.swift
// REPLACE the happyPathTransitions test body with:

@Test("happy path: idle → recording → idle, refine is enqueued not run inline")
func happyPathTransitions() async throws {
    let root = MenuBarFixtures.tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = StubOrchestrator()
    let enqueued = EnqueueMailbox()

    let vm = RecordingViewModel(
        settings: try settings(outputRoot: root),
        orchestratorFactory: { _, _ in stub },
        enqueueAutoRefine: { url, recordingId in
            await enqueued.record(url: url, recordingId: recordingId)
        })

    #expect(vm.status == .idle)
    await vm.startRecording()
    if case .recording = vm.status {} else { Issue.record("not recording") }

    await vm.stopRecording()
    #expect(vm.status == .idle)

    let recorded = await enqueued.entries
    #expect(recorded.count == 1)
    #expect(recorded.first?.recordingId.hasPrefix("rec_") == true)
}

actor EnqueueMailbox {
    var entries: [(url: URL, recordingId: String)] = []
    func record(url: URL, recordingId: String) { entries.append((url, recordingId)) }
}
```

Add similar updates wherever a test asserts `.refining` (search the file for `case .refining`).

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter RecordingViewModelTests
```

Expected: compile error — `enqueueAutoRefine` parameter not on `RecordingViewModel`, and `.refining` references will compile-fail.

- [ ] **Step 3: Drop `.refining` and switch to enqueue**

```swift
// Sources/PulsarTraceMenuBar/MenuBarState.swift — replace the enum body:

public enum RecordingStatus: Equatable, Sendable {
    case idle
    case launching
    case recording(id: String, startedAt: Date)
    case crashed(id: String, partialFolderURL: URL?)
    case error(message: String)

    public var canStartRecording: Bool {
        if case .idle = self { return true }
        return false
    }
    public var canStopRecording: Bool {
        if case .recording = self { return true }
        return false
    }
    public var isActive: Bool {
        switch self {
        case .launching, .recording: return true
        case .idle, .crashed, .error: return false
        }
    }
}
```

```swift
// Sources/PulsarTraceMenuBar/RecordingViewModel.swift — replace runRefine + the
// references to it. The new field is an `enqueueAutoRefine` closure the host
// (AppEnvironment) supplies, which forwards into the queue.

private let enqueueAutoRefine: @Sendable (URL, String) async -> Void

public init(
    settings: MenuBarSettings,
    paths: AppPaths = .standard,
    events: EventWriter? = nil,
    clock: @escaping @Sendable () -> Date = { Date() },
    binaryURLResolver: (@Sendable (String) -> URL)? = nil,
    orchestratorFactory: (@Sendable (RecordPlan, @escaping @Sendable (String) -> URL)
        -> RecordingOrchestrating)? = nil,
    enqueueAutoRefine: (@Sendable (URL, String) async -> Void)? = nil
) {
    /* … existing assignments … */
    self.enqueueAutoRefine = enqueueAutoRefine ?? { _, _ in }
}
```

Replace `runRefine`'s body in `stopRecording` and `recoverFromCrash` with:

```swift
// Sources/PulsarTraceMenuBar/RecordingViewModel.swift

public func stopRecording() async {
    guard case .recording(let id, _) = status,
          let orchestrator else { return }
    crashWatch?.cancel()
    crashWatch = nil
    progressMessage = "Stopping…"
    await orchestrator.stop()
    self.orchestrator = nil
    liveMarkdownURL = nil
    if let folder = currentRecordingFolder {
        await enqueueAutoRefine(folder, id)
    }
    currentRecordingFolder = nil
    status = .idle
    progressMessage = ""
}

public func recoverFromCrash() async {
    guard case .crashed(let id, let partialFolder) = status,
          let partialFolder else {
        dismissCrash(); return
    }
    await enqueueAutoRefine(partialFolder, id)
    status = .idle
    progressMessage = ""
}
```

Delete the `reRefiner` parameter and the `runRefine` method entirely.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RecordingViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceMenuBar/MenuBarState.swift \
        Sources/PulsarTraceMenuBar/RecordingViewModel.swift \
        Tests/MenuBarTests/RecordingViewModelTests.swift
git commit -m "refactor(refine): drop RecordingStatus.refining; enqueue auto-refine onto queue"
```

---

### Task D2: AppEnvironment wires the queue + auto-pause on recording start

**Files:**
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`

- [ ] **Step 1: Wire the queue into `AppEnvironment`**

Add the queue + ViewModel to `AppEnvironment.init`, pass an `enqueueAutoRefine` closure to `RecordingViewModel`, and call `queue.pauseForRecording()` / `resumeAfterRecording()` at the recording boundaries. The simplest place is `toggleRecording()` plus a small observer on `recording.status`.

```swift
// Sources/pulsartrace-mac/PulsarTraceMacApp.swift — inside AppEnvironment:

let queue: RefinementJobQueue
let queueVM: RefinementJobQueueViewModel  // (added in Task E1)

init() {
    let settings = MenuBarSettings()
    let paths = AppPaths.standard
    let events = EventWriter(directory: paths.eventsDirectory)
    self.settings = settings
    self.paths = paths
    self.events = events

    // Build the queue first so the recording VM can enqueue into it.
    let queue = await RefinementJobQueue.makeStandard(
        events: events, paths: paths,
        settings: {
            let model = ModelCatalog.model(named: settings.refineModelName)
                ?? ModelCatalog.base
            return (model, model.sha256)
        })
    self.queue = queue

    let enqueue: @Sendable (URL, String) async -> Void = { url, recordingId in
        let model = ModelCatalog.model(named: settings.refineModelName)
            ?? ModelCatalog.base
        try? await queue.enqueueAutoRefine(
            folderURL: url, recordingId: recordingId,
            modelName: model.name, modelSHA256: model.sha256)
    }
    self.recording = RecordingViewModel(
        settings: settings, paths: paths, events: events,
        enqueueAutoRefine: enqueue)
    /* … remainder of init … */
}
```

(Resolving `await` in a synchronous `init`: this is where the existing `Task { await events.bootstrap() }` pattern applies. The cleanest fix is to make AppEnvironment's bootstrap a separate `func bootstrap() async` invoked from the SwiftUI `App.task { }`. Confirm during implementation.)

And add the auto-pause/resume hook to `toggleRecording()` and `startRecording()`:

```swift
// Sources/pulsartrace-mac/PulsarTraceMacApp.swift — replace toggleRecording

func toggleRecording() async {
    switch recording.status {
    case .idle:
        await queue.pauseForRecording()
        await recording.startRecording()
        // If the start failed and we are still .idle, undo the pause so the
        // queue continues. .error / .recording / .launching all keep the
        // pause until stop.
        if case .idle = recording.status {
            await queue.resumeAfterRecording()
        }
    case .recording:
        await recording.stopRecording()
        await queue.resumeAfterRecording()
    default:
        break
    }
}
```

- [ ] **Step 2: Run the existing menubar tests to confirm nothing else breaks**

```bash
swift test --filter MenuBarTests
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/pulsartrace-mac/PulsarTraceMacApp.swift
git commit -m "feat(refine): AppEnvironment wires the refinement queue + auto-pause"
```

---

### Task D3: wire `Diarizer.cancel()` into the queue's `pauseForRecording`

The pause gate stalls the refiner between regions / stages. While diarization is *in flight* (a long pyannote subprocess), the gate doesn't help — the queue's pause needs to additionally kill the python subprocess (D-Q7). The refiner's `runDiarization` already retries on `DiarizeError.cancelled` (Task B7), so the queue's job is just to terminate the inflight subprocess.

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/Cancellable.swift`
- Modify: `Sources/PulsarTraceEngine/Diarization/Diarizer.swift` (conform)
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`
- Modify: `Tests/PipelineTests/RefinementJobQueueTests.swift`

- [ ] **Step 1: Define the `Cancellable` protocol**

A tiny seam so the queue does not have to import `Diarizer` directly, and tests can plug in a spy without standing up a real subprocess.

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/Cancellable.swift
import Foundation

/// One-method seam the queue uses to terminate an inflight worker on pause
/// (D-Q7). `Diarizer` is the production conformer; tests inject a spy.
public protocol RefinementCancellable: Sendable {
    func cancel() async
}
```

And conform `Diarizer`:

```swift
// Sources/PulsarTraceEngine/Diarization/Diarizer.swift — at the bottom of the file:

extension Diarizer: RefinementCancellable {}
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/PipelineTests/RefinementJobQueueTests.swift — append

@Test("pauseForRecording cancels the inflight diarizer")
func pauseCancelsDiarizer() async throws {
    actor DiarizerSpy: RefinementCancellable {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    let spy = DiarizerSpy()
    let store = RefinementJobStore(directory: tempDir())
    let gate = PauseGate(initiallyOpen: true)
    let started = expectation()

    let queue = RefinementJobQueue(
        store: store,
        runJob: { [weak queueRef = nil as RefinementJobQueue?] _ in
            // Register the spy with the queue, then "diarize" (just wait
            // on a gate so the test controls timing).
            // Resolve `queueRef` by setting it in step 3 below.
            started.fulfill()
            await Task.sleep(for: .seconds(1))
        },
        pauseGate: gate)
    // After init, hand the queue a strong reference to itself so the
    // runJob can register the spy. (In production this is done via the
    // `setInflightCancellable` setter from inside makeStandard's runJob.)
    try await queue.start()
    await queue.setInflightCancellable(spy)

    try await queue.enqueueManualRefine(
        folderURL: URL(fileURLWithPath: "/tmp/x"), recordingId: "rec_x",
        modelName: "base", modelSHA256: "deadbeef")
    await started.wait(timeout: .seconds(2))

    await queue.pauseForRecording()
    let wasCancelled = await spy.cancelled
    #expect(wasCancelled)
}
```

- [ ] **Step 3: Wire `inflightCancellable` into the queue**

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift

/// The worker currently running, if any. Set by `runJob` at the start of
/// a refine and cleared on exit. The queue calls `.cancel()` on this when
/// `pauseForRecording` fires (D-Q7).
private var inflightCancellable: RefinementCancellable?

/// Register a cancellable for the in-flight job. Production `runJob`
/// passes a `Diarizer`; tests pass a spy.
public func setInflightCancellable(_ cancellable: RefinementCancellable?) {
    inflightCancellable = cancellable
}

// pauseForRecording: terminate the subprocess. No "resume" call on the
// cancellable — when the gate reopens the refiner just calls diarize()
// again from scratch (D-Q7).
public func pauseForRecording() async {
    pausedForRecording = true
    await pauseGate.close()
    if let c = inflightCancellable { await c.cancel() }
}

public func resumeAfterRecording() async {
    pausedForRecording = false
    await pauseGate.open()
    pumpIfIdle()
}
```

And update `makeStandard`'s `runJob` to register the diarizer:

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift — inside makeStandard

// makeStandard now builds the queue with a runJob that needs a reference
// back to the queue. Easiest restructure: build the queue first with a
// placeholder runJob; install the real runJob via a setter.

let queue = RefinementJobQueue(
    store: store, runJob: { _ in }, pauseGate: gate)

let runJob: RunJob = { job in
    let modelStore = ModelStore(events: events)
    let modelURL = try await modelStore.ensureAvailable(
        ModelCatalog.model(named: job.modelName) ?? ModelCatalog.base)
    let vadURL = try? await modelStore.ensureAvailable(ModelCatalog.sileroVAD)
    let diarizer = try OfflineRefiner.makeDiarizer()
    await queue.setInflightCancellable(diarizer)
    defer { Task { await queue.setInflightCancellable(nil) } }

    let refiner = ResumableRefiner(
        transcribe: { samples, region, options in
            let t = try WhisperTranscriber(modelURL: modelURL)
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
        events: events)
    try await refiner.run(job: job)
}
await queue.setRunJob(runJob)
try? await queue.start()
return queue
```

Add the setter on the queue:

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift

private var _runJob: RunJob
public func setRunJob(_ runJob: @escaping RunJob) { self._runJob = runJob }
```

(Refactor `runNext` to use `_runJob` instead of the immutable `runJob` field.)

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter RefinementJobQueueTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/Cancellable.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift \
        Sources/PulsarTraceEngine/Diarization/Diarizer.swift \
        Tests/PipelineTests/RefinementJobQueueTests.swift
git commit -m "feat(refine): pauseForRecording cancels the inflight diarizer"
```

---

## Phase E — Refinements pane and visual integration

### Task E1: `RefinementJobQueueViewModel` main-actor façade

**Files:**
- Create: `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift`
- Test:   `Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@Suite("RefinementJobQueueViewModel")
@MainActor
struct RefinementJobQueueViewModelTests {

    @Test("snapshot updates propagate to the @Observable VM")
    func snapshotPropagates() async throws {
        let store = RefinementJobStore(directory: FileManager.default
            .temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let queue = RefinementJobQueue(
            store: store, runJob: { _ in })
        try await queue.start()
        let vm = RefinementJobQueueViewModel(queue: queue)
        await vm.refresh()
        #expect(vm.running == nil)
        #expect(vm.queued.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter RefinementJobQueueViewModelTests
```

Expected: compile error.

- [ ] **Step 3: Write the VM**

```swift
// Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift
import Foundation
import PulsarTraceEngine

/// Main-actor `@Observable` façade over `RefinementJobQueue`. Views bind to
/// this; mutations forward into the actor.
///
/// The queue actor is the source of truth; this VM caches the last snapshot
/// and refreshes on a light timer. (A push channel via `AsyncStream` is a
/// cleaner long-term answer — the live-watcher polling pattern in
/// `LiveTranscriptWatcher` works fine for v1.)
@MainActor
@Observable
public final class RefinementJobQueueViewModel {

    public private(set) var running: RefinementJob?
    public private(set) var queued: [RefinementJob] = []
    public private(set) var recent: [RefinementJob] = []
    public private(set) var pausedForRecording = false

    private let queue: RefinementJobQueue
    private var poller: Task<Void, Never>?

    public init(queue: RefinementJobQueue) {
        self.queue = queue
    }

    /// Re-read the queue once.
    public func refresh() async {
        let s = await queue.snapshot()
        running = s.running
        queued = s.queued
        recent = s.recent
        pausedForRecording = s.pausedForRecording
    }

    /// Start a light poll (250 ms) so the UI updates without a push channel.
    /// Cancelled when the VM is deinited or `stop()` is called.
    public func startPolling() {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// Forward a "Refine" button press.
    public func enqueueManual(folderURL: URL, recordingId: String,
                              modelName: String, modelSHA256: String) async {
        try? await queue.enqueueManualRefine(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256)
        await refresh()
    }

    public func cancel(recordingId: String) async {
        await queue.cancel(recordingId: recordingId)
        await refresh()
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter RefinementJobQueueViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift \
        Tests/MenuBarTests/RefinementJobQueueViewModelTests.swift
git commit -m "feat(refine): RefinementJobQueueViewModel main-actor facade"
```

---

### Task E2: add the `Refinements` sidebar pane

**Files:**
- Modify: `Sources/pulsartrace-mac/AppNavigation.swift` (add `.refinements`)
- Modify: `Sources/pulsartrace-mac/MainWindowView.swift` (route `.refinements`)
- Create: `Sources/pulsartrace-mac/RefinementsListView.swift`
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift` (inject the VM)

- [ ] **Step 1: Add the enum case**

```swift
// Sources/pulsartrace-mac/AppNavigation.swift — replace AppSection:

enum AppSection: String, CaseIterable, Identifiable {
    case recordings, refinements, speakers, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings:  return "Recordings"
        case .refinements: return "Refinements"
        case .speakers:    return "Speakers"
        case .settings:    return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .recordings:  return "waveform"
        case .refinements: return "arrow.triangle.2.circlepath"
        case .speakers:    return "person.2"
        case .settings:    return "gearshape"
        }
    }
}
```

- [ ] **Step 2: Route the new section**

```swift
// Sources/pulsartrace-mac/MainWindowView.swift — replace the detail switch:

@ViewBuilder private var detail: some View {
    switch navigation.section {
    case .recordings:  RecordingsListView()
    case .refinements: RefinementsListView()
    case .speakers:    SpeakerEditorView(events: events)
    case .settings:    SettingsView()
    }
}
```

- [ ] **Step 3: Build the pane**

```swift
// Sources/pulsartrace-mac/RefinementsListView.swift
import SwiftUI
import PulsarTraceEngine
import PulsarTraceMenuBar

struct RefinementsListView: View {
    @Environment(RefinementJobQueueViewModel.self) private var queue

    var body: some View {
        List {
            if let running = queue.running {
                Section("Running") {
                    JobRow(job: running, allowCancel: false) {}
                }
            }
            if !queue.queued.isEmpty {
                Section("Queued") {
                    ForEach(queue.queued) { job in
                        JobRow(job: job, allowCancel: true) {
                            Task { await queue.cancel(recordingId: job.recordingId) }
                        }
                    }
                }
            }
            if !queue.recent.isEmpty {
                Section("Recent") {
                    ForEach(queue.recent) { job in
                        JobRow(job: job, allowCancel: false) {}
                    }
                }
            }
            if queue.running == nil && queue.queued.isEmpty && queue.recent.isEmpty {
                EmptyStateRow()
            }
        }
        .task { queue.startPolling() }
        .onDisappear { queue.stopPolling() }
    }
}

private struct JobRow: View {
    let job: RefinementJob
    let allowCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recordingId).font(.body.monospaced())
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let fraction = job.state.progressFraction {
                ProgressView(value: fraction).frame(width: 120)
            }
            if allowCancel {
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var stateText: String {
        switch job.state {
        case .queued: return "Queued"
        case .running(let stage, let done, let total, let r, let rt):
            if let r, let rt {
                return "\(stage.rawValue) · step \(done + 1)/\(total) · region \(r)/\(rt)"
            }
            return "\(stage.rawValue) · step \(done + 1)/\(total)"
        case .paused(let reason, let stage):
            return "Paused (\(reason.rawValue)) at \(stage.rawValue)"
        case .completed(let s, let n):
            return String(format: "Done · %.1fs · %d speaker(s)", s, n)
        case .failed(let cls, let retry):
            return retry ? "Failed (\(cls)) · retryable" : "Failed (\(cls))"
        case .cancelled:
            return "Cancelled"
        }
    }
}

private struct EmptyStateRow: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No refinements in flight.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Inject the VM into the unified window's environment**

```swift
// Sources/pulsartrace-mac/PulsarTraceMacApp.swift — in the body's
// Window("PulsarTrace", id: WindowID.main) scene, add the environment:

Window("PulsarTrace", id: WindowID.main) {
    MainWindowView(events: environment.events)
        .environment(environment.settings)
        .environment(environment.recording)
        .environment(environment.scanner)
        .environment(environment.navigation)
        .environment(environment.queueVM)   // NEW
}
```

And construct `queueVM` in `AppEnvironment.init` after `queue`:

```swift
self.queueVM = RefinementJobQueueViewModel(queue: queue)
```

- [ ] **Step 5: Build, verify the new pane renders**

```bash
swift build
.build/debug/pulsartrace-mac &
# Manual: open the unified window, click "Refinements". Confirm the
# empty state renders. Quit the app afterwards.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/pulsartrace-mac/AppNavigation.swift \
        Sources/pulsartrace-mac/MainWindowView.swift \
        Sources/pulsartrace-mac/RefinementsListView.swift \
        Sources/pulsartrace-mac/PulsarTraceMacApp.swift
git commit -m "feat(refine): add Refinements sidebar pane"
```

---

### Task E3: recordings list — per-row badge + enqueue via queue

**Files:**
- Modify: `Sources/pulsartrace-mac/RecordingsListView.swift`
- Modify: `Sources/PulsarTraceMenuBar/RecordingsScanner.swift` (remove the in-process re-refine; the list now goes via the queue)

- [ ] **Step 1: Replace the Refine button's handler**

```swift
// Sources/pulsartrace-mac/RecordingsListView.swift
// Replace the Refine button in `row(_:)`:

Button("Refine") {
    Task {
        let model = ModelCatalog.model(named: settings.refineModelName)
            ?? ModelCatalog.base
        await queueVM.enqueueManual(
            folderURL: recording.folderURL,
            recordingId: recording.id,
            modelName: model.name,
            modelSHA256: model.sha256)
    }
}
.disabled(jobInFlight(recording.id))
```

Add a small helper that reads `queueVM`:

```swift
private func jobInFlight(_ recordingId: String) -> Bool {
    if queueVM.running?.recordingId == recordingId { return true }
    return queueVM.queued.contains { $0.recordingId == recordingId }
}
```

And inject the two environments:

```swift
@Environment(RefinementJobQueueViewModel.self) private var queueVM
@Environment(MenuBarSettings.self) private var settings
```

Also add a small badge to the row showing the latest job state for this recording (if any).

- [ ] **Step 2: Drop the in-process re-refine from `RecordingsScanner`**

The scanner now only reads folders. Remove the `reRefiner` closure, the `reRefine` method, and the related `ReRefineError`. (Search the codebase for callers — the only one is `RecordingsListView`'s Refine button, which is moved to the queue in Step 1.)

```swift
// Sources/PulsarTraceMenuBar/RecordingsScanner.swift — delete:
//   - the reRefiner stored property
//   - the reRefine(_:) method
//   - the ReRefineError enum
//   - the makeDefaultReRefiner static method
//   - the events parameter on init (no longer used)
```

Update `RecordingsScannerTests.swift` to drop tests that exercised re-refine — they belong in `RefinementJobQueueTests.swift` now.

- [ ] **Step 3: Build + test**

```bash
swift test
```

Expected: PASS for all suites. Manually verify in the running app that clicking "Refine" enqueues onto the queue and the Refinements pane shows it.

- [ ] **Step 4: Commit**

```bash
git add Sources/pulsartrace-mac/RecordingsListView.swift \
        Sources/PulsarTraceMenuBar/RecordingsScanner.swift \
        Tests/MenuBarTests/RecordingsScannerTests.swift
git commit -m "feat(refine): recordings list enqueues via the refinement queue"
```

---

### Task E4: menubar dropdown status reflects the queue

**Files:**
- Modify: `Sources/pulsartrace-mac/MenuBarMenuView.swift`

- [ ] **Step 1: Show a queue-aware status line**

```swift
// Sources/pulsartrace-mac/MenuBarMenuView.swift — extend the existing
// statusText computed property:

@Environment(RefinementJobQueueViewModel.self) private var queueVM

private var statusText: String {
    switch recording.status {
    case .recording(_, let startedAt):
        let started = startedAt.formatted(date: .omitted, time: .shortened)
        // Show recording + a tail for the queue if it's busy in the background.
        if let q = queueStatus { return "Recording since \(started) · \(q)" }
        return "Recording since \(started)"
    case .idle:
        if let q = queueStatus { return q }
        return recording.progressMessage.isEmpty
            ? "Ready" : recording.progressMessage
    case .launching: return "Starting…"
    case .crashed:   return "Recording stopped unexpectedly"
    case .error(let message): return message
    }
}

private var queueStatus: String? {
    if let running = queueVM.running, case .running(let stage, _, _, _, _) = running.state {
        if let pct = running.state.progressFraction {
            return String(format: "Refining %.0f%% (%@)", pct * 100, stage.rawValue)
        }
        return "Refining (\(stage.rawValue))"
    }
    if !queueVM.queued.isEmpty {
        return "\(queueVM.queued.count) queued"
    }
    return nil
}
```

Also remove the `.refining` branch from the `recordControls` switch (`Refining…` button) — the recording state machine no longer has `.refining`.

Update the menubar icon picker in `PulsarTraceMacApp.swift`:

```swift
// Sources/pulsartrace-mac/PulsarTraceMacApp.swift — replace menuBarSymbol:

extension RecordingStatus {
    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform"
        case .launching: return "waveform.badge.plus"
        case .recording: return "waveform.badge.microphone"
        case .crashed:   return "exclamationmark.triangle"
        case .error:     return "exclamationmark.triangle"
        }
    }
}
```

If a queue-busy icon is wanted, derive it at the `MenuBarExtra` label site using `environment.queueVM.running != nil` rather than baking it into the status enum.

- [ ] **Step 2: Build + test**

```bash
swift test --filter MenuBarTests
swift build
```

- [ ] **Step 3: Manual smoke**

```bash
.build/debug/pulsartrace-mac &
# Manual: start a recording. Confirm "Start Recording" is greyed but
# the dropdown still works. Stop the recording. Open the unified window's
# Refinements pane. Watch the progress fill. Start a second recording
# while the refine is mid-flight: confirm the refine pauses (its
# progress bar stops advancing) and resumes after the new recording stops.
```

- [ ] **Step 4: Commit**

```bash
git add Sources/pulsartrace-mac/MenuBarMenuView.swift \
        Sources/pulsartrace-mac/PulsarTraceMacApp.swift
git commit -m "feat(refine): menubar dropdown shows queue progress"
```

---

### Task E5: clean up `OfflineRefiner` — keep only the CLI's bare-WAV path

`OfflineRefiner` is no longer the menubar's path; only `pulsartrace refine` uses it. Make that explicit so a future reader does not think it is shared.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift`

- [ ] **Step 1: Add a doc-comment + maybe simplify**

```swift
// Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift
// At the top, replace the existing doc block:

/// One-shot, no-queue refine — the entry point for the `pulsartrace refine`
/// CLI. The menubar app no longer calls this; it uses
/// `RefinementJobQueue` + `ResumableRefiner` so a refine is pause-resumable
/// and back-to-back recordings don't block each other.
///
/// This path stays so the CLI can take a bare WAV (or a folder) without
/// touching the queue: bare-WAV runs are typically one-shot scripts where
/// pause/resume is not useful. The shared merge + write step is in
/// `RefinementPipeline.assembleAndWrite` (Task B4).
```

- [ ] **Step 2: Run the full test suite**

```bash
swift test
```

Expected: every suite green.

- [ ] **Step 3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift
git commit -m "docs(refine): clarify OfflineRefiner is the CLI-only path"
```

---

### Task E6: update `project-docs/PLAN.md` + add a `DECISIONS.md` entry

**Files:**
- Modify: `project-docs/PLAN.md` (append a new section)
- Modify: `project-docs/DECISIONS.md` (add D-Q1…D-Q6 if you keep them; or one merged "D34 — refinement job queue" entry)

- [ ] **Step 1: Add the section + decision**

Document what this work delivers, with the same `[x] committed <hash>` format the file uses.

- [ ] **Step 2: Commit**

```bash
git add project-docs/PLAN.md project-docs/DECISIONS.md
git commit -m "docs(plan): record refinement job queue work + decisions"
```

---

## Self-Review (filled in)

**1. Spec coverage**

| Requirement (from the request) | Task |
|---|---|
| Queue-based state machine with observability | Phase C (C1–C4) + Phase E (E1, E2) |
| Dedicated sub-page | Task E2 — Refinements sidebar pane |
| Pausable mid-run with persisted progress | Task B1 (PauseGate), B4–B7 (ResumableRefiner + checkpoint file + diarize cancel-retry) |
| Resume from intermediate file | Task B5 — resume-from-checkpoint regression test |
| Bounded duplicated effort (≤ region size, ~5 min) | Task B4 — VAD region granularity (D-Q6); Task B7 — diarize re-run on resume (D-Q7) |
| Recording is exclusive | Task D1 — `.refining` removed from `RecordingStatus` |
| New recording allowed while refinement runs | Task D1 + Task D2 (`canStartRecording` is now true while queue is busy) |
| Recording pauses refinement (resource constraint) | Task D2 — `pauseForRecording()` on start; Task D3 — terminate pyannote subprocess (D-Q7) |
| Auto + manual refine share one queue | Task C1 — both `enqueueAutoRefine` and `enqueueManualRefine` route to the same FIFO |
| Refinement progress visible | Task C4 — `reportStage` updates; Task E2 — progress bar in row |
| Visibility from recordings page too | Task E3 — per-row badge + state |

**2. Placeholder scan**

The only deliberate placeholders are the two `fatalError("…")` markers in **Task B4** (`awaitSync` and `assembleAndWrite`), each annotated with an instruction that the engineer makes one obvious refactor (`loadSamples` becomes `async`, and three private merge/write helpers become `internal static`). These are documented decisions, not unfilled gaps, but be aware of them on entry.

**3. Type consistency**

- `RefinementJobState.Stage` and `RefinementPipeline.Stage` are intentionally distinct (one is the queue's serialised stage, the other is the pipeline's internal progress reporter). Mapping is by `rawValue` — `Stage.allCases` is enumerated in `ResumableRefiner` to compute `stepsTotal`. The two enums should stay 1:1; if one grows a case, the other must too.
- `RefinementJob.state` field name is consistent across tasks (`state`, not `status` — the recording uses `status`, the job uses `state`, matching their respective domain language).
- `enqueueManualRefine` / `enqueueAutoRefine` / `enqueueCrashRecovery` — three distinct entry points so the `Trigger` is always set correctly; no `enqueue(trigger:)` general form exposed publicly.
- The `PauseGate` is shared by exactly two parties: the queue (`pauseForRecording`) and the refiner (`waitOpen` at every checkpoint). The production `makeStandard` is the one place that wires the same `gate` reference into both.

**4. Risks called out**

- **Whisper Metal lock interaction.** A live recording's `StreamingTranscriber` and a refine `WhisperTranscriber` both want `Self.metalLock`. The refine's whisper context is released between regions (the lock is acquired per-call in `transcribeRegion`), so a recording can claim it freely while the refine waits at the pause gate. Verify in Task D2's manual smoke: start a recording while a refine is in-flight and watch the live transcript's lag for any pause.
- **Pyannote re-run cost (D-Q7, accepted).** A diarize cancelled by `pauseForRecording` is re-run from scratch when the recording stops. The pyannote model load alone is ~10–30 s. Worst case (a 1 h recording where diarize was 95% done at cancel time): ~10–30 s of re-loaded model + a few minutes of re-inference, well within the user's "5 minutes of duplicated effort" budget.
- **Recording-folder portability (acknowledged, not addressed).** `refine-progress.json` lives in the folder and may exist in a half-finished state across copies / interruptions. The user has confirmed this is acceptable for v1 — the same shape already exists across the file tree + speakers SQLite, so this does not regress portability further. No follow-up required.

---

## Execution Handoff

**Plan complete and saved to `docs/specs/2026-05-19-refinement-job-queue-plan.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using pulsartrace-executing-plans, batch execution with checkpoints.

**Which approach?**

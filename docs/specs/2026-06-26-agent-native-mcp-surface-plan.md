# Agent-Native MCP Surface — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development
> (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, in-app, loopback MCP server so a local AI agent (Claude Code, Codex) can
list recordings and speakers, read transcripts off disk, and manage speaker identity and recording
titles — driving PulsarTrace autonomously.

**Architecture:** The menubar app hosts an MCP server in-process (it already owns the speaker
library, so an agent edit and a UI edit are the same code path). A new `PulsarTraceMCP` library
holds the tool registry, the JSON-RPC handlers, and a hand-rolled `NWListener` loopback HTTP front
end that feeds the official MCP Swift SDK's `StatelessHTTPServerTransport`. Speaker mutations route
through a new engine-level `SpeakerEditService` (extracted from `SpeakerEditorViewModel`) so the
retroactive `final.md` rewrite (PT-R90) happens identically for every caller.

**Tech Stack:** Swift 6 / SwiftPM, `Network.framework` (`NWListener`),
`modelcontextprotocol/swift-sdk` (Apache-2.0/MIT), `PulsarTraceEngine` (`SpeakerLibrary`,
`FinalMarkdownRewriter`, events), `PulsarTraceMenuBar` (`RecordingsScanner`, `MenuBarSettings`),
Swift Testing. Source of truth: `.erratum/projects/P6-agent-native-mcp-surface/` (`prd.md`
`PT-P6-R1..R11`, `decisions.md` `PT-P6-D1..D11`).

______________________________________________________________________

## How to build & test (read once)

These come from `CLAUDE.md` and are easy to get wrong:

- `swift build`, `swift test` must run **bare (no shell operators — no `|`, `>`, `&&`, `;`)** and
  with `dangerouslyDisableSandbox: true`. Anything else is denied in don't-ask mode.
- Run a focused suite with `--filter`, e.g. `swift test --filter SpeakerEditService` (bare).
- `git` and every other command run **plain, in-sandbox** (no `dangerouslyDisableSandbox`).
- Never leave a red suite. After each epic, the relevant `--filter` suites must be green.

______________________________________________________________________

## Epic overview (the decomposition)

Build in this order; each epic ships working, testable software on its own. The detailed bite-sized
TDD steps for **Epic 1** are below in full. Epics 2–6 carry their scope, file structure, and ordered
task list here; their step-level TDD detail is authored when the epic opens (their exact code
depends on the API the prior epic lands — the per-subsystem cadence the writing-plans skill calls
for). As each epic opens, the doc-owner also writes its Erratum `epics/E{n}-…/spec.md`, and its
`completion.md` at close.

- **E1 — `SpeakerEditService` extraction + menubar adoption.** Requirements: PT-P6-R9 (core).
  Depends on: —. Ships: the engine service; the menubar parity suite stays green; new service unit
  tests.
- **E2 — MCP server foundation.** Requirements: PT-P6-R1, R2, R10, R11. Depends on: E1. Ships: a
  running, authenticated loopback server (`initialize` + empty `tools/list`) with the Settings
  toggle/port/token, `/healthz`, supervision, and a manual restart.
- **E3 — Read tools.** Requirements: PT-P6-R3, R4, R7. Depends on: E2. Ships: `list_recordings`,
  `get_recording_meta`, `list_speakers`, `get_speaker`, `recent_events`.
- **E4 — Speaker write tools.** Requirements: PT-P6-R5. Depends on: E2, E1. Ships: the nine speaker
  tools (`rename`/`merge`/`split`/`unmerge`/`unsplit`/`delete`/`undelete`/`delist`/`undelist`), with
  the during-capture gate.
- **E5 — Recording write tools + discovery.** Requirements: PT-P6-R6, R8. Depends on: E2. Ships:
  `rename_recording`, `request_refine`, the `manual` tool, and self-documenting descriptions.
- **E6 — CLI adoption + ops-manual content.** Requirements: PT-P6-R9 (CLI clause). Depends on: E1.
  Ships: `pulsartrace speakers` rename/merge/etc. drive the retroactive rewrite; the manual Markdown
  is finalized.

**Tool surface (final, 17 tools), for reference while building E3–E5:**

- Read: `list_recordings`, `get_recording_meta`, `list_speakers`, `get_speaker`, `recent_events`.
- Speaker writes: `rename_speaker`, `merge_speakers`, `split_speaker`, `unmerge_speakers`,
  `unsplit_speaker`, `delete_speaker`, `undelete_speaker`, `delist_speaker`, `undelist_speaker`.
- Recording writes: `rename_recording`, `request_refine`.
- Discovery: `manual`.

______________________________________________________________________

## Epic 1 — `SpeakerEditService` extraction + menubar adoption

**What it delivers:** the orchestration currently inlined in
`Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift` (library mutation with events suppressed →
`FinalMarkdownRewriter` → paired events in causal order) becomes a reusable `actor` in
`PulsarTraceEngine`. The view model delegates to it; its behaviour is unchanged, proven by the
existing `SpeakerEditorViewModel` suite staying green. New `SpeakerEditService` tests prove the
service stands alone for the MCP/CLI callers that bypass the view model.

**Why an `actor`:** the read-appearances-then-rewrite sequence must run to completion before another
edit starts. When the MCP server and the UI can both edit, an actor serialises them (the
`SpeakerLibrary` actor only serialises the DB writes, not the whole edit).

### File structure

- Create: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift` — the service, result
  type, and error type. One responsibility: orchestrate one speaker edit end-to-end.
- Create: `Tests/MenuBarTests/SpeakerEditServiceTests.swift` — direct service tests. (Placed in
  `MenuBarTests` because that target already imports `PulsarTraceEngine` and owns `MenuBarFixtures`
  — `makeRecordingFolder`, `soloFinalMarkdown`, `tempDir` — which build the on-disk `final.md`
  fixtures these tests need.)
- Modify: `Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift` — delegate each mutating method
  to the service; keep the UI concerns (`isRewriting`, toast, `reload`, `lastError`) and the cheap
  pre-checks that preserve UX.

The service takes `outputFolderRoots: [URL]` **per call** (not at init) because the configured
output folders can change between edits; each caller passes its current roots (the view model passes
`outputRoots()`).

### Task 1: Service skeleton — result type, error type, `validateName`

**Files:**

- Create: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift`

- Test: `Tests/MenuBarTests/SpeakerEditServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MenuBarTests/SpeakerEditServiceTests.swift`:

```swift
import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// `SpeakerEditService` orchestrates one speaker edit end-to-end (PT-P6-R9):
/// library mutation, the retroactive `final.md` rewrite, and the paired events
/// in causal order — identically for every caller.
@Suite("SpeakerEditService")
struct SpeakerEditServiceTests {

    private func centroid(_ seed: Float) -> [Float] { (0..<256).map { _ in seed } }

    @Test("validateName rejects empty and label-breaking characters")
    func validateNameRules() {
        #expect(throws: SpeakerEditError.self) { try SpeakerEditService.validateName("  ") }
        #expect(throws: SpeakerEditError.self) { try SpeakerEditService.validateName("Bob+Alice") }
        #expect(throws: SpeakerEditError.self) { try SpeakerEditService.validateName("Star*") }
        #expect(throws: SpeakerEditError.self) { try SpeakerEditService.validateName("back`tick") }
        #expect(throws: Never.self) { try SpeakerEditService.validateName("Steven") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter SpeakerEditService` Expected:
FAIL to compile — `cannot find 'SpeakerEditService' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift`:

```swift
import Foundation

/// The recordings whose `final.md` an edit actually rewrote (may be empty).
public struct SpeakerEditResult: Sendable, Equatable {
    public let rewrittenRecordingIds: [String]
    public init(rewrittenRecordingIds: [String]) {
        self.rewrittenRecordingIds = rewrittenRecordingIds
    }
}

/// Errors a speaker edit can surface to any caller (UI, MCP, CLI).
public enum SpeakerEditError: Error, CustomStringConvertible, Equatable {
    case invalidName(String)
    case speakerNotFound
    case micCannotBeDelisted

    public var description: String {
        switch self {
        case .invalidName(let why): return why
        case .speakerNotFound: return "speaker not found"
        case .micCannotBeDelisted: return "The microphone speaker cannot be delisted."
        }
    }
}

/// The one place speaker edits are orchestrated (PT-R90 / PT-P6-R9): mutate the
/// library with the event suppressed, run the retroactive `final.md` rewrite,
/// and emit the `speaker_*` cause before its `final_md_rewritten` effects. The
/// menubar editor, the MCP server, and the CLI all call this so an edit produces
/// identical file and event effects regardless of who triggers it.
public actor SpeakerEditService {
    private let library: SpeakerLibrary
    private let events: EventWriter?
    private let rewriter: FinalMarkdownRewriter

    public init(
        library: SpeakerLibrary,
        events: EventWriter?,
        rewriter: FinalMarkdownRewriter = FinalMarkdownRewriter()
    ) {
        self.library = library
        self.events = events
        self.rewriter = rewriter
    }

    /// Canonical speaker-name rule shared by every caller. A name containing
    /// `+`, `*`, or a backtick breaks `final.md`'s `**[HH:MM:SS] <label>:**`
    /// label parsing (`+` is the co-attribution separator).
    public static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeakerEditError.invalidName("A speaker name cannot be empty.")
        }
        let forbidden: Set<Character> = ["+", "*", "`"]
        guard !trimmed.contains(where: { forbidden.contains($0) }) else {
            throw SpeakerEditError.invalidName("A speaker name cannot contain + * or `.")
        }
    }

    /// Emit one `final_md_rewritten` per rewritten recording, after the
    /// `speaker_*` cause (causal order, PT-R90 paired events).
    func emitRewriteEvents(
        _ results: [FinalMarkdownRewriter.RecordingResult],
        reason: FinalMarkdownRewriter.RewriteReason
    ) async {
        for result in results {
            _ = try? await events?.append(FinalMDRewrittenEvent(
                recordingId: result.recordingId,
                pathBasename: RecordingFolder.FileName.final,
                sha256: result.newSHA256,
                reason: reason.rawValue))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerEditService` Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift \
        Tests/MenuBarTests/SpeakerEditServiceTests.swift
git commit -m "feat(engine): SpeakerEditService skeleton + name validation (PT-P6-R9)"
```

### Task 2: Service `rename` and `merge`

**Files:**

- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift`

- Test: `Tests/MenuBarTests/SpeakerEditServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `SpeakerEditServiceTests`:

```swift
    @Test("rename rewrites past final.md, emits cause before effect, no-ops on unchanged name")
    func renameRewritesAndIsCausalAndNoOps() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "standup", recordingId: "rec_standup")

        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"), events: events)
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)

        let service = SpeakerEditService(library: library, events: events)
        let result = try await service.rename(
            speakerId: steve.id, to: "Steven", outputFolderRoots: [root])
        #expect(result.rewrittenRecordingIds == ["rec_standup"])

        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Steven:**"))
        #expect(!finalText.contains("] Steve:**"))
        #expect(try await library.liveSpeakers().first { $0.id == steve.id }?.name == "Steven")

        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        let renamedIdx = try #require(log.range(of: "speaker_renamed"))
        let rewrittenIdx = try #require(log.range(of: "final_md_rewritten"))
        #expect(renamedIdx.lowerBound < rewrittenIdx.lowerBound)

        // Unchanged name: no rewrite (no new .bak beyond the first), empty result.
        let again = try await service.rename(
            speakerId: steve.id, to: "Steven", outputFolderRoots: [root])
        #expect(again.rewrittenRecordingIds.isEmpty)
    }

    @Test("merge rewrites the merged speaker's recordings and drops its metadata row")
    func mergeRewritesFinalMarkdown() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_other", recordingFolderName: "other")
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)

        let service = SpeakerEditService(library: library, events: nil)
        _ = try await service.merge(
            primaryId: steve.id, otherId: unknown.id, outputFolderRoots: [root])

        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Steve:**"))
        #expect(!finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("Steve+Steve"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeakerEditService` Expected: FAIL to compile —
`value of type 'SpeakerEditService' has no member 'rename'`.

- [ ] **Step 3: Write the implementation**

Add to `SpeakerEditService` (before `emitRewriteEvents`):

```swift
    public func rename(
        speakerId: String, to newName: String, outputFolderRoots: [URL]
    ) async throws -> SpeakerEditResult {
        try Self.validateName(newName)
        // No-op: committing an unchanged name must not rewrite every final.md.
        guard try await library.speaker(id: speakerId)?.name != newName else {
            return SpeakerEditResult(rewrittenRecordingIds: [])
        }
        let oldName = try await library.rename(
            speakerId: speakerId, to: newName, suppressEvent: true)
        let appearances = try await library.appearances(of: speakerId)
        let results = try await rewriter.rewrite(
            oldName: oldName, newName: newName, appearances: appearances,
            outputFolderRoots: outputFolderRoots, reason: .speakerRenamed)
        _ = try? await events?.append(SpeakerRenamedEvent(
            speakerId: speakerId, oldName: oldName, newName: newName,
            appliedToRecordings: results.map(\.recordingId)))
        await emitRewriteEvents(results, reason: .speakerRenamed)
        return SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId))
    }

    public func merge(
        primaryId: String, otherId: String, outputFolderRoots: [URL]
    ) async throws -> SpeakerEditResult {
        let names = try await library.merge(
            primaryId: primaryId, otherId: otherId, suppressEvent: true)
        let appearances = try await library.appearances(of: primaryId)
        let results = try await rewriter.rewrite(
            oldName: names.otherName, newName: names.primaryName,
            appearances: appearances, outputFolderRoots: outputFolderRoots,
            reason: .speakerMerged, removedSpeakerId: otherId)
        _ = try? await events?.append(SpeakerMergedEvent(
            primarySpeakerId: primaryId, mergedSpeakerId: otherId,
            appliedToRecordings: results.map(\.recordingId)))
        await emitRewriteEvents(results, reason: .speakerMerged)
        return SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SpeakerEditService` Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift \
        Tests/MenuBarTests/SpeakerEditServiceTests.swift
git commit -m "feat(engine): SpeakerEditService rename + merge (PT-P6-R9)"
```

### Task 3: Service `split`

**Files:**

- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift`

- Test: `Tests/MenuBarTests/SpeakerEditServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SpeakerEditServiceTests`:

```swift
    @Test("split moves a recording to a new speaker and rewrites its final.md")
    func splitRewritesFinalMarkdown() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)

        let service = SpeakerEditService(library: library, events: nil)
        let (newSpeaker, result) = try await service.split(
            originalId: unknown.id, movingRecordingIds: ["rec_review"],
            newName: "Bob", outputFolderRoots: [root])

        #expect(newSpeaker.name == "Bob")
        #expect(result.rewrittenRecordingIds == ["rec_review"])
        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Bob:**"))
        #expect(!finalText.contains("] Unknown #1:**"))
    }

    @Test("split validates the new name")
    func splitValidatesName() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let s = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: "review")
        let service = SpeakerEditService(library: library, events: nil)
        await #expect(throws: SpeakerEditError.self) {
            _ = try await service.split(
                originalId: s.id, movingRecordingIds: ["rec_review"],
                newName: "Bad+Name", outputFolderRoots: [root])
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerEditService` Expected: FAIL to compile — no member `split`.

- [ ] **Step 3: Write the implementation**

Add to `SpeakerEditService`:

```swift
    public func split(
        originalId: String, movingRecordingIds: [String], newName: String,
        outputFolderRoots: [URL]
    ) async throws -> (newSpeaker: Speaker, result: SpeakerEditResult) {
        try Self.validateName(newName)
        guard let originalName = try await library.speaker(id: originalId)?.name else {
            throw SpeakerEditError.speakerNotFound
        }
        let newSpeaker = try await library.split(
            originalId: originalId, movingRecordingIds: movingRecordingIds,
            newName: newName, suppressEvent: true)
        let appearances = try await library.appearances(of: newSpeaker.id)
        let results = try await rewriter.rewrite(
            oldName: originalName, newName: newName, appearances: appearances,
            outputFolderRoots: outputFolderRoots, reason: .speakerSplit)
        _ = try? await events?.append(SpeakerSplitEvent(
            originalSpeakerId: originalId, newSpeakerId: newSpeaker.id,
            appliedToRecordings: results.map(\.recordingId)))
        await emitRewriteEvents(results, reason: .speakerSplit)
        return (newSpeaker, SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId)))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeakerEditService` Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift \
        Tests/MenuBarTests/SpeakerEditServiceTests.swift
git commit -m "feat(engine): SpeakerEditService split (PT-P6-R9)"
```

### Task 4: Service `delist` and `undelist`

**Files:**

- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift`

- Test: `Tests/MenuBarTests/SpeakerEditServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `SpeakerEditServiceTests`:

```swift
    @Test("delist drops the speaker's label, returns its name, rejects the mic speaker")
    func delistDropsLabelAndRejectsMic() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)
        let you = try await library.createSpeaker(
            name: "You", centroid: centroid(0.5), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)

        let service = SpeakerEditService(library: library, events: nil)
        let (name, _) = try await service.delist(
            speakerId: unknown.id, outputFolderRoots: [root])
        #expect(name == "Unknown #1")
        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Unrecognized:**"))
        #expect(!finalText.contains("] Unknown #1:**"))

        await #expect(throws: SpeakerEditError.micCannotBeDelisted) {
            _ = try await service.delist(speakerId: you.id, outputFolderRoots: [root])
        }
        #expect(try await library.liveSpeakers().first { $0.id == you.id }?.isDelisted == false)
    }

    @Test("undelist restores the Unrecognized solo line back to the speaker name")
    func undelistRestoresLabel() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)
        let service = SpeakerEditService(library: library, events: nil)
        _ = try await service.delist(speakerId: unknown.id, outputFolderRoots: [root])
        _ = try await service.undelist(speakerId: unknown.id, outputFolderRoots: [root])

        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("Unrecognized"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeakerEditService` Expected: FAIL to compile — no member `delist`.

- [ ] **Step 3: Write the implementation**

Add to `SpeakerEditService`:

```swift
    public func delist(
        speakerId: String, outputFolderRoots: [URL]
    ) async throws -> (name: String, result: SpeakerEditResult) {
        guard let speaker = try await library.speaker(id: speakerId) else {
            throw SpeakerEditError.speakerNotFound
        }
        guard speaker.name != "You" else { throw SpeakerEditError.micCannotBeDelisted }
        let name = speaker.name
        _ = try await library.delist(speakerId: speakerId, suppressEvent: true)
        let appearances = try await library.appearances(of: speakerId)
        let results = try await rewriter.rewriteDropping(
            name: name, speakerId: speakerId, appearances: appearances,
            outputFolderRoots: outputFolderRoots, reason: .speakerDelisted)
        let recoverableUntil = Timestamps.event(
            Date().addingTimeInterval(SpeakerLibrary.recoveryWindow))
        _ = try? await events?.append(SpeakerDelistedEvent(
            speakerId: speakerId, recoverableUntil: recoverableUntil,
            appliedToRecordings: results.map(\.recordingId)))
        await emitRewriteEvents(results, reason: .speakerDelisted)
        return (name, SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId)))
    }

    public func undelist(
        speakerId: String, outputFolderRoots: [URL]
    ) async throws -> SpeakerEditResult {
        let name = try await library.undelist(speakerId: speakerId, suppressEvent: true)
        let appearances = try await library.appearances(of: speakerId)
        let results = try await rewriter.rewrite(
            oldName: "Unrecognized", newName: name, appearances: appearances,
            outputFolderRoots: outputFolderRoots, reason: .speakerUndelisted)
        _ = try? await events?.append(SpeakerUndelistedEvent(
            speakerId: speakerId, appliedToRecordings: results.map(\.recordingId)))
        await emitRewriteEvents(results, reason: .speakerUndelisted)
        return SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SpeakerEditService` Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift \
        Tests/MenuBarTests/SpeakerEditServiceTests.swift
git commit -m "feat(engine): SpeakerEditService delist + undelist (PT-P6-R9)"
```

### Task 5: Service `unmerge`, `unsplit`, `delete`, `undelete`

**Files:**

- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift`

- Test: `Tests/MenuBarTests/SpeakerEditServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `SpeakerEditServiceTests`:

```swift
    @Test("unmerge restores the merged-away speaker's final.md labels")
    func unmergeRestoresLabels() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_other", recordingFolderName: "other")
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)
        let service = SpeakerEditService(library: library, events: nil)
        _ = try await service.merge(
            primaryId: steve.id, otherId: unknown.id, outputFolderRoots: [root])
        _ = try await service.unmerge(
            primaryId: steve.id, otherId: unknown.id, outputFolderRoots: [root])
        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("] Steve:**"))
    }

    @Test("unsplit folds the split-off speaker's labels back")
    func unsplitFoldsBack() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "review", recordingId: "rec_review")
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let unknown = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_review", recordingFolderName: folder.lastPathComponent)
        let service = SpeakerEditService(library: library, events: nil)
        let (bob, _) = try await service.split(
            originalId: unknown.id, movingRecordingIds: ["rec_review"],
            newName: "Bob", outputFolderRoots: [root])
        _ = try await service.unsplit(
            originalId: unknown.id, newId: bob.id, outputFolderRoots: [root])
        let finalText = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("] Bob:**"))
    }

    @Test("delete then undelete round-trips the library row")
    func deleteUndeleteRoundTrips() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.3), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let service = SpeakerEditService(library: library, events: nil)
        try await service.delete(speakerId: steve.id)
        #expect(try await library.liveSpeakers().isEmpty)
        try await service.undelete(speakerId: steve.id)
        #expect(try await library.liveSpeakers().count == 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpeakerEditService` Expected: FAIL to compile — no member `unmerge`.

- [ ] **Step 3: Write the implementation**

Add to `SpeakerEditService`. Note `unmerge`/`unsplit` do **not** suppress the library event — the
library emits the `speaker_unmerged`/`speaker_unsplit` cause itself; the service appends the
`final_md_rewritten` effects after. `delete`/`undelete` perform no rewrite and let the library emit.

```swift
    public func unmerge(
        primaryId: String, otherId: String, outputFolderRoots: [URL]
    ) async throws -> SpeakerEditResult {
        guard let primaryName = try await library.speaker(id: primaryId)?.name,
              let otherName = try await library.speaker(id: otherId)?.name else {
            throw SpeakerEditError.speakerNotFound
        }
        try await library.unmerge(primaryId: primaryId, otherId: otherId)
        let appearances = try await library.appearances(of: otherId)
        let results = try await rewriter.rewrite(
            oldName: primaryName, newName: otherName, appearances: appearances,
            outputFolderRoots: outputFolderRoots, reason: .speakerUnmerged)
        await emitRewriteEvents(results, reason: .speakerUnmerged)
        return SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId))
    }

    public func unsplit(
        originalId: String, newId: String, outputFolderRoots: [URL]
    ) async throws -> SpeakerEditResult {
        guard let originalName = try await library.speaker(id: originalId)?.name,
              let newName = try await library.speaker(id: newId)?.name else {
            throw SpeakerEditError.speakerNotFound
        }
        // Capture the moved appearances BEFORE the library mutation moves them back.
        let appearances = try await library.appearances(of: newId)
        try await library.unsplit(originalId: originalId, newId: newId)
        let results = try await rewriter.rewrite(
            oldName: newName, newName: originalName, appearances: appearances,
            outputFolderRoots: outputFolderRoots, reason: .speakerUnsplit)
        await emitRewriteEvents(results, reason: .speakerUnsplit)
        return SpeakerEditResult(rewrittenRecordingIds: results.map(\.recordingId))
    }

    public func delete(speakerId: String) async throws {
        try await library.delete(speakerId: speakerId)
    }

    public func undelete(speakerId: String) async throws {
        try await library.undelete(speakerId: speakerId)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SpeakerEditService` Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift \
        Tests/MenuBarTests/SpeakerEditServiceTests.swift
git commit -m "feat(engine): SpeakerEditService unmerge/unsplit/delete/undelete (PT-P6-R9)"
```

### Task 6: `SpeakerEditorViewModel` delegates to the service (parity)

The view model keeps its UI concerns (`isRewriting`, toast, `reload`, `lastError`) and the cheap
pre-checks that preserve UX, but its mutating bodies now call the service. The existing
`SpeakerEditorViewModel` suite is the parity guard — it must stay green unchanged.

**Files:**

- Modify: `Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift`

- [ ] **Step 1: Replace the private deps and construct the service**

In `SpeakerEditorViewModel`, replace the `rewriter` stored property with a `service`:

```swift
    private let library: SpeakerLibrary
    private let events: EventWriter?
    private let settings: MenuBarSettings
    private let service: SpeakerEditService
```

In `init(...)`, replace `self.rewriter = FinalMarkdownRewriter()` with:

```swift
        self.service = SpeakerEditService(library: library, events: events)
```

- [ ] **Step 2: Delegate each mutating method to the service**

Replace the bodies (keep signatures, the `withRewrite { }` wrapper, the pre-checks, and the toast
calls). `validateName` now delegates to the service's static rule:

```swift
    public func rename(speakerId: String, to newName: String) async {
        guard validateName(newName) else { return }
        guard liveSpeakers.first(where: { $0.id == speakerId })?.name != newName else { return }
        await withRewrite {
            _ = try await self.service.rename(
                speakerId: speakerId, to: newName, outputFolderRoots: self.outputRoots())
        }
    }

    public func merge(primaryId: String, otherId: String) async {
        await withRewrite {
            _ = try await self.service.merge(
                primaryId: primaryId, otherId: otherId, outputFolderRoots: self.outputRoots())
        }
    }

    public func split(
        originalId: String, movingRecordingIds: [String], newName: String
    ) async {
        guard validateName(newName) else { return }
        await withRewrite {
            _ = try await self.service.split(
                originalId: originalId, movingRecordingIds: movingRecordingIds,
                newName: newName, outputFolderRoots: self.outputRoots())
        }
    }

    public func delete(speakerId: String) async {
        let name = liveSpeakers.first { $0.id == speakerId }?.name ?? "speaker"
        await withRewrite { try await self.service.delete(speakerId: speakerId) }
        if lastError == nil {
            showToast(UndoToast(message: "Deleted \(name)") { [weak self] in
                await self?.undelete(speakerId: speakerId)
            })
        }
    }

    public func undelete(speakerId: String) async {
        await withRewrite { try await self.service.undelete(speakerId: speakerId) }
    }

    public func delist(speakerId: String) async {
        guard let target = liveSpeakers.first(where: { $0.id == speakerId }) else {
            lastError = "Speaker not found."; return
        }
        guard target.name != "You" else {
            lastError = "The microphone speaker cannot be delisted."; return
        }
        let name = target.name
        await withRewrite {
            _ = try await self.service.delist(
                speakerId: speakerId, outputFolderRoots: self.outputRoots())
        }
        if lastError == nil {
            showToast(UndoToast(message: "Stopped recognizing \(name)") { [weak self] in
                await self?.undelist(speakerId: speakerId)
            })
        }
    }

    public func undelist(speakerId: String) async {
        await withRewrite {
            _ = try await self.service.undelist(
                speakerId: speakerId, outputFolderRoots: self.outputRoots())
        }
    }

    public func unmerge(primaryId: String, otherId: String) async {
        await withRewrite {
            _ = try await self.service.unmerge(
                primaryId: primaryId, otherId: otherId, outputFolderRoots: self.outputRoots())
        }
    }

    public func unsplit(originalId: String, newId: String) async {
        await withRewrite {
            _ = try await self.service.unsplit(
                originalId: originalId, newId: newId, outputFolderRoots: self.outputRoots())
        }
    }
```

- [ ] **Step 3: Point `validateName` at the shared rule and delete the now-dead helper**

Replace the body of `validateName(_:)` so the rule lives in one place, and delete the private
`emitRewriteEvents(_:reason:)` method (its logic now lives in the service):

```swift
    func validateName(_ name: String) -> Bool {
        do { try SpeakerEditService.validateName(name); return true }
        catch { lastError = "\(error)"; return false }
    }
```

Delete the `emitRewriteEvents(_:reason:)` method and the `EditorError` enum if no longer referenced
(the service owns `speakerNotFound` now). Leave `outputRoots()`, `withRewrite`, the toast lifecycle,
`reload`, `appearances(ofSpeaker:)`, and `load(...)` unchanged.

- [ ] **Step 4: Build, then run BOTH suites to verify parity**

Run (bare, `dangerouslyDisableSandbox: true`): `swift build` Expected: builds clean.

Run: `swift test --filter SpeakerEditorViewModel` Expected: PASS — all existing view-model tests
green (parity proven).

Run: `swift test --filter SpeakerEditService` Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift
git commit -m "refactor(menubar): SpeakerEditorViewModel delegates to SpeakerEditService (PT-P6-R9)"
```

### Epic 1 close

- [ ] Run `swift test --filter SpeakerEditService` and `swift test --filter SpeakerEditorViewModel`
  — both green.
- [ ] Doc-owner: write
  `.erratum/projects/P6-agent-native-mcp-surface/epics/E1-speaker-edit-service/spec.md` and
  `completion.md` (code links in the service use `// PT-P6-R9`).

______________________________________________________________________

## Epic 2 — MCP server foundation

**Delivers:** a running, authenticated loopback MCP server that completes `initialize` and answers
`tools/list` (with zero tools yet), gated by a bearer token, with a Settings toggle/port/token UI, a
`/healthz` endpoint, in-process supervision, and a manual restart. Satisfies PT-P6-R1, R2, R10, R11.
Detailed TDD steps authored when this epic opens.

### File structure

- Modify: `Package.swift` — add the dependency
  `.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "<pinned>")` (pin
  exactly — pre-1.0; verify the latest tag at epic start) and a new library target plus its test
  target:
  - `PulsarTraceMCP` (depends on `PulsarTraceEngine`, `PulsarTraceMenuBar`, and the SDK's `MCP`
    product) — tool registry, JSON-RPC handlers, the `NWListener` loopback HTTP front end, auth,
    `/healthz`, supervision.
  - `pulsartrace-mac` gains a dependency on `PulsarTraceMCP`.
  - `MCPTests` test target (depends on `PulsarTraceMCP`).
- Create: `Sources/PulsarTraceMCP/MCPServer.swift` — owns the SDK `Server`, capability declaration,
  start/stop, and supervision (rebuild a failed `NWListener` with bounded backoff; stop-with-error
  on repeated bind failure — no port rotation, PT-P6-D3).
- Create: `Sources/PulsarTraceMCP/LoopbackHTTPListener.swift` — `NWListener` bound to `127.0.0.1` on
  the configured port; parses HTTP/1.1; routes `POST /mcp` into
  `StatelessHTTPServerTransport.handleRequest`, `GET /healthz` to a status JSON, `GET /mcp` to 405.
- Create: `Sources/PulsarTraceMCP/MCPAuth.swift` — bearer-token generation, the owner-only (0600)
  token file under app-support, and per-request `Authorization` validation.
- Create: `Sources/PulsarTraceMCP/MCPServerStatus.swift` — the status enum (`stopped` /
  `running(port:)` / `portInUse(port:)` / `failed(reason:)`) the health probe and Settings render.
- Modify: `Sources/PulsarTraceMenuBar/MenuBarSettings.swift` — persisted `mcpServerEnabled: Bool`
  (default `false`) and `mcpServerPort: Int` (default `8276`).
- Modify: `Sources/pulsartrace-mac/AppEnvironment.swift` (and the app entry) — start the server when
  enabled at launch; stop on quit; react to the settings toggle.
- Modify: the SwiftUI Settings scene — the toggle, the port field with live status, a copyable
  connection snippet (URL + `Authorization: Bearer …`), and a manual Restart button.

### Tasks (titles — detail at epic open)

1. Add the SDK dependency and the `PulsarTraceMCP` + `MCPTests` targets; assert the package resolves
   and an empty target builds.
2. `MCPAuth`: token generation + owner-only persistence + `validate(authorizationHeader:)`. Tests:
   missing/blank/wrong token rejected; the right token accepted; file mode is `0600`.
3. `LoopbackHTTPListener`: bind `127.0.0.1:port`; minimal HTTP/1.1 request parse + single-response
   write; route table (`POST /mcp`, `GET /healthz`, `GET /mcp` → 405). Tests over a real loopback
   socket: a `POST /mcp` round-trips a body; `GET /mcp` returns 405; a bound-port conflict surfaces
   `portInUse`.
4. `MCPServer`: construct the SDK `Server` (declare `tools` capability), wire the transport, feed
   listener requests into `handleRequest`, enforce auth ahead of the transport. Test: an
   `initialize` + `tools/list` round-trips and returns an empty tool list; an unauthenticated
   request gets 401.
5. `/healthz` + supervision: health returns `MCPServerStatus`; a forced listener failure is rebuilt
   with backoff; repeated bind failure stops-with-error.
6. Settings + lifecycle: `mcpServerEnabled` / `mcpServerPort` persistence; start/stop on toggle;
   start-at-launch-when-enabled; the Settings UI (toggle, port, status, copy-config, Restart).
7. Epic close: green `--filter MCP`; doc-owner writes the E2 Erratum spec/completion.

______________________________________________________________________

## Epic 3 — Read tools

**Delivers:** `list_recordings` (filters: `since`/`until`, `status`, `limit`), `get_recording_meta`,
`list_speakers`, `get_speaker` (+ appearances), `recent_events`. Satisfies PT-P6-R3, R4, R7. No tool
returns transcript/audio bytes — they return metadata and the `final_path`/`live_path` filesystem
paths; `list_recordings` flags the live recording. Detailed TDD steps authored when this epic opens.

### File structure

- Create: `Sources/PulsarTraceMCP/Tools/ToolRegistry.swift` — registers tool name → (schema,
  handler); backs the SDK `ListTools`/`CallTool` handlers.
- Create: `Sources/PulsarTraceMCP/Tools/RecordingReadTools.swift` — `list_recordings`,
  `get_recording_meta`, backed by `RecordingsScanner` + `RecordingViewModel.status` (the
  live-in-progress flag and `liveMarkdownURL`).
- Create: `Sources/PulsarTraceMCP/Tools/SpeakerReadTools.swift` — `list_speakers`, `get_speaker`,
  backed by `SpeakerLibrary.liveSpeakers()` / `appearances(of:)`.
- Create: `Sources/PulsarTraceMCP/Tools/EventsReadTool.swift` — `recent_events`, reading
  `events/*.jsonl` via the engine's event-log reader with optional since/type filters.
- Create: `Sources/PulsarTraceMCP/Tools/ToolJSON.swift` — the Codable DTOs the tools return.

### Tasks (titles — detail at epic open)

1. `ToolRegistry` + `ListTools`/`CallTool` wiring (assert a registered echo tool round-trips).
2. `list_recordings` (DTO, filters, `is_live`, paths) — tests over temp recording folders +
   `RecordingsScanner`.
3. `get_recording_meta` — by id; not-found error shape.
4. `list_speakers` / `get_speaker` (+ appearances) — over a seeded library.
5. `recent_events` — since/type filters over a seeded events dir.
6. Epic close: green `--filter MCP`; E3 Erratum spec/completion.

______________________________________________________________________

## Epic 4 — Speaker write tools

**Delivers:** `rename_speaker`, `merge_speakers`, `split_speaker`, `unmerge_speakers`,
`unsplit_speaker`, `delete_speaker`, `undelete_speaker`, `delist_speaker`, `undelist_speaker` — each
a thin wrapper over `SpeakerEditService` (E1), so an agent edit drives the retroactive rewrite and
paired events exactly as the UI. A speaker-library mutation requested while a recording is in
progress is refused (PT-R32). Satisfies PT-P6-R5. Detailed TDD steps authored when this epic opens.

### File structure

- Create: `Sources/PulsarTraceMCP/Tools/SpeakerWriteTools.swift` — the nine tools; each resolves the
  current output-folder roots from `MenuBarSettings`, checks the during-capture gate, calls the
  service, and returns the affected recording ids.
- Create: `Sources/PulsarTraceMCP/RecordingGate.swift` — a tiny seam reading
  `RecordingViewModel.status`; throws a `recording_in_progress` tool error for mutations during
  capture.

### Tasks (titles — detail at epic open)

1. `RecordingGate` + the busy-error tool shape (test: gate open vs. `.recording` → refuse).
2. `rename_speaker` / `merge_speakers` / `split_speaker` — assert the same `final.md` + event
   effects as the E1 service tests, via a `CallTool` round-trip.
3. The inverses `unmerge_speakers` / `unsplit_speaker`.
4. `delete_speaker` / `undelete_speaker` / `delist_speaker` / `undelist_speaker`.
5. During-capture refusal across all nine (parametrised).
6. Epic close: green `--filter MCP`; E4 Erratum spec/completion.

______________________________________________________________________

## Epic 5 — Recording write tools + discovery

**Delivers:** `rename_recording` (writes the title sidecar via `RecordingTitleStore.write`),
`request_refine` (enqueues via `RefinementJobQueue.enqueueManualRefine`, returns immediately), the
`manual` tool, and rich self-documenting descriptions/schemas for every tool. Satisfies PT-P6-R6,
R8. Detailed TDD steps authored when this epic opens.

### File structure

- Create: `Sources/PulsarTraceMCP/Tools/RecordingWriteTools.swift` — `rename_recording`,
  `request_refine`.
- Create: `Sources/PulsarTraceMCP/Tools/ManualTool.swift` — returns the operations manual.
- Create: `Sources/PulsarTraceMCP/Resources/manual.md` — the standalone operations manual content
  (data model, per-operation semantics + reversibility, read-via-filesystem, safe-autonomy notes).
  Describes PulsarTrace on its own terms; references no external program, service, or workflow.
- Modify: every `Tools/*.swift` — fill in each tool's `description` and input `schema` so
  `tools/list` is self-documenting (PT-P6-R8).

### Tasks (titles — detail at epic open)

1. `rename_recording` — writes `title.txt`; reflected in the next `list_recordings`.
2. `request_refine` — enqueues and returns immediately (assert a job is queued, no block).
3. `manual.md` content + `manual` tool returning it; a test asserts it names no external system.
4. Description/schema pass over all 17 tools; assert `tools/list` carries a description + schema for
   each.
5. Epic close: green `--filter MCP`; E5 Erratum spec/completion.

______________________________________________________________________

## Epic 6 — CLI adoption + ops-manual finalization

**Delivers:** the `pulsartrace speakers` subcommands (`rename`/`merge`/…) call `SpeakerEditService`
so a CLI edit drives the retroactive rewrite it previously skipped (PT-P6-D7), completing PT-P6-R9.
Resolves the CLI's output-root question. Detailed TDD steps authored when this epic opens.

### File structure

- Modify: `Sources/pulsartrace/SpeakersCommand.swift` — route mutations through
  `SpeakerEditService`.
- Create: `Sources/PulsarTraceEngine/SpeakerLibrary/OutputFolderRoots.swift` — resolves roots for a
  non-menubar caller: an explicit `--output-folder` (repeatable) if given, else the default
  `~/Documents/PulsarTrace`. (Documented limitation: without `--output-folder`, only the default
  folder is scanned; a custom output folder must be passed explicitly. The CLI previously rewrote
  nothing, so this is strictly an improvement.)

### Tasks (titles — detail at epic open)

1. `OutputFolderRoots.resolved(explicit:)` (unit test: explicit roots vs. default).
2. `speakers rename` routes through the service + `--output-folder` flag; integration test over a
   temp folder asserts the `final.md` rewrite.
3. `speakers merge` / `delete` likewise.
4. Finalize `manual.md` wording; verify it stays calendar/external-system-free.
5. Epic close: green `--filter Speaker` and a CLI smoke; E6 Erratum spec/completion. Project P6 is
   then ready for Erratum close-out (mint PT-R115+, reconcile the matrix, re-point `// PT-P6-R*`
   code links to the minted product IDs).

______________________________________________________________________

## Self-Review

**1. Spec coverage.** PT-P6-R1 (E2 task 6), R2 (E2 tasks 2,4), R3 (E3 tasks 2–3), R4 (E3 task 4), R5
(E4), R6 (E5 tasks 1–2), R7 (E3 task 5), R8 (E5 tasks 3–4), R9 (E1 + E6), R10 (E4 gate + the
no-content/no-settings/no-capture tool surface — verified by the absence of such tools and the
during-capture gate), R11 (E2 task 5). All eleven requirements map to tasks.

**2. Placeholders.** Epic 1 is fully specified with complete code in every step. Epics 2–6 carry
explicit file structure and ordered task lists; their step-level code is deferred by design (each is
a separate subsystem plan whose code depends on the prior epic's landed API — the writing-plans
scope-check sanctions per-subsystem plans). No "TBD"/"add error handling"/"similar to" placeholders
inside Epic 1.

**3. Type consistency.** `SpeakerEditService`, `SpeakerEditResult`, `SpeakerEditError`,
`SpeakerEditService.validateName`, and the per-op signatures used in the Epic-1 view-model refactor
match their definitions in Tasks 1–5. The view model's delegating bodies call exactly the service
methods defined (`rename`/`merge`/`split`/`delist`/`undelist`/`unmerge`/`unsplit`/`delete`/
`undelete`), each taking `outputFolderRoots:` where it rewrites.

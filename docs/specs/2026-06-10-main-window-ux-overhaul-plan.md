# Main Window UX Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved spec `docs/specs/2026-06-10-main-window-ux-overhaul-design.md` — master–detail Recordings pane with in-window live transcript, renameable recordings via a `title.txt` sidecar, the provisional marker changed to `?` at the engine source, one NSTextView transcript renderer with find-in-transcript, a Record button on every pane, the Refinements pane folded into Recordings, and an app-wide consistency sweep.

**Architecture:** All new logic lives in `PulsarTraceMenuBar` as `@Observable` models (`RecordingsPaneModel`, `TranscriptDetailModel`) tested in `Tests/MenuBarTests`; views in `pulsartrace-mac` stay pure bindings. One deliberate engine change (`LiveRunner.resolveSystemLabel` suffix). The Recordings pane's resizable split is an `NSSplitView`-backed representable (`autosaveName` gives divider persistence for free).

**Tech Stack:** Swift 6 / SwiftUI (macOS 14 floor), Swift Testing (`@Test`/`#expect`), AppKit interop via `NSViewRepresentable`.

---

## Build & test commands (read first — CLAUDE.md rules)

- `swift build` and `swift test --filter <X>` must run **bare** (no `|`, `;`, `>`, `&&`) with `dangerouslyDisableSandbox: true`.
- All other commands (git, ls, grep) run plain, in-sandbox, WITHOUT that flag.
- NEVER run the broad `--filter PipelineTests` (known cross-suite flaky). Narrow filters used by this plan: `UnitTests`, `MenuBar`, `Refinement`, `Streaming`, `Transcription`, `LiveRunner`, `FinalMarkdownRewriter`, `Speaker`, `Lifecycle`.
- No failing tests, ever: fix, gate explicitly with a named condition, or escalate. "My new tests pass" is not enough — every filter you touched must be green.

## File structure (locked decomposition)

| File | Status | Responsibility |
|---|---|---|
| `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift` | modify | `" (provisional)"` → `"?"` in `resolveSystemLabel` |
| `Sources/PulsarTraceEngine/Refinement/RecordingFolder.swift` | modify | add `FileName.title = "title.txt"` |
| `Sources/PulsarTraceMenuBar/RecordingTitleStore.swift` | create | read/normalize/write the `title.txt` sidecar |
| `Sources/PulsarTraceMenuBar/RecordingEntry.swift` | modify | `customTitle` decode; `displayTitle` prefers it; `defaultTitle` |
| `Sources/PulsarTraceMenuBar/AppNavigation.swift` | modify | add `selectedRecordingID`; later drop `.refinements` |
| `Sources/PulsarTraceMenuBar/RecordingsPaneModel.swift` | create | rows, day groups, filter, badges, live-row, auto-select, rename, trash |
| `Sources/PulsarTraceMenuBar/TranscriptDetailModel.swift` | create | §4.2 source/banner table, async load, pending-refined gate |
| `Sources/PulsarTraceMenuBar/TranscriptPlainText.swift` | create | rendered-plain-text for Copy (§5) |
| `Sources/PulsarTraceMenuBar/AppEnvironment.swift` | modify | own + wire the two new models |
| `Sources/pulsartrace-mac/TranscriptView.swift` | rewrite | single NSTextView renderer, find bar, scroll modes, append fast path |
| `Sources/pulsartrace-mac/PersistentHSplit.swift` | create | NSSplitView representable (divider persistence, min widths) |
| `Sources/pulsartrace-mac/RecordingsSplitView.swift` | create | Recordings pane: list + detail + toolbar + banners |
| `Sources/pulsartrace-mac/TranscriptDetailView.swift` | create | detail header + banner + renderer |
| `Sources/pulsartrace-mac/RecordToolbarButton.swift` | create | shared Record/Stop toolbar button (§6) |
| `Sources/pulsartrace-mac/RecordingsListView.swift` | delete | replaced by RecordingsSplitView (sheet + RefineStatusIcon absorbed) |
| `Sources/pulsartrace-mac/RefinementsListView.swift` | delete | folded per §7 (after `friendly(_:)` is lifted into the model) |
| `Sources/pulsartrace-mac/MainWindowView.swift` | modify | drop brand heading + `.refinements` case; minWidth 800 |
| `Sources/pulsartrace-mac/PulsarTraceMacApp.swift` | modify | defaultSize 900×560; inject new models + liveWatcher into main window |
| `Sources/pulsartrace-mac/LiveTranscriptView.swift` | modify | header → toolbar |
| `Sources/pulsartrace-mac/SpeakerEditorView.swift` | modify | multi-select, toolbar Merge/Split, safeAreaInset banners, sheet min sizes |
| `Sources/pulsartrace-mac/MenuBarMenuView.swift` | modify | hover colors |
| `Sources/pulsartrace-mac/SettingsView.swift` | modify | `LabeledContent` output row |
| `Tests/MenuBarTests/RecordingTitleStoreTests.swift` | create | sidecar round-trip |
| `Tests/MenuBarTests/RecordingsPaneModelTests.swift` | create | §11 list |
| `Tests/MenuBarTests/TranscriptDetailModelTests.swift` | create | §11 list |
| `Tests/MenuBarTests/TranscriptPlainTextTests.swift` | create | rendered text |
| docs: `project-docs/PRD.md`, `docs/file-format.md`, `README.md`, `CHANGELOG.md` | modify | `?` suffix; changelog entry |
| `docs/qa/2026-06-10-main-window-ux-overhaul-qa.md` | create | click-through manual QA guide |

Key existing shapes (verified 2026-06-10, for reference while implementing):

- `RecordingStatus`: `.idle / .launching / .recording(id:startedAt:) / .crashed(id:partialFolderURL:) / .error(message:)`; `canStartRecording` is true only for `.idle`.
- `RefinementJobState`: `.queued / .running(stage:stepsCompleted:stepsTotal:regionIndex:regionsTotal:) / .paused(reason:lastStage:) / .completed(durationSeconds:speakerCount:) / .failed(errorClass:retryAvailable:) / .cancelled`; `progressFraction: Double?`; `Stage.displayName`.
- `RefinementJobQueueViewModel`: `running: RefinementJob?`, `queued/recent: [RefinementJob]`, `lastEnqueueError`, `onJobsTerminated: (@MainActor @Sendable ([RefinementJob]) -> Void)?`, `enqueueManual(folderURL:recordingId:refineModelName:)`, `cancel(recordingId:)`.
- `RecordingsScanner`: `recordings: [RecordingEntry]` newest-first, `refresh() async`, `isScanning`.
- `LiveTranscriptWatcher`: `lines: [String]`, `isActive`, `start(liveMarkdownURL:)`, `stop()`.
- `RecordPlan.recordingId` and `RecordingEntry.decodeUnrefined`'s id are **the same derivation** — both call `RecordingFolder.recordingId(forName: <folder basename>)` (`RecordPlan.swift:52`, `RecordingEntry.swift:213`). Spec §12's open question is resolved: no mapping; pin with a test (Task 3).
- Test conventions: Swift Testing, `@MainActor`, `MenuBarFixtures.tempDir()` + `makeRecordingFolder(root:name:recordingId:...)` + `makeUnrefinedRecordingFolder(root:name:)`, throwaway `UserDefaults(suiteName:)`.

---

### Task 1: Provisional marker becomes `?` at the engine source (§5)

**Files:**
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift:639-682`
- Modify (comments only): `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift:473-477`, `Sources/PulsarTraceEngine/Streaming/LiveSink.swift:37`, `Sources/PulsarTraceEngine/Streaming/LiveMarkdownWriter.swift:107-111`
- Test: `Tests/MenuBarTests/TranscriptLineTests.swift:16-20`, `Tests/UnitTests/LiveMarkdownWriterTests.swift` (lines 70, 79, 96, 121, 123, 206), `Tests/PipelineTests/StreamingPipelineTests.swift` (lines 51, 82-83, 215, 241), `Tests/PipelineTests/LiveRunnerLibraryLookupTests.swift` (lines 5-7, 106-107, 147), `Tests/PipelineTests/LiveRunnerResilienceTests.swift:338`, `Tests/PipelineTests/FinalMarkdownRewriterTests.swift:265-271`
- Docs: `project-docs/PRD.md:358` + `project-docs/PRD.md:1124-1134`, `docs/file-format.md:92-93` + `docs/file-format.md:134-150`, `README.md:182-193`

- [ ] **Step 1: Update the tests first (they pin the new format).** In `Tests/MenuBarTests/TranscriptLineTests.swift` replace the provisional case:

```swift
    @Test("a provisional live label keeps its ? suffix in the speaker field")
    func provisionalSpeaker() {
        let kind = TranscriptLine.parse("**[00:00:05] Them?:** hi")
        #expect(kind == .utterance(timestamp: "00:00:05", speaker: "Them?", text: "hi"))
    }
```

Then sweep the engine tests: every literal `"Them (provisional)"` → `"Them?"`, `"Dana Lee (provisional)"` → `"Dana Lee?"`, `"Unknown #1 (provisional)"` → `"Unknown #1?"`, the substring check `text.contains("(provisional):")` in `LiveRunnerResilienceTests.swift:338` → `text.contains("?:** ")` (note: match `?:** ` — bare `?:` would also match nothing else here, but the bold-close makes it unambiguous), `text.contains("Them (provisional):** lets review the auth flow")` → `text.contains("Them?:** lets review the auth flow")`, and `#expect(text.contains("Them (provisional):"))` → `#expect(text.contains("Them?:"))`. Update test display names/comments that say "(provisional)". Find every site with: `grep -rn "provisional" Tests/`

- [ ] **Step 2: Run the parser test to verify it fails**

Run (bare, dangerouslyDisableSandbox): `swift test --filter TranscriptLineTests`
Expected: PASS actually — the parser is format-agnostic; the updated test passes without code changes. The engine tests are the failing ones: `swift test --filter LiveMarkdownWriterTests` → FAIL (writer tests feed the label as input — they pass too; the genuinely failing ones are `LiveRunner`-driven). Run `swift test --filter LiveRunner` → FAIL with label mismatches (`Dana Lee (provisional)` produced, `Dana Lee?` expected).

- [ ] **Step 3: Change the suffix at its single source.** In `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift`, `resolveSystemLabel` — two return statements:

```swift
                    return "\(match.speaker.name)?"
```

```swift
        return "\(key)?"
```

Update the function's doc comment: `/// the live diarizer's stitched key, optionally upgraded to a library name` / `/// (read-only lookup, R18). Always carries the `?` provisional suffix (R16).` Also update the marker-mentioning comments: `LiveDiarizer.swift:474` (`(R16 — the `?` suffix is added by the line formatter)`), `LiveSink.swift:37` (no code change; reword "provisional label" comment only if it names the old literal), `LiveMarkdownWriter.swift:110-111` (`speakerLabel already carries any provisional `?` suffix the caller wants (mic is `You`, system speakers are `Them?` etc.)`).

- [ ] **Step 4: Run engine + parser suites**

Run each bare with dangerouslyDisableSandbox, expect PASS on all:
`swift test --filter LiveRunner` · `swift test --filter Streaming` · `swift test --filter UnitTests` · `swift test --filter MenuBar` · `swift test --filter FinalMarkdownRewriter` · `swift test --filter Transcription`

- [ ] **Step 5: Update the docs.**
  - `project-docs/PRD.md:358` (R16 row): example `*Them (provisional)*` → `*Them?*`.
  - `project-docs/PRD.md:1129`: `**[14:30:12] Sarah (provisional):** …` → `**[14:30:12] Sarah?:** …`; line 1134 prose: "and `(provisional)` annotations are removed" → "and the provisional `?` speaker suffixes are removed".
  - `docs/file-format.md:92-93`: the bullet becomes "- `?` speaker suffix — present in `live.md` only, on speakers whose identity is not yet confirmed (e.g. `Them?`). Removed in `final.md`."
  - `docs/file-format.md:134-150`: retitle stays; rewrite the four bullets to `**[HH:MM:SS] Them?:** …`, `**[HH:MM:SS] Them #2?:** …`, `**[HH:MM:SS] Steve?:** …`, and `You` (unchanged, never marked); prose "always carry a `(provisional)` suffix" → "always carry a `?` suffix (`Them?`)".
  - `README.md:190`: `**[00:00:12] Them (provisional):** …` → `**[00:00:12] Them?:** …`; line 193: "`(provisional)` annotations and provisional labels are resolved" → "provisional `?` labels are resolved".
  - Verify zero leftovers: `grep -rn "(provisional)" Sources Tests docs project-docs README.md` → only historical spec files under `docs/specs/` may remain (do not edit past specs).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(engine)!: live provisional speaker suffix becomes ? — format, tests, docs (spec §5)"
```

---

### Task 2: `title.txt` sidecar — store + `RecordingEntry.customTitle` (§4.1)

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/RecordingFolder.swift:32-40`
- Create: `Sources/PulsarTraceMenuBar/RecordingTitleStore.swift`
- Modify: `Sources/PulsarTraceMenuBar/RecordingEntry.swift`
- Test: `Tests/MenuBarTests/RecordingTitleStoreTests.swift` (new), `Tests/MenuBarTests/RecordingEntryDecodeTests.swift` (extend)

- [ ] **Step 1: Add the filename constant.** In `RecordingFolder.FileName` add:

```swift
        /// UI-owned custom-title sidecar — written by the mac app's rename
        /// flow, never read by the engine (spec §4.1).
        public static let title = "title.txt"
```

- [ ] **Step 2: Write the failing store tests** (`Tests/MenuBarTests/RecordingTitleStoreTests.swift`):

```swift
import Foundation
import Testing
@testable import PulsarTraceMenuBar

@Suite("RecordingTitleStore")
struct RecordingTitleStoreTests {

    @Test("round-trips a title, trimming whitespace and flattening newlines")
    func roundTrip() throws {
        let folder = MenuBarFixtures.tempDir()
        try RecordingTitleStore.write("  Sprint platform\nsync  ", folderURL: folder)
        #expect(RecordingTitleStore.read(folderURL: folder) == "Sprint platform sync")
    }

    @Test("absent sidecar reads nil")
    func absent() {
        #expect(RecordingTitleStore.read(folderURL: MenuBarFixtures.tempDir()) == nil)
    }

    @Test("writing a blank title removes the sidecar (restores the default title)")
    func clear() throws {
        let folder = MenuBarFixtures.tempDir()
        try RecordingTitleStore.write("Standup", folderURL: folder)
        try RecordingTitleStore.write("   \n ", folderURL: folder)
        #expect(RecordingTitleStore.read(folderURL: folder) == nil)
        let url = folder.appendingPathComponent("title.txt")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
```

- [ ] **Step 3: Run to verify failure.** `swift test --filter RecordingTitleStore` → FAIL ("cannot find 'RecordingTitleStore'").

- [ ] **Step 4: Implement the store** (`Sources/PulsarTraceMenuBar/RecordingTitleStore.swift`):

```swift
import Foundation
import PulsarTraceEngine

/// Reads/writes the UI-owned `title.txt` sidecar inside a recording folder
/// (spec §4.1). The engine never reads this file and `metadata.json` stays
/// refine-owned, so a re-refine can never clobber a user-assigned title. The
/// folder basename — which the recording id derives from — is never renamed.
public enum RecordingTitleStore {

    /// Single-line normalization: newlines collapse to spaces, surrounding
    /// whitespace trimmed; `nil` when nothing printable remains.
    public static func normalized(_ raw: String) -> String? {
        let flattened = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The custom title stored in `folderURL`, or `nil` (absent or blank).
    public static func read(folderURL: URL) -> String? {
        let url = folderURL.appendingPathComponent(RecordingFolder.FileName.title)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return normalized(raw)
    }

    /// Persist `rawTitle` atomically; a title that normalizes to nothing
    /// removes the sidecar so the date-based default title returns.
    public static func write(_ rawTitle: String, folderURL: URL) throws {
        let url = folderURL.appendingPathComponent(RecordingFolder.FileName.title)
        guard let title = normalized(rawTitle) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try Data((title + "\n").utf8).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Run the store tests.** `swift test --filter RecordingTitleStore` → PASS (3 tests).

- [ ] **Step 6: Extend `RecordingEntry`.** Add the stored property + init parameter (after `isRefined`), keep `Equatable` synthesis:

```swift
    /// User-assigned title from the `title.txt` sidecar (spec §4.1), `nil`
    /// when none is set. UI-owned; decoded at scan time like everything else.
    public let customTitle: String?
```

```swift
    public init(
        id: String,
        recordingStart: Date,
        folderURL: URL,
        durationSeconds: Double,
        speakers: [RecordingSpeaker],
        isRefined: Bool,
        customTitle: String? = nil
    ) {
```

(assign `self.customTitle = customTitle`). Change `displayTitle` and add `defaultTitle`:

```swift
    /// Human title — the custom title when one is set, else the date-based
    /// default. The one source for the list, the detail header, and
    /// notifications.
    public var displayTitle: String {
        customTitle ?? defaultTitle
    }

    /// The date-based default title ("Today at 2:30 PM"), regardless of any
    /// custom title — the detail header shows it as a caption under a custom
    /// title.
    public var defaultTitle: String {
        Self.displayTitle(for: recordingStart, relativeTo: Date())
    }
```

In `decode(folderURL:)` add `customTitle: RecordingTitleStore.read(folderURL: folderURL)` to the `RecordingEntry(...)` construction; same in `decodeUnrefined(folderURL:)`.

- [ ] **Step 7: Add decode tests** to `Tests/MenuBarTests/RecordingEntryDecodeTests.swift` (match the file's existing style):

```swift
    @Test("title.txt sidecar decodes into customTitle and displayTitle prefers it")
    func customTitleDecodes() throws {
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-090000", recordingId: "rec_a")
        try RecordingTitleStore.write("Quarterly sync", folderURL: folder)
        let entry = try #require(RecordingEntry.decode(folderURL: folder))
        #expect(entry.customTitle == "Quarterly sync")
        #expect(entry.displayTitle == "Quarterly sync")
        #expect(entry.defaultTitle != "Quarterly sync")
    }

    @Test("no sidecar → customTitle nil, displayTitle falls back to the date default")
    func noSidecar() throws {
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-090000", recordingId: "rec_a")
        let entry = try #require(RecordingEntry.decode(folderURL: folder))
        #expect(entry.customTitle == nil)
        #expect(entry.displayTitle == entry.defaultTitle)
    }
```

- [ ] **Step 8: Run.** `swift test --filter MenuBar` → PASS. `swift build` → succeeds.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(menubar): title.txt sidecar — RecordingTitleStore + RecordingEntry.customTitle (spec §4.1)"
```

---

### Task 3: `AppNavigation.selectedRecordingID` + `RecordingsPaneModel` core (sections, filter, live row, auto-select)

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/AppNavigation.swift`
- Create: `Sources/PulsarTraceMenuBar/RecordingsPaneModel.swift`
- Test: `Tests/MenuBarTests/RecordingsPaneModelTests.swift` (new)

- [ ] **Step 1: Add the selection to `AppNavigation`** (keep `.refinements` for now — deleted in Task 9):

```swift
    /// The recording selected in the Recordings pane's master list (§4.1).
    /// Process-lifetime, like `section`, so the selection survives the window
    /// being closed and re-opened.
    public var selectedRecordingID: String?
```

- [ ] **Step 2: Write the failing core tests** (`Tests/MenuBarTests/RecordingsPaneModelTests.swift`). Build helpers once at the top — a deterministic fixture set the whole suite shares:

```swift
import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@MainActor
@Suite("RecordingsPaneModel")
struct RecordingsPaneModelTests {

    /// Fixed reference clock: 2026-06-10 15:00 local.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 10; c.hour = 15
        return Calendar.current.date(from: c)!
    }()

    static func date(daysAgo: Int, hour: Int = 9) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return Calendar.current.date(
            bySettingHour: hour, minute: 30, second: 0, of: day)!
    }

    static func entry(
        id: String, start: Date, refined: Bool = true,
        speakers: [String] = [], customTitle: String? = nil,
        folder: URL = MenuBarFixtures.tempDir()
    ) -> RecordingEntry {
        RecordingEntry(
            id: id, recordingStart: start, folderURL: folder,
            durationSeconds: refined ? 60 : 0,
            speakers: speakers.map {
                RecordingSpeaker(label: $0, speakerId: nil, isMicrophone: $0 == "You")
            },
            isRefined: refined, customTitle: customTitle)
    }

    /// A model over injected fixtures. The scanner is real but never
    /// refreshed — `recordings` is seeded through an unrefreshed scanner via
    /// the injectable `entries` override below.
    static func makeModel(
        entries: [RecordingEntry],
        status: RecordingStatus = .idle,
        navigation: AppNavigation = AppNavigation()
    ) -> RecordingsPaneModel {
        let model = RecordingsPaneModel(
            scanner: RecordingsScanner(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            queueVM: RefinementJobQueueViewModel(
                queue: RefinementJobQueue(
                    store: RefinementJobStore(directory: MenuBarFixtures.tempDir()),
                    runJob: { _ in })),
            recording: RecordingViewModel(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            navigation: navigation,
            now: { Self.now })
        model.entriesOverride = entries
        model.statusOverride = status
        return model
    }

    // MARK: Day sections (§4.1)

    @Test("day keys: today / yesterday / weekday-within-week / older")
    func dayKeys() {
        #expect(RecordingsPaneModel.dayKey(for: Self.date(daysAgo: 0), now: Self.now) == .today)
        #expect(RecordingsPaneModel.dayKey(for: Self.date(daysAgo: 1), now: Self.now) == .yesterday)
        let d3 = Self.date(daysAgo: 3)
        #expect(RecordingsPaneModel.dayKey(for: d3, now: Self.now)
                == .weekday(Calendar.current.startOfDay(for: d3)))
        let d9 = Self.date(daysAgo: 9)
        #expect(RecordingsPaneModel.dayKey(for: d9, now: Self.now)
                == .older(Calendar.current.startOfDay(for: d9)))
    }

    @Test("groups preserve newest-first order and split on day boundaries")
    func grouping() {
        let model = Self.makeModel(entries: [
            Self.entry(id: "rec_a", start: Self.date(daysAgo: 0, hour: 14)),
            Self.entry(id: "rec_b", start: Self.date(daysAgo: 0, hour: 9)),
            Self.entry(id: "rec_c", start: Self.date(daysAgo: 1)),
            Self.entry(id: "rec_d", start: Self.date(daysAgo: 9)),
        ])
        let groups = model.groups
        #expect(groups.map(\.key) == [
            .today, .yesterday,
            .older(Calendar.current.startOfDay(for: Self.date(daysAgo: 9))),
        ])
        #expect(groups[0].rows.map(\.id) == ["rec_a", "rec_b"])
    }

    // MARK: Filter (§4.1)

    @Test("filter matches custom title, speaker label, and date words; misses show no rows")
    func filtering() {
        let model = Self.makeModel(entries: [
            Self.entry(id: "rec_a", start: Self.date(daysAgo: 0),
                       speakers: ["You", "Dana"], customTitle: "Platform sync"),
            Self.entry(id: "rec_b", start: Self.date(daysAgo: 1)),
        ])
        model.filterText = "platform"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_a"])
        model.filterText = "dana"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_a"])
        model.filterText = "zzz-no-match"
        #expect(model.groups.isEmpty)
    }

    @Test("the live row is exempt from filtering")
    func liveRowFilterExempt() {
        let model = Self.makeModel(
            entries: [Self.entry(id: "rec_old", start: Self.date(daysAgo: 1))],
            status: .recording(id: "rec_live", startedAt: Self.now))
        model.filterText = "zzz-no-match"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_live"])
    }

    // MARK: Live row synthesis (§4.1)

    @Test("recording status synthesizes a live row that dedupes once the scanner has the id")
    func liveRowSynthesisAndDedup() {
        let startedAt = Self.date(daysAgo: 0, hour: 14)
        let model = Self.makeModel(
            entries: [Self.entry(id: "rec_x", start: Self.date(daysAgo: 1))],
            status: .recording(id: "rec_live", startedAt: startedAt))
        var rows = model.rows
        #expect(rows.first?.id == "rec_live")
        #expect(rows.first?.isLive == true)
        #expect(rows.count == 2)

        // Scanner now returns the same id — no duplicate row, still live-badged.
        model.entriesOverride = [
            Self.entry(id: "rec_live", start: startedAt, refined: false),
            Self.entry(id: "rec_x", start: Self.date(daysAgo: 1)),
        ]
        rows = model.rows
        #expect(rows.map(\.id) == ["rec_live", "rec_x"])
        #expect(rows.first?.isLive == true)
    }

    @Test("live row disappears when the status leaves .recording")
    func liveRowRemoval() {
        let model = Self.makeModel(entries: [], status: .recording(id: "rec_live", startedAt: Self.now))
        #expect(model.rows.count == 1)
        model.statusOverride = .idle
        #expect(model.rows.isEmpty)
    }

    // MARK: Auto-select (§4.1)

    @Test("nil or stale selection falls back to the newest row; a valid selection is never moved")
    func autoSelect() {
        let nav = AppNavigation()
        let model = Self.makeModel(entries: [
            Self.entry(id: "rec_new", start: Self.date(daysAgo: 0)),
            Self.entry(id: "rec_old", start: Self.date(daysAgo: 1)),
        ], navigation: nav)
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_new")

        nav.selectedRecordingID = "rec_old"
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_old")

        nav.selectedRecordingID = "rec_gone"
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_new")
    }

    @Test("recording id derivation is shared between RecordPlan and the scanner (spec §12)")
    func idDerivationUnified() {
        // Both sides call RecordingFolder.recordingId(forName:) on the folder
        // basename — pin the equivalence so neither side can drift.
        let name = RecordingViewModel.recordingFolderName(at: Self.now)
        #expect(RecordingFolder.recordingId(forName: name).hasPrefix("rec_"))
        // decodeUnrefined uses the identical call — see RecordingEntry.swift.
        let root = MenuBarFixtures.tempDir()
        let folder = try! MenuBarFixtures.makeUnrefinedRecordingFolder(root: root, name: name)
        let entry = RecordingEntry.decodeUnrefined(folderURL: folder)
        #expect(entry?.id == RecordingFolder.recordingId(forName: name))
    }
}
```

Note: `RecordingViewModel.recordingFolderName(at:)` is `internal static` — the test target uses `@testable import`, fine.

- [ ] **Step 3: Run to verify failure.** `swift test --filter RecordingsPaneModel` → FAIL (type not found).

- [ ] **Step 4: Implement the model core** (`Sources/PulsarTraceMenuBar/RecordingsPaneModel.swift`). Full file:

```swift
import Foundation
import PulsarTraceEngine

/// Day-section key for the recordings list (§4.1). Category-level on purpose
/// so tests assert structure, not locale strings.
public enum DayKey: Equatable, Hashable, Sendable {
    case today
    case yesterday
    /// Within the last week (but not today/yesterday) — "Monday, June 8".
    case weekday(Date)
    /// Older — "June 3, 2026".
    case older(Date)

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .weekday(let day):
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .older(let day):
            return day.formatted(.dateTime.month(.wide).day().year())
        }
    }
}

/// One row in the recordings list — a scanned recording or the synthesized
/// in-progress row (§4.1).
public struct RecordingRow: Identifiable, Equatable {

    /// Exceptional-only status badge (§4.1) — `.none` for a steady refined
    /// recording. Queue state wins over the intrinsic refined flag,
    /// preserving the documented `RefineStatusIcon` precedence
    /// (running > queued > recent > intrinsic).
    public enum Badge: Equatable {
        case recordingNow(startedAt: Date)
        case queued
        case refining(fraction: Double?, stageName: String)
        case failed(friendlyMessage: String, errorClass: String, retryable: Bool)
        case notYetRefined
        case justRefined
        case none
    }

    public let entry: RecordingEntry
    public let isLive: Bool
    public let badge: Badge
    public var id: String { entry.id }

    /// Row title: the custom title when one is set, else time (+ duration
    /// when known — unrefined rows carry `durationSeconds == 0`).
    public var titleText: String { entry.customTitle ?? timeAndDuration }

    /// Caption beneath a custom title; `nil` when the title already IS the
    /// time + duration line.
    public var captionText: String? { entry.customTitle != nil ? timeAndDuration : nil }

    private var timeAndDuration: String {
        let time = entry.recordingStart.formatted(date: .omitted, time: .shortened)
        guard entry.durationSeconds > 0 else { return time }
        return "\(time) · \(RecordingEntry.formatDuration(entry.durationSeconds))"
    }
}

public struct RecordingDayGroup: Identifiable, Equatable {
    public let key: DayKey
    public let rows: [RecordingRow]
    public var id: DayKey { key }
}

/// Composes scanner entries + recording status + queue state + filter text
/// into the day-sectioned row models of the Recordings pane (§4.1): live-row
/// synthesis & dedup, badge derivation (incl. the transient just-refined
/// check), filtering, auto-select rules, rename, move-to-Trash.
@MainActor
@Observable
public final class RecordingsPaneModel {

    /// Inline filter text ("Filter by title, speaker, or date").
    public var filterText: String = ""

    /// Last rename/trash failure — dismissible banner in the list column.
    public private(set) var lastActionError: String?

    private let scanner: RecordingsScanner
    private let queueVM: RefinementJobQueueViewModel
    private let recording: RecordingViewModel
    private let navigation: AppNavigation
    private let now: () -> Date
    private let trashItem: (URL) throws -> Void

    /// Completed job ids whose transient green check was acknowledged —
    /// either by selecting the row, or because the row was already selected
    /// when its refine completed (§4.1). No timer, no clock: badge clearing
    /// also happens naturally when the job ages out of `queueVM.recent`.
    private var acknowledgedJobIDs: Set<String> = []

    /// Test seams — production leaves these nil and reads the real scanner /
    /// recording VM. (`@ObservationIgnored` so flipping them in tests still
    /// recomputes through the public accessors below.)
    var entriesOverride: [RecordingEntry]?
    var statusOverride: RecordingStatus?

    public init(
        scanner: RecordingsScanner,
        queueVM: RefinementJobQueueViewModel,
        recording: RecordingViewModel,
        navigation: AppNavigation,
        now: @escaping () -> Date = { Date() },
        trashItem: ((URL) throws -> Void)? = nil
    ) {
        self.scanner = scanner
        self.queueVM = queueVM
        self.recording = recording
        self.navigation = navigation
        self.now = now
        self.trashItem = trashItem ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private var entries: [RecordingEntry] { entriesOverride ?? scanner.recordings }
    private var status: RecordingStatus { statusOverride ?? recording.status }

    // MARK: - Rows

    /// All rows, newest first: the synthesized live row (while
    /// `status == .recording`) followed by scanned entries. The live row is
    /// built from the VM's status + `liveMarkdownURL` — no dependence on the
    /// scanner noticing the new folder. Once a scan returns an entry with the
    /// same id, that entry backs the row (dedup — ids are stable across
    /// refine).
    public var rows: [RecordingRow] {
        var out: [RecordingRow] = []
        var liveID: String?
        if case .recording(let id, let startedAt) = status {
            liveID = id
            let entry = entries.first { $0.id == id }
                ?? synthesizedEntry(id: id, startedAt: startedAt)
            out.append(RecordingRow(
                entry: entry, isLive: true,
                badge: .recordingNow(startedAt: startedAt)))
        }
        for entry in entries where entry.id != liveID {
            out.append(RecordingRow(entry: entry, isLive: false, badge: badge(for: entry)))
        }
        return out
    }

    private func synthesizedEntry(id: String, startedAt: Date) -> RecordingEntry {
        let folder = recording.liveMarkdownURL?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        return RecordingEntry(
            id: id, recordingStart: startedAt, folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false,
            customTitle: RecordingTitleStore.read(folderURL: folder))
    }

    /// Day-sectioned, filter-applied rows. The live row is exempt from
    /// filtering while recording (§4.1).
    public var groups: [RecordingDayGroup] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let visible = rows.filter { row in
            row.isLive || query.isEmpty || Self.matches(row.entry, query: query)
        }
        let reference = now()
        var grouped: [(DayKey, [RecordingRow])] = []
        for row in visible {
            let key = Self.dayKey(for: row.entry.recordingStart, now: reference)
            if grouped.last?.0 == key {
                grouped[grouped.count - 1].1.append(row)
            } else {
                grouped.append((key, [row]))
            }
        }
        return grouped.map { RecordingDayGroup(key: $0.0, rows: $0.1) }
    }

    static func dayKey(for date: Date, now: Date, calendar: Calendar = .current) -> DayKey {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let day = calendar.startOfDay(for: date)
        if date < now,
           let weekAgo = calendar.date(
               byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           day >= weekAgo {
            return .weekday(day)
        }
        return .older(day)
    }

    /// Case-insensitive match over the custom title, the date-default title,
    /// the folder basename (the raw date string), and speaker labels —
    /// custom titles matching is what makes the filter genuinely useful.
    static func matches(_ entry: RecordingEntry, query: String) -> Bool {
        let q = query.lowercased()
        if entry.displayTitle.lowercased().contains(q) { return true }
        if entry.defaultTitle.lowercased().contains(q) { return true }
        if entry.displayName.lowercased().contains(q) { return true }
        if entry.recordingStart
            .formatted(date: .abbreviated, time: .shortened)
            .lowercased().contains(q) { return true }
        return entry.speakers.contains { $0.label.lowercased().contains(q) }
    }

    // MARK: - Selection (§4.1)

    /// Select a row — selecting *is* opening. Acknowledges the transient
    /// just-refined badge for that recording.
    public func select(_ recordingId: String?) {
        navigation.selectedRecordingID = recordingId
        if let recordingId { acknowledgeCompleted(recordingId: recordingId) }
    }

    /// Auto-select rule: when the selection is nil or its row no longer
    /// exists, select the newest row so the detail is never blank. NEVER
    /// moves an existing valid selection (a hotkey-started recording must
    /// not steal the reading position — §6).
    public func ensureSelection() {
        let ids = rows.map(\.id)
        if let current = navigation.selectedRecordingID, ids.contains(current) { return }
        navigation.selectedRecordingID = ids.first
    }

    // MARK: - Badges (Task 4 wires the queue-driven cases)

    func badge(for entry: RecordingEntry) -> RecordingRow.Badge {
        if let running = queueVM.running, running.recordingId == entry.id {
            return .refining(
                fraction: running.state.progressFraction,
                stageName: Self.stageName(of: running.state))
        }
        if queueVM.queued.contains(where: { $0.recordingId == entry.id }) {
            return .queued
        }
        if let recent = queueVM.recent.first(where: { $0.recordingId == entry.id }) {
            switch recent.state {
            case .completed:
                if !acknowledgedJobIDs.contains(recent.id) { return .justRefined }
            case .failed(let errorClass, let retryable):
                return .failed(
                    friendlyMessage: Self.friendlyFailure(errorClass),
                    errorClass: errorClass, retryable: retryable)
            default:
                break  // cancelled etc. fall through to the intrinsic flag
            }
        }
        return entry.isRefined ? .none : .notYetRefined
    }

    static func stageName(of state: RefinementJobState) -> String {
        if case .running(let stage, _, _, _, _) = state { return stage.displayName }
        return ""
    }

    /// Humanized refine-failure copy. Lifted verbatim from the deleted
    /// RefinementsListView's `JobRow.friendly(_:)` in Task 4.
    public static func friendlyFailure(_ errorClass: String) -> String {
        errorClass  // placeholder until Task 4 Step 2 moves the real mapping
    }

    /// Called (via AppEnvironment) when refinement jobs reach a terminal
    /// state. A completion for the recording the user is *already looking
    /// at* never shows the row badge — the detail's completion banner is the
    /// signal there (§4.1).
    public func noteJobsTerminated(_ jobs: [RefinementJob]) {
        for job in jobs {
            if case .completed = job.state,
               navigation.selectedRecordingID == job.recordingId {
                acknowledgedJobIDs.insert(job.id)
            }
        }
    }

    private func acknowledgeCompleted(recordingId: String) {
        for job in queueVM.recent where job.recordingId == recordingId {
            if case .completed = job.state { acknowledgedJobIDs.insert(job.id) }
        }
    }

    // MARK: - Actions (Task 4)

    /// Rename via the `title.txt` sidecar (§4.1); a blank title clears back
    /// to the date default. The folder basename is never renamed.
    public func rename(recordingId: String, to rawTitle: String) async {
        guard let row = rows.first(where: { $0.id == recordingId }) else { return }
        do {
            try RecordingTitleStore.write(rawTitle, folderURL: row.entry.folderURL)
            lastActionError = nil
        } catch {
            lastActionError = "Could not save the title: \(error.localizedDescription)"
            return
        }
        await scanner.refresh()
    }

    /// Move a recording folder to the Trash (§4.1) — the Trash itself is the
    /// undo. Selection falls back per the auto-select rule.
    public func moveToTrash(recordingId: String) async {
        guard let row = rows.first(where: { $0.id == recordingId }), !row.isLive
        else { return }
        do {
            try trashItem(row.entry.folderURL)
            lastActionError = nil
        } catch {
            lastActionError =
                "Could not move the recording to the Trash: \(error.localizedDescription)"
            return
        }
        if navigation.selectedRecordingID == recordingId {
            navigation.selectedRecordingID = nil
        }
        await scanner.refresh()
        ensureSelection()
    }

    public func clearActionError() { lastActionError = nil }
}
```

Mark the two override vars `@ObservationIgnored` only if observation churn shows up in tests — plain stored vars on an `@Observable` work fine for the test seam.

- [ ] **Step 5: Run.** `swift test --filter RecordingsPaneModel` → PASS (8 tests). `swift test --filter MenuBar` → PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(menubar): RecordingsPaneModel core — day sections, filter, live-row synthesis, auto-select (spec §4.1)"
```

---

### Task 4: `RecordingsPaneModel` badges, just-refined acknowledgment, rename + trash tests

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/RecordingsPaneModel.swift` (replace the `friendlyFailure` placeholder)
- Modify: `Sources/pulsartrace-mac/RefinementsListView.swift` (source of the lifted mapping — file itself deleted in Task 9)
- Test: `Tests/MenuBarTests/RecordingsPaneModelTests.swift` (extend)

- [ ] **Step 1: Write the failing badge/action tests.** Append to `RecordingsPaneModelTests`. A queue-state seam is needed: extend `makeModel` with `running`/`queued`/`recent` parameters by adding test-only overrides to the model (same pattern as `entriesOverride`):

In `RecordingsPaneModel`, add (next to the other seams):

```swift
    var runningOverride: RefinementJob??     // .some(nil) forces "no running job"
    var queuedOverride: [RefinementJob]?
    var recentOverride: [RefinementJob]?
```

and switch `badge(for:)`/`acknowledgeCompleted` to read through private accessors:

```swift
    private var runningJob: RefinementJob? { runningOverride ?? queueVM.running }
    private var queuedJobs: [RefinementJob] { queuedOverride ?? queueVM.queued }
    private var recentJobs: [RefinementJob] { recentOverride ?? queueVM.recent }
```

(Replace every direct `queueVM.running` / `queueVM.queued` / `queueVM.recent` read inside the model with these.) Test helper for jobs:

```swift
    static func job(
        _ id: String, recordingId: String, state: RefinementJobState
    ) -> RefinementJob {
        RefinementJob(
            id: id, recordingId: recordingId,
            folderURL: MenuBarFixtures.tempDir(),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: Self.now, state: state)
    }
```

Tests:

```swift
    // MARK: Badges (§4.1)

    @Test("badge precedence: running beats queued beats recent beats intrinsic")
    func badgePrecedence() {
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let model = Self.makeModel(entries: [e])
        model.runningOverride = .some(Self.job(
            "job_1", recordingId: "rec_a",
            state: .running(stage: .diarizing, stepsCompleted: 1, stepsTotal: 4,
                            regionIndex: nil, regionsTotal: nil)))
        guard case .refining = model.rows[0].badge else {
            Issue.record("expected .refining, got \(model.rows[0].badge)"); return
        }

        model.runningOverride = .some(nil)
        model.queuedOverride = [Self.job("job_2", recordingId: "rec_a", state: .queued)]
        #expect(model.rows[0].badge == .queued)

        model.queuedOverride = []
        model.recentOverride = [Self.job(
            "job_3", recordingId: "rec_a",
            state: .failed(errorClass: "model_load_failed", retryAvailable: true))]
        guard case .failed = model.rows[0].badge else {
            Issue.record("expected .failed, got \(model.rows[0].badge)"); return
        }
    }

    @Test("steady refined row shows no badge; unrefined shows notYetRefined; cancelled falls through")
    func intrinsicBadges() {
        let refined = Self.entry(id: "rec_r", start: Self.date(daysAgo: 0))
        let raw = Self.entry(id: "rec_u", start: Self.date(daysAgo: 0), refined: false)
        let model = Self.makeModel(entries: [refined, raw])
        #expect(model.rows[0].badge == .none)
        #expect(model.rows[1].badge == .notYetRefined)

        model.recentOverride = [Self.job("job_c", recordingId: "rec_r", state: .cancelled)]
        #expect(model.rows[0].badge == .none)  // cancelled → intrinsic
    }

    // MARK: Transient just-refined badge (§4.1)

    @Test("completed job shows justRefined until the row is selected")
    func justRefinedClearsOnSelection() {
        let nav = AppNavigation()
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let model = Self.makeModel(entries: [e], navigation: nav)
        model.recentOverride = [Self.job(
            "job_1", recordingId: "rec_a",
            state: .completed(durationSeconds: 60, speakerCount: 2))]
        #expect(model.rows[0].badge == .justRefined)

        model.select("rec_a")
        #expect(model.rows[0].badge == .none)
    }

    @Test("a row already selected when its refine completes never shows the badge")
    func justRefinedSuppressedWhenAlreadySelected() {
        let nav = AppNavigation()
        nav.selectedRecordingID = "rec_a"
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let model = Self.makeModel(entries: [e], navigation: nav)
        let done = Self.job("job_1", recordingId: "rec_a",
                            state: .completed(durationSeconds: 60, speakerCount: 2))
        model.recentOverride = [done]
        model.noteJobsTerminated([done])
        #expect(model.rows[0].badge == .none)
    }

    @Test("justRefined clears when the job ages out of recent")
    func justRefinedClearsOnEviction() {
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let model = Self.makeModel(entries: [e])
        model.recentOverride = [Self.job(
            "job_1", recordingId: "rec_a",
            state: .completed(durationSeconds: 60, speakerCount: 2))]
        #expect(model.rows[0].badge == .justRefined)
        model.recentOverride = []
        #expect(model.rows[0].badge == .none)
    }

    // MARK: Rename round-trip (§4.1)

    @Test("rename writes the sidecar; clearing restores the default; filter matches the new title")
    func renameRoundTrip() async throws {
        let folder = MenuBarFixtures.tempDir()
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0), folder: folder)
        let model = Self.makeModel(entries: [e])
        await model.rename(recordingId: "rec_a", to: "  Board\nreview ")
        #expect(RecordingTitleStore.read(folderURL: folder) == "Board review")

        await model.rename(recordingId: "rec_a", to: "   ")
        #expect(RecordingTitleStore.read(folderURL: folder) == nil)
    }

    // MARK: Move to Trash (§4.1)

    @Test("moveToTrash recycles the folder and the selection falls back to newest")
    func moveToTrash() async {
        let nav = AppNavigation()
        var trashed: [URL] = []
        let a = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let b = Self.entry(id: "rec_b", start: Self.date(daysAgo: 1))
        let model = RecordingsPaneModel(
            scanner: RecordingsScanner(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            queueVM: RefinementJobQueueViewModel(
                queue: RefinementJobQueue(
                    store: RefinementJobStore(directory: MenuBarFixtures.tempDir()),
                    runJob: { _ in })),
            recording: RecordingViewModel(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            navigation: nav,
            now: { Self.now },
            trashItem: { trashed.append($0) })
        model.entriesOverride = [a, b]
        nav.selectedRecordingID = "rec_a"

        await model.moveToTrash(recordingId: "rec_a")
        #expect(trashed == [a.folderURL])
        // entriesOverride still contains rec_a (no real scan ran) — drop it
        // the way a refresh would, then the fallback picks the newest left.
        model.entriesOverride = [b]
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_b")
    }
```

- [ ] **Step 2: Lift the real `friendly(_:)` mapping.** Open `Sources/pulsartrace-mac/RefinementsListView.swift`, find `JobRow`'s `static func friendly(_ errorClass: String) -> String` (referenced from `stateText` line ~139) and MOVE its body verbatim into `RecordingsPaneModel.friendlyFailure(_:)`, replacing the placeholder. Leave `RefinementsListView` calling its own copy for now (it is deleted whole in Task 9) — duplicate for two tasks is fine; deleting the view removes it.

- [ ] **Step 3: Run.** `swift test --filter RecordingsPaneModel` → PASS (all). `swift test --filter MenuBar` → PASS. `swift build` → succeeds.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(menubar): badge derivation incl. transient just-refined, rename + move-to-Trash actions (spec §4.1)"
```

---

### Task 5: `TranscriptDetailModel` + `TranscriptPlainText` + AppEnvironment wiring

**Files:**
- Create: `Sources/PulsarTraceMenuBar/TranscriptDetailModel.swift`
- Create: `Sources/PulsarTraceMenuBar/TranscriptPlainText.swift`
- Modify: `Sources/PulsarTraceMenuBar/AppEnvironment.swift`
- Test: `Tests/MenuBarTests/TranscriptDetailModelTests.swift`, `Tests/MenuBarTests/TranscriptPlainTextTests.swift`

- [ ] **Step 1: Write the failing `TranscriptPlainText` tests:**

```swift
import Testing
@testable import PulsarTraceMenuBar

@Suite("TranscriptPlainText")
struct TranscriptPlainTextTests {

    @Test("renders utterances as displayed, drops markers and blanks")
    func rendered() {
        let lines = [
            "<!-- pulsartrace:final -->",
            "## Transcript — 2026-05-01 09:00",
            "",
            "**[00:00:03] Them?:** Morning everyone.",
            "",
            "**[00:00:09] You:** Hi.",
        ]
        #expect(TranscriptPlainText.rendered(from: lines) == """
        Transcript — 2026-05-01 09:00
        [00:00:03] Them?  Morning everyone.
        [00:00:09] You  Hi.
        """)
    }

    @Test("unparseable lines pass through verbatim")
    func passthrough() {
        #expect(TranscriptPlainText.rendered(from: ["just prose"]) == "just prose")
    }
}
```

- [ ] **Step 2: Implement** (`Sources/PulsarTraceMenuBar/TranscriptPlainText.swift`):

```swift
import Foundation

/// "Copy copies what you see" (§5): the styled renderer's text content as a
/// plain string — `[HH:MM:SS] Speaker  text` per utterance, headers verbatim,
/// comment markers and blank lines dropped. The raw Markdown file remains one
/// Reveal-in-Finder away for anyone who wants the source form.
public enum TranscriptPlainText {
    public static func rendered(from lines: [String]) -> String {
        var out: [String] = []
        for raw in lines {
            switch TranscriptLine.parse(raw) {
            case .utterance(let ts, let speaker, let text):
                out.append("[\(ts)] \(speaker)  \(text)")
            case .header(let title):
                out.append(title)
            case .plain(let s):
                out.append(s)
            case .marker, .blank:
                continue
            }
        }
        return out.joined(separator: "\n")
    }
}
```

Run: `swift test --filter TranscriptPlainText` → PASS.

- [ ] **Step 3: Write the failing detail-model tests** (`Tests/MenuBarTests/TranscriptDetailModelTests.swift`):

```swift
import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@MainActor
@Suite("TranscriptDetailModel")
struct TranscriptDetailModelTests {

    static func makeModel() -> (TranscriptDetailModel, RefinementJobQueueViewModel) {
        let queueVM = RefinementJobQueueViewModel(
            queue: RefinementJobQueue(
                store: RefinementJobStore(directory: MenuBarFixtures.tempDir()),
                runJob: { _ in }))
        let model = TranscriptDetailModel(
            queueVM: queueVM, liveWatcher: LiveTranscriptWatcher())
        return (model, queueVM)
    }

    static func row(
        _ entry: RecordingEntry, isLive: Bool = false,
        badge: RecordingRow.Badge = .none
    ) -> RecordingRow {
        RecordingRow(entry: entry, isLive: isLive, badge: badge)
    }

    static func refinedEntry(in root: URL) throws -> RecordingEntry {
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-090000", recordingId: "rec_a")
        return RecordingEntry.decode(folderURL: folder)!
    }

    // MARK: Source selection + three-way load (§4.2)

    @Test("a refined row loads final.md lines")
    func loadsFinal() async throws {
        let (model, _) = Self.makeModel()
        let entry = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        guard case .lines(let lines) = model.content else {
            Issue.record("expected .lines, got \(model.content)"); return
        }
        #expect(lines.contains { $0.contains("Morning everyone") })
    }

    @Test("a missing file yields the placeholder; an unreadable file yields loadError + Retry")
    func threeWayResult() async throws {
        let (model, _) = Self.makeModel()
        // Folder with neither final.md nor live.md readable:
        let folder = MenuBarFixtures.tempDir()
        let entry = RecordingEntry(
            id: "rec_x", recordingStart: .now, folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false)
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        #expect(model.content == .placeholder)

        // Unreadable: a directory where live.md should be.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("live.md"),
            withIntermediateDirectories: true)
        model.reload()
        await model.awaitLoadForTesting()
        #expect(model.content == .unreadable)
        #expect(model.banner == .loadError)
    }

    @Test("a live row streams (no file load) and shows no banner")
    func liveRow() throws {
        let (model, _) = Self.makeModel()
        let entry = RecordingEntry(
            id: "rec_live", recordingStart: .now,
            folderURL: MenuBarFixtures.tempDir(),
            durationSeconds: 0, speakers: [], isRefined: false)
        model.show(Self.row(entry, isLive: true, badge: .recordingNow(startedAt: .now)))
        #expect(model.content == .live)
        #expect(model.banner == .none)
    }

    // MARK: Banner decision table (§4.2)

    @Test("queued and refining rows banner with Cancel; failed rows banner with Retry")
    func queueBanners() async throws {
        let (model, _) = Self.makeModel()
        let entry = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()

        model.queueOverride = .queued
        #expect(model.banner == .queued)

        model.queueOverride = .refining(fraction: 0.45, stageName: "Diarizing")
        #expect(model.banner == .refining(fraction: 0.45, stageName: "Diarizing"))

        model.queueOverride = .failed(errorClass: "model_load_failed", retryable: true)
        guard case .failed(_, _, let retryable) = model.banner, retryable else {
            Issue.record("expected retryable .failed, got \(model.banner)"); return
        }
    }

    @Test("unrefined idle row banners with the Refine prompt; refined steady row shows none")
    func intrinsicBanners() async throws {
        let (model, _) = Self.makeModel()
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeUnrefinedRecordingFolder(
            root: root, name: "2026-05-02-090000")
        let unrefined = RecordingEntry.decode(folderURL: folder)!
        model.show(Self.row(unrefined))
        await model.awaitLoadForTesting()
        #expect(model.banner == .unrefined)

        let refined = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(refined))
        await model.awaitLoadForTesting()
        #expect(model.banner == .none)
    }

    // MARK: The pending-refined-content gate (§4.2)

    @Test("refine completion with content on screen flips the banner, never the content")
    func noAutoSwap() async throws {
        let (model, _) = Self.makeModel()
        let entry = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        let before = model.content

        model.noteJobsTerminated([RefinementJob(
            id: "job_1", recordingId: entry.id, folderURL: entry.folderURL,
            modelName: "base", modelSHA256: "deadbeef", trigger: .manual,
            enqueuedAt: .now,
            state: .completed(durationSeconds: 60, speakerCount: 2))])
        #expect(model.content == before)          // unchanged under the user
        #expect(model.banner == .refineCompleted) // … the banner is the signal

        model.showRefinedTranscript()
        await model.awaitLoadForTesting()
        #expect(model.banner != .refineCompleted) // explicit action reloads
    }

    @Test("refine completion over a placeholder/error reloads immediately")
    func immediateReloadFromPlaceholder() async throws {
        let (model, _) = Self.makeModel()
        let folder = MenuBarFixtures.tempDir()
        let entry = RecordingEntry(
            id: "rec_a", recordingStart: .now, folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false)
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        #expect(model.content == .placeholder)

        // The refine pass writes final.md, then completes:
        try Data(MenuBarFixtures.finalMarkdown().utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        model.noteJobsTerminated([RefinementJob(
            id: "job_1", recordingId: "rec_a", folderURL: folder,
            modelName: "base", modelSHA256: "deadbeef", trigger: .manual,
            enqueuedAt: .now,
            state: .completed(durationSeconds: 60, speakerCount: 2))])
        await model.awaitLoadForTesting()
        guard case .lines = model.content else {
            Issue.record("expected immediate reload, got \(model.content)"); return
        }
    }

    @Test("selection change away and back reloads naturally (pending flag does not leak)")
    func selectionChangeClearsPending() async throws {
        let (model, _) = Self.makeModel()
        let a = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(a))
        await model.awaitLoadForTesting()
        model.noteJobsTerminated([RefinementJob(
            id: "job_1", recordingId: a.id, folderURL: a.folderURL,
            modelName: "base", modelSHA256: "deadbeef", trigger: .manual,
            enqueuedAt: .now,
            state: .completed(durationSeconds: 60, speakerCount: 2))])
        #expect(model.banner == .refineCompleted)

        let b = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(b))
        await model.awaitLoadForTesting()
        #expect(model.banner == .none)
    }
}
```

- [ ] **Step 4: Run to verify failure.** `swift test --filter TranscriptDetailModel` → FAIL (type not found).

- [ ] **Step 5: Implement the model** (`Sources/PulsarTraceMenuBar/TranscriptDetailModel.swift`):

```swift
import Foundation
import PulsarTraceEngine

/// Picks the transcript source and banner for the selected recording row —
/// the §4.2 decision table — and owns the async file load with the
/// pending-refined-content gate (a refine completion never swaps content
/// under the user).
@MainActor
@Observable
public final class TranscriptDetailModel {

    public enum Content: Equatable {
        /// No selection / no recordings — ContentUnavailableView.
        case empty
        /// Live row — render `liveWatcher.lines` with auto-scroll.
        case live
        case loading
        case lines([String])
        /// File missing — "no transcript yet" placeholder.
        case placeholder
        /// File exists but could not be read — loadError banner + Retry.
        case unreadable
    }

    public enum Banner: Equatable {
        case none
        case queued
        case refining(fraction: Double?, stageName: String)
        case refineCompleted
        case unrefined
        case failed(friendlyMessage: String, errorClass: String, retryable: Bool)
        case loadError
    }

    /// Queue-state seam for tests; production leaves `nil` and derives from
    /// `queueVM` (same override pattern as `RecordingsPaneModel`).
    public enum QueuePosture: Equatable {
        case idle
        case queued
        case refining(fraction: Double?, stageName: String)
        case failed(errorClass: String, retryable: Bool)
    }
    var queueOverride: QueuePosture?

    public private(set) var content: Content = .empty
    /// The row the detail is showing (fresh copy on every list recompute).
    public private(set) var shown: RecordingRow?
    /// Set when a refine completed for the on-screen recording while
    /// readable content was loaded (§4.2) — the banner offers "Show refined
    /// transcript" instead of reloading.
    public private(set) var pendingRefinedContent = false

    private let queueVM: RefinementJobQueueViewModel
    /// Exposed so the view renders live lines through the model's owner.
    public let liveWatcher: LiveTranscriptWatcher
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    public init(
        queueVM: RefinementJobQueueViewModel,
        liveWatcher: LiveTranscriptWatcher
    ) {
        self.queueVM = queueVM
        self.liveWatcher = liveWatcher
    }

    // MARK: - Selection

    /// Show a row. Same id → only the row snapshot updates (badge/entry
    /// freshness); the content is NOT reloaded under the user. A different
    /// id (or a live↔file flip for the same id) loads the new source.
    public func show(_ row: RecordingRow?) {
        let previous = shown
        shown = row
        guard row?.id != previous?.id || row?.isLive != previous?.isLive else {
            return
        }
        pendingRefinedContent = false
        loadTask?.cancel()
        guard let row else {
            content = .empty
            return
        }
        if row.isLive {
            content = .live
            return
        }
        reload()
    }

    /// Re-read the file source (explicit triggers only: selection change,
    /// "Show refined transcript", load-error Retry, completion-over-placeholder).
    public func reload() {
        guard let row = shown, !row.isLive else { return }
        pendingRefinedContent = false
        loadGeneration += 1
        let generation = loadGeneration
        let finalURL = row.entry.finalURL
        let liveURL = row.entry.liveURL
        content = .loading
        loadTask = Task { [weak self] in
            // Three-way result lifted from the deleted RecordedTranscriptSheet:
            // [] = no file, nil = unreadable, lines = success.
            let result: [String]? = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let url = fm.fileExists(atPath: finalURL.path) ? finalURL : liveURL
                guard fm.fileExists(atPath: url.path) else { return [] }
                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                return text.components(separatedBy: "\n")
            }.value
            guard let self, self.loadGeneration == generation else { return }
            switch result {
            case nil: self.content = .unreadable
            case .some(let lines) where lines.allSatisfy(\.isEmpty):
                self.content = .placeholder
            case .some(let lines): self.content = .lines(lines)
            }
        }
    }

    /// The "Show refined transcript" banner action (§4.2).
    public func showRefinedTranscript() { reload() }

    /// Awaitable load completion for deterministic tests.
    public func awaitLoadForTesting() async {
        await loadTask?.value
    }

    // MARK: - Banner (§4.2 decision table)

    public var banner: Banner {
        guard let row = shown, !row.isLive else { return .none }
        if case .unreadable = content { return .loadError }
        switch queuePosture(for: row.id) {
        case .refining(let fraction, let stage):
            return .refining(fraction: fraction, stageName: stage)
        case .queued:
            return .queued
        case .failed(let errorClass, let retryable):
            return .failed(
                friendlyMessage: RecordingsPaneModel.friendlyFailure(errorClass),
                errorClass: errorClass, retryable: retryable)
        case .idle:
            break
        }
        if pendingRefinedContent { return .refineCompleted }
        if !row.entry.isRefined { return .unrefined }
        return .none
    }

    private func queuePosture(for recordingId: String) -> QueuePosture {
        if let override = queueOverride { return override }
        if let running = queueVM.running, running.recordingId == recordingId {
            return .refining(
                fraction: running.state.progressFraction,
                stageName: RecordingsPaneModel.stageName(of: running.state))
        }
        if queueVM.queued.contains(where: { $0.recordingId == recordingId }) {
            return .queued
        }
        if let recent = queueVM.recent.first(where: { $0.recordingId == recordingId }),
           case .failed(let errorClass, let retryable) = recent.state {
            return .failed(errorClass: errorClass, retryable: retryable)
        }
        return .idle
    }

    // MARK: - Refine-completion gate (§4.2)

    public func noteJobsTerminated(_ jobs: [RefinementJob]) {
        guard let row = shown, !row.isLive else { return }
        let completedForShown = jobs.contains { job in
            guard job.recordingId == row.id else { return false }
            if case .completed = job.state { return true }
            return false
        }
        guard completedForShown else { return }
        switch content {
        case .lines:
            pendingRefinedContent = true
        case .placeholder, .unreadable, .empty, .loading:
            reload()
        case .live:
            break
        }
    }
}
```

Banner-equality note: the `queueBanners` test compares `.failed` via pattern match because `friendlyFailure` output is part of the value.

- [ ] **Step 6: Wire both models into `AppEnvironment`.** Add stored properties after `queueVM`:

```swift
    /// Recordings-pane list model (§4.1) — process-lifetime so the selection,
    /// filter, and just-refined acknowledgments survive window churn.
    public let paneModel: RecordingsPaneModel

    /// Transcript detail model (§4.2).
    public let detailModel: TranscriptDetailModel
```

In `init()` after `self.onboarding = OnboardingTourViewModel()`:

```swift
        self.paneModel = RecordingsPaneModel(
            scanner: scanner, queueVM: queueVM,
            recording: recording, navigation: navigation)
        self.detailModel = TranscriptDetailModel(
            queueVM: queueVM, liveWatcher: liveWatcher)
```

(`scanner`/`liveWatcher` are assigned just above — keep the new lines after those assignments; `navigation` is a `let` with inline initializer, available.) In `bootstrap()`, extend the `onJobsTerminated` closure — first lines become:

```swift
        queueVM.onJobsTerminated = { [weak self] jobs in
            self?.paneModel.noteJobsTerminated(jobs)
            self?.detailModel.noteJobsTerminated(jobs)
            Task { [weak self] in await self?.scanner.refresh() }
```

(rest unchanged).

- [ ] **Step 7: Run.** `swift test --filter TranscriptDetailModel` → PASS. `swift test --filter MenuBar` → PASS. `swift build` → succeeds.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(menubar): TranscriptDetailModel decision table + pending-refined gate; TranscriptPlainText; AppEnvironment wiring (spec §4.2, §5)"
```

---

### Task 6: One transcript renderer — find bar, scroll modes, append fast path (§5)

**Files:**
- Rewrite: `Sources/pulsartrace-mac/TranscriptView.swift`
- Modify: `Sources/pulsartrace-mac/LiveTranscriptView.swift`
- (No new unit tests — NSView plumbing; `AutoScrollControllerTests` must stay green. The behavior contract is in the §11 manual QA list.)

- [ ] **Step 1: Rewrite `TranscriptView.swift`.** Replace the whole file with the single-renderer version. The diff from today's file, precisely:

1. `TranscriptView.body` loses the `LazyVStack` branch — the NSTextView path renders both modes:

```swift
struct TranscriptView: View {
    /// The transcript lines, in file order.
    let lines: [String]
    /// Shown when `lines` is empty.
    var placeholder: String = "No transcript yet."
    /// Opt-in smart auto-scroll (live mode). `nil` = static transcript:
    /// opens at the top, no follow-mode, no jump pill.
    var autoScroll: AutoScrollController? = nil
    /// Find-in-transcript hook (⌘F / toolbar Find) — optional.
    var findActivator: TranscriptFindActivator? = nil

    var body: some View {
        if lines.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let autoScroll {
            ZStack(alignment: .bottomTrailing) {
                TranscriptTextView(
                    lines: lines, controller: autoScroll,
                    findActivator: findActivator)
                Group {
                    if !autoScroll.isAtBottom, autoScroll.pendingNewLines > 0 {
                        JumpToLatestPill(count: autoScroll.pendingNewLines) {
                            autoScroll.jumpToLatest()
                        }
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: autoScroll.isAtBottom)
                .animation(.easeOut(duration: 0.15), value: autoScroll.pendingNewLines)
            }
        } else {
            TranscriptTextView(
                lines: lines, controller: nil, findActivator: findActivator)
        }
    }
}
```

(The old `SmartScrollingTranscript` struct and the whole `transcriptRow`/`LazyVStack` path are deleted; `JumpToLatestPill` stays as-is.)

2. `LiveScrollableTranscript` is renamed `TranscriptTextView`, its `controller` becomes optional, and it gains the find bar + scroll-mode + append fast path. Full replacement for the representable:

```swift
/// The single transcript renderer (§5): an NSTextView-backed scroll view.
/// Live mode (controller != nil) opens at the bottom and follows appends;
/// static mode opens at the top. Both get native cross-line selection and
/// the find bar (⌘F / NSTextFinder).
private struct TranscriptTextView: NSViewRepresentable {
    let lines: [String]
    let controller: AutoScrollController?
    let findActivator: TranscriptFindActivator?

    private static let bottomThreshold: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // Find-in-transcript (§5): the system find bar, incremental.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textStorage?.setAttributedString(Self.attributed(from: lines))

        scrollView.documentView = textView
        findActivator?.textView = textView

        context.coordinator.lastSeenLineCount = lines.count
        context.coordinator.lastSeenRawText = lines.joined(separator: "\n")

        if let controller {
            scrollView.contentView.postsBoundsChangedNotifications = true
            context.coordinator.observe(
                scrollView: scrollView, threshold: Self.bottomThreshold)
            // Live mode opens at the bottom — "show me the latest". One
            // runloop turn so layout has happened.
            DispatchQueue.main.async {
                Self.scrollToBottom(in: scrollView, animated: false)
                controller.setIsAtBottom(true)
            }
        }
        // Static mode opens at the top (§5 requirement) — NSScrollView's
        // natural origin; nothing to do.

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        findActivator?.textView = textView

        let newText = lines.joined(separator: "\n")
        let oldText = context.coordinator.lastSeenRawText
        let textChanged = oldText != newText

        // Before-render check: sample with the OLD text still in place.
        let wasAtBottom = controller != nil
            && Self.isAtBottom(in: scrollView, threshold: Self.bottomThreshold)

        if textChanged {
            let oldCount = context.coordinator.lastSeenLineCount
            // Suffix-append fast path (§5): live updates append
            // `lines[oldCount...]` instead of rebuilding the whole attributed
            // string per poll tick. The boundary must be a clean line break —
            // a mutated tail line falls back to the full rebuild, as does a
            // shrink (truncation/overwrite).
            if lines.count > oldCount, oldCount > 0,
               newText.count > oldText.count,
               newText.hasPrefix(oldText),
               newText[newText.index(newText.startIndex, offsetBy: oldText.count)] == "\n" {
                textView.textStorage?.append(
                    Self.attributed(from: Array(lines[oldCount...])))
            } else {
                textView.textStorage?.setAttributedString(Self.attributed(from: lines))
            }
            context.coordinator.lastSeenRawText = newText
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            context.coordinator.lastSeenLineCount = lines.count

            if let controller {
                if wasAtBottom {
                    Self.scrollToBottom(in: scrollView, animated: false)
                    controller.setIsAtBottom(true)
                } else {
                    controller.notePendingNewLines(lines.count - oldCount)
                }
            }
        }

        if let controller,
           context.coordinator.lastSeenJumpGeneration != controller.jumpToLatestGeneration {
            context.coordinator.lastSeenJumpGeneration = controller.jumpToLatestGeneration
            Self.scrollToBottom(in: scrollView, animated: true)
            controller.setIsAtBottom(true)
        }
    }
    // isAtBottom / attributed(from:) / scrollToBottom and the Coordinator
    // stay exactly as they are today (Coordinator's `controller` becomes
    // `AutoScrollController?` and `observe` is only called in live mode).
}
```

Coordinator change: `private let controller: AutoScrollController?` + `init(controller: AutoScrollController?)`; inside `observe`'s closure unwrap: `guard let controller = self?.controller` — simplest is to keep capturing the unwrapped controller since `observe` is only invoked when non-nil: `let controller = self.controller!` is forbidden style; instead pass it: `func observe(scrollView: NSScrollView, threshold: CGFloat)` body starts `guard let controller else { return }`.

3. Add the activator class at the bottom of the file (replacing nothing):

```swift
/// Bridges the SwiftUI Find affordance (toolbar button / ⌘F) to the
/// NSTextView's NSTextFinder find bar. The accessory app has no visible menu
/// bar, so the standard ⌘F responder-chain route is wired explicitly (§5
/// risk flag).
@MainActor
final class TranscriptFindActivator {
    weak var textView: NSTextView?

    func showFind() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
}
```

4. `copyTranscriptToPasteboard` switches to rendered text (§5 — Copy copies what you see):

```swift
@MainActor
func copyTranscriptToPasteboard(_ lines: [String]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(TranscriptPlainText.rendered(from: lines), forType: .string)
}
```

- [ ] **Step 2: Move the detached window's header into its toolbar.** In `LiveTranscriptView.swift`, delete the in-content `HStack` header ("Live Transcript" title + badge + Copy) and its `Divider()`; the body becomes the `TranscriptView` alone, with:

```swift
        .navigationTitle("Live Transcript")
        .toolbar {
            ToolbarItem {
                if watcher.isActive {
                    Label("Recording", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .accessibilityLabel("Recording in progress")
                }
            }
            ToolbarItem {
                Button {
                    copyTranscriptToPasteboard(watcher.lines)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(watcher.lines.isEmpty)
                .help("Copy the transcript text")
            }
        }
```

Keep `.frame(minWidth: 360, minHeight: 320)`.

- [ ] **Step 3: Build + targeted tests.** `swift build` → succeeds (the deleted `transcriptRow` had the only other `TranscriptLine` view usage; `RecordingsListView` still compiles against `TranscriptView(lines:placeholder:)` unchanged signature). `swift test --filter MenuBar` → PASS (`AutoScrollControllerTests` green).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ui): single NSTextView transcript renderer — find bar, mode-scoped initial scroll, suffix-append fast path, rendered-text copy (spec §5)"
```

---

### Task 7: Recordings master–detail split (§3, §4)

**Files:**
- Create: `Sources/pulsartrace-mac/PersistentHSplit.swift`
- Create: `Sources/pulsartrace-mac/TranscriptDetailView.swift`
- Create: `Sources/pulsartrace-mac/RecordingsSplitView.swift`
- Delete: `Sources/pulsartrace-mac/RecordingsListView.swift`
- Modify: `Sources/pulsartrace-mac/MainWindowView.swift` (`.recordings` case), `Sources/pulsartrace-mac/PulsarTraceMacApp.swift` (environment injection)

- [ ] **Step 1: The split container** (`Sources/pulsartrace-mac/PersistentHSplit.swift`):

```swift
import AppKit
import SwiftUI

/// A two-pane horizontal split backed by NSSplitView — chosen over
/// `HSplitView` because `autosaveName` gives divider-position persistence
/// across launches for free and the delegate enforces hard minimum widths
/// (§3: list ≥ 240, detail ≥ 320).
///
/// IMPORTANT: content crosses an NSHostingView boundary — SwiftUI
/// environment does NOT flow across it automatically. Both panes must
/// receive their models via init injection (RecordingsSplitView does), or
/// re-apply `.environment(...)` on the pane views here.
struct PersistentHSplit<Leading: View, Trailing: View>: NSViewRepresentable {
    let autosaveName: String
    let leadingMinWidth: CGFloat
    let trailingMinWidth: CGFloat
    let leading: Leading
    let trailing: Trailing

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.addArrangedSubview(NSHostingView(rootView: leading))
        split.addArrangedSubview(NSHostingView(rootView: trailing))
        // Set AFTER the subviews exist so the restored position applies.
        split.autosaveName = autosaveName
        return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        (nsView.arrangedSubviews[0] as? NSHostingView<Leading>)?.rootView = leading
        (nsView.arrangedSubviews[1] as? NSHostingView<Trailing>)?.rootView = trailing
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(leadingMin: leadingMinWidth, trailingMin: trailingMinWidth)
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leadingMin: CGFloat
        let trailingMin: CGFloat

        init(leadingMin: CGFloat, trailingMin: CGFloat) {
            self.leadingMin = leadingMin
            self.trailingMin = trailingMin
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(proposedMinimumPosition, leadingMin)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(proposedMaximumPosition,
                splitView.bounds.width - splitView.dividerThickness - trailingMin)
        }
    }
}
```

- [ ] **Step 2: The detail pane** (`Sources/pulsartrace-mac/TranscriptDetailView.swift`). Init-injected (NSHostingView boundary — see PersistentHSplit doc):

```swift
import AppKit
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// Right side of the Recordings split (§4.2): header + state banner + the
/// shared transcript renderer. Pure binding onto `TranscriptDetailModel`.
struct TranscriptDetailView: View {
    let detailModel: TranscriptDetailModel
    let queueVM: RefinementJobQueueViewModel
    let settings: MenuBarSettings

    @State private var autoScroll = AutoScrollController()
    @State private var find = TranscriptFindActivator()

    var body: some View {
        if let row = detailModel.shown {
            VStack(alignment: .leading, spacing: 0) {
                header(row)
                Divider()
                banner(row)
                transcript(row)
            }
        } else {
            ContentUnavailableView(
                "Select a recording",
                systemImage: "waveform",
                description: Text("Choose a recording from the list to read its transcript."))
        }
    }

    // MARK: Header (§4.2)

    private func header(_ row: RecordingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.displayTitle)
                        .font(.headline)
                        .help(row.entry.displayName)
                    HStack(spacing: 6) {
                        if row.entry.customTitle != nil {
                            Text(row.entry.defaultTitle)
                        }
                        if row.entry.durationSeconds > 0 {
                            Text(RecordingEntry.formatDuration(row.entry.durationSeconds))
                        }
                        if row.isLive {
                            LiveElapsedBadge(startedAt: liveStartedAt(row))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    find.showFind()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in transcript (⌘F)")
                Button {
                    copyTranscriptToPasteboard(currentLines(row))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(currentLines(row).isEmpty)
                .help("Copy the transcript text")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([row.entry.folderURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal the recording folder in Finder")
            }
            if !row.entry.speakers.isEmpty {
                SpeakerPillsView(speakers: row.entry.speakers)
            }
        }
        .padding(12)
    }

    private func liveStartedAt(_ row: RecordingRow) -> Date {
        if case .recordingNow(let startedAt) = row.badge { return startedAt }
        return row.entry.recordingStart
    }

    private func currentLines(_ row: RecordingRow) -> [String] {
        if row.isLive { return detailModel.liveWatcher.lines }
        if case .lines(let lines) = detailModel.content { return lines }
        return []
    }

    // MARK: Banner (§4.2 decision table)

    @ViewBuilder
    private func banner(_ row: RecordingRow) -> some View {
        switch detailModel.banner {
        case .none:
            EmptyView()
        case .queued:
            bannerStrip(tint: .secondary) {
                Text("Queued for refinement")
                Spacer()
                Button("Cancel") {
                    Task { await queueVM.cancel(recordingId: row.id) }
                }
            }
        case .refining(let fraction, let stageName):
            bannerStrip(tint: .blue) {
                if let fraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(stageName.isEmpty ? "Refining…" : "Refining · \(stageName)")
                Spacer()
                Button("Cancel") {
                    Task { await queueVM.cancel(recordingId: row.id) }
                }
            }
        case .refineCompleted:
            bannerStrip(tint: .green) {
                Text("Refinement complete")
                Spacer()
                Button("Show refined transcript") {
                    detailModel.showRefinedTranscript()
                }
            }
        case .unrefined:
            bannerStrip(tint: .orange) {
                Text("This transcript hasn't been refined yet")
                Spacer()
                Button("Refine") {
                    Task {
                        await queueVM.enqueueManual(
                            folderURL: row.entry.folderURL,
                            recordingId: row.id,
                            refineModelName: settings.refineModelName)
                    }
                }
            }
        case .failed(let friendlyMessage, let errorClass, let retryable):
            bannerStrip(tint: .red) {
                Text("Refinement failed — \(friendlyMessage)").help(errorClass)
                Spacer()
                if retryable {
                    Button("Retry") {
                        Task {
                            await queueVM.enqueueManual(
                                folderURL: row.entry.folderURL,
                                recordingId: row.id,
                                refineModelName: settings.refineModelName)
                        }
                    }
                }
            }
        case .loadError:
            bannerStrip(tint: .red) {
                Text("Could not read the transcript file.")
                Spacer()
                Button("Retry") { detailModel.reload() }
            }
        }
    }

    private func bannerStrip(
        tint: Color, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 8, content: content)
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(tint.opacity(0.3)),
                     alignment: .bottom)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Transcript body

    @ViewBuilder
    private func transcript(_ row: RecordingRow) -> some View {
        Group {
            if row.isLive {
                TranscriptView(
                    lines: detailModel.liveWatcher.lines,
                    placeholder: "Waiting for transcript…",
                    autoScroll: autoScroll,
                    findActivator: find)
            } else {
                switch detailModel.content {
                case .lines(let lines):
                    TranscriptView(lines: lines, findActivator: find)
                case .placeholder:
                    TranscriptView(lines: [], placeholder: "No transcript file yet.")
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unreadable, .empty, .live:
                    // unreadable → the banner carries the error + Retry;
                    // keep the body quiet.
                    Color.clear
                }
            }
        }
        .animation(.default, value: detailModel.banner)
    }
}

/// Ticking elapsed-time badge for the live row's header (red, 1 s cadence).
struct LiveElapsedBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(
                elapsedString(to: context.date),
                systemImage: "circle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel("Recording, elapsed \(elapsedString(to: context.date))")
        }
    }

    private func elapsedString(to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(startedAt)))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

- [ ] **Step 3: The list pane + pane shell** (`Sources/pulsartrace-mac/RecordingsSplitView.swift`):

```swift
import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// The Recordings pane (§4): master list + transcript detail in a resizable,
/// persistent split. Reads models from the SwiftUI environment and hands
/// them to the panes by init (they cross an NSHostingView boundary inside
/// `PersistentHSplit` — environment does not flow across it).
struct RecordingsSplitView: View {
    @Environment(RecordingsPaneModel.self) private var paneModel
    @Environment(TranscriptDetailModel.self) private var detailModel
    @Environment(RefinementJobQueueViewModel.self) private var queueVM
    @Environment(MenuBarSettings.self) private var settings
    @Environment(RecordingViewModel.self) private var recording
    @Environment(AppNavigation.self) private var navigation
    @Environment(RecordingsScanner.self) private var scanner

    var body: some View {
        PersistentHSplit(
            autosaveName: "RecordingsSplit",
            leadingMinWidth: 240,
            trailingMinWidth: 320,
            leading: RecordingsListPane(
                paneModel: paneModel, queueVM: queueVM,
                settings: settings, navigation: navigation),
            trailing: TranscriptDetailView(
                detailModel: detailModel, queueVM: queueVM, settings: settings))
        .toolbar {
            ToolbarItem(placement: .navigation) { RecordToolbarButton() }
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
        .safeAreaInset(edge: .top, spacing: 0) { recordingStateBanner }
        .task { await scanner.refresh() }
        .onAppear {
            paneModel.ensureSelection()
            syncDetail()
        }
        .onChange(of: navigation.selectedRecordingID) { syncDetail() }
        .onChange(of: paneModel.rows) {
            paneModel.ensureSelection()
            syncDetail()
        }
    }

    /// Push the selected row (fresh snapshot) into the detail model.
    private func syncDetail() {
        let row = paneModel.rows.first { $0.id == navigation.selectedRecordingID }
        detailModel.show(row)
    }

    /// Crash/error parity with the menubar (§6): the window must be
    /// self-sufficient.
    @ViewBuilder
    private var recordingStateBanner: some View {
        switch recording.status {
        case .crashed:
            HStack(spacing: 8) {
                Text("Recording stopped unexpectedly.")
                Spacer()
                Button("Recover Transcript") {
                    Task { await recording.recoverFromCrash() }
                }
                Button("Dismiss") { recording.dismissCrash() }
            }
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        case .error(let message):
            HStack(spacing: 8) {
                Text(message)
                Spacer()
                Button("Dismiss") { recording.dismissCrash() }
            }
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

/// Left side of the split: filter field + day-grouped, selection-driven list.
private struct RecordingsListPane: View {
    @Bindable var paneModel: RecordingsPaneModel
    let queueVM: RefinementJobQueueViewModel
    let settings: MenuBarSettings
    let navigation: AppNavigation

    @State private var renameTargetID: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by title, speaker, or date", text: $paneModel.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(8)
            Divider()
            content
        }
        .safeAreaInset(edge: .top, spacing: 0) { errorBanners }
        .onDisappear { commitPendingRename() }
    }

    @ViewBuilder
    private var content: some View {
        if paneModel.rows.isEmpty {
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform")
            } description: {
                Text("Record a meeting and its transcript will appear here.")
            } actions: {
                RecordToolbarButton()
            }
        } else if paneModel.groups.isEmpty {
            ContentUnavailableView.search(text: paneModel.filterText)
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selectionBinding) {
            ForEach(paneModel.groups) { group in
                Section(group.key.title) {
                    ForEach(group.rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .contextMenu { contextMenu(row) }
                    }
                }
            }
        }
        .onDeleteCommand {
            guard let id = navigation.selectedRecordingID else { return }
            Task { await paneModel.moveToTrash(recordingId: id) }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { navigation.selectedRecordingID },
            set: { paneModel.select($0) })
    }

    // MARK: Row

    @ViewBuilder
    private func rowView(_ row: RecordingRow) -> some View {
        if renameTargetID == row.id {
            renameField(row)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.titleText)
                        .help(row.entry.displayName)
                    if let caption = row.captionText {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if row.entry.isRefined && !row.entry.speakers.isEmpty {
                        SpeakerPillsView(speakers: row.entry.speakers)
                    }
                }
                Spacer()
                RecordingBadgeView(badge: row.badge)
            }
            .contentShape(Rectangle())
            // Double-click renames. `simultaneousGesture` (not
            // `onTapGesture`) so the List still receives the first click for
            // selection — the §12 coexistence requirement: neither the
            // gesture nor selection may be dropped.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                beginRename(row)
            })
        }
    }

    private func renameField(_ row: RecordingRow) -> some View {
        TextField("Title", text: $renameText)
            .textFieldStyle(.roundedBorder)
            .focused($renameFocused)
            .onAppear {
                renameFocused = true
                // Select-all needs the AppKit field editor, installed only
                // after the focus change processes (same pattern as the
                // speakers list).
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                }
            }
            .onSubmit { commitRename(row) }
            .onExitCommand { renameTargetID = nil }
    }

    private func beginRename(_ row: RecordingRow) {
        renameText = row.entry.customTitle ?? ""
        renameTargetID = row.id
    }

    private func commitRename(_ row: RecordingRow) {
        let title = renameText
        renameTargetID = nil
        Task { await paneModel.rename(recordingId: row.id, to: title) }
    }

    /// Navigating away (e.g. the Record button jumping to Recordings, or a
    /// sidebar switch) must not silently discard an in-progress rename —
    /// commit it (§6 planning note).
    private func commitPendingRename() {
        guard let id = renameTargetID,
              let row = paneModel.rows.first(where: { $0.id == id }) else { return }
        commitRename(row)
    }

    // MARK: Context menu (§4.1)

    @ViewBuilder
    private func contextMenu(_ row: RecordingRow) -> some View {
        Button("View Transcript") { paneModel.select(row.id) }
        Button("Rename") { beginRename(row) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.entry.folderURL])
        }
        Divider()
        Button("Refine") {
            Task {
                await queueVM.enqueueManual(
                    folderURL: row.entry.folderURL,
                    recordingId: row.id,
                    refineModelName: settings.refineModelName)
            }
        }
        .disabled(jobInFlight(row.id) || row.isLive)
        if case .queued = row.badge {
            Button("Cancel Refinement") {
                Task { await queueVM.cancel(recordingId: row.id) }
            }
        }
        if case .failed(_, _, let retryable) = row.badge, retryable {
            Button("Retry") {
                Task {
                    await queueVM.enqueueManual(
                        folderURL: row.entry.folderURL,
                        recordingId: row.id,
                        refineModelName: settings.refineModelName)
                }
            }
        }
        Divider()
        Button("Move to Trash") {
            Task { await paneModel.moveToTrash(recordingId: row.id) }
        }
        .disabled(row.isLive)
    }

    private func jobInFlight(_ recordingId: String) -> Bool {
        queueVM.running?.recordingId == recordingId
            || queueVM.queued.contains { $0.recordingId == recordingId }
    }

    // MARK: Banners

    @ViewBuilder
    private var errorBanners: some View {
        VStack(spacing: 4) {
            if let err = paneModel.lastActionError {
                dismissibleBanner(err, tint: .red) { paneModel.clearActionError() }
            }
            if let err = queueVM.lastEnqueueError {
                dismissibleBanner(err, tint: .orange) { queueVM.clearEnqueueError() }
            }
        }
        .animation(.default, value: paneModel.lastActionError)
        .animation(.default, value: queueVM.lastEnqueueError)
    }

    private func dismissibleBanner(
        _ text: String, tint: Color, dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss error")
        }
        .padding(8)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.4)))
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Exceptional-only row badge (§4.1).
private struct RecordingBadgeView: View {
    let badge: RecordingRow.Badge

    var body: some View {
        switch badge {
        case .recordingNow(let startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text(elapsed(from: startedAt, to: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            .help("Recording now")
            .accessibilityLabel("Recording now")
        case .queued:
            icon("clock", tint: .secondary, help: "Queued for refinement")
        case .refining(let fraction, let stageName):
            HStack(spacing: 4) {
                if let fraction {
                    ProgressView(value: fraction)
                        .controlSize(.mini)
                        .frame(width: 40)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .help(stageName.isEmpty ? "Refining…" : "Refining · \(stageName)")
            .accessibilityLabel("Refining")
        case .failed(let friendlyMessage, let errorClass, _):
            icon("exclamationmark.circle.fill", tint: .red,
                 help: "Refinement failed — \(friendlyMessage)")
                .help(errorClass)
        case .notYetRefined:
            icon("clock.badge", tint: .orange, help: "Not yet refined")
        case .justRefined:
            icon("checkmark.circle.fill", tint: .green, help: "Just refined")
        case .none:
            EmptyView()
        }
    }

    private func icon(_ name: String, tint: Color, help: String) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(tint)
            .help(help)
            .accessibilityLabel(help)
    }
}
```

Note on `.failed`: the doubled `.help` is wrong — keep ONE `.help("Refinement failed — \(friendlyMessage)")` and put the raw `errorClass` into the accessibility label is also wrong; spec: humanized copy in the badge, raw `errorClass` in the tooltip. Final form:

```swift
        case .failed(let friendlyMessage, let errorClass, _):
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("\(friendlyMessage) (\(errorClass))")
                .accessibilityLabel("Refinement failed — \(friendlyMessage)")
```

- [ ] **Step 4: Swap the pane in.** `MainWindowView.swift`: `case .recordings: RecordingsSplitView()` (replacing `RecordingsListView()`); update the file-header comment naming the panes. Delete `Sources/pulsartrace-mac/RecordingsListView.swift` entirely (the sheet, `RefineStatusIcon`, and the chevron row die with it — all absorbed). In `PulsarTraceMacApp.swift`, the main `Window` gains the new environment objects (after `.environment(environment.queueVM)`):

```swift
                .environment(environment.paneModel)
                .environment(environment.detailModel)
                .environment(environment.liveWatcher)
```

- [ ] **Step 5: Build + full MenuBar suite.** `swift build` → succeeds. `swift test --filter MenuBar` → PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(ui): Recordings master-detail split — day-grouped list, filter, rename, trash, detail banners; sheet deleted (spec §3-4)"
```

---

### Task 8: Record button on every pane + action-scoped navigation (§6)

**Files:**
- Create: `Sources/pulsartrace-mac/RecordToolbarButton.swift`
- Modify: `Sources/pulsartrace-mac/SpeakerEditorView.swift`, `Sources/pulsartrace-mac/SettingsView.swift` (toolbar item)

- [ ] **Step 1: The shared button:**

```swift
import PulsarTraceMenuBar
import SwiftUI

/// The shared Record/Stop toolbar control (§6), present on all three panes.
///
/// Navigation and auto-select are scoped to the BUTTON ACTION, not the
/// status transition: a hotkey- or menubar-started recording must not steal
/// the window's selection or section (§6 — review finding).
struct RecordToolbarButton: View {
    @Environment(RecordingViewModel.self) private var recording
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        switch recording.status {
        case .idle:
            Button(action: startFromButton) {
                Label("Record", systemImage: "record.circle.fill")
            }
            .help("Start recording")
        case .launching:
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                }
            }
            .disabled(true)
        case .recording(_, let startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    Task { await recording.stopRecording() }
                } label: {
                    Label("Stop · \(elapsed(from: startedAt, to: context.date))",
                          systemImage: "stop.circle.fill")
                        .monospacedDigit()
                }
                .tint(.red)
                .help("Stop recording")
            }
        case .crashed:
            disabledRecord(reason: "Recording stopped unexpectedly — recover or dismiss below.")
        case .error(let message):
            disabledRecord(reason: message)
        }
    }

    private func disabledRecord(reason: String) -> some View {
        Button {} label: {
            Label("Record", systemImage: "record.circle.fill")
        }
        .disabled(true)
        .help(reason)
    }

    /// §6: pressing Record navigates to Recordings and selects the live row
    /// — a direct response to the click. `startRecording()` returns only
    /// after the status settled (`.recording` or `.error`), so the id is
    /// readable right here; the synthesized row exists the moment status
    /// flips.
    private func startFromButton() {
        Task {
            await recording.startRecording()
            navigation.section = .recordings
            if case .recording(let id, _) = recording.status {
                navigation.selectedRecordingID = id
            }
        }
    }
}

func elapsed(from start: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}
```

(Then delete the private `elapsed` duplicate if one was added in Task 7's `LiveElapsedBadge` — `LiveElapsedBadge` switches to this shared `elapsed(from:to:)`; one helper, file-scope `internal`, lives here.)

- [ ] **Step 2: Add the toolbar item to the other two panes.** In `SpeakerEditorView.swift` and `SettingsView.swift`, inside their existing `.toolbar { ... }` blocks add as the FIRST entry:

```swift
            ToolbarItem(placement: .navigation) { RecordToolbarButton() }
```

(Recordings already got it in Task 7. The chrome rule: every detail pane carries a toolbar — verify all three now do.)

- [ ] **Step 3: Build + manual sanity.** `swift build` → succeeds. `swift test --filter MenuBar` → PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ui): shared Record toolbar button on every pane, action-scoped navigation; crash/error banner parity (spec §6)"
```

---

### Task 9: Delete the Refinements pane; window frame + sidebar cleanup (§3, §7)

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/AppNavigation.swift` (drop `.refinements`)
- Delete: `Sources/pulsartrace-mac/RefinementsListView.swift`
- Modify: `Sources/pulsartrace-mac/MainWindowView.swift`, `Sources/pulsartrace-mac/PulsarTraceMacApp.swift`
- Modify (comment): `Sources/PulsarTraceMenuBar/AppEnvironment.swift:183`

- [ ] **Step 1: Drop the enum case.** In `AppNavigation.swift` remove `refinements` from the case list and its two switch arms (`title` → "Refinements", `systemImage` → "arrow.triangle.2.circlepath"). The enum becomes `case recordings, speakers, settings`.

- [ ] **Step 2: Delete the view + its switch arm.** Delete `Sources/pulsartrace-mac/RefinementsListView.swift` (its `friendly(_:)` already lives in `RecordingsPaneModel` since Task 4). In `MainWindowView.swift` remove:

```swift
        case .refinements:
            RefinementsListView()
```

and update the header comment (line ~21) that names it.

- [ ] **Step 3: Sidebar + frame.** In `MainWindowView.swift`:
  - Delete the brand heading — the `sidebar` computed property loses the `VStack` + `Text("PulsarTrace")` wrapper and becomes the bare `List(AppSection.allCases, selection: sidebarSelection) { ... }` (§3: deliberately brandless in-content; the per-pane `.navigationTitle` stays).
  - `.frame(minWidth: 640, minHeight: 420)` → `.frame(minWidth: 800, minHeight: 420)`.

  In `PulsarTraceMacApp.swift`: `.defaultSize(width: 760, height: 480)` → `.defaultSize(width: 900, height: 560)` on the main window (the Live Transcript window's size is untouched).

- [ ] **Step 4: Fix the stale comment** in `AppEnvironment.swift:183` — "before this change polling only ran while RefinementsListView was visible" → "before this change polling only ran while the (since-deleted) Refinements pane was visible".

- [ ] **Step 5: Verify nothing references the dead case.** `grep -rn "refinements\|RefinementsListView" Sources Tests` → zero hits (case-sensitive variants too). `swift build` → succeeds. `swift test --filter MenuBar` → PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(ui)!: fold Refinements pane into Recordings; brandless sidebar; window 800 min / 900x560 default (spec §3, §7)"
```

---

### Task 10: Speakers pane consistency sweep (§8)

**Files:**
- Modify: `Sources/pulsartrace-mac/SpeakerEditorView.swift`

- [ ] **Step 1: Selection model.** Add `@State private var selection: Set<String> = []` and bind the speakers `List(selection: $selection)`. Rows get `.tag(speaker.id)`.

- [ ] **Step 2: Toolbar Merge/Split.** In the existing `.toolbar` (after the `RecordToolbarButton` from Task 8) add:

```swift
            ToolbarItem {
                Button("Merge") { startMerge(viewModel) }
                    .disabled(selection.count != 2)
                    .help("Merge the two selected speakers")
            }
            ToolbarItem {
                Button("Split") { startSplit(viewModel) }
                    .disabled(selection.count != 1)
                    .help("Split a recording's lines out of the selected speaker")
            }
```

Re-seed the sheet starters from the selection (sheet pickers stay editable — which one to keep is still an explicit choice):

```swift
    private func startMerge(_ viewModel: SpeakerEditorViewModel) {
        let selected = viewModel.liveSpeakers.filter { selection.contains($0.id) }
        mergePrimaryId = selected.first?.id ?? viewModel.liveSpeakers.first?.id
        mergeOtherId = selected.dropFirst().first?.id
            ?? viewModel.liveSpeakers.dropFirst().first?.id
        showMerge = true
    }

    private func startSplit(_ viewModel: SpeakerEditorViewModel) {
        splitOriginalId = viewModel.liveSpeakers
            .first { selection.contains($0.id) }?.id
            ?? viewModel.liveSpeakers.first?.id
        splitNewName = ""
        splitSelectedRecordingIds = []
        showSplit = true
    }
```

If the view previously exposed Merge/Split through other buttons (e.g. per-row context menu), keep those entry points — the toolbar adds the selection-seeded path.

- [ ] **Step 3: Banners move off the content.** Replace

```swift
.overlay(alignment: .top) { errorBanner(viewModel) }
.overlay(alignment: .bottom) { undoBanner(viewModel) }
```

with

```swift
.safeAreaInset(edge: .top, spacing: 0) { errorBanner(viewModel) }
.safeAreaInset(edge: .bottom, spacing: 0) { undoBanner(viewModel) }
```

and give both banner builders a transition + animation hook: inside `errorBanner`, on the outer `HStack`, add `.transition(.move(edge: .top).combined(with: .opacity))`; wrap the conditional content in a `Group` carrying `.animation(.default, value: viewModel.lastError)`. Same for `undoBanner` with `.move(edge: .bottom)` and `value: viewModel.undoToast != nil` (use a `Bool` value — `UndoToast` need not be `Equatable`).

- [ ] **Step 4: Sheets get min sizes.** Merge sheet: `.frame(width: 320)` → `.frame(minWidth: 320, minHeight: 180)`. Split sheet: `.frame(width: 380)` → `.frame(minWidth: 380, minHeight: 320)` (its recordings picker keeps `.frame(height: 160)` → change to `.frame(minHeight: 160)`).

- [ ] **Step 5: Rename survives navigation.** Keep the double-click `.onTapGesture(count: 2)`… actually switch it to the same `simultaneousGesture(TapGesture(count: 2))` form used by the recordings list (consistency + selection coexistence — the list is now selection-driven). Add `.onDisappear { commitPendingSpeakerRename(viewModel) }` near the List:

```swift
    /// §6 planning note: navigating away (Record button → Recordings) must
    /// not silently discard an in-progress rename — commit it like Save.
    private func commitPendingSpeakerRename(_ viewModel: SpeakerEditorViewModel) {
        guard let id = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty else { return }
        Task { await viewModel.rename(speakerId: id, to: name) }
    }
```

- [ ] **Step 6: Run.** `swift build` → succeeds. `swift test --filter Speaker` → PASS. `swift test --filter MenuBar` → PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(ui): speakers pane — multi-select with seeded Merge/Split, inset banners with transitions, resizable sheets (spec §8)"
```

---

### Task 11: Menubar hover colors + Settings polish (§8)

**Files:**
- Modify: `Sources/pulsartrace-mac/MenuBarMenuView.swift:213-244`, `Sources/pulsartrace-mac/SettingsView.swift:82-91`

- [ ] **Step 1: Hover colors.** In `MenuRowButtonStyle.MenuRow`:

```swift
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(highlighted
                            ? Color(nsColor: .selectedContentBackgroundColor)
                            : .clear))
```

```swift
        private func foreground(highlighted: Bool) -> Color {
            if !isEnabled { return .secondary }
            return highlighted
                ? Color(nsColor: .selectedMenuItemTextColor)
                : .primary
        }
```

- [ ] **Step 2: Settings output row.** Wrap in `LabeledContent`:

```swift
            Section("Output") {
                LabeledContent("Location") {
                    HStack {
                        Text(settings.outputFolderURL?.path ?? "No folder chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseOutputFolder() }
                    }
                }
            }
```

- [ ] **Step 3: Build, test, commit.** `swift build` → succeeds. `swift test --filter MenuBar` → PASS.

```bash
git add -A
git commit -m "fix(ui): accent-correct menubar hover colors; Settings output row gets LabeledContent (spec §8)"
```

---

### Task 12: Full verification, changelog, QA guide, PR

- [ ] **Step 1: Full verification battery.** Each bare with dangerouslyDisableSandbox, ALL must pass:
`swift build` · `swift test --filter UnitTests` · `swift test --filter MenuBar` · `swift test --filter Refinement` · `swift test --filter Streaming` · `swift test --filter Transcription` · `swift test --filter LiveRunner` · `swift test --filter FinalMarkdownRewriter` · `swift test --filter Speaker` · `swift test --filter Lifecycle`
Any failure: fix or explicitly gate per CLAUDE.md before proceeding.

- [ ] **Step 2: Final consistency greps.**
`grep -rn "(provisional)" Sources Tests README.md docs/file-format.md project-docs/PRD.md` → zero hits.
`grep -rn "RecordedTranscriptSheet\|RefinementsListView\|RecordingsListView" Sources Tests` → zero hits.

- [ ] **Step 3: CHANGELOG.** Append under the Unreleased/top section of `CHANGELOG.md`, matching the existing prose style:

```markdown
### Changed

- The main window's Recordings pane is now a master–detail split: the transcript of the selected recording — including the one being recorded right now — renders in the window, with day-grouped sections, an inline filter, rename (double-click), Move to Trash, and a resizable divider that persists across launches.
- A Record/Stop button lives in the window toolbar on every pane; pressing it jumps to the live transcript. Hotkey-started recordings no longer move your selection.
- The Refinements pane is gone — refinement status lives on recording rows and the transcript detail's banner (queued/refining with Cancel, completion with "Show refined transcript", failures with Retry).
- **Breaking (file format):** live transcripts mark provisional speakers with a compact `?` suffix (`Them?`, `Steve?`) instead of `(provisional)`. `final.md` is unchanged; previously recorded `live.md` files keep the old marker until refined.
- One transcript renderer everywhere: cross-line selection now works in recorded transcripts, ⌘F opens find-in-transcript, and Copy copies the rendered text (not raw Markdown).
```

- [ ] **Step 4: Write the manual QA guide** to `docs/qa/2026-06-10-main-window-ux-overhaul-qa.md` (create the `docs/qa/` directory). Content: the §11 manual GUI smoke list expanded into numbered click-through steps with expected results (build via `scripts/make-dev-app.sh`, open `.build/PulsarTrace.app`). Cover: record → live detail streams with `Them?` labels → stop → row settles queued→refining→completion banner → "Show refined transcript"; filter field; day groups; double-click rename (recording + speaker, selection must not glitch); Move to Trash + ⌫; speakers ⌘-click multi-select → Merge seeded; ⌘F find; divider drag + relaunch persistence; all three empty states; hotkey-start-while-reading (selection must not move); menubar hover under a non-blue accent color; window min-size resize behavior; Copy yields rendered text.

- [ ] **Step 5: Commit, push, open the PR.**

```bash
git add -A
git commit -m "docs: changelog + manual QA guide for the main-window UX overhaul"
git push -u origin feat/main-window-ux-overhaul
```

PR via the GitHub API (gh CLI fails in-sandbox — use curl with `gh auth token --user mt-krainski`): title "Main window UX overhaul — master–detail recordings, in-window live transcript, queue folding"; body summarizes the spec sections, the breaking `?` format change, the verification filters run, and links `docs/specs/2026-06-10-main-window-ux-overhaul-design.md` + the QA guide.

---

## Self-review notes (already applied)

- Spec coverage checked section-by-section: §3 (Task 9 + 7), §4.1 (Tasks 2-4, 7), §4.2 (Tasks 5, 7), §5 (Tasks 1, 6), §6 (Task 8), §7 (Task 9), §8 (Tasks 10-11), §10 error handling (Tasks 4, 5, 7, 8), §11 testing (Tasks 1-5, 12), §12 open questions (id unification pinned in Task 3; ⌘F wired explicitly in Task 6; double-click/selection via `simultaneousGesture` in Task 7).
- Type-consistency pass: `RecordingRow.Badge` cases used by `RecordingBadgeView` match Task 3/4 definitions; `TranscriptDetailModel.Content/.Banner` cases match Task 7's switches; `friendlyFailure` is the single humanizer shared by both models.
- Known judgment calls for the implementer: `@Bindable var paneModel` requires `RecordingsPaneModel` to be `@Observable` (it is); if `ContentUnavailableView.search(text:)` reads oddly in a list column, a plain `Text("No matches")` centered is acceptable (§4.1 names an inline "No matches" placeholder); if `simultaneousGesture` proves to also fire on rapid selection clicks of two different rows, gate `beginRename` on `navigation.selectedRecordingID == row.id`.

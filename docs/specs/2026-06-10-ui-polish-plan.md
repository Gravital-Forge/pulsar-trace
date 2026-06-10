# UI/UX Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the menubar app from "works but reads like a CRUD debug tool" to native-feeling macOS polish: styled transcripts, friendly titles, a glanceable menubar icon, completion notifications, no guaranteed first-run failure, native list interactions, confirmations for file-rewriting operations, honest busy/toast/banner state, a working hotkey recorder, and an accessibility pass.

**Architecture:** All new *logic* (parser, formatters, notification content, defaults) lives in `PulsarTraceMenuBar` and is TDD'd in `Tests/MenuBarTests` (the `pulsartrace-mac` executable has no test target by design, D27). Views consume that logic. No engine/public-API changes.

**Tech Stack:** SwiftUI (macOS 14 min — `symbolEffect(.pulse)` OK, `.rotate` is NOT available), AppKit (NSTextView path, NSEvent recorder), UserNotifications (bundle-guarded), Swift Testing.

---

## Build/test commands (CLAUDE.md rules)

- `swift build` / `swift test --filter X` BARE (no pipes/;/&&/redirects) with `dangerouslyDisableSandbox: true`. Everything else plain.
- Narrow filters only — for this plan mostly `MenuBar` (+ `UnitTests` for regressions). NEVER broad `PipelineTests`, NEVER `WhisperSubprocessAcceptance` (wedges under this harness).
- Manual GUI smoke (`scripts/make-dev-app.sh`) is deferred to branch finish — note it, don't attempt to drive a GUI.

## Locked facts from research (don't rediscover)

- Transcript line shape (live AND final, byte-stable, tests pin it): `**[HH:MM:SS] Speaker:** text`; header lines: `<!-- pulsartrace:live|final -->`, `## Transcript — yyyy-MM-dd HH:mm`, blank. NO parser exists anywhere — write one.
- `TranscriptView` paths: static sheet = `ScrollView { Text(lines.joined()) }` (lines ~30-39); live = `LiveScrollableTranscript` NSViewRepresentable setting `textView.string` (~92+). Content arrives as `[String]` lines.
- `RecordingEntry.recordingStart: Date` is always populated (metadata ISO-8601, or folder-name parse). Title today = `displayName` = folder basename.
- `RecordingStatus.recording(id:, startedAt: Date)` carries the start time; `MenuBarExtra label:` closure can read `environment.recording.status` AND can read `environment.queueVM` (it's in the App struct's scope — the research note about injection only concerns `.environment(...)` of the content).
- `RefinementJobQueueViewModel.onJobsTerminated: (@MainActor @Sendable ([RefinementJob]) -> Void)?` fires with terminal jobs; `RefinementJobState`: `.completed(durationSeconds: Double, speakerCount: Int)`, `.failed(errorClass: String, retryAvailable: Bool)`, `.cancelled`. Zero UserNotifications usage today. UN APIs CRASH in non-bundled processes — every UN call must be behind `Bundle.main.bundleIdentifier != nil`.
- `PermissionChecker` (PulsarTraceCapture, reachable from PulsarTraceMenuBar): `requestMicrophoneIfNeeded() async -> Bool`, `screenRecordingGranted() async -> Bool`. The TCC-race KNOWN ISSUE comment sits in `RecordingViewModel.swift` ~198-204.
- `MenuBarSettings.outputFolderPath: String?` defaults nil → first record fails with "Choose an output folder in Settings first." (RecordingViewModel ~169-173). `SecureFiles.createDirectoryPrivateIfNew` exists (security plan) for lazy creation.
- Button strips: RecordingsListView row ~70-109 (View/Reveal/Refine), SpeakerEditorView rows ~244-268 (Rename/Don't recognize/Delete). No `.contextMenu` anywhere.
- `SpeakerEditorViewModel.appearances(ofSpeaker:) async -> [SpeakerAppearance]` exists (count = recordings affected). `isRewriting` is set/cleared in `withRewrite` but NO view reads it. `undoToast` never auto-dismisses. `lastEnqueueError` clears only on next successful enqueue.
- `KeyCombo { keyCode: UInt16, modifiers: UInt }` JSON-in-UserDefaults; SettingsView shows `"Hotkey set (key N)"`; `HotkeyController.install` is one-shot (no re-install on change) and matches `[.command,.control,.option,.shift]`-masked modifiers.
- Accessibility: ONE `.accessibilityLabel` in the app (TranscriptView:287). `RefineStatusIcon` uses `.help()` only. Pills encode kind by color only. `MenuRowButtonStyle` is hover-only.
- MenuBarTests conventions: Swift Testing, `@MainActor` suites, throwaway `UserDefaults(suiteName: "pt-X-\(UUID())")`, `MenuBarFixtures.tempDir()`, stub protocols.

Tasks 1–4 are logic-heavy (strict TDD). Tasks 5–11 are view wiring verified by build + MenuBar suite + the new logic tests.

---

### Task 1: Transcript parser + styled rendering

**Files:**
- Create: `Sources/PulsarTraceMenuBar/TranscriptLine.swift`
- Create: `Tests/MenuBarTests/TranscriptLineTests.swift`
- Modify: `Sources/pulsartrace-mac/TranscriptView.swift` (both render paths)

- [ ] **Step 1: failing tests** — `Tests/MenuBarTests/TranscriptLineTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceMenuBar

/// Parser for the stable `**[HH:MM:SS] Speaker:** text` transcript line
/// shape (live.md/final.md public contract — docs/file-format.md).
@Suite("TranscriptLine parser")
struct TranscriptLineTests {

    @Test("an utterance line parses into timestamp, speaker, text")
    func utterance() {
        let kind = TranscriptLine.parse("**[00:01:23] Steve:** hello there")
        #expect(kind == .utterance(timestamp: "00:01:23", speaker: "Steve", text: "hello there"))
    }

    @Test("a provisional live label keeps its suffix in the speaker field")
    func provisionalSpeaker() {
        let kind = TranscriptLine.parse("**[00:00:05] Them (provisional):** hi")
        #expect(kind == .utterance(timestamp: "00:00:05", speaker: "Them (provisional)", text: "hi"))
    }

    @Test("speaker names containing colons survive (greedy up to the last ':**')")
    func colonInSpeaker() {
        let kind = TranscriptLine.parse("**[00:00:05] Dr. Who: The Second:** text")
        #expect(kind == .utterance(timestamp: "00:00:05", speaker: "Dr. Who: The Second", text: "text"))
    }

    @Test("the document marker is recognized")
    func marker() {
        #expect(TranscriptLine.parse("<!-- pulsartrace:final -->") == .marker)
        #expect(TranscriptLine.parse("<!-- pulsartrace:live -->") == .marker)
    }

    @Test("the H2 header is recognized with its text")
    func header() {
        #expect(TranscriptLine.parse("## Transcript — 2026-05-16 14:30")
            == .header("Transcript — 2026-05-16 14:30"))
    }

    @Test("blank and unrecognized lines fall through")
    func fallthroughs() {
        #expect(TranscriptLine.parse("") == .blank)
        #expect(TranscriptLine.parse("   ") == .blank)
        #expect(TranscriptLine.parse("not a transcript line") == .plain("not a transcript line"))
        #expect(TranscriptLine.parse("**[bad] Steve:** x") == .plain("**[bad] Steve:** x"))
    }

    @Test("empty utterance text is allowed")
    func emptyText() {
        let kind = TranscriptLine.parse("**[00:00:01] You:** ")
        #expect(kind == .utterance(timestamp: "00:00:01", speaker: "You", text: ""))
    }
}
```
Run bare: `swift test --filter TranscriptLine` — compile failure expected.

- [ ] **Step 2: implement** — `Sources/PulsarTraceMenuBar/TranscriptLine.swift`:

```swift
import Foundation

/// One parsed line of a `live.md`/`final.md` transcript. The utterance
/// shape (`**[HH:MM:SS] Speaker:** text`) is a public file-format
/// contract (docs/file-format.md), so this parser is deliberately
/// conservative: anything that doesn't match a known shape exactly is
/// passed through as `.plain` and rendered verbatim.
public enum TranscriptLine: Equatable, Sendable {
    case marker
    case header(String)
    case utterance(timestamp: String, speaker: String, text: String)
    case plain(String)
    case blank

    /// `**[HH:MM:SS] <speaker>:** <text>` — speaker is greedy up to the
    /// LAST `:**` so names containing colons survive.
    private static let utteranceRegex =
        /^\*\*\[(\d{2}:\d{2}:\d{2})\] (.+):\*\* (.*)$/

    public static func parse(_ line: String) -> TranscriptLine {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        if line.hasPrefix("<!-- pulsartrace:") { return .marker }
        if line.hasPrefix("## ") {
            return .header(String(line.dropFirst(3)))
        }
        if let match = line.wholeMatch(of: utteranceRegex) {
            return .utterance(
                timestamp: String(match.1),
                speaker: String(match.2),
                text: String(match.3))
        }
        return .plain(line)
    }
}
```
(Swift `.+` is greedy → matches up to the last `:**`; verify with the colon test.) Run bare: `swift test --filter TranscriptLine` — green; `swift test --filter MenuBar` — green.

- [ ] **Step 3: styled static path** — in `TranscriptView.swift`, replace the static `Text(lines.joined())` branch with:

```swift
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                    transcriptRow(raw)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

    @ViewBuilder
    private func transcriptRow(_ raw: String) -> some View {
        switch TranscriptLine.parse(raw) {
        case .utterance(let ts, let speaker, let text):
            (Text("[\(ts)] ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
             + Text("\(speaker)  ")
                .font(.callout.weight(.semibold))
             + Text(text)
                .font(.callout))
                .textSelection(.enabled)
        case .header(let title):
            Text(title).font(.headline).padding(.bottom, 2)
        case .plain(let s):
            Text(s).font(.callout).textSelection(.enabled)
        case .marker, .blank:
            EmptyView()
        }
    }
```
(Adapt names/structure to the file; keep the empty-state placeholder branch as is.)

- [ ] **Step 4: styled live path** — in the `LiveScrollableTranscript` NSViewRepresentable, replace `textView.string = lines.joined(...)` with an attributed build (keep all scrolling/selection logic untouched):

```swift
    private static func attributed(from lines: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let stamp: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let name: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        for raw in lines {
            switch TranscriptLine.parse(raw) {
            case .utterance(let ts, let speaker, let text):
                out.append(NSAttributedString(string: "[\(ts)] ", attributes: stamp))
                out.append(NSAttributedString(string: "\(speaker)  ", attributes: name))
                out.append(NSAttributedString(string: text + "\n", attributes: body))
            case .header(let title):
                out.append(NSAttributedString(string: title + "\n", attributes: name))
            case .plain(let s):
                out.append(NSAttributedString(string: s + "\n", attributes: body))
            case .marker, .blank:
                continue
            }
        }
        return out
    }
```
Apply via `textView.textStorage?.setAttributedString(...)` at the same call site that previously set `.string` (preserve the "only update when lines changed" logic if present). Semantic NSColors keep dark mode correct.

- [ ] **Step 5: verify + commit** — bare: `swift build` (zero new warnings), `swift test --filter MenuBar`, `swift test --filter UnitTests`. Commit:
```bash
git add Sources/PulsarTraceMenuBar/TranscriptLine.swift Tests/MenuBarTests/TranscriptLineTests.swift Sources/pulsartrace-mac/TranscriptView.swift
git commit -m "ui(transcripts): render styled rows instead of raw Markdown source in both sheet and live views"
```

---

### Task 2: Friendly recording titles

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/RecordingEntry.swift` (+ formatter)
- Create: `Tests/MenuBarTests/RecordingTitleTests.swift`
- Modify: `Sources/pulsartrace-mac/RecordingsListView.swift` (row + sheet header)

- [ ] **Step 1: failing tests**:

```swift
import Foundation
import Testing
@testable import PulsarTraceMenuBar

@Suite("RecordingEntry.displayTitle")
struct RecordingTitleTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }

    @Test("a recording from today reads 'Today at <time>'")
    func today() {
        let now = Date()
        let title = RecordingEntry.displayTitle(for: now, relativeTo: now)
        #expect(title.hasPrefix("Today at "))
    }

    @Test("an older recording reads like 'May 16, 2026 at 2:30 PM' (locale-formatted)")
    func older() {
        let start = date(2026, 5, 16, 14, 30)
        let ref = date(2026, 6, 10, 9, 0)
        let title = RecordingEntry.displayTitle(for: start, relativeTo: ref)
        #expect(!title.hasPrefix("Today"))
        #expect(title.contains("2026"))
    }
}
```

- [ ] **Step 2: implement** — on `RecordingEntry`:

```swift
    /// Human title for a recording — "Today at 2:30 PM" / "Yesterday at …" /
    /// "May 16, 2026 at 2:30 PM". The folder basename stays available as
    /// `displayName` (secondary text / tooltips / Reveal).
    public var displayTitle: String {
        Self.displayTitle(for: recordingStart, relativeTo: Date())
    }

    /// Injectable-now variant for deterministic tests.
    public static func displayTitle(for start: Date, relativeTo now: Date) -> String {
        let cal = Calendar.current
        let time = start.formatted(date: .omitted, time: .shortened)
        if cal.isDate(start, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(start, inSameDayAs: yesterday) { return "Yesterday at \(time)" }
        return start.formatted(date: .abbreviated, time: .shortened)
    }
```

- [ ] **Step 3: use it** — `RecordingsListView` row: `Text(recording.displayTitle)` with `.help(recording.displayName)`; sheet header likewise (`Text(recording.displayTitle).font(.headline)`).
- [ ] **Step 4: verify + commit** — bare `swift test --filter RecordingTitle`, then `--filter MenuBar`. Commit `ui(recordings): friendly date titles; folder basename demoted to tooltip`.

---

### Task 3: Glanceable menubar icon (red recording tint + timer, pulsing refine state)

**Files:**
- Modify: `Sources/pulsartrace-mac/PulsarTraceMacApp.swift` (MenuBarExtra label + menuBarSymbol extension)

No new VM logic (status + queueVM already expose everything) → no new tests; MenuBar suite guards regressions.

- [ ] **Step 1: label view** — replace `Image(systemName: environment.recording.status.menuBarSymbol)` with a small private `MenuBarLabel` view in the same file:

```swift
private struct MenuBarLabel: View {
    let status: RecordingStatus
    let isRefining: Bool

    var body: some View {
        switch status {
        case .recording(_, let startedAt):
            // Red waveform + elapsed time — unambiguous "live" state (R40).
            HStack(spacing: 3) {
                Image(systemName: "waveform.badge.microphone")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.red, Color.primary)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(timerString(from: startedAt, to: context.date))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .accessibilityLabel("PulsarTrace, recording")
        case .launching:
            Image(systemName: "waveform.badge.plus")
                .accessibilityLabel("PulsarTrace, starting recording")
        case .crashed, .error:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel("PulsarTrace, needs attention")
        case .idle:
            Image(systemName: isRefining ? "arrow.triangle.2.circlepath" : "waveform")
                .symbolEffect(.pulse, isActive: isRefining)
                .accessibilityLabel(isRefining
                    ? "PulsarTrace, refining a transcript"
                    : "PulsarTrace, idle")
        }
    }

    private func timerString(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
```
Wire: `label: { MenuBarLabel(status: environment.recording.status, isRefining: environment.queueVM.running != nil) }` — check the actual queueVM API for "a job is running" (`running`, `snapshot().running`, or similar — read RefinementJobQueueViewModel and use what exists; if only a polled snapshot exists, add a tiny computed `var isRefining: Bool` to the VM, trivially covered by the existing VM tests' fixtures... if that needs new test code, add one test case following the suite's conventions).
NOTE: MenuBarExtra labels are rendered as template images by default; the red palette color may require `.menuBarExtraStyle` interplay — if the red tint doesn't survive (template rendering), fall back to the timer text alone as the recording signal plus the badge symbol, and SAY SO in your report rather than fighting AppKit.
- [ ] **Step 2: delete the now-unused `menuBarSymbol` extension** (or keep it if MenuBarMenuView reuses it — grep first).
- [ ] **Step 3: verify + commit** — bare `swift build`, `swift test --filter MenuBar`. Commit `ui(menubar): state-distinct icon — red+timer while recording, pulse while refining (R40)`.

---

### Task 4: Refinement completion/failure notifications

**Files:**
- Create: `Sources/PulsarTraceMenuBar/RefinementNotification.swift` (content builder — pure, TDD)
- Create: `Tests/MenuBarTests/RefinementNotificationTests.swift`
- Modify: `Sources/PulsarTraceMenuBar/AppEnvironment.swift` (wire into onJobsTerminated + provisional auth at bootstrap)

- [ ] **Step 1: failing tests**:

```swift
import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@Suite("RefinementNotification content")
struct RefinementNotificationTests {
    // Build RefinementJob fixtures the way RefinementJobQueueViewModelTests does —
    // read that file and reuse its job-construction helpers/idioms.

    @Test("a completed job yields a 'Transcript ready' notification with duration and speakers")
    func completed() {
        let n = RefinementNotification.from(job: completedJob(duration: 2520, speakers: 3,
                                                              start: .init(timeIntervalSince1970: 1_750_000_000)))
        let unwrapped = try? #require(n)
        #expect(unwrapped?.title == "Transcript ready")
        #expect(unwrapped?.body.contains("3 speakers") == true)
        #expect(unwrapped?.body.contains("42 min") == true)
    }

    @Test("one speaker is singular")
    func singular() {
        let n = RefinementNotification.from(job: completedJob(duration: 60, speakers: 1, start: Date()))
        #expect(n?.body.contains("1 speaker,") == true)
    }

    @Test("a failed job yields a failure notification naming no internals")
    func failed() {
        let n = RefinementNotification.from(job: failedJob(errorClass: "model_load_failed"))
        let unwrapped = try? #require(n)
        #expect(unwrapped?.title == "Refinement failed")
        #expect(unwrapped?.body.contains("model_load_failed") == false)  // no raw error classes at the user
    }

    @Test("a cancelled job yields no notification")
    func cancelled() {
        #expect(RefinementNotification.from(job: cancelledJob()) == nil)
    }
}
```
(Adapt fixture helpers to the real `RefinementJob` initializer — copy from RefinementJobQueueViewModelTests.)

- [ ] **Step 2: implement**:

```swift
import Foundation
import PulsarTraceEngine

/// User-facing notification content for a terminal refinement job.
/// Pure data — the UN delivery lives separately so this is testable
/// and the UN dependency stays bundle-guarded.
public struct RefinementNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let folderURL: URL

    public static func from(job: RefinementJob) -> RefinementNotification? {
        switch job.state {
        case .completed(let durationSeconds, let speakerCount):
            let minutes = max(1, Int((durationSeconds / 60).rounded()))
            let speakers = speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers"
            return RefinementNotification(
                title: "Transcript ready",
                body: "\(speakers), \(minutes) min — \(RecordingEntry.displayTitle(for: job.recordingStart, relativeTo: Date()))",
                folderURL: job.folderURL)
        case .failed:
            return RefinementNotification(
                title: "Refinement failed",
                body: "A recording could not be refined. Open PulsarTrace to retry.",
                folderURL: job.folderURL)
        default:
            return nil
        }
    }
}
```
ADAPT: check what `RefinementJob` actually carries (folderURL? recordingStart? — read it; if there's no recordingStart on the job, drop the title-date suffix rather than inventing plumbing). `42 min` for 2520s: 2520/60 = 42 ✓.

- [ ] **Step 3: delivery + wiring** — in `AppEnvironment.bootstrap()` extend the existing `onJobsTerminated` closure (keep the scanner refresh):

```swift
        queueVM.onJobsTerminated = { [weak self] jobs in
            Task { [weak self] in await self?.scanner.refresh() }
            guard Bundle.main.bundleIdentifier != nil else { return }  // bare-binary dev runs: UN would crash
            for job in jobs {
                guard let content = RefinementNotification.from(job: job) else { continue }
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: {
                        let c = UNMutableNotificationContent()
                        c.title = content.title
                        c.body = content.body
                        return c
                    }(),
                    trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        }
```
Plus once in `bootstrap()` (same bundle guard): `try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .provisional])`. `import UserNotifications` at top. Keep ALL UN calls behind the bundle guard — running the bare `.build/debug/pulsartrace-mac` must not crash.

- [ ] **Step 4: verify + commit** — bare `swift test --filter RefinementNotification`, `--filter MenuBar`, `swift build`. Commit `ui(notifications): notify on refinement completion/failure (bundle-guarded, provisional auth)`.

---

### Task 5: Default output folder + permission preflight

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/MenuBarSettings.swift` (default), `Sources/PulsarTraceMenuBar/RecordingViewModel.swift` (preflight seam + use)
- Modify/Create tests: `Tests/MenuBarTests/MenuBarSettingsTests.swift` (default), `Tests/MenuBarTests/RecordingViewModelTests.swift` (preflight paths)

- [ ] **Step 1: failing tests** — (a) settings: a fresh suite's `outputFolderURL` is `~/Documents/PulsarTrace` (not nil); explicit user value still wins; (b) recording VM: a denied-mic preflight surfaces `.error` containing "Microphone" WITHOUT calling orchestrator.start; granted preflight proceeds (reuse `StubOrchestrator`). Write them following the existing suites' patterns; the VM needs an injectable seam:

```swift
    /// Permission preflight seam — production uses PermissionChecker;
    /// tests inject canned outcomes.
    public struct PermissionPreflight: Sendable {
        public var microphone: @Sendable () async -> Bool
        public var screenRecording: @Sendable () async -> Bool
        public init(microphone: @escaping @Sendable () async -> Bool,
                    screenRecording: @escaping @Sendable () async -> Bool) { … }
        public static var live: PermissionPreflight {
            PermissionPreflight(
                microphone: { await PermissionChecker.requestMicrophoneIfNeeded() },
                screenRecording: { await PermissionChecker.screenRecordingGranted() })
        }
    }
```
(Check PermissionChecker's real spelling — static vs instance — and adapt. Add `preflight: PermissionPreflight = .live` to RecordingViewModel's init with a default so existing tests/wiring stay source-compatible.)

- [ ] **Step 2: implement** —
(a) `MenuBarSettings`: where `outputFolderPath` is loaded/read, default nil → `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("PulsarTrace").path`. Decide placement: make `outputFolderURL` fall back to the default (don't write it into UserDefaults — a user clearing it should re-default). Document in the property comment.
(b) `RecordingViewModel.startRecording`: after the output-folder guard (which now effectively always passes), BEFORE `orchestrator.start`/pause wiring:
```swift
        guard await preflight.microphone() else {
            status = .error(message: "Microphone access is required. Grant it in System Settings → Privacy & Security → Microphone, then try again.")
            progressMessage = ""
            return
        }
        if settings.captureSystemAudio {   // check the real property name
            guard await preflight.screenRecording() else {
                status = .error(message: "System-audio capture needs Screen Recording permission. Grant it in System Settings → Privacy & Security → Screen Recording, then try again.")
                progressMessage = ""
                return
            }
        }
```
(c) Ensure the default folder is created lazily at record start with `SecureFiles.createDirectoryPrivateIfNew` — check whether RecordingViewModel already creates the output dir (it does, ~line 179 per the security sweep) — if so nothing more is needed; confirm.
(d) Update the KNOWN ISSUE comment (~198-204): the race is now mitigated by the preflight; rewrite the comment to say the wizard remains future work but mic/screen grants are now requested up front.

- [ ] **Step 3: verify + commit** — bare `swift test --filter MenuBar` (all suites; the settings-default change may break existing tests that assert nil default — UPDATE those tests' expectations deliberately and note it: this is an intentional product change, not a snapshot-fix). Commit `ui(recording): default output folder + mic/screen permission preflight — first run can no longer fail by default`.

---

### Task 6: Native list interactions (context menus, double-click, kill the button strips)

**Files:**
- Modify: `Sources/pulsartrace-mac/RecordingsListView.swift`, `Sources/pulsartrace-mac/SpeakerEditorView.swift`

- [ ] **Step 1: recordings rows** — remove the View/Reveal/Refine button strip; row becomes:
```swift
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewing = recording }
        .contextMenu {
            Button("View Transcript") { viewing = recording }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.folderURL])
            }
            Divider()
            Button("Refine") { Task { await queueVM.enqueueManual(…same args…) } }
                .disabled(jobInFlight(recording.id))
        }
```
Keep ONE quiet affordance so the primary action is discoverable: a trailing `Button { viewing = recording } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).foregroundStyle(.secondary)` with `.accessibilityLabel("View transcript")`.
- [ ] **Step 2: speaker rows** — remove Rename/Don't recognize/Delete strip; double-click starts rename (`renameText = …; renameTarget = …`), context menu:
```swift
        .contextMenu {
            Button("Rename") { renameText = speaker.name; renameTarget = speaker.id }
            if speaker.name != "You" {
                Button("Don't Recognize This Speaker") { pendingDelist = speaker }  // Task 7 wires the confirmation
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await viewModel.delete(speakerId: speaker.id) } }
        }
```
(If Task 7 isn't merged yet when you do this, call the VM directly and let Task 7 swap in the confirmation — tasks land in order, so wire `pendingDelist` only if Task 7's state already exists; otherwise keep the direct call and Task 7 will adjust.) Keep the inline rename TextField branch exactly as is.
- [ ] **Step 3: verify + commit** — bare `swift build`, `swift test --filter MenuBar`. Commit `ui(lists): context menus + double-click replace always-visible button strips`.

---

### Task 7: Confirmation dialogs with rewrite counts (merge, delist)

**Files:**
- Modify: `Sources/pulsartrace-mac/SpeakerEditorView.swift`

- [ ] **Step 1** — add state + dialogs. For DELIST: `@State private var pendingDelist: Speaker?` and `@State private var pendingDelistCount: Int = 0`; the context-menu item sets it after fetching the count:
```swift
            Button("Don't Recognize This Speaker") {
                Task {
                    pendingDelistCount = await viewModel.appearances(ofSpeaker: speaker.id).count
                    pendingDelist = speaker
                }
            }
```
Dialog (on the List):
```swift
        .confirmationDialog(
            "Stop recognizing \(pendingDelist?.name ?? "")?",
            isPresented: Binding(get: { pendingDelist != nil },
                                 set: { if !$0 { pendingDelist = nil } })
        ) {
            Button("Stop Recognizing", role: .destructive) {
                if let s = pendingDelist { Task { await viewModel.delist(speakerId: s.id) } }
                pendingDelist = nil
            }
        } message: {
            Text(pendingDelistCount == 0
                 ? "Their lines become “Unrecognized”. Undoable for 30 days."
                 : "\(pendingDelistCount) recording\(pendingDelistCount == 1 ? "" : "s") will be rewritten. Their lines become “Unrecognized”. Undoable for 30 days.")
        }
```
For MERGE: in the merge sheet, before performing, fetch `appearances(ofSpeaker: mergeOtherId).count` and change the Merge button to set a `pendingMergeCount`/`showMergeConfirm` pair with an equivalent confirmationDialog: "Merge ‘X’ into ‘Y’? N recordings will be rewritten." Proceed on confirm. (Names: resolve from the VM's speaker list.) Delete stays one-click + undo toast (it rewrites nothing — locked decision from the review).
- [ ] **Step 2: verify + commit** — bare `swift build`, `swift test --filter MenuBar`. Commit `ui(speakers): confirmation dialogs with rewrite counts for merge and delist`.

---

### Task 8: Honest busy/toast/banner state

**Files:**
- Modify: `Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift` (toast auto-dismiss), `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift` (dismiss API), `Sources/pulsartrace-mac/SpeakerEditorView.swift` (isRewriting gate + banner ✕), `Sources/pulsartrace-mac/RecordingsListView.swift` (banner ✕)
- Test: extend `Tests/MenuBarTests/SpeakerEditorViewModelTests.swift`

- [ ] **Step 1: failing test** — toast auto-dismiss:
```swift
    @Test("the undo toast auto-dismisses after its lifetime")
    func toastAutoDismisses() async throws {
        // construct VM per the suite's pattern, with a SHORT toastLifetime
        // injected (add `toastLifetime: Duration = .seconds(8)` to the VM init)
        // delete a speaker → toast != nil
        // wait past the lifetime (Task.sleep) → toast == nil
        // and: a second delete REPLACES the toast and restarts the clock.
    }
```
Write it concretely against the real suite helpers (read the file; it has full delete fixtures). Keep the sleep bounded (e.g. lifetime .milliseconds(80), poll up to 2 s).
- [ ] **Step 2: implement** — VM: `private var toastDismissTask: Task<Void, Never>?`; whenever `undoToast` is set, cancel the old task and start `toastDismissTask = Task { try? await Task.sleep(for: toastLifetime); if !Task.isCancelled { undoToast = nil } }`; cancel it when the user taps Undo (existing path sets undoToast = nil — cancel there too). `toastLifetime` injected via init default `.seconds(8)`.
- [ ] **Step 3: views** — SpeakerEditorView: `.disabled(viewModel.isRewriting)` on the speaker `List` + a thin `ProgressView().controlSize(.small)` next to the toolbar while `isRewriting`; error banner gains a trailing ✕ (`Button { viewModel.clearError() }` — add `public func clearError() { lastError = nil }` to the VM). RecordingsListView banner: same ✕ calling a new `public func clearEnqueueError()` on RefinementJobQueueViewModel. While in the banners: fix contrast (Task 10 overlaps — do it here): replace white-on-orange/white-on-red with `.foregroundStyle(.primary)` on `.orange.opacity(0.2)` / `.red.opacity(0.2)` backgrounds with a matching border (`RoundedRectangle.stroke`).
- [ ] **Step 4: verify + commit** — bare `swift test --filter SpeakerEditorViewModel`, `--filter MenuBar`. Commit `ui(state): isRewriting gates the editor, toasts auto-dismiss, banners dismissible with accessible contrast`.

---

### Task 9: Hotkey recorder in Settings

**Files:**
- Create: `Sources/PulsarTraceMenuBar/KeyComboFormatter.swift` (TDD)
- Create: `Tests/MenuBarTests/KeyComboFormatterTests.swift`
- Create: `Sources/pulsartrace-mac/HotkeyRecorderField.swift` (NSViewRepresentable)
- Modify: `Sources/pulsartrace-mac/SettingsView.swift` (recorder UI), `Sources/pulsartrace-mac/PulsarTraceMacApp.swift` (re-install on change)

- [ ] **Step 1: failing tests** — display string for KeyCombo:
```swift
import Foundation
import AppKit
import Testing
@testable import PulsarTraceMenuBar

@Suite("KeyComboFormatter")
struct KeyComboFormatterTests {
    @Test("⇧⌘R renders with canonical modifier order")
    func cmdShiftR() {
        let combo = KeyCombo(
            keyCode: 15,  // kVK_ANSI_R
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        #expect(KeyComboFormatter.displayString(for: combo) == "⇧⌘R")
    }

    @Test("all four modifiers render in ⌃⌥⇧⌘ order")
    func allModifiers() {
        let combo = KeyCombo(
            keyCode: 15,
            modifiers: NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue)
        #expect(KeyComboFormatter.displayString(for: combo) == "⌃⌥⇧⌘R")
    }

    @Test("an unmapped key code falls back to 'key N'")
    func unmapped() {
        let combo = KeyCombo(keyCode: 999, modifiers: 0)
        #expect(KeyComboFormatter.displayString(for: combo) == "key 999")
    }
}
```
Canonical macOS modifier order is Control, Option, Shift, Command — glyphs ⌃ ⌥ ⇧ ⌘, appended in exactly that order.
- [ ] **Step 2: implement** — `KeyComboFormatter.displayString(for:)`: modifier glyphs in ⌃⌥⇧⌘ order + key name from a static `[UInt16: String]` table covering letters (kVK_ANSI_A…Z), digits, Space("Space"), Return("↩"), Tab("⇥"), Escape("⎋"), arrows ("←→↑↓"), F-keys ("F1"–"F12"); unmapped → `"key \(code)"`. (UCKeyTranslate is overkill — a table matches the codebase's pragmatism; note the limitation in a comment.) PulsarTraceMenuBar may `import AppKit` for ModifierFlags? It currently avoids AppKit-monitor code but `NSEvent.ModifierFlags` is just an OptionSet on UInt — to keep the no-AppKit posture, define the modifier masks as raw constants (`controlKeyMask: UInt = 1 << 18` etc.? NO — fragile). DECISION: put the formatter in PulsarTraceMenuBar but `import AppKit` for `NSEvent.ModifierFlags` only (the target already links AppKit transitively via PulsarTraceCapture; using value-level flag constants is not "AppKit monitor code"). Note this in the type's doc comment.
- [ ] **Step 3: recorder field** — `HotkeyRecorderField: NSViewRepresentable` wrapping a focusable NSView whose `keyDown` captures `event.keyCode` + masked modifiers into a `@Binding var combo: KeyCombo?`; click to focus ("Type shortcut…"), Escape cancels, Delete clears. ~60 lines; visual: rounded-rect border, shows `KeyComboFormatter.displayString` or placeholder.
- [ ] **Step 4: SettingsView** — Shortcut section becomes the recorder + a Clear button; binding writes `settings.globalHotkey`.
- [ ] **Step 5: re-install on change** — in `PulsarTraceMacApp`, on the MenuBarExtra content (always alive): `.onChange(of: environment.settings.globalHotkey) { hotkey.install(settings: environment.settings, recording: environment.recording) }` (install already removes the old monitor first — verified).
- [ ] **Step 6: verify + commit** — bare `swift test --filter KeyComboFormatter`, `--filter MenuBar`, `swift build`. Commit `ui(settings): hotkey recorder with ⌃⌥⇧⌘ glyph display; monitor re-installs on change (R41)`.

---

### Task 10: Accessibility pass

**Files:**
- Modify: `Sources/pulsartrace-mac/RecordingsListView.swift` (RefineStatusIcon), `Sources/pulsartrace-mac/SpeakerPillsView.swift`, `Sources/pulsartrace-mac/MenuBarMenuView.swift`

- [ ] **Step 1** — `RefineStatusIcon.icon(...)`: add `.accessibilityLabel(help)` (mirror the existing help strings — they're already user-quality).
- [ ] **Step 2** — pills: `.accessibilityLabel("\(speaker.label), \(kindDescription)")` where kindDescription = "microphone" / "unnamed speaker" / "known speaker" matching the existing color logic — non-color channel for the kind.
- [ ] **Step 3** — MenuBarMenuView: `.keyboardShortcut("q")` on Quit; show the configured hotkey next to Start/Stop Recording (`Text(KeyComboFormatter.displayString(for: combo)).foregroundStyle(.secondary)` when `settings.globalHotkey != nil`); MenuRowButtonStyle: also highlight on keyboard focus — give the row `@Environment(\.isFocused)`? ButtonStyle labels don't receive focus; pragmatic fix: add `.focusable()` to the buttons and accept the standard macOS focus ring (do NOT build a custom focus system; if the ring renders acceptably, ship it; report what you saw). Menubar icon labels were added in Task 3.
- [ ] **Step 4: verify + commit** — bare `swift build`, `swift test --filter MenuBar`. Commit `ui(a11y): labels for status icons and pills, Quit shortcut, hotkey hint, focusable menu rows`.

---

### Task 11: Dropdown progress + retry affordance

**Files:**
- Modify: `Sources/pulsartrace-mac/MenuBarMenuView.swift` (determinate progress), `Sources/pulsartrace-mac/RefinementsListView.swift` (Retry button)

- [ ] **Step 1** — MenuBarMenuView: where the status line composes "Refining 42% · Diarizing", add beneath it (when a job is running) `ProgressView(value: fraction)` + caption with the stage name — the fraction already exists (`RefinementJobState.progressFraction` or via queueVM; read the current status-line code ~93-123 and reuse its data source). Width-capped to the panel, `.controlSize(.small)`.
- [ ] **Step 2** — RefinementsListView: on `.failed(_, retryAvailable: true)` rows, a `Button("Retry") { Task { await queueVM.enqueueManual(…) } }` — read what identifiers the row has (folderURL/recordingId/model) and reuse the same enqueue path the recordings list uses; ALSO humanize the failure line: replace `"Failed (\(errorClass))"` with `"Failed — \(friendly)"` where friendly maps known error classes ("model_load_failed" → "the model could not be loaded", default → "an internal error"); keep the raw class in `.help()` for diagnosis.
- [ ] **Step 3: verify + commit** — bare `swift build`, `swift test --filter MenuBar`. Commit `ui(refinements): determinate progress in the dropdown; retry button and humanized failure copy`.

---

### Task 12: Full verification sweep

- [ ] Run in order, each bare with dangerouslyDisableSandbox, all green: `UnitTests`, `MenuBar`, `Refinement`, `IPC`, `LiveRunner`, `Streaming`, `Transcription`, `Speaker`, `Source`, `Lifecycle`, `FinalMarkdownRewriter`, `RecordOrchestrator`.
- [ ] `swift build` — zero warnings.
- [ ] `git status --short` — clean tracked tree.
- [ ] Note for the human: GUI changes need the manual smoke test (`scripts/make-dev-app.sh`, docs/release-smoke-test.md) — flag it in the final report; do not attempt to drive the GUI.

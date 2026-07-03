import XCTest
import PulsarTraceMenuBar
import PulsarTraceEngine

/// The speaker-editor flow (PT-P7-R4; smoke-checklist "speaker rename retroactive
/// rewrite") driven through the real Speakers pane against the pre-seeded state
/// (PT-P7-D6). Renaming a speaker mutates the library AND retroactively rewrites
/// every past `final.md` that named them (PT-P1-D16), leaving a backup sibling
/// per rewritten folder, and emits the cause (`speaker_renamed`) BEFORE its
/// effects (`final_md_rewritten`, one per rewritten recording) — Hard Invariant
/// #8. This is also the first empirical exercise of the speaker-editor AX
/// bridges: the floor suite only proved the rows render; this suite is the first
/// to drive the inline rename field and assert what it does on disk.
///
/// The pane is reached through the shared `openMainWindow(_:section:)` in
/// `PanelDriver.swift` — the opener can `throw XCTSkip` via the status-item gate,
/// so it runs at the START of each test method (not in `setUp`), mirroring the
/// sibling suites; `setUp` owns only the launch.
///
/// PT-P7-E3-T4 will extend this same file with a merge + undo-toast round-trip —
/// hence `setUp`/`tearDown` and the `openSpeakers()` helper are factored so a
/// second test method reuses them.
// PT-P7-R4
final class SpeakerFlowTests: XCTestCase {

    private var seed: SeededHome!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        seed = try await SeededHome.make()
        app = XCUIApplication()
        app.launchEnvironment.merge(
            seed.launchEnvironment, uniquingKeysWith: { _, new in new })
        app.launch()
    }

    override func tearDown() {
        // On failure, copy the seed home's final.md/.bak/events/logs out BEFORE
        // the seed is purged — this suite's failure modes (a rewrite that didn't
        // land, a missing backup, an out-of-order event log) are diagnosable
        // only from that throwaway state (PT-P7-R4). Done before the app is
        // terminated so a hung main thread's state is captured as-is.
        if (testRun?.totalFailureCount ?? 0) > 0, let seed {
            let dir = preserveSeedDiagnostics(seed, label: "SpeakerFlow")
            print("PT-DIAG preserved failure evidence at "
                + "\(dir?.path ?? "<none>")")
        }
        // Terminate the app before purging the seed (nil-safe — either may be
        // unset if setUp threw before assigning it), matching the sibling suites.
        app?.terminate()
        seed?.tearDown()
    }

    func testRenameRewritesAllPastFinalMarkdown() throws {
        // Open the Speakers pane here (not in setUp): the shared opener can skip
        // the run via the status-item gate, and that skip must attribute to the
        // test, not to setUp.
        try openSpeakers()

        // Locate Alice by her stable seed-time id — the row identifier keys on
        // `spk_<ulid>`, which the rename leaves unchanged, so we never look the
        // row up by (mutating) display name (PT-P7-R3).
        let aliceId = try XCTUnwrap(seed.speakerIds["Alice"], "Alice not seeded")
        let row = app.descendants(matching: .any)[A11yID.Speakers.row(aliceId)]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "seeded speaker Alice not rendered")

        // Empirical AX (this suite is the first to drive the rename): the editor
        // exposes TWO ways into inline-rename — a `TapGesture(count: 2)` on the
        // row and a context-menu "Rename" item. The double-click gesture does
        // NOT arm reliably under XCUITest: the SwiftUI `.simultaneousGesture`
        // races the List's native NSTableView click handling (the row's own
        // source comments flag this same "NSHostingView-eats-mouseDown" race),
        // so `row.doubleClick()` lands on the table, the gesture never fires, and
        // no rename field appears. The context menu is deterministic: right-click
        // the row, then click "Rename", located by its identifier
        // (`A11yID.Speakers.renameButton`, PT-P7-R3) — this is also the first
        // proof that a SwiftUI `.contextMenu` Button's `.accessibilityIdentifier`
        // propagates to the AX menu item, which is how the merge flow (T4) will
        // locate `mergeButton`/`mergeTarget`.
        row.rightClick()
        let renameItem = app.menuItems[A11yID.Speakers.renameButton]
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5),
                      "Rename context-menu item did not surface on right-click")
        renameItem.click()

        // The rename `TextField` now replaces the row's name and auto-focuses
        // with its text selected. While it is up, the row exposes the
        // `renameField` identifier (SpeakerEditorView swaps the row id for it in
        // rename mode so the field's id is not shadowed by the row id). Select-
        // all defensively, type the new name, and submit with Return (the
        // field's `.onSubmit` commits like Save).
        // `.firstMatch`: while renaming, both the collapsed row and the inner
        // TextField can legitimately carry `renameField` on some macOS AX shapes;
        // they are the same control, so taking the first is safe.
        let field = app.descendants(matching: .any)[A11yID.Speakers.renameField]
            .firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "inline rename field did not surface after Rename")
        field.click()
        field.typeKey("a", modifierFlags: .command)   // select-all
        field.typeText("Alicia\r")                     // \r → Return → commit

        // The retroactive rewrite runs briefly off the main actor; poll the
        // on-disk artifacts, never a spinner. Each seeded `final.md` names Alice
        // in a `**[HH:MM:SS] Alice:**` utterance label, so the rewrite turns
        // that label into `Alicia:**`. ("Alice:**" is NOT a substring of
        // "Alicia:**" — after "Alice" comes "ia", not ":**" — so the two needles
        // cleanly distinguish the old and new labels.)
        for folder in SeededHome.recordingFolders {
            let folderURL = seed.outputRoot.appendingPathComponent(folder)
            let finalURL = folderURL.appendingPathComponent(
                RecordingFolder.FileName.final)
            // Return the settled text from the probe (and read it `try?`-tolerant
            // so a transient read during the atomic write keeps polling rather
            // than aborting), then run the negative assert on that same snapshot
            // instead of re-reading — no second read to race the rewrite.
            let text = try poll(timeout: 30, message: "rewrite of \(folder)") {
                () -> String? in
                guard let text = try? String(contentsOf: finalURL, encoding: .utf8)
                else { return nil }
                return text.contains("Alicia:**") ? text : nil
            }
            XCTAssertFalse(text.contains("Alice:**"),
                           "\(folder) still carries the old speaker label")

            // Backup sibling: `FinalMarkdownRewriter.rewriteFolder` copies the
            // prior `final.md` to `final.md.bak` (RecordingFolder.FileName
            // .finalBackup) before its atomic write — an exact filename, not a
            // loose `*.bak` glob.
            let backupURL = folderURL.appendingPathComponent(
                RecordingFolder.FileName.finalBackup)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: backupURL.path),
                "no final.md.bak backup left in \(folder)")
        }

        // Cause before effect (Hard Invariant #8): `SpeakerEditService.rename`
        // appends the `speaker_renamed` cause, THEN one `final_md_rewritten` per
        // rewritten recording. Those appends (an actor hop + a file write each)
        // complete AFTER the disk rewrite the polls above already observed, so
        // poll the log — a single read here can catch it before the lines land.
        // `eventTypes` returns raw type strings in file order, matched exactly
        // against the pinned event-type constants.
        let types = try poll(timeout: 10, message: "rename events flushed") {
            let t = try eventTypes(home: seed.home)
            return t.contains(SpeakerRenamedEvent.eventType)
                && t.filter { $0 == FinalMDRewrittenEvent.eventType }.count >= 2
                ? t : nil
        }
        let renameIdx = try XCTUnwrap(
            types.firstIndex(of: SpeakerRenamedEvent.eventType),
            "no \(SpeakerRenamedEvent.eventType) event")
        let rewrites = types.indices.filter {
            types[$0] == FinalMDRewrittenEvent.eventType && $0 > renameIdx
        }
        // Alice appears in both seeded recordings, both of which name her, so the
        // rename rewrites exactly two `final.md` files — two effects, all after
        // the cause. Seeding writes the fixtures directly (no rewriter), so no
        // stray `final_md_rewritten` precedes the rename.
        XCTAssertEqual(rewrites.count, 2,
            "expected one \(FinalMDRewrittenEvent.eventType) per rewritten "
            + "recording, all after the \(SpeakerRenamedEvent.eventType) cause")
        XCTAssertEqual(
            types.filter { $0 == FinalMDRewrittenEvent.eventType }.count, 2,
            "a \(FinalMDRewrittenEvent.eventType) fired outside the rename cause")

        // The pane reflects the rename — the row (still keyed on the unchanged
        // id) now shows the new name. Uses the shared tolerant check because the
        // List can merge a row into a single AX element (PanelDriver
        // .assertRowShowsName), so `row.staticTexts["Alicia"]` alone is fragile.
        try poll(timeout: 10, message: "pane reflects the rename") {
            rowShowsName(row, "Alicia") ? true : nil
        }
        assertRowShowsName(row, "Alicia")
    }

    // MARK: - Navigation

    /// Open the main window at the Speakers pane via the shared panel-driven
    /// opener (`PanelDriver.openMainWindow`). Factored for PT-P7-E3-T4's merge
    /// test, which opens the same pane.
    private func openSpeakers() throws {
        try openMainWindow(app, section: A11yID.MenuBar.openSpeakers)
    }
}

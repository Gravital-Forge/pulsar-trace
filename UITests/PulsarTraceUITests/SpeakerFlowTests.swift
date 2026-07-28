import XCTest
import PulsarTraceMenuBar
import PulsarTraceEngine

/// The speaker-editor flow (PT-R129; smoke-checklist "speaker rename retroactive
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
// PT-R129
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
        // only from that throwaway state (PT-R129). Done before the app is
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
        // row up by (mutating) display name (PT-R128).
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
        // (`A11yID.Speakers.renameButton`, PT-R128) — this is also the first
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

    /// PT-P7-E3-T4 — the merge half of the smoke-checklist round-trip: fold Carol
    /// INTO Alice through the context-menu "Merge With" submenu and its
    /// `confirmationDialog`, then assert the retroactive `final.md` rewrite and
    /// cause-before-effect ordering (Hard Invariant #8). The undo half is the
    /// separate round-trip test below
    /// (`testMergeUndoRoundTripRestoresLibraryAndTranscript`).
    ///
    /// This is the first live drive of three speaker-editor AX bridges, all
    /// verified working on macOS 26.5: the `mergeButton` submenu, its
    /// `mergeTarget(_:)` items, and — the last unverified bridge in the registry
    /// — the `confirmationDialog`'s `mergeConfirm` button.
    func testMergeConfirmationRewritesTranscriptAndLogsCauseBeforeEffect() throws {
        // Open the Speakers pane here (not in setUp): the shared opener can skip
        // the run via the status-item gate, and that skip must attribute to the
        // test, not to setUp.
        try openSpeakers()

        // Merge direction (verified against `SpeakerEditorView` +
        // `SpeakerEditService`, NOT the task skeleton, which picked the operands
        // backwards). The context menu acts on the RIGHT-CLICKED speaker, who
        // SURVIVES: the view stages `PendingMerge(primaryId: <right-clicked>,
        // otherId: <submenu pick>)`, and `SpeakerEditService.merge` rewrites the
        // OTHER's label to the PRIMARY's (`oldName: otherName → newName:
        // primaryName`) then soft-deletes the other. So to fold Carol INTO Alice
        // — Carol vanishes, Alice survives — right-click ALICE (primary) and pick
        // Carol from "Merge With" (other). `mergeTarget(id)`'s `id` is the
        // folded-in speaker (Carol), matching the A11yID doc comment.
        let aliceId = try XCTUnwrap(seed.speakerIds["Alice"], "Alice not seeded")
        let carolId = try XCTUnwrap(seed.speakerIds["Carol"], "Carol not seeded")
        let aliceRow = app.descendants(matching: .any)[A11yID.Speakers.row(aliceId)]
        XCTAssertTrue(aliceRow.waitForExistence(timeout: 10),
                      "seeded speaker Alice not rendered")

        try mergeCarolIntoAlice(survivorRow: aliceRow, absorbedId: carolId)

        // Retroactive rewrite lands on the SECOND seeded recording (Carol's only
        // appearance). Poll the settled text `try?`-tolerant (a transient read
        // during the atomic write keeps polling), then negative-assert on that
        // same snapshot. Carol's ABSENCE is the real signal: Alice already had a
        // line in this file before the merge, so "Alice:**" present alone proves
        // nothing — but "Carol:**" gone means her label was folded into Alice.
        let merged = try waitForMergeRewrite()
        XCTAssertFalse(merged.contains("Carol:**"),
                       "recording 2 still labels the merged-away Carol")

        // Cause before effect (Hard Invariant #8): `speaker_merged` precedes its
        // `final_md_rewritten`. The appends are an actor hop + file write each, so
        // they land AFTER the disk rewrite the poll above observed — poll the log.
        let types = try poll(timeout: 10, message: "merge events flushed") {
            let t = try eventTypes(home: seed.home)
            return t.contains(SpeakerMergedEvent.eventType)
                && t.contains(FinalMDRewrittenEvent.eventType) ? t : nil
        }
        let mergeIdx = try XCTUnwrap(
            types.firstIndex(of: SpeakerMergedEvent.eventType),
            "no \(SpeakerMergedEvent.eventType) event")
        let rewrites = types.indices.filter {
            types[$0] == FinalMDRewrittenEvent.eventType && $0 > mergeIdx
        }
        // Carol appears only in recording 2, so the merge rewrites exactly one
        // `final.md` — one effect, after the cause. Recording 1 (no Carol) is not
        // rewritten. Seeding writes the fixtures directly (no rewriter), so no
        // stray `final_md_rewritten` precedes the merge.
        XCTAssertEqual(rewrites.count, 1,
            "merge should rewrite exactly recording 2 (Carol's only appearance) "
            + "after the \(SpeakerMergedEvent.eventType) cause")
        XCTAssertEqual(
            types.filter { $0 == FinalMDRewrittenEvent.eventType }.count, 1,
            "a \(FinalMDRewrittenEvent.eventType) fired outside the merge cause")
    }

    /// PT-P7-E3-T4 second AC — the undo round-trip. Now that
    /// `SpeakerEditorViewModel.merge` surfaces an undo toast whose action runs
    /// `unmerge` (PT-R32b; mirroring `delete`/`delist`), the full round-trip is
    /// exercised end to end: confirm the merge, assert the `undoButton` renders
    /// in the ~8 s toast window, click it, and verify it restores both the
    /// library (Carol's row returns) and the transcript (recording 2 rewritten
    /// back from Alice to Carol), with `speaker_unmerged` logged before its
    /// paired `final_md_rewritten` (Hard Invariant #8). This matches the smoke
    /// checklist (`docs/release-smoke-test.md`, "Speaker merge … the undo toast
    /// … restores both the library and the transcripts").
    func testMergeUndoRoundTripRestoresLibraryAndTranscript() throws {
        try openSpeakers()
        let aliceId = try XCTUnwrap(seed.speakerIds["Alice"], "Alice not seeded")
        let carolId = try XCTUnwrap(seed.speakerIds["Carol"], "Carol not seeded")
        let aliceRow = app.descendants(matching: .any)[A11yID.Speakers.row(aliceId)]
        XCTAssertTrue(aliceRow.waitForExistence(timeout: 10),
                      "seeded speaker Alice not rendered")
        try mergeCarolIntoAlice(survivorRow: aliceRow, absorbedId: carolId)

        // Toast-window ordering (T4 correction #3): the undo toast lives only
        // ~8 s, so assert it is UP FIRST — a cheap AX check right after confirm,
        // before any disk poll that could outlive the toast.
        let undo = app.descendants(matching: .any)[A11yID.Speakers.undoButton]
        XCTAssertTrue(undo.waitForExistence(timeout: 8),
                      "merge undo toast did not appear after confirming the merge")

        // Wait for the merge rewrite to land (returns as soon as the ms–s write
        // completes, well within the toast window), then undo.
        _ = try waitForMergeRewrite()
        undo.click()

        // The library is restored: Carol's row (keyed on her unchanged id, which
        // the merge soft-deleted and the undo un-deletes) returns to the live
        // list.
        let carolRow = app.descendants(matching: .any)[A11yID.Speakers.row(carolId)]
        XCTAssertTrue(carolRow.waitForExistence(timeout: 10),
                      "Carol's row did not return after undo")

        // The transcript is restored: recording 2 is rewritten back from Alice to
        // Carol (solo lines round-trip; PT-R44 undo).
        let secondFinal = seed.outputRoot
            .appendingPathComponent(SeededHome.recordingFolders[1])
            .appendingPathComponent(RecordingFolder.FileName.final)
        try poll(timeout: 30, message: "undo rewrite restores Carol") {
            () -> String? in
            guard let text = try? String(contentsOf: secondFinal, encoding: .utf8)
            else { return nil }
            return text.contains("Carol:**") ? text : nil
        }

        // Cause before effect (Hard Invariant #8): the undo's `speaker_unmerged`
        // precedes its `final_md_rewritten`. Tighten to the merge test's
        // discipline: exactly one rewrite after the unmerge cause, and exactly
        // two total by now (the merge's + the undo's, both on recording 2).
        let types = try poll(timeout: 10, message: "unmerge events flushed") {
            let t = try eventTypes(home: seed.home)
            return t.contains(SpeakerUnmergedEvent.eventType)
                && t.filter { $0 == FinalMDRewrittenEvent.eventType }.count >= 2
                ? t : nil
        }
        let unmergeIdx = try XCTUnwrap(
            types.firstIndex(of: SpeakerUnmergedEvent.eventType),
            "no \(SpeakerUnmergedEvent.eventType) event")
        let rewritesAfterUnmerge = types.indices.filter {
            types[$0] == FinalMDRewrittenEvent.eventType && $0 > unmergeIdx
        }
        XCTAssertEqual(rewritesAfterUnmerge.count, 1,
            "expected exactly one \(FinalMDRewrittenEvent.eventType) after the "
            + "\(SpeakerUnmergedEvent.eventType) undo cause (Hard Invariant #8)")
        XCTAssertEqual(
            types.filter { $0 == FinalMDRewrittenEvent.eventType }.count, 2,
            "expected exactly two \(FinalMDRewrittenEvent.eventType) total "
            + "(the merge's and the undo's, both on recording 2)")
    }

    // MARK: - Navigation

    /// Open the main window at the Speakers pane via the shared panel-driven
    /// opener (`PanelDriver.openMainWindow`). Factored for PT-P7-E3-T4's merge
    /// test, which opens the same pane.
    private func openSpeakers() throws {
        try openMainWindow(app, section: A11yID.MenuBar.openSpeakers)
    }

    // MARK: - Merge driver

    /// Fold the `absorbedId` speaker INTO the one shown in `survivorRow`, through
    /// the context menu → "Merge With" submenu → `confirmationDialog`. Shared by
    /// both merge tests so the driving is identical.
    ///
    /// Empirical AX shape (verified live on macOS 26.5, PT-P7-E3-T4 — this is the
    /// first suite to drive the merge bridges):
    /// - Context menus are the reliable affordance under XCUITest (T3 proved
    ///   double-click gestures do not arm): right-click the survivor row.
    /// - "Merge With" is a SwiftUI `Menu` (submenu); its per-target items are its
    ///   children. Both carry their `.accessibilityIdentifier` directly on the AX
    ///   menu items (as `renameButton` did in T3). Opening the submenu is a plain
    ///   `.click()` on the parent menu item, then `.click()` on the child target.
    /// - The `confirmationDialog`'s "Merge" button carries `mergeConfirm` and
    ///   surfaces directly by identifier — the last previously-unverified AX
    ///   bridge in the registry, now confirmed working. Located tolerantly
    ///   (`descendants`) since a confirmationDialog can render its buttons as
    ///   `.button` or `.menuItem` across macOS versions.
    /// Poll recording 2's `final.md` until the merge rewrite has settled —
    /// Alice's label present, the merged-away Carol's gone — and return the
    /// settled text. Both merge tests probe the same "Alice present, Carol
    /// absent" condition on the same file, so it lives here once. The read is
    /// `try?`-tolerant: a transient read during the atomic write keeps polling
    /// rather than aborting.
    private func waitForMergeRewrite() throws -> String {
        let secondFinal = seed.outputRoot
            .appendingPathComponent(SeededHome.recordingFolders[1])
            .appendingPathComponent(RecordingFolder.FileName.final)
        return try poll(timeout: 30, message: "merge rewrite of recording 2") {
            () -> String? in
            guard let text = try? String(contentsOf: secondFinal, encoding: .utf8)
            else { return nil }
            return text.contains("Alice:**") && !text.contains("Carol:**")
                ? text : nil
        }
    }

    private func mergeCarolIntoAlice(
        survivorRow: XCUIElement, absorbedId: String
    ) throws {
        survivorRow.rightClick()

        let mergeMenu = app.menuItems[A11yID.Speakers.mergeButton]
        XCTAssertTrue(mergeMenu.waitForExistence(timeout: 5),
                      "Merge With submenu did not surface on right-click")
        mergeMenu.click()

        let target = app.menuItems[A11yID.Speakers.mergeTarget(absorbedId)]
        XCTAssertTrue(target.waitForExistence(timeout: 5),
                      "merge target did not surface under Merge With")
        target.click()

        let confirm = app.descendants(matching: .any)[A11yID.Speakers.mergeConfirm]
            .firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "merge confirmation button did not surface")

        // The dialog states the rewrite count before the user commits
        // (SpeakerEditorView message: "…N recording(s) will be rewritten."). Carol
        // appears in exactly one seeded recording, so the copy reads "1 recording".
        // Assert on that count-bearing substring, not the full copy, to stay robust
        // to wording; the LOCATOR for the button (mergeConfirm) is what pins the
        // affordance, this is a content-only check.
        //
        // Empirically (macOS 26.5): the SwiftUI confirmationDialog surfaces as an AX
        // Sheet (label 'alert') attached to the Speakers window, and its message is
        // a StaticText sibling of the confirm button whose text lives in the `value`
        // attribute — the `label` is EMPTY. So match value-OR-label (mirroring
        // `fieldShows`) and scope to the sheet that contains the button, rather than
        // an app-level `label CONTAINS` reach that never sees the value.
        let dialog = app.sheets.firstMatch
        let countText = dialog.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                        "1 recording", "1 recording")).firstMatch
        XCTAssertTrue(countText.waitForExistence(timeout: 5),
                      "merge confirmation did not state the rewrite count")

        confirm.click()
    }
}

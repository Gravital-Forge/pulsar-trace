import XCTest
import PulsarTraceMenuBar

/// The PT-P7-R4 floor: every idle-reachable surface opens and renders the
/// seeded state — menubar panel, Recordings, Speakers, Settings; the run never
/// touches daily state (PT-P7-R9). The live-transcript window (recording-only
/// affordance) is asserted by the PT-P7-E3 record flow instead.
///
/// Every surface is reached through the menubar status-item panel (the app's
/// only entry point — the two `Window` scenes open only from the panel). The
/// suite therefore begins each test by opening that panel. On a session where
/// macOS cannot place the status item on-screen (a frontmost full-screen app
/// hiding the menu bar, a full menu bar, or a non-primary/secondary-display
/// session), the item exists in the accessibility tree but is not hittable;
/// `openPanel()` then `throw`s `XCTSkip` with the observed frame so the run is
/// explicitly gated rather than red (see the guard for the exact condition).
// PT-P7-R4
final class FloorTests: XCTestCase {

    private var seed: SeededHome!
    private var app: XCUIApplication!
    /// Real daily-state paths captured before launch → mtime.
    private var dailyState: [String: Date] = [:]

    /// Real daily-state paths the run must not touch (PT-P7-R9). The two
    /// directories are asserted unchanged; the production settings plist is
    /// advisory (a daily instance can rewrite it independently — see tearDown).
    private var realStatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/PulsarTrace",
            "\(home)/Library/Logs/PulsarTrace",
            productionPlistPath,
        ]
    }

    /// The production settings plist. A daily instance running alongside the
    /// test can legitimately rewrite it, so its mtime check is advisory.
    private var productionPlistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Preferences/com.gravitalforge.PulsarTrace.plist"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        for path in realStatePaths {
            if let attrs = try? FileManager.default
                .attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                dailyState[path] = mtime
            }
        }
        seed = try await SeededHome.make()
        app = XCUIApplication()
        app.launchEnvironment.merge(
            seed.launchEnvironment, uniquingKeysWith: { _, new in new })
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
        // Clean the seed BEFORE the mtime assertions: with
        // `continueAfterFailure = false` a failing assertion raises
        // immediately, and the seed's defaults-domain plist must never leak
        // (the OS reclaims the tmp tree but not the plist). Removing the
        // isolated home cannot affect the real-path mtimes below.
        seed?.tearDown()
        // PT-P7-R9: the run must not have touched any real daily-state path.
        // The app-under-test re-roots all of AppPaths + the settings suite via
        // PULSARTRACE_HOME / PULSARTRACE_DEFAULTS_SUITE (PT-P7-R1), so it never
        // writes to any of these. The two directories are asserted unchanged;
        // the production plist is advisory because a concurrent daily instance
        // (not the test) can rewrite it.
        for (path, before) in dailyState {
            let after = (try? FileManager.default
                .attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if path == productionPlistPath {
                if before != after {
                    print("PT-P7-R9 note: production plist mtime changed during "
                        + "the run (\(path)). The app-under-test writes only to "
                        + "the isolated override suite; this indicates a "
                        + "concurrent daily instance, not the test.")
                }
            } else {
                XCTAssertEqual(before, after,
                               "daily state was modified: \(path)")
            }
        }
    }

    // MARK: - Surface openers

    // `openPanel(_:)` and `openMainWindow(_:section:)` — the shared status-item
    // opener (with its on-screen skip gate) and the per-section main-window
    // opener — live in `PanelDriver.swift` (every suite drives surfaces through
    // the panel, so the openers are factored out).

    // MARK: - Tests

    func testMenubarPanelShowsRecordControl() throws {
        try openPanel(app)
        // PT-P7-R4: the always-present record control renders in the panel.
        XCTAssertTrue(app.buttons[A11yID.MenuBar.recordToggle]
            .waitForExistence(timeout: 5),
            "record toggle not rendered in the menubar panel")
        // Content-bearing: the panel's status line renders (reads "Ready" on a
        // seeded, idle home — no queued/running refinement).
        XCTAssertTrue(app.descendants(matching: .any)[A11yID.MenuBar.progressLabel]
            .waitForExistence(timeout: 5),
            "menubar status line not rendered")
    }

    func testRecordingsPaneRendersSeededRecordings() throws {
        try openMainWindow(app, section: A11yID.MenuBar.openRecordings)
        // The sidebar itself renders (PT-P7-R4): all three section entries.
        for id in [A11yID.Sidebar.recordings, A11yID.Sidebar.speakers,
                   A11yID.Sidebar.settings] {
            XCTAssertTrue(app.descendants(matching: .any)[id]
                .waitForExistence(timeout: 10), "sidebar entry missing: \(id)")
        }
        // Content-bearing (PT-P7-R4): every seeded recording folder renders as
        // a row keyed on its on-disk basename.
        for folder in SeededHome.recordingFolders {
            XCTAssertTrue(
                app.descendants(matching: .any)[A11yID.Recordings.row(folder)]
                    .waitForExistence(timeout: 10),
                "seeded recording \(folder) not rendered")
        }
    }

    func testSpeakersPaneRendersSeededLibrary() throws {
        try openMainWindow(app, section: A11yID.MenuBar.openSpeakers)
        // Content-bearing (PT-P7-R4): each seeded speaker renders as a row
        // (keyed on the stable id) that shows the speaker's name.
        for (name, id) in seed.speakerIds {
            let row = app.descendants(matching: .any)[A11yID.Speakers.row(id)]
            XCTAssertTrue(row.waitForExistence(timeout: 10),
                          "seeded speaker \(name) not rendered")
            assertRowShowsName(row, name)
        }
    }

    func testSettingsPaneRendersSeededValues() throws {
        try openMainWindow(app, section: A11yID.MenuBar.openSettings)
        for id in [A11yID.Settings.micPicker, A11yID.Settings.refineModelPicker,
                   A11yID.Settings.outputFolderField,
                   A11yID.Settings.systemAudioToggle,
                   A11yID.Settings.hotkeyRecorder, A11yID.Settings.mcpToggle] {
            XCTAssertTrue(app.descendants(matching: .any)[id]
                .waitForExistence(timeout: 10), "missing control: \(id)")
        }
        // Content-bearing (PT-P7-R4): the field shows the seeded output folder.
        let field = app.descendants(matching: .any)[A11yID.Settings.outputFolderField]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "output folder field not rendered")
        // Fallback needle is the seed home's unique `pt-ui-seed-<uuid>` path
        // component — "PulsarTrace" alone would also match a daily value and
        // mask a defaults-suite regression.
        XCTAssertTrue(fieldShows(field, seed.outputRoot.path)
            || fieldShows(field, seed.home.lastPathComponent),
            "seeded output folder not shown — value=\(String(describing: field.value)) "
            + "label=\(field.label)")
    }

    // The live-transcript window is NOT covered here: its only entry point is
    // the menubar panel row `openLiveTranscript`, which renders solely while a
    // recording is running — the idle floor cannot reach it without models and
    // a fixture session. The PT-P7-E3 record flow (which drives a real fixture
    // recording anyway) opens and asserts that window mid-recording instead.

    // MARK: - Helpers

    /// Assert a row surfaces the speaker's name — as a child staticText, or,
    /// when the List merges the row into a single element, in its label/value.
    private func assertRowShowsName(_ row: XCUIElement, _ name: String) {
        let shows = row.staticTexts[name].exists
            || row.label.contains(name)
            || (row.value as? String)?.contains(name) == true
        XCTAssertTrue(shows,
            "row does not show the name \(name) — label=\(row.label) "
            + "value=\(String(describing: row.value))")
    }
}

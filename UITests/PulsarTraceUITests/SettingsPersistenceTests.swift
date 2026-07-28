import XCTest
import PulsarTraceMenuBar

/// Settings persist across an app relaunch on the same isolated suite
/// (PT-R129; smoke-checklist "Settings persistence"). Changes a setting
/// through the real Settings pane, terminates the app, relaunches on the same
/// `SeededHome`, and reads the value back through the UI — proving the write
/// reached the override defaults suite and reloads on the next launch. The run
/// stays entirely on the seeded suite; it never touches the production suite
/// (PT-R134), since `PULSARTRACE_DEFAULTS_SUITE` re-roots every read/write.
// PT-R129
final class SettingsPersistenceTests: XCTestCase {

    private var seed: SeededHome!
    /// Reassigned across the relaunch — teardown terminates whichever instance
    /// is current (nil-safe if `setUp` threw before the first launch).
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        seed = try await SeededHome.make()
    }

    override func tearDown() {
        // Terminate the app before purging the seed (nil-safe — either may be
        // unset if setUp threw, and `app` is the most recent relaunch).
        app?.terminate()
        seed?.tearDown()
    }

    func testSystemAudioToggleSurvivesRelaunch() throws {
        // First launch: flip the seeded-on system-audio toggle off.
        app = launch()
        try openMainWindow(app, section: A11yID.MenuBar.openSettings)
        let toggle = app.descendants(matching: .any)[A11yID.Settings.systemAudioToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "system-audio toggle not rendered")
        XCTAssertEqual(toggleState(toggle), true,
                       "seeded system-audio toggle is not on at first launch")
        setToggle(toggle, to: false)
        XCTAssertEqual(toggleState(toggle), false,
                       "toggle did not flip off on click")

        // Relaunch on the SAME seeded suite — the off state must survive.
        app.terminate()
        app = launch()
        try openMainWindow(app, section: A11yID.MenuBar.openSettings)
        let after = app.descendants(matching: .any)[A11yID.Settings.systemAudioToggle]
        XCTAssertTrue(after.waitForExistence(timeout: 10),
                      "system-audio toggle not rendered after relaunch")
        XCTAssertEqual(toggleState(after), false,
                       "toggle did not survive the relaunch")

        // The seeded output folder still renders (the path survived; no
        // re-default to a production/home-default location).
        let field = app.descendants(matching: .any)[A11yID.Settings.outputFolderField]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "output folder field not rendered after relaunch")
        // Fallback needle is the seed home's unique `pt-ui-seed-<uuid>` path
        // component — "PulsarTrace" alone would also match a daily value and
        // mask a defaults-suite regression.
        XCTAssertTrue(fieldShows(field, seed.outputRoot.path)
            || fieldShows(field, seed.home.lastPathComponent),
            "seeded output folder not shown after relaunch — "
            + "value=\(String(describing: field.value)) label=\(field.label)")
    }

    // MARK: - Launch / navigation

    /// A fresh `XCUIApplication` bound to the seeded home + override suite. The
    /// same environment on every launch is what makes the relaunch read back
    /// exactly what the prior instance wrote.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(
            seed.launchEnvironment, uniquingKeysWith: { _, new in new })
        app.launch()
        return app
    }

    // The Settings pane is reached via the shared `openMainWindow(_:section:)`
    // in `PanelDriver.swift` — `openPanel` handles the status item (and skips
    // the run when it can't be placed on-screen).

    // MARK: - Toggle helpers

    /// A SwiftUI `Toggle`'s state as read through XCUITest. On this host the
    /// `.grouped` Form renders it as a `Switch` (elementType 40) whose `value`
    /// is a boxed `1`/`0`; the shape has shifted across macOS versions (String
    /// "1"/"0", boxed `Bool`, boxed `Int`), so stay tolerant of all three.
    private func toggleState(_ element: XCUIElement) -> Bool? {
        if let b = element.value as? Bool { return b }
        if let n = element.value as? Int { return n != 0 }
        if let s = element.value as? String {
            switch s.lowercased() {
            case "1", "true", "on": return true
            case "0", "false", "off": return false
            default: return nil
            }
        }
        return nil
    }

    /// Drive the toggle to `target` and wait for its state to settle. SwiftUI
    /// attaches the id to the control itself here (SettingsView notes "no
    /// container promotion"), so a click on the id-bearing element flips it —
    /// the locator stays identifier-based.
    private func setToggle(_ element: XCUIElement, to target: Bool) {
        guard let current = toggleState(element) else {
            XCTFail("unreadable toggle value: \(String(describing: element.value))")
            return
        }
        guard current != target else { return }
        element.click()
        XCTAssertTrue(waitToggle(element, becomes: target),
            "toggle did not settle to \(target) — "
            + "value=\(String(describing: element.value))")
    }

    /// Poll the toggle's state until it reaches `target` or a short deadline.
    private func waitToggle(_ element: XCUIElement, becomes target: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if toggleState(element) == target { return true }
            usleep(100_000)
        }
        return toggleState(element) == target
    }
}

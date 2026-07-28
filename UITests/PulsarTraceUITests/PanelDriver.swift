// PT-R129
import XCTest
import PulsarTraceMenuBar

/// Shared driver for the menubar status-item panel — the app's only entry point
/// (the `Window` scenes and the live-transcript window open only from it). Every
/// UI suite that reaches a surface begins by opening this panel, so the opener
/// (with its on-screen-placement skip gate) lives here once rather than being
/// copied per suite.
extension XCTestCase {

    /// Open the menubar status-item panel of `app`. Skips the test (explicitly
    /// gated) when the status item cannot be placed on-screen in this session.
    func openPanel(_ app: XCUIApplication) throws {
        let item = app.statusItems[A11yID.statusItem]
        XCTAssertTrue(item.waitForExistence(timeout: 15),
                      "status item never appeared")
        // Bring the accessory app forward and give macOS time to lay the item
        // into the visible menu bar. A freshly launched LSUIElement app, or one
        // launched into a session whose menu bar is occupied/hidden, parks its
        // status item off-screen (a large negative x) where it is not hittable.
        // When the frontmost app is full-screen the menu bar auto-hides and the
        // item is parked until the bar is revealed — so also nudge the pointer
        // to the very top edge of the screen each iteration, which drops the
        // menu bar (and the status item) into a visible, hittable position.
        app.activate()
        let topEdge = app.menuBars.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let deadline = Date().addingTimeInterval(15)
        while !item.isHittable && Date() < deadline {
            app.activate()
            topEdge.hover()
            usleep(300_000)
        }
        // PT-R129 gate: the panel is the only entry point to every surface, so
        // when the item can't be placed on-screen the whole floor is
        // unreachable. Skip (not fail) with the observed frame — re-running on
        // an interactive session with the menu bar visible and room for the
        // item resolves it with no code change.
        guard item.isHittable else {
            throw XCTSkip(
                "status item not placeable on-screen (frame \(item.frame)); the "
                + "menu bar is not presenting it — a frontmost full-screen app, "
                + "a full menu bar, or a secondary-display session. Every UI "
                + "suite drives surfaces through this item. Re-run on an "
                + "interactive session with the menu bar visible.")
        }
        item.click()
    }

    /// Open the main window at a specific pane via that pane's dedicated
    /// menubar opener (`Recordings…` / `Speakers…` / `Settings…`), each of
    /// which sets the sidebar section before opening the window. Shared because
    /// every window-reaching suite navigates identically — open the panel,
    /// click the per-section opener, wait for the window — so this panel-driven
    /// navigation lives here once rather than being copied per suite.
    func openMainWindow(_ app: XCUIApplication, section opener: String) throws {
        try openPanel(app)
        let button = app.buttons[opener]
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "menubar opener \(opener) not found")
        button.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "main window did not open")
    }

    /// Whether `field` surfaces `needle` in its value, its label, or a contained
    /// staticText. Shared because both the floor and settings-persistence suites
    /// assert that a seeded path is shown, and XCUITest renders the same field's
    /// text in any of those three places across macOS versions — so the tolerant
    /// three-way check lives here once rather than being copied per suite.
    func fieldShows(_ field: XCUIElement, _ needle: String) -> Bool {
        if (field.value as? String)?.contains(needle) == true { return true }
        if field.label.contains(needle) { return true }
        if field.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", needle)).count > 0 {
            return true
        }
        return false
    }

    /// Whether a row surfaces the speaker's name — as a child staticText, or,
    /// when the List merges the row into a single element, in its label/value.
    /// The tolerant three-way check lives here once because XCUITest renders a
    /// List row's text in any of those places across macOS versions; both the
    /// assert form and the speaker-flow suite's rename poll build on it.
    func rowShowsName(_ row: XCUIElement, _ name: String) -> Bool {
        row.staticTexts[name].exists
            || row.label.contains(name)
            || (row.value as? String)?.contains(name) == true
    }

    /// Assert a row surfaces the speaker's name — as a child staticText, or,
    /// when the List merges the row into a single element, in its label/value.
    /// Shared because both the floor suite (rows render the seeded names) and
    /// the speaker-flow suite (the pane reflects a rename) need the same
    /// tolerant three-way check.
    func assertRowShowsName(_ row: XCUIElement, _ name: String) {
        XCTAssertTrue(rowShowsName(row, name),
            "row does not show the name \(name) — label=\(row.label) "
            + "value=\(String(describing: row.value))")
    }
}

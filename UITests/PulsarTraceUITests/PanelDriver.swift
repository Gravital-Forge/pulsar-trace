// PT-P7-R4
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
        // PT-P7-R4 gate: the panel is the only entry point to every surface, so
        // when the item can't be placed on-screen the whole floor is
        // unreachable. Skip (not fail) with the observed frame — re-running on
        // an interactive session with the menu bar visible and room for the
        // item resolves it with no code change.
        guard item.isHittable else {
            throw XCTSkip(
                "status item not placeable on-screen (frame \(item.frame)); the "
                + "menu bar is not presenting it — a frontmost full-screen app, "
                + "a full menu bar, or a secondary-display session. The floor "
                + "suite drives every surface through this item. Re-run on an "
                + "interactive session with the menu bar visible.")
        }
        item.click()
    }
}

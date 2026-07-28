// PT-R130
import XCTest
import PulsarTraceMenuBar

/// Harness proof (PT-R130): the wrapper app launches on an isolated home
/// and surfaces its status item. Isolation only — no seeded state yet.
final class LaunchSmokeTests: XCTestCase {

    func testLaunchesIsolatedAndShowsStatusItem() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ui-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = XCUIApplication()
        app.launchEnvironment["PULSARTRACE_HOME"] = home.path            // PT-R126
        app.launchEnvironment["PULSARTRACE_DEFAULTS_SUITE"] =
            "com.gravitalforge.PulsarTrace.uitest.\(UUID().uuidString)"
        app.launch()
        defer { app.terminate() }

        // The MenuBarExtra label carries A11yID.statusItem (PT-R128) —
        // empirically proven to surface on `app.statusItems` directly, so no
        // firstMatch fallback (an id regression must fail, not degrade).
        XCTAssertTrue(app.statusItems[A11yID.statusItem]
            .waitForExistence(timeout: 15),
            "status item never appeared")
    }
}

// PT-P7-R5
import XCTest

/// Harness proof (PT-P7-R5): the wrapper app launches on an isolated home
/// and surfaces its status item. Isolation only — no seeded state yet.
final class LaunchSmokeTests: XCTestCase {

    func testLaunchesIsolatedAndShowsStatusItem() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ui-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = XCUIApplication()
        app.launchEnvironment["PULSARTRACE_HOME"] = home.path            // PT-P7-R1
        app.launchEnvironment["PULSARTRACE_DEFAULTS_SUITE"] =
            "com.gravitalforge.PulsarTrace.uitest.\(UUID().uuidString)"
        app.launch()
        defer { app.terminate() }

        // The MenuBarExtra label carries A11yID.statusItem (PT-P7-R3); fall
        // back to firstMatch if the identifier does not surface on the status
        // item itself on this macOS version — record which path passed.
        let byId = app.statusItems["pt.statusItem"]
        let item = byId.waitForExistence(timeout: 15)
            ? byId : app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15),
                      "status item never appeared")
    }
}

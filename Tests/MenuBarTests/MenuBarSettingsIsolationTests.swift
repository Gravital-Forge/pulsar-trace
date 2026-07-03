import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// Settings-side isolation (PT-P7-R1, PT-P7-R9).
@MainActor
@Suite("MenuBarSettings isolation")
struct MenuBarSettingsIsolationTests {

    @Test("defaults-suite override routes persistence to the named suite")
    func suiteOverride() {
        let suite = "com.gravitalforge.PulsarTrace.isolation-test-\(UUID().uuidString)"
        let overrides = EnvironmentOverrides(
            environment: ["PULSARTRACE_DEFAULTS_SUITE": suite])
        let settings = MenuBarSettings(overrides: overrides)
        settings.systemAudioEnabled = false

        let store = UserDefaults(suiteName: suite)
        #expect(store?.object(forKey: "systemAudioEnabled") as? Bool == false)
        // Never leak into the production suite from this test path.
        store?.removePersistentDomain(forName: suite)
    }

    @Test("fresh overridden suite has the safe E2E defaults")
    func safeDefaults() {
        let suite = "com.gravitalforge.PulsarTrace.isolation-test-\(UUID().uuidString)"
        let settings = MenuBarSettings(overrides: EnvironmentOverrides(
            environment: ["PULSARTRACE_DEFAULTS_SUITE": suite]))
        #expect(settings.globalHotkey == nil)      // PT-P7-R9
        #expect(settings.mcpServerEnabled == false) // PT-P7-R9
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test("default output folder follows the home override")
    func outputFolderFollowsHome() {
        let url = MenuBarSettings.defaultOutputFolderURL(
            overrides: EnvironmentOverrides(
                environment: ["PULSARTRACE_HOME": "/tmp/pt-e2e-home"]))
        #expect(url?.path == "/tmp/pt-e2e-home/Documents/PulsarTrace")
        let plain = MenuBarSettings.defaultOutputFolderURL(
            overrides: EnvironmentOverrides(environment: [:]))
        #expect(plain == FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PulsarTrace", isDirectory: true))
    }
}

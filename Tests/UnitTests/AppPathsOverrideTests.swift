import Testing
import Foundation
@testable import PulsarTraceEngine

/// Environment-driven re-rooting of the path choke points (PT-R126).
@Suite("AppPaths overrides")
struct AppPathsOverrideTests {

    private let overridden = EnvironmentOverrides(environment: [
        "PULSARTRACE_HOME": "/tmp/pt-e2e-home",
        "PULSARTRACE_MODELS_DIR": "/tmp/pt-shared-models",
    ])
    private let empty = EnvironmentOverrides(environment: [:])

    @Test("PULSARTRACE_HOME re-roots every AppPaths location")
    func homeOverride() {
        let paths = AppPaths.standard(overrides: overridden)
        let root = "/tmp/pt-e2e-home"
        #expect(paths.home.path == root)
        #expect(paths.applicationSupport.path.hasPrefix(root))
        #expect(paths.eventsDirectory.path.hasPrefix(root))
        #expect(paths.speakersDatabaseURL.path.hasPrefix(root))
        #expect(paths.mcpTokenURL.path.hasPrefix(root))
        #expect(paths.logDirectory.path.hasPrefix(root))
    }

    @Test("PULSARTRACE_MODELS_DIR re-points only the model store")
    func modelsOverride() {
        let paths = AppPaths.standard(overrides: overridden)
        #expect(paths.modelsCacheDirectory.path == "/tmp/pt-shared-models")
        // Without the models variable, the cache derives from home as before.
        let homeOnly = AppPaths.standard(overrides: EnvironmentOverrides(
            environment: ["PULSARTRACE_HOME": "/tmp/pt-e2e-home"]))
        #expect(homeOnly.modelsCacheDirectory.path
            == "/tmp/pt-e2e-home/Library/Caches/PulsarTrace/models")
    }

    @Test("no overrides — parity with the user home")
    func parity() {
        let paths = AppPaths.standard(overrides: empty)
        #expect(paths.home == FileManager.default.homeDirectoryForCurrentUser)
        #expect(paths.modelsCacheDirectory
            == paths.home.appendingPathComponent(
                "Library/Caches/PulsarTrace/models", isDirectory: true))
    }

    @Test("default output root honors the home override")
    func outputRoot() {
        #expect(OutputFolderRoots.defaultRoot(overrides: overridden).path
            == "/tmp/pt-e2e-home/Documents/PulsarTrace")
        #expect(OutputFolderRoots.defaultRoot(overrides: empty)
            == FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PulsarTrace", isDirectory: true))
    }
}

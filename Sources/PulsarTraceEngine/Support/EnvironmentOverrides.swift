import Foundation

/// The end-to-end test overrides (PT-P7-R1, PT-P7-R2).
///
/// E2E harnesses launch the app with these variables to redirect all mutable
/// state into an isolated root and to run recordings from committed fixture
/// WAVs instead of device capture. With no variables set every consumer
/// behaves exactly as before. All consumers read the one `current` value;
/// tests construct their own with an injected dictionary.
// PT-P7-R1
public struct EnvironmentOverrides: Sendable, Equatable {
    /// `PULSARTRACE_HOME` — re-roots every `AppPaths` location and the
    /// default output folder root.
    public let home: URL?
    /// `PULSARTRACE_DEFAULTS_SUITE` — substitutes the settings suite.
    public let defaultsSuite: String?
    /// `PULSARTRACE_MODELS_DIR` — points the model store at an existing
    /// cache (typically the real one, shared read-only) so an isolated run
    /// skips the multi-GB model download.
    public let modelsDirectory: URL?
    /// `PULSARTRACE_SYSTEM_FIXTURE` — system-stream fixture WAV (PT-P7-R2).
    public let systemFixture: URL?
    /// `PULSARTRACE_MIC_FIXTURE` — mic-stream fixture WAV (PT-P7-R2).
    public let micFixture: URL?

    public init(environment: [String: String]) {
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        func url(_ key: String) -> URL? {
            value(key).map { URL(fileURLWithPath: $0) }
        }
        self.home = url("PULSARTRACE_HOME")
        self.defaultsSuite = value("PULSARTRACE_DEFAULTS_SUITE")
        self.modelsDirectory = url("PULSARTRACE_MODELS_DIR")
        self.systemFixture = url("PULSARTRACE_SYSTEM_FIXTURE")
        self.micFixture = url("PULSARTRACE_MIC_FIXTURE")
    }

    /// Fixture capture mode is active when at least one fixture is set.
    public var fixtureCaptureActive: Bool {
        systemFixture != nil || micFixture != nil
    }

    /// The process environment's overrides, resolved once per process.
    public static let current = EnvironmentOverrides(
        environment: ProcessInfo.processInfo.environment)
}

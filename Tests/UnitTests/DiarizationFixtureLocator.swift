import Foundation

/// Resolves committed diarization JSON fixtures by repo-relative path.
///
/// These fixtures are generated **once** from real pyannote and
/// committed at `Tests/Fixtures/diarization/`. The Swift merge / Pipeline
/// tests consume them so they stay fast and deterministic — running pyannote
/// (~10–30s model load) in every Swift test run would blow the ~30s budget.
/// Real pyannote correctness is verified in the `pytest` suite instead.
///
/// Resolves by walking up from this source file's `#filePath`
/// (`Tests/UnitTests/`) to `Tests/` — same approach as `PipelineTests`'
/// `FixtureLocator` (project-docs/DECISIONS.md D6).
enum DiarizationFixtureLocator {

    /// The `Tests/` directory (one level above `Tests/UnitTests/`).
    static let testsRoot: URL = {
        URL(fileURLWithPath: #filePath)        // …/Tests/UnitTests/Diarization…
            .deletingLastPathComponent()        // …/Tests/UnitTests
            .deletingLastPathComponent()        // …/Tests
    }()

    /// The committed diarization JSON fixtures directory.
    static let directory: URL =
        testsRoot.appendingPathComponent("Fixtures/diarization", isDirectory: true)

    /// URL of a named diarization JSON fixture.
    static func json(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Raw bytes of a named diarization JSON fixture.
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: json(name))
    }
}

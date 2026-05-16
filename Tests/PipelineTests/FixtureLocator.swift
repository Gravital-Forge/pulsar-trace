import Foundation

/// Resolves committed audio fixtures by repo-relative path.
///
/// Fixtures live at `Tests/Fixtures/audio/`. This locator walks up from this
/// source file's location (`#filePath` → `Tests/PipelineTests/`) to the
/// `Tests/` directory, so tests find fixtures without a bundle-resource copy
/// and without an absolute path baked in.
///
/// Note: PRD §12 writes the path as `tests/fixtures/audio/` (lowercase). On a
/// case-insensitive macOS filesystem that collides with SwiftPM's required
/// `Tests/` directory; on a case-sensitive filesystem they would be two
/// directories. The canonical capitalized `Tests/Fixtures/` avoids the
/// collision — see DECISIONS.md (D6).
enum FixtureLocator {

    /// The `Tests/` directory (one level above `Tests/PipelineTests/`).
    static let testsRoot: URL = {
        URL(fileURLWithPath: #filePath)        // …/Tests/PipelineTests/FixtureLocator.swift
            .deletingLastPathComponent()        // …/Tests/PipelineTests
            .deletingLastPathComponent()        // …/Tests
    }()

    /// The committed audio fixtures directory.
    static let audioDirectory: URL =
        testsRoot.appendingPathComponent("Fixtures/audio", isDirectory: true)

    /// URL of a named fixture WAV under `Tests/Fixtures/audio/`.
    static func audio(_ name: String) -> URL {
        audioDirectory.appendingPathComponent(name)
    }
}

// swift-tools-version: 6.0
import PackageDescription
import Foundation

// whisper.cpp is vendored + built by `scripts/build-whisper.sh` into
// `vendor/whisper-install/` (gitignored, reproducible from the pinned commit in
// project-docs/DECISIONS.md D7). SwiftPM can't run that script, so PulsarTraceEngine reaches
// the built library through absolute -I/-L/-rpath flags computed here from the
// package directory. `swift build` works once the script has run.
let whisperInstall = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("vendor/whisper-install")
let whisperInclude = whisperInstall.appendingPathComponent("include").path
let whisperLib = whisperInstall.appendingPathComponent("lib").path

let package = Package(
    name: "PulsarTrace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PulsarTraceEngine", targets: ["PulsarTraceEngine"]),
        .executable(name: "pulsartrace-engine", targets: ["pulsartrace-engine"]),
        .executable(name: "pulsartrace", targets: ["pulsartrace"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        // System-library wrapper around the vendored whisper.cpp (Epic 2).
        // The dylib + headers are produced by scripts/build-whisper.sh; see
        // project-docs/DECISIONS.md D7 for the integration approach and pinned commit.
        .systemLibrary(name: "CWhisper"),
        // Core library: the engine, all AudioFrameSources, logging, events log, IPC.
        .target(
            name: "PulsarTraceEngine",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "CWhisper",
            ],
            cSettings: [
                .unsafeFlags(["-I", whisperInclude]),
            ],
            swiftSettings: [
                .unsafeFlags(["-I", whisperInclude]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", whisperLib,
                    "-Xlinker", "-rpath", "-Xlinker", whisperLib,
                ]),
            ]
        ),
        // The streaming engine binary. Consumes an AudioFrameSource; counts/logs frames.
        .executableTarget(
            name: "pulsartrace-engine",
            dependencies: ["PulsarTraceEngine"]
        ),
        // The user-facing CLI skeleton. Real subcommands land in later epics.
        .executableTarget(
            name: "pulsartrace",
            dependencies: ["PulsarTraceEngine"]
        ),
        // Layer 1: unit tests — pure logic, <5s, no devices.
        .testTarget(
            name: "UnitTests",
            dependencies: [
                "PulsarTraceEngine",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            // Recorded snapshots are read by swift-snapshot-testing directly
            // from the source tree, not as bundle resources.
            exclude: ["__Snapshots__"]
        ),
        // Layer 2 + 4: pipeline + IPC integration tests, fixture-fed, no devices.
        // Audio fixtures live at the repo's `Tests/Fixtures/audio/` (PRD §12, project-docs/DECISIONS.md D6)
        // and are resolved by path relative to the test source file (#filePath)
        // rather than copied as bundle resources, so they are not duplicated.
        .testTarget(
            name: "PipelineTests",
            dependencies: [
                "PulsarTraceEngine",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
        // Layer 3: capture tests — require BlackHole; skip gracefully when absent.
        .testTarget(
            name: "CaptureTests",
            dependencies: ["PulsarTraceEngine"]
        ),
    ]
)

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
        .library(name: "PulsarTraceMenuBar", targets: ["PulsarTraceMenuBar"]),
        .executable(name: "pulsartrace-engine", targets: ["pulsartrace-engine"]),
        .executable(name: "pulsartrace", targets: ["pulsartrace"]),
        .executable(name: "pulsartrace-capture", targets: ["pulsartrace-capture"]),
        .executable(name: "pulsartrace-mac", targets: ["pulsartrace-mac"]),
        .executable(name: "pulsartrace-whisper", targets: ["pulsartrace-whisper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        // System-library wrapper around the vendored whisper.cpp.
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
        // The whisper inference subprocess (docs/specs/2026-05-26-whisper-subprocess-design.md).
        // One per concurrent transcription workload; SIGKILL'd by the
        // parent to recover from a wedged decode. Depends on
        // `PulsarTraceEngine` so it can reuse `WhisperTranscriber` and
        // the shared IPC + lock types.
        .executableTarget(
            name: "pulsartrace-whisper",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "PulsarTraceEngine",
            ]
        ),
        // The user-facing CLI. `refine`/`speakers`, plus `record`, `doctor`,
        // and `events tail`. Depends on
        // PulsarTraceCapture so `doctor` can read TCC permission state and
        // `doctor --capture-test` can drive the real capture path (R68).
        .executableTarget(
            name: "pulsartrace",
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // Real device capture. Owns AVFoundation (mic) and
        // ScreenCaptureKit (system audio) — the only code that needs TCC
        // grants — and writes 16 kHz mono Float32 frames to Unix domain
        // sockets the engine reads via `SocketSource`. Depends on
        // PulsarTraceEngine for the shared `FrameProtocol`/`AudioFrame` wire
        // types and the events log; it does not use the transcription stack.
        .target(
            name: "PulsarTraceCapture",
            dependencies: ["PulsarTraceEngine"]
        ),
        // The capture daemon binary. Thin wrapper over `DeviceCaptureSource`.
        .executableTarget(
            name: "pulsartrace-capture",
            dependencies: ["PulsarTraceCapture"]
        ),
        // The menubar UI logic. All ViewModels, settings persistence,
        // the recordings scanner, the live-transcript watcher, the speaker
        // editor — everything testable. No SwiftUI. `PulsarTraceCapture`
        // already depends on `PulsarTraceEngine`, so depending on both here
        // introduces no diamond (D27).
        .target(
            name: "PulsarTraceMenuBar",
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // The thin SwiftUI executable — `MenuBarExtra` + `Settings`
        // scenes bound to `PulsarTraceMenuBar`'s ViewModels. No logic, no
        // unit tests; exercised only by manual smoke test (D27).
        // `PulsarTraceEngine` is declared honestly (it was reached
        // transitively before): a few views legitimately name engine types —
        // static catalogs (`ModelCatalog`, `WhisperLanguageCatalog`,
        // `AudioInputDevices`) and display types (`RefinementJob`, `Speaker`,
        // `EventWriter`) — but never construct engine objects.
        .executableTarget(
            name: "pulsartrace-mac",
            dependencies: ["PulsarTraceMenuBar", "PulsarTraceEngine"]
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
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // Menubar UI logic tests — pure logic + temp-folder fixtures,
        // no devices, no real subprocesses (orchestration is behind an
        // injected seam).
        .testTarget(
            name: "MenuBarTests",
            dependencies: ["PulsarTraceMenuBar"]
        ),
    ]
)

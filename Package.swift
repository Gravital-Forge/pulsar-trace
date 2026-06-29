// swift-tools-version: 6.0
import PackageDescription

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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        // ANE transcription backends (PT-P5-D1). Pinned exact: both projects
        // churn their APIs release-to-release. Bump deliberately, with the
        // release notes open.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        // Official MCP Swift SDK (PT-P6-D2). Pinned exact: pre-1.0, minor
        // bumps carry breaking changes (the HTTP-server transports are recent).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        // Core library: the engine, all AudioFrameSources, transcription
        // (Parakeet live / WhisperKit refine, both ANE — PT-P5-D1), logging,
        // events log, IPC.
        .target(
            name: "PulsarTraceEngine",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        // The streaming engine binary. Consumes an AudioFrameSource; runs
        // the live pass.
        .executableTarget(
            name: "pulsartrace-engine",
            dependencies: ["PulsarTraceEngine"]
        ),
        // The user-facing CLI. `refine`/`speakers`, plus `record`, `doctor`,
        // and `events tail`. Depends on PulsarTraceCapture so `doctor` can
        // read TCC permission state and `doctor --capture-test` can drive
        // the real capture path (PT-R68).
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
        // introduces no diamond (PT-P2-D9).
        .target(
            name: "PulsarTraceMenuBar",
            dependencies: ["PulsarTraceEngine", "PulsarTraceCapture"]
        ),
        // The MCP server core (PT-P6-D1): tool registry + JSON-RPC handlers
        // behind a hand-rolled loopback HTTP front end feeding the SDK's
        // StatelessHTTPServerTransport. No SwiftUI — the menubar executable
        // owns the lifecycle.
        .target(
            name: "PulsarTraceMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "PulsarTraceEngine",
            ]
        ),
        // The thin SwiftUI executable — `MenuBarExtra` + `Settings`
        // scenes bound to `PulsarTraceMenuBar`'s ViewModels. No logic, no
        // unit tests; exercised only by manual smoke test (PT-P2-D9).
        // `PulsarTraceEngine` is declared honestly: a few views name engine
        // types — static catalogs (`WhisperKitModelCatalog`,
        // `LanguageCatalog`, `AudioInputDevices`) and display types
        // (`RefinementJob`, `Speaker`, `EventWriter`) — but never construct
        // engine objects.
        .executableTarget(
            name: "pulsartrace-mac",
            dependencies: ["PulsarTraceMenuBar", "PulsarTraceEngine", "PulsarTraceMCP"]
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
        // Audio fixtures live at the repo's `Tests/Fixtures/audio/` (PT-P1-D6)
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
        // MCP server tests — auth, the loopback listener, and the SDK
        // round-trip, against temp folders and ephemeral loopback ports.
        .testTarget(
            name: "MCPTests",
            dependencies: ["PulsarTraceMCP"]
        ),
    ]
)

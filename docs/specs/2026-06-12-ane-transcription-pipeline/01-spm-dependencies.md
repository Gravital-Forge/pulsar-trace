> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 01: SPM dependencies

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the two packages and wire them into `PulsarTraceEngine`**

In `Package.swift`, extend `dependencies`:

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        // ANE transcription backends (docs/specs/2026-06-12-ane-transcription-pipeline/).
        // Pinned exact: both projects churn their APIs release-to-release
        // (FluidAudio broke `transcribe` twice in 0.12→0.13; WhisperKit's
        // v1.0.0 was a breaking rename). Bump deliberately, with the release
        // notes open.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
    ],
```

and extend the `PulsarTraceEngine` target's `dependencies`:

```swift
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "CWhisper",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
```

(`CWhisper` stays for now — the legacy backend keeps compiling until tasks 16–17 delete it.)

- [ ] **Step 2: Build**

Run: `swift build` (bare — no pipes/redirects; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: dependency resolution fetches both packages from github.com; build succeeds. If `vendor/whisper-install` is missing, run `scripts/build-whisper.sh` first (D7 — still required until task 16 removes the vendored library).

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add FluidAudio 0.15.2 and argmax-oss-swift 1.0.0 (ANE transcription backends)"
```

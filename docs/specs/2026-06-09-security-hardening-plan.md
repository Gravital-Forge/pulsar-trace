# Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PulsarTrace's on-disk privacy posture match its "strictly local, privacy-first" pitch: owner-only permissions (0600/0700) on every artifact that can hold meeting content, peer-UID verification on both Unix-socket servers, and home-path redaction of whisper subprocess stderr before it reaches the operational log.

**Architecture:** One new policy helper (`SecureFiles`) and one peer-check helper (`PeerCredentials`) in `PulsarTraceEngine/Support`, then a mechanical sweep replacing default-permission `FileManager` calls at the ~12 sites that create sensitive files/dirs. No behavior change other than permissions, one rejected-peer branch per socket server, and one redaction wrapper.

**Tech Stack:** Swift 6 / Foundation / Darwin (`getpeereid`, `fchmod`), Swift Testing (`@Suite`/`@Test`/`#expect`), SQLite C API (existing wrapper).

---

## Build/test commands (read CLAUDE.md rules first!)

- `swift build` and `swift test --filter <X>` must run **bare** (no pipes, no redirects, no `&&`) with `dangerouslyDisableSandbox: true`.
- Relevant narrow filters for this plan: `UnitTests`, `IPC`, `Speaker`, `Streaming`, `LiveRunner`, `Refinement`.
- Never leave a failing test. The broad `--filter PipelineTests` is known-flaky cross-suite; use the narrow filters.

## Policy decisions (locked — do not re-litigate during implementation)

1. **PulsarTrace-owned dirs** (`~/Library/Application Support/PulsarTrace/` and subdirs, `$TMPDIR/PulsarTrace/` sockets dir, live-diarizer window dirs) → created 0700 **and repaired to 0700 if they already exist** with looser perms.
2. **User-chosen dirs** (recording output folders) → 0700 **only when PulsarTrace creates them fresh**; an existing directory's permissions are the user's business — never chmod those.
3. **Content files** (live.md, final.md, metadata.json via AtomicFile, `audio-*.wav`, events `*.jsonl`, `speakers.sqlite` + `-wal`/`-shm`/`.bak`, `whisper.lock`) → 0600, with repair-on-touch for files created before this change.
4. **Out of scope** (deliberately): `~/Library/Caches/PulsarTrace/models/` (public model files), `~/Library/Logs/PulsarTrace/` (content-free by design, R57), `CLIInstaller` (`/usr/local/bin` is system territory), `DoctorCommand` temp probes. Also deferred to Epic 10 (distribution): HF token → Keychain (R54a) and `Bundle.main`-based binary resolution with `#if DEBUG`-gated env overrides — both need the production `.app` packaging that doesn't exist yet; gating env overrides now would break the documented dev workflow.
5. Socket servers verify the connected peer's euid via `getpeereid(2)`; mismatch → close + reject. Same-uid test traffic must keep passing.

---

### Task 1: `SecureFiles` + `PeerCredentials` helpers

**Files:**
- Create: `Sources/PulsarTraceEngine/Support/SecureFiles.swift`
- Create: `Sources/PulsarTraceEngine/Support/PeerCredentials.swift`
- Create: `Tests/UnitTests/SecureFilesTests.swift`
- Create: `Tests/UnitTests/PeerCredentialsTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/UnitTests/SecureFilesTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// Unit coverage for `SecureFiles`, the single home of the owner-only
/// (0600/0700) on-disk permission policy for content-bearing artifacts.
@Suite("SecureFiles permission policy")
struct SecureFilesTests {

    private func tempBase() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-secure-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(ofPath path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("ensurePrivateDirectory creates a 0700 directory")
    func ensureCreates0700() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("owned", isDirectory: true)

        try SecureFiles.ensurePrivateDirectory(at: dir)

        #expect(mode(ofPath: dir.path) == 0o700)
    }

    @Test("ensurePrivateDirectory repairs an existing 0755 directory to 0700")
    func ensureRepairsExisting() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        try SecureFiles.ensurePrivateDirectory(at: dir)

        #expect(mode(ofPath: dir.path) == 0o700)
    }

    @Test("createDirectoryPrivateIfNew creates fresh dirs 0700")
    func ifNewCreates0700() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("fresh", isDirectory: true)

        try SecureFiles.createDirectoryPrivateIfNew(at: dir)

        #expect(mode(ofPath: dir.path) == 0o700)
    }

    @Test("createDirectoryPrivateIfNew leaves an existing user dir untouched")
    func ifNewLeavesExisting() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("users-own", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        try SecureFiles.createDirectoryPrivateIfNew(at: dir)

        #expect(mode(ofPath: dir.path) == 0o755)
    }

    @Test("createPrivateFile creates a 0600 file")
    func createPrivateFile0600() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("secret.md")

        #expect(SecureFiles.createPrivateFile(atPath: file.path))

        #expect(mode(ofPath: file.path) == 0o600)
    }

    @Test("restrictToOwner repairs an existing 0644 file to 0600")
    func restrictRepairs() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("legacy.md")
        FileManager.default.createFile(
            atPath: file.path, contents: Data("x".utf8),
            attributes: [.posixPermissions: 0o644])

        SecureFiles.restrictToOwner(file)

        #expect(mode(ofPath: file.path) == 0o600)
    }
}
```

`Tests/UnitTests/PeerCredentialsTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `getpeereid`-based same-user verification for UDS peers.
@Suite("PeerCredentials")
struct PeerCredentialsTests {

    @Test("a socketpair peer in the same process is the same user")
    func socketpairIsSameUser() {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #expect(rc == 0)
        defer { close(fds[0]); close(fds[1]) }

        #expect(PeerCredentials.peerIsSameUser(fd: fds[0]))
        #expect(PeerCredentials.peerIsSameUser(fd: fds[1]))
    }

    @Test("an invalid fd is rejected")
    func invalidFDRejected() {
        #expect(!PeerCredentials.peerIsSameUser(fd: -1))
    }

    @Test("a non-socket fd is rejected")
    func nonSocketFDRejected() {
        let devnull = open("/dev/null", O_RDONLY)
        #expect(devnull >= 0)
        defer { close(devnull) }
        #expect(!PeerCredentials.peerIsSameUser(fd: devnull))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter SecureFiles`
Expected: compile FAILURE — `SecureFiles` not defined. Same for `swift test --filter PeerCredentials`.

- [ ] **Step 3: Implement the helpers**

`Sources/PulsarTraceEngine/Support/SecureFiles.swift`:

```swift
import Foundation

/// Single home for the owner-only on-disk permission policy (0700 dirs /
/// 0600 files) applied to everything PulsarTrace writes that can contain
/// meeting content or speaker identity: transcripts, audio, the events
/// log, the speaker library, and the per-session sockets.
///
/// Two directory flavors exist because the policy differs by ownership:
/// directories PulsarTrace owns outright are *enforced* private (created
/// 0700 and repaired if a pre-hardening run left them 0755); directories
/// in user-chosen territory (recording output folders) are made private
/// only when PulsarTrace creates them fresh — an existing directory's
/// permissions are the user's deliberate choice and are never touched.
public enum SecureFiles {

    /// Create-and-enforce: a directory PulsarTrace owns. Creates it (and
    /// any intermediates) 0700, then repairs the leaf to 0700 if a
    /// previous version of the app created it with looser permissions.
    public static func ensurePrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory` is a no-op (and applies no attributes) when
        // the directory already exists — repair explicitly.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Create-if-new: a directory in user-chosen territory. Fresh
    /// directories are 0700; an existing one is left exactly as the
    /// user has it.
    public static func createDirectoryPrivateIfNew(at url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// `FileManager.createFile` with owner-only (0600) permissions.
    /// Same truncate-if-exists semantics as the Foundation call it wraps.
    @discardableResult
    public static func createPrivateFile(atPath path: String) -> Bool {
        FileManager.default.createFile(
            atPath: path, contents: nil,
            attributes: [.posixPermissions: 0o600])
    }

    /// Repair an existing file to 0600 — for files created by APIs that
    /// take no mode (SQLite, `FileManager.replaceItemAt`). Missing files
    /// are a silent no-op.
    public static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
```

`Sources/PulsarTraceEngine/Support/PeerCredentials.swift`:

```swift
import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Identity verification for Unix-domain-socket peers.
///
/// Defense in depth on top of the 0700 socket directory: even a process
/// that reaches the socket path is only served if it runs as the same
/// user. `getpeereid(2)` reports the peer's *effective* uid as of
/// `connect(2)`; comparing against our own euid rejects any cross-user
/// connection without a round-trip.
public enum PeerCredentials {
    /// `true` iff the connected peer of `fd` runs as our effective uid.
    /// Any `getpeereid` failure (bad fd, not a socket, not connected)
    /// counts as a rejection.
    public static func peerIsSameUser(fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter SecureFiles`
Expected: PASS (6 tests). Then `swift test --filter PeerCredentials` — PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Support/SecureFiles.swift Sources/PulsarTraceEngine/Support/PeerCredentials.swift Tests/UnitTests/SecureFilesTests.swift Tests/UnitTests/PeerCredentialsTests.swift
git commit -m "security: add SecureFiles (0600/0700 policy) and PeerCredentials (getpeereid) helpers"
```

---

### Task 2: Owner-only permissions sweep — content files and owned directories

**Files:**
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveMarkdownWriter.swift:80-85`
- Modify: `Sources/PulsarTraceEngine/Audio/StreamingWAVWriter.swift:57`
- Modify: `Sources/PulsarTraceEngine/Events/EventWriter.swift:67-68,181`
- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerLibrary.swift:88` (Application Support dir)
- Modify: `Sources/PulsarTraceCapture/DeviceCaptureSource.swift:116` (socket dir)
- Modify: `Sources/PulsarTraceEngine/WhisperIPC/WhisperSubprocessHost.swift:219-221` (socket dir)
- Modify: `Sources/pulsartrace-whisper/main.swift:74-76` (lock-file parent dir)
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift:203` (window-WAV dir — verify it holds audio; it does, treat as owned)
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobStore.swift:108` (jobs dir under Application Support)
- Modify: `Sources/pulsartrace/RecordCommand.swift:83` (user-chosen output dir → if-new)
- Modify: `Sources/PulsarTraceMenuBar/RecordingViewModel.swift:179` (user-chosen output dir → if-new)
- Test: extend `Tests/UnitTests/LiveMarkdownWriterTests.swift`, `Tests/UnitTests/EventWriterTests.swift`; create `Tests/UnitTests/StreamingWAVWriterPermissionsTests.swift`

Rules for the sweep — read each site's surrounding code before editing:
- Owned dirs (per Policy #1) → `try SecureFiles.ensurePrivateDirectory(at: …)` (keep the original `try`/`try?` discipline of the call you replace: `EventWriter.bootstrap` uses `try?`, keep `try?`).
- User-chosen dirs (RecordCommand, RecordingViewModel) → `try SecureFiles.createDirectoryPrivateIfNew(at: …)`.
- Content files → `SecureFiles.createPrivateFile(atPath: …)` (same truncate semantics as the `createFile` it replaces).
- `pulsartrace-whisper/main.swift` already has access to PulsarTraceEngine (it uses `WhisperLock`); confirm the import exists before using `SecureFiles` there.
- `PulsarTraceMenuBar` and `PulsarTraceCapture` already depend on `PulsarTraceEngine` — no Package.swift change needed (verify with a build).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnitTests/LiveMarkdownWriterTests.swift` (inside the existing suite, reusing its `tempDir()`/`fixedStart` helpers):

```swift
    @Test("live.md is created owner-only (0600)")
    func liveFileIsOwnerOnly() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live.md")

        let writer = LiveMarkdownWriter(fileURL: url, recordingStart: fixedStart)
        try await writer.start()
        await writer.finish()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
```

(If `LiveMarkdownWriter` is not an actor, drop the `await`s to match the existing tests in that file — copy the call shape of `startCreatesMarkerAndHeader`.)

Append to `Tests/UnitTests/EventWriterTests.swift` (reuse that suite's construction pattern for `EventWriter` — copy the setup of its first test verbatim, then assert):

```swift
    @Test("events directory is 0700 and the day file is 0600")
    func eventArtifactsAreOwnerOnly() async throws {
        // Copy the exact EventWriter + temp-directory setup used by the
        // suite's existing append test, then:
        // (writer bootstrapped, one event appended, file exists)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: dayFileURL.path)
        #expect((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
```

Create `Tests/UnitTests/StreamingWAVWriterPermissionsTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// The streaming WAV writer produces audio of the user's meeting — the
/// file must be owner-only from creation (security hardening sweep).
@Suite("StreamingWAVWriter permissions")
struct StreamingWAVWriterPermissionsTests {

    @Test("the WAV file is created 0600")
    func wavIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio-system.wav")

        let writer = try StreamingWAVWriter(url: url)
        try writer.append([0.0, 0.1, -0.1])
        try writer.finalize()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
```

(Adjust `finalize()` to the actual method name — check the type before writing; if `StreamingWAVWriter.append`/teardown differ, mirror an existing caller in `LiveRunner.swift`.)

- [ ] **Step 2: Run the new tests to verify they fail**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter UnitTests`
Expected: the three new tests FAIL on the permission assertion (current files are 0644/dirs 0755); everything else PASSES.

- [ ] **Step 3: Apply the sweep**

Exact replacements (verify surrounding context as you go):

`LiveMarkdownWriter.swift` lines 80–85:
```swift
        let directory = fileURL.deletingLastPathComponent()
        try SecureFiles.createDirectoryPrivateIfNew(at: directory)

        // Create the file fresh. A pre-existing live.md (a previous, crashed
        // run) is overwritten *only here at session start* — never mid-session.
        SecureFiles.createPrivateFile(atPath: fileURL.path)
```

`StreamingWAVWriter.swift` line 57:
```swift
        // Create (or truncate) the file owner-only, then open a handle.
        SecureFiles.createPrivateFile(atPath: url.path)
```

`EventWriter.swift` lines 67–68:
```swift
        try? SecureFiles.ensurePrivateDirectory(at: directory)
```
`EventWriter.swift` line 181:
```swift
            SecureFiles.createPrivateFile(atPath: url.path)
```

`SpeakerLibrary.swift` line 88 — replace the `createDirectory` call with:
```swift
        try SecureFiles.ensurePrivateDirectory(at: databaseURL.deletingLastPathComponent())
```
(keep whatever argument the current call derives the directory from — read lines 84–92 first and preserve them.)

`DeviceCaptureSource.swift` line 116 and `WhisperSubprocessHost.swift` lines 219–221 (both create the socket directory):
```swift
        try SecureFiles.ensurePrivateDirectory(at: <existing directory expression>)
```

`pulsartrace-whisper/main.swift` lines 74–76:
```swift
            try SecureFiles.ensurePrivateDirectory(
                at: parsed.lockPath.deletingLastPathComponent())
```

`LiveDiarizer.swift` line 203 and `RefinementJobStore.swift` line 108: same `ensurePrivateDirectory` replacement (read context first; keep the existing `try`/`try?` form and variable names).

`RecordCommand.swift` line 83 and `RecordingViewModel.swift` line 179:
```swift
            try SecureFiles.createDirectoryPrivateIfNew(at: <existing url expression>)
```
Note: `createDirectoryPrivateIfNew` returns without error when the directory exists — if the original call relied on `withIntermediateDirectories: true` to tolerate pre-existing dirs, behavior is preserved.

- [ ] **Step 4: Build and run the suites**

Run (each bare, `dangerouslyDisableSandbox: true`):
1. `swift build` — expected: succeeds, no warnings introduced.
2. `swift test --filter UnitTests` — expected: PASS including the three new tests.
3. `swift test --filter Streaming` — PASS.
4. `swift test --filter Speaker` — PASS.
5. `swift test --filter IPC` — PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "security: owner-only perms (0600/0700) for transcripts, audio, events, sockets, library dirs"
```

---

### Task 3: `AtomicFile` writes 0600 (and repairs pre-existing targets)

**Files:**
- Modify: `Sources/PulsarTraceEngine/Support/AtomicFile.swift:24-46`
- Test: create `Tests/UnitTests/AtomicFilePermissionsTests.swift` (check first: if an `AtomicFile` suite already exists — `grep -rn "AtomicFile" Tests/UnitTests` — extend it instead)

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// `AtomicFile` writes `final.md` / `metadata.json` — meeting content.
/// Both the fresh-write and replace-existing paths must yield 0600.
@Suite("AtomicFile permissions")
struct AtomicFilePermissionsTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-atomic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a fresh atomic write produces a 0600 file")
    func freshWriteIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("final.md")

        try AtomicFile.write("# transcript", to: url)

        #expect(mode(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# transcript")
    }

    @Test("replacing a pre-hardening 0644 file converges to 0600")
    func replaceRepairsPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("final.md")
        FileManager.default.createFile(
            atPath: url.path, contents: Data("old".utf8),
            attributes: [.posixPermissions: 0o644])

        try AtomicFile.write("new", to: url)

        #expect(mode(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    @Test("a failed write still leaves no stray temp file")
    func noStrayTempOnSuccess() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metadata.json")

        try AtomicFile.write("{}", to: url)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["metadata.json"])
    }
}
```

- [ ] **Step 2: Run to verify the permission tests fail**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter AtomicFilePermissions`
Expected: `freshWriteIsOwnerOnly` and `replaceRepairsPermissions` FAIL (current files are 0644). `noStrayTempOnSuccess` may already pass.

- [ ] **Step 3: Rework `AtomicFile.write(_:to:)`**

Replace the body of the `Data` overload (keep the doc comment, signature, and SHA-256 return):

```swift
    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> String {
        let directory = url.deletingLastPathComponent()
        try SecureFiles.createDirectoryPrivateIfNew(at: directory)

        // A unique temp name in the destination directory: same volume, so the
        // rename is a true atomic in-place replace.
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            // Owner-only from the first byte: create the temp file 0600 and
            // stream the payload through a handle. (`Data.write(.atomic)`
            // would create its own 0644 temp file behind our back.)
            guard SecureFiles.createPrivateFile(atPath: tempURL.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // `replaceItemAt` performs an atomic exchange when the destination
            // already exists, and a plain rename when it does not.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            // When the destination existed, `replaceItemAt` preserves the *old*
            // item's metadata — repair so pre-hardening 0644 files converge to
            // 0600 on their next rewrite.
            SecureFiles.restrictToOwner(url)
        } catch {
            // Never leave a stray temp file behind on failure.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return sha256Hex(data)
    }
```

- [ ] **Step 4: Run the suites**

Run (each bare, `dangerouslyDisableSandbox: true`):
1. `swift test --filter AtomicFilePermissions` — PASS (3 tests).
2. `swift test --filter UnitTests` — PASS.
3. `swift test --filter Refinement` — PASS (final.md/metadata.json writers go through this path).
4. `swift test --filter FinalMarkdownRewriter` — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Support/AtomicFile.swift Tests/UnitTests/AtomicFilePermissionsTests.swift
git commit -m "security: AtomicFile writes final.md/metadata.json owner-only, repairing legacy 0644 targets"
```

---

### Task 4: `whisper.lock` owner-only

**Files:**
- Modify: `Sources/PulsarTraceEngine/WhisperIPC/WhisperLock.swift:57-90`
- Test: extend the existing WhisperLock tests (`grep -rln "WhisperLock" Tests/` to find the suite; if none exists, create `Tests/UnitTests/WhisperLockPermissionsTests.swift`)

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The lock file's existence/mtime leaks session timing — owner-only.
@Suite("WhisperLock permissions")
struct WhisperLockPermissionsTests {

    private func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a fresh lock file is created 0600")
    func freshLockIsOwnerOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-lock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = try WhisperLock(lockPath: url)
        _ = lock

        #expect(mode(url) == 0o600)
    }

    @Test("a pre-existing 0644 lock file is repaired to 0600 on acquire")
    func legacyLockIsRepaired() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-lock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o644])

        let lock = try WhisperLock(lockPath: url)
        _ = lock

        #expect(mode(url) == 0o600)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter WhisperLockPermissions`
Expected: both tests FAIL (file is 0644).

- [ ] **Step 3: Change the open mode and add the fchmod repair**

In `WhisperLock.init` (line ~69), change:

```swift
        let fd = path.withCString { cstr in
            open(cstr, O_CREAT | O_RDWR, 0o600)
        }
        guard fd >= 0 else {
            throw WhisperLockError.openFailed(path: path, errno: errno)
        }
        // open(2)'s mode applies only at creation — repair a lock file a
        // pre-hardening build created 0644. fchmod on the held fd: no
        // TOCTOU window, and a failure is non-fatal (the flock still works).
        _ = fchmod(fd, 0o600)
```

Also update the init doc comment: "The file is created with mode 0644 if absent" → "created (or repaired to) owner-only 0600".

- [ ] **Step 4: Run the suites**

Run (each bare, `dangerouslyDisableSandbox: true`):
1. `swift test --filter WhisperLock` — PASS (existing + new).
2. `swift test --filter UnitTests` — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/WhisperIPC/WhisperLock.swift Tests/UnitTests/WhisperLockPermissionsTests.swift
git commit -m "security: whisper.lock owner-only (0600), with fchmod repair of legacy files"
```

---

### Task 5: speakers.sqlite, -wal/-shm, and .bak owner-only

**Files:**
- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SQLiteDatabase.swift:49-74` (init) and `:200-226` (backup)
- Test: create `Tests/UnitTests/SQLitePermissionsTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// speakers.sqlite holds voice embeddings + names; the DB, its WAL/SHM
/// journals, and the .bak backup must all be owner-only.
@Suite("SQLite database permissions")
struct SQLitePermissionsTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-sqlite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("a freshly created database (and its WAL journals) is 0600")
    func freshDatabaseIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")

        let db = try SQLiteDatabase(url: dbURL)
        try db.exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1);")

        #expect(mode(dbURL) == 0o600)
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            #expect(mode(wal) == 0o600)
        }
        let shm = URL(fileURLWithPath: dbURL.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) {
            #expect(mode(shm) == 0o600)
        }
    }

    @Test("a pre-existing 0644 database is repaired on open")
    func legacyDatabaseIsRepaired() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        // Create through SQLite first, then loosen, then re-open.
        _ = try SQLiteDatabase(url: dbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: dbURL.path)

        _ = try SQLiteDatabase(url: dbURL)

        #expect(mode(dbURL) == 0o600)
    }

    @Test("the online backup file is 0600")
    func backupIsOwnerOnly() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")
        let bakURL = dbURL.appendingPathExtension("bak")
        let db = try SQLiteDatabase(url: dbURL)
        try db.exec("CREATE TABLE t(x INTEGER);")

        try db.backup(to: bakURL)

        #expect(mode(bakURL) == 0o600)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter SQLitePermissions`
Expected: all three FAIL on the 0600 assertions.

- [ ] **Step 3: Add the restricts**

In `SQLiteDatabase.init(url:)`, immediately after the `guard rc == SQLITE_OK …` block succeeds and **before** `try exec("PRAGMA journal_mode=WAL;")`:

```swift
        // sqlite3_open_v2 creates the file with the process umask (0644);
        // the library holds voice embeddings and names, so restrict to
        // owner before the WAL pragma — -wal/-shm inherit the database
        // file's mode when SQLite creates them.
        SecureFiles.restrictToOwner(url)
```

At the end of `init`, after `try exec("PRAGMA busy_timeout=5000;")` — repair journals a pre-hardening run may have left behind:

```swift
        // Journals from a pre-hardening run were created 0644 — repair.
        SecureFiles.restrictToOwner(URL(fileURLWithPath: url.path + "-wal"))
        SecureFiles.restrictToOwner(URL(fileURLWithPath: url.path + "-shm"))
```

In `backup(to:)` (line ~200), after the backup completes successfully (after the last `guard`/error check, before returning):

```swift
        // sqlite3_open_v2 on the destination used the umask — restrict.
        SecureFiles.restrictToOwner(destinationURL)
```

- [ ] **Step 4: Run the suites**

Run (each bare, `dangerouslyDisableSandbox: true`):
1. `swift test --filter SQLitePermissions` — PASS (3 tests).
2. `swift test --filter Speaker` — PASS (library + reconciler suites exercise open/backup/restore paths).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/SQLiteDatabase.swift Tests/UnitTests/SQLitePermissionsTests.swift
git commit -m "security: speakers.sqlite, WAL journals, and .bak backup owner-only (0600)"
```

---

### Task 6: Verify socket peers with `getpeereid`

**Files:**
- Modify: `Sources/PulsarTraceCapture/CaptureSocketServer.swift:119-121`
- Modify: `Sources/pulsartrace-whisper/main.swift:129-148`

No new unit test can simulate a foreign uid; the same-uid acceptance path is covered by the existing IPC integration suites (which must stay green), and `PeerCredentials` itself is unit-tested in Task 1. This task is the wiring.

- [ ] **Step 1: Wire the check into `CaptureSocketServer.beginServing()`**

At lines 119–121, change:

```swift
            let client = accept(listen, nil, nil)
            guard client >= 0 else { return }
            // Defense in depth: only a process running as our own user may
            // consume raw PCM. The socket dir is 0700; verify the peer too.
            guard PeerCredentials.peerIsSameUser(fd: client) else {
                close(client)
                return
            }
            configureClientSocket(client)
```

(`PulsarTraceCapture` already imports `PulsarTraceEngine` at the top of this file — no import change. A rejected peer leaves the thread exactly as the "no consumer ever connected" path does; `stop()` already handles that: `clientFD` is never set, `threadFinished` is signalled by the `defer`.)

- [ ] **Step 2: Wire the check into `pulsartrace-whisper/main.swift` `runListener`**

Immediately after `defer { close(clientFD) }` (line ~139) and before the `SO_NOSIGPIPE` setsockopt:

```swift
        // Only the parent — same euid — may drive the decode loop. The
        // transcripts that flow back over this socket are meeting content.
        if !PeerCredentials.peerIsSameUser(fd: clientFD) {
            FileHandle.standardError.write(Data(
                "ERROR: rejected socket peer with foreign uid\n".utf8))
            return 1
        }
```

(Confirm `import PulsarTraceEngine` is present at the top of `main.swift` — it already uses `WhisperLock` from that module.)

- [ ] **Step 3: Build and run the IPC + capture-adjacent suites**

Run (each bare, `dangerouslyDisableSandbox: true`):
1. `swift build` — succeeds.
2. `swift test --filter IPC` — PASS (engine connects as same uid; nothing rejected).
3. `swift test --filter LiveRunner` — PASS.
4. `swift test --filter Transcription` — PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/PulsarTraceCapture/CaptureSocketServer.swift Sources/pulsartrace-whisper/main.swift
git commit -m "security: verify UDS peer uid with getpeereid on capture and whisper sockets"
```

---

### Task 7: Redact home paths in whisper subprocess stderr forwarding

**Files:**
- Modify: `Sources/PulsarTraceEngine/WhisperIPC/WhisperSubprocessHost.swift:675-702` (`drainStderrLines`)
- Test: create `Tests/UnitTests/WhisperStderrRedactionTests.swift`

Background: `pulsartrace-whisper` writes its lock path to stderr on failure (`main.swift:84`); `drainStderrLines` forwards stderr lines to the operational log **without** `PathRedactor`, violating Hard Invariant #7 (no full user paths in logs). The Python subprocess path already redacts; this closes the whisper-side gap.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// Hard Invariant #7: no full user paths in the operational log. The
/// whisper subprocess's stderr is forwarded into the log by
/// `drainStderrLines` — those lines must pass through PathRedactor.
@Suite("Whisper stderr redaction")
struct WhisperStderrRedactionTests {

    /// Minimal capturing LogHandler local to this suite. (A shared
    /// test-support consolidation is planned separately — keep this
    /// self-contained for now.)
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func add(_ s: String) { lock.withLock { _lines.append(s) } }
    }

    private struct CapturingHandler: LogHandler {
        let sink: Sink
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message,
                 metadata: Logger.Metadata?, source: String,
                 file: String, function: String, line: UInt) {
            sink.add(message.description)
        }
    }

    @Test("forwarded stderr lines have the home directory redacted")
    func forwardedLinesAreRedacted() throws {
        let sink = Sink()
        let logger = Logger(label: "test") { _ in CapturingHandler(sink: sink) }

        let pipe = Pipe()
        let raw = "ERROR: could not acquire whisper lock at \(NSHomeDirectory())/Library/Application Support/PulsarTrace/whisper.lock: errno 13\n"
        pipe.fileHandleForWriting.write(Data(raw.utf8))
        try pipe.fileHandleForWriting.close()

        WhisperSubprocessHost.drainStderrLines(
            from: pipe.fileHandleForReading, logger: logger)

        let joined = sink.lines.joined(separator: "\n")
        #expect(!joined.isEmpty)
        #expect(!joined.contains(NSHomeDirectory()))
        #expect(joined.contains("~/Library/Application Support/PulsarTrace/whisper.lock"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter WhisperStderrRedaction`
Expected: FAIL — the captured line contains the raw home path.

- [ ] **Step 3: Apply the redaction**

In `drainStderrLines` (`WhisperSubprocessHost.swift`), wrap both emit sites:

Line ~687 (EOF flush):
```swift
                    logger.notice("[whisper-subprocess] \(PathRedactor.redactHome(line))")
```

Line ~697 (per-line emit):
```swift
                    logger.notice("[whisper-subprocess] \(PathRedactor.redactHome(line))")
```

(Keep the `if !line.isEmpty` guard on the second site exactly as is.)

- [ ] **Step 4: Run the suites**

Run (each bare, `dangerouslyDisableSandbox: true`):
1. `swift test --filter WhisperStderrRedaction` — PASS.
2. `swift test --filter UnitTests` — PASS.
3. `swift test --filter Transcription` — PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/WhisperIPC/WhisperSubprocessHost.swift Tests/UnitTests/WhisperStderrRedactionTests.swift
git commit -m "security: redact home paths in whisper subprocess stderr before logging (Hard Invariant 7)"
```

---

### Task 8: Full verification sweep

**Files:** none modified (verification only).

- [ ] **Step 1: Run every narrow suite**

Run each bare with `dangerouslyDisableSandbox: true`, in order; every one must be green:

1. `swift test --filter UnitTests`
2. `swift test --filter Refinement`
3. `swift test --filter IPC`
4. `swift test --filter RecordOrchestrator`
5. `swift test --filter LiveRunner`
6. `swift test --filter Streaming`
7. `swift test --filter Transcription`
8. `swift test --filter Speaker`
9. `swift test --filter Source`
10. `swift test --filter Lifecycle`
11. `swift test --filter FinalMarkdownRewriter`

Any failure: stop, diagnose per pulsartrace-systematic-debugging, fix before proceeding. Do not hand-wave a failure as "flaky".

- [ ] **Step 2: Grep-audit for missed sites**

```bash
grep -rn "createFile(atPath\|createDirectory(" Sources --include="*.swift"
```
Expected: every remaining default-permission call is in the out-of-scope list (ModelStore, LogRotator, CLIInstaller, DoctorCommand) or test-only. Anything else: fold into the sweep, re-run suites, amend the Task 2 commit message convention.

- [ ] **Step 3: Commit (only if Step 2 found stragglers)**

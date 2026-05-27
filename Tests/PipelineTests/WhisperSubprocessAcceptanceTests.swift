import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

#if canImport(Darwin)
import Darwin
#endif

/// Phase 7 — end-to-end acceptance tests for the `pulsartrace-whisper`
/// subprocess (`docs/specs/2026-05-26-whisper-subprocess-design.md` §11).
///
/// Unlike `RemoteWindowTranscriberTests` (which exercises the state
/// machine against a fake `WhisperHostProtocol`), these tests spawn the
/// **real** binary and assert the spec-level invariants:
///
///   1. A wedged decode is recovered: the parent SIGKILLs the subprocess
///      and a respawn brings the next decode in within
///      `decodeDeadline + spawn-budget` (target ~15 s).
///   2. Two subprocesses sharing the same `--lock-path` cannot both run:
///      the second exits with code 75 (`EX_TEMPFAIL`) and stderr says
///      "already running".
///
/// (The "recording continues uninterrupted" criterion from the spec is
/// out of scope for this suite — it requires the full live pipeline
/// with two real audio sources, and Phase 4's architecture already
/// guarantees the structural invariant via process separation between
/// `pulsartrace-engine` and `pulsartrace-whisper`.)
///
/// ## Why this suite name is prefixed
///
/// CLAUDE.md notes that running the broad `--filter PipelineTests` is
/// known-flaky under cross-suite races. The suite name + each test
/// description start with "WhisperSubprocessAcceptance" so the narrow
/// filter `--filter WhisperSubprocessAcceptance` will pick them up
/// exclusively.
///
/// ## Model availability
///
/// Both tests need the binary's model-load step to succeed. They are
/// gated on `hasBaseModelCached()` so a fresh dev box / CI box without
/// `~/Library/Caches/PulsarTrace/models/ggml-base.bin` reports a clean
/// skip rather than auto-downloading ~140 MB.
@Suite("WhisperSubprocessAcceptance (real spawn)", .serialized)
struct WhisperSubprocessAcceptanceTests {

    // MARK: - Test 1: Wedge recovery (end-to-end)

    @Test(
        "WhisperSubprocessAcceptance: a wedged real subprocess is SIGKILL'd and a fresh one takes over within budget",
        .enabled(if: hasBaseModelCached()),
        .timeLimit(.minutes(1)))
    func wedgeRecoveryEndToEnd() throws {
        // Resolve the real binary + an isolated temp dir for sockets +
        // lock. Using a per-test temp dir keeps two parallel test runs
        // (or this test re-running while a stuck instance lingers) from
        // colliding on the shared `~/Library/.../whisper.lock`.
        let binaryURL = try resolveWhisperBinary()
        let tempDir = makeTempDir(tag: "wedge")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockPath = tempDir.appendingPathComponent("whisper.lock")
        let modelURL = try locateCachedBaseModel()

        // First host: `--hang-on-sentinel` makes every decode block in
        // `Thread.sleep` forever. Init still completes normally.
        // Second host: vanilla — the respawn after SIGKILL.
        let wedgedConfig = WhisperSubprocessHost.Configuration(
            binaryURL: binaryURL,
            socketDirectory: tempDir,
            lockPath: lockPath,
            forceCPU: true,
            spawnTimeout: .seconds(10),
            initTimeout: .seconds(30),
            extraArgs: ["--hang-on-sentinel"])
        let respawnConfig = WhisperSubprocessHost.Configuration(
            binaryURL: binaryURL,
            socketDirectory: tempDir,
            lockPath: lockPath,
            forceCPU: true,
            spawnTimeout: .seconds(10),
            initTimeout: .seconds(30),
            extraArgs: [])

        let factory = SequencedRealHostConfigs(configs: [wedgedConfig, respawnConfig])

        let trans = RemoteWindowTranscriber(
            configuration: .init(
                binaryURL: binaryURL,
                modelURL: modelURL,
                socketDirectory: tempDir,
                lockPath: lockPath,
                forceCPU: true,
                // Keep the decode deadline short so the test finishes
                // promptly. The spec budget is "decodeDeadline +
                // spawn-budget"; we target ≤20 s total below.
                decodeDeadline: .seconds(5),
                respawnDeadline: .seconds(30),
                spawnTimeout: .seconds(10)),
            hostFactory: factory.factory)
        defer { trans.shutdown() }

        // The first decode hits the wedged subprocess: it must throw
        // `transcriptionFailed(-1)` after the 5 s deadline, the parent
        // SIGKILLs and respawns, and the second decode succeeds on the
        // fresh subprocess.
        let samples = makeSyntheticSamples(seconds: 1)
        let opts = WhisperOptions()
        let clock = ContinuousClock()

        let totalStart = clock.now
        var wedgeRecovered = false
        do {
            _ = try trans.transcribeWindow(
                samples, windowStart: .seconds(0), options: opts, abort: nil)
            Issue.record("expected the first decode to fail (subprocess wedged)")
        } catch WhisperTranscribeError.transcriptionFailed(let code) {
            // Spec §6: a wedged window throws `.transcriptionFailed(-1)`.
            #expect(code == -1)
            wedgeRecovered = true
        } catch {
            Issue.record("unexpected error from wedged decode: \(error)")
        }
        #expect(wedgeRecovered)

        // The respawn happens lazily inside the failed call's
        // `handleHostError` path. The next decode should land on the
        // fresh subprocess and succeed.
        let secondDecode = try trans.transcribeWindow(
            samples, windowStart: .seconds(0), options: opts, abort: nil)
        let totalElapsed = clock.now - totalStart

        // The second decode produces a real result (segments may be
        // empty for synthetic silence, but the call must return without
        // throwing). The interesting acceptance signal is timing.
        _ = secondDecode

        // Acceptance budget: decodeDeadline (5 s) + spawn + model load
        // (base CPU ≈ a few s) + one short decode ≤ 20 s.
        #expect(totalElapsed < .seconds(20),
                "wedge-recovery elapsed \(totalElapsed) exceeded 20s budget")

        // Both host slots in the factory were consumed: the wedged
        // first and the clean respawn second.
        #expect(factory.callCount == 2)
    }

    // MARK: - Test 2: Flock collision

    @Test(
        "WhisperSubprocessAcceptance: two pulsartrace-whisper subprocesses on the same lockPath: second exits 75",
        .enabled(if: hasBaseModelCached()),
        .timeLimit(.minutes(1)))
    func flockCollisionExitCode75() throws {
        // The flock test does NOT need the model — neither subprocess
        // sends `init` (the second one exits before we even connect).
        // We still gate on `hasBaseModelCached()` so the suite has a
        // single uniform skip condition.
        let binaryURL = try resolveWhisperBinary()
        let tempDir = makeTempDir(tag: "flock")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockPath = tempDir.appendingPathComponent("whisper.lock")

        // --- First subprocess: acquires the lock, prints "ready: …".
        let proc1Socket = tempDir.appendingPathComponent("a.sock")
        let proc1 = Process()
        proc1.executableURL = binaryURL
        proc1.arguments = [
            "--socket-path", proc1Socket.path,
            "--lock-path", lockPath.path,
            "--cpu",
        ]
        let proc1Stdout = Pipe()
        proc1.standardOutput = proc1Stdout
        // Drain stderr into a pipe too so it doesn't leak into the
        // test runner's stderr; we don't assert on it.
        proc1.standardError = Pipe()
        try proc1.run()

        // Wait for "ready: <path>\n" on proc1's stdout — confirms the
        // lock is held. A 5 s budget is generous for a no-model
        // listener bind; bind() is sub-millisecond on a hot path.
        let handshake = try readLineWithTimeout(
            from: proc1Stdout.fileHandleForReading,
            timeout: .seconds(5))
        let expectedHandshake = "ready: \(proc1Socket.path)"
        #expect(handshake.trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedHandshake)

        defer {
            // Always reap proc1 even on failure — leaving it alive
            // would orphan a subprocess holding the lock for the next
            // test run.
            if proc1.isRunning {
                kill(proc1.processIdentifier, SIGTERM)
                proc1.waitUntilExit()
                if proc1.isRunning {
                    kill(proc1.processIdentifier, SIGKILL)
                    proc1.waitUntilExit()
                }
            }
        }

        // --- Second subprocess: same lock path, should exit 75 fast.
        let proc2Socket = tempDir.appendingPathComponent("b.sock")
        let proc2 = Process()
        proc2.executableURL = binaryURL
        proc2.arguments = [
            "--socket-path", proc2Socket.path,
            "--lock-path", lockPath.path,
            "--cpu",
        ]
        proc2.standardOutput = Pipe()
        let proc2StderrPipe = Pipe()
        proc2.standardError = proc2StderrPipe
        try proc2.run()
        proc2.waitUntilExit()

        // Spec §5/§8: another instance holding the lock → exit 75.
        #expect(proc2.terminationStatus == 75,
                "second subprocess should exit 75, got \(proc2.terminationStatus)")

        // The stderr message helps a human operator diagnose the
        // collision; assert it carries the "already running" string we
        // log in `main.swift`.
        let stderrData = proc2StderrPipe.fileHandleForReading
            .readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        #expect(stderrText.contains("already running"),
                "expected 'already running' in proc2 stderr, got: \(stderrText)")
    }

    // MARK: - Test 3 (skipped here; documented for context)

    // The third spec acceptance criterion — "recording continues
    // uninterrupted when whisper wedges" — is deferred. It needs the
    // full live pipeline driven against both system + mic socket
    // sources with a wedged subprocess in the loop, which is wider
    // scope than this structural-invariants suite. Phase 4's
    // architectural decoupling (audio capture + WAV writers live in
    // `pulsartrace-engine`, not in `pulsartrace-whisper`) is the
    // structural guarantee; observability of that invariant in a
    // live pipeline test is tracked separately if/when it becomes
    // worth automating.
}

// MARK: - Skip-gate helper

/// Gate used by `@Test(.enabled(if: ...))`. Returns `true` when the
/// `base` whisper model is already present in the user's cache, so
/// these tests can run without triggering a ~140 MB download on a
/// fresh dev box / CI box.
private func hasBaseModelCached() -> Bool {
    let modelURL = ModelStore.defaultCacheDirectory()
        .appendingPathComponent(ModelCatalog.base.fileName)
    return FileManager.default.fileExists(atPath: modelURL.path)
}

/// Return the local `ggml-base.bin` path (precondition: cached, gated
/// by `hasBaseModelCached`).
private func locateCachedBaseModel() throws -> URL {
    let modelURL = ModelStore.defaultCacheDirectory()
        .appendingPathComponent(ModelCatalog.base.fileName)
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        // Shouldn't happen — `.enabled(if:)` gates this — but a
        // defensive throw beats a confusing whisper.cpp "no such file"
        // crash inside the subprocess.
        throw AcceptanceTestError.modelNotCached(modelURL.path)
    }
    return modelURL
}

// MARK: - Binary resolution

/// Locate the `pulsartrace-whisper` executable that was built into the
/// project's `.build/<arch>/<config>/` directory.
///
/// Under `swift test` the runner's `CommandLine.arguments[0]` is
/// `/Applications/Xcode.app/.../usr/libexec/swift/pm/swiftpm-testing-helper`,
/// which has no sibling whisper binary — so we can't reuse
/// `WhisperBinaryResolver.defaultBinaryURL()` here. Instead we walk up
/// from this source file's `#filePath` to the package root (which is
/// stable across machines because SwiftPM bakes `#filePath` in at
/// compile time) and search the `.build/` tree for a built binary.
///
/// Resolution order:
///   1. `PULSARTRACE_WHISPER_BINARY` env override if set + executable.
///   2. Any `pulsartrace-whisper` discovered by a shallow walk under
///      `<package-root>/.build/`. The first executable hit wins.
private func resolveWhisperBinary(testFilePath: String = #filePath) throws -> URL {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo
        .environment[WhisperBinaryResolver.envOverrideKey],
       !override.isEmpty,
       fm.isExecutableFile(atPath: override) {
        return URL(fileURLWithPath: override)
    }

    // Walk from this source file (Tests/PipelineTests/WhisperSubprocessAcceptanceTests.swift)
    // up to the package root (the directory holding `Package.swift` and
    // `.build/`). Two `deletingLastPathComponent`s puts us at the
    // project root.
    let packageRoot = URL(fileURLWithPath: testFilePath)
        .deletingLastPathComponent()   // Tests/PipelineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <package root>
    let buildDir = packageRoot.appendingPathComponent(".build", isDirectory: true)

    // Probe the well-known SwiftPM layout first — fastest path on a
    // hot dev box.
    let arch = currentArchitectureTriple()
    let candidates: [URL] = [
        buildDir.appendingPathComponent("debug/pulsartrace-whisper"),
        buildDir.appendingPathComponent("release/pulsartrace-whisper"),
        buildDir.appendingPathComponent("\(arch)/debug/pulsartrace-whisper"),
        buildDir.appendingPathComponent("\(arch)/release/pulsartrace-whisper"),
    ]
    for c in candidates {
        if fm.isExecutableFile(atPath: c.path) {
            return c
        }
    }

    // Fallback: shallow enumeration in case SwiftPM changes the layout
    // (e.g. cross-compile profile dirs). Bounded depth so we never
    // descend into Swift package checkouts.
    if let url = findFirstWhisperBinary(under: buildDir, maxDepth: 3) {
        return url
    }
    throw AcceptanceTestError.binaryNotFound(argv0: testFilePath)
}

/// Current-architecture triple SwiftPM uses for its build directory
/// (`arm64-apple-macosx`, `x86_64-apple-macosx`). Mirrors the directory
/// name `swift build` writes under `.build/`.
private func currentArchitectureTriple() -> String {
    #if arch(arm64)
    return "arm64-apple-macosx"
    #elseif arch(x86_64)
    return "x86_64-apple-macosx"
    #else
    return ""
    #endif
}

/// Shallow recursive search for an executable named `pulsartrace-whisper`
/// under `root`, bounded by `maxDepth`. Returns the first hit.
private func findFirstWhisperBinary(under root: URL, maxDepth: Int) -> URL? {
    let fm = FileManager.default
    guard maxDepth >= 0,
          let entries = try? fm.contentsOfDirectory(at: root,
              includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
              options: [.skipsHiddenFiles]) else {
        return nil
    }
    for entry in entries {
        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey])
            .isDirectory) ?? false
        if !isDir, entry.lastPathComponent == "pulsartrace-whisper",
           fm.isExecutableFile(atPath: entry.path) {
            return entry
        }
    }
    // Recurse — depth first into directories that might hold the
    // binary (skip well-known irrelevant subtrees to keep the walk fast).
    let skip: Set<String> = [
        "checkouts", "repositories", "ModuleCache",
        "index", "plugins", "artifacts",
    ]
    for entry in entries {
        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey])
            .isDirectory) ?? false
        if isDir && !skip.contains(entry.lastPathComponent) {
            if let hit = findFirstWhisperBinary(under: entry,
                                                maxDepth: maxDepth - 1) {
                return hit
            }
        }
    }
    return nil
}

private enum AcceptanceTestError: Error, CustomStringConvertible {
    case binaryNotFound(argv0: String)
    case modelNotCached(String)
    case handshakeTimeout
    case readError(String)

    var description: String {
        switch self {
        case .binaryNotFound(let argv0):
            return "could not locate pulsartrace-whisper near argv0=\(argv0)"
        case .modelNotCached(let p):
            return "base model not cached at \(p)"
        case .handshakeTimeout:
            return "timed out waiting for handshake line"
        case .readError(let m):
            return "read error: \(m)"
        }
    }
}

// MARK: - Temp dir + synthetic samples

/// Build a unique temp directory rooted at the test runner's writable
/// scratch space. Used as the socket directory + lock home for one
/// test.
///
/// Resolution order:
///   1. `TMPDIR` env var (set by the Claude Code Bash sandbox to a
///      writable allowlisted directory).
///   2. `FileManager.default.temporaryDirectory` (resolves to
///      `/var/folders/.../T/` on macOS).
///
/// Unix-domain-socket paths have a ~104 byte limit on Darwin; the
/// per-test directory must be short enough that any `w-<8hex>.sock`
/// minted under it still fits. The tag is intentionally short.
private func makeTempDir(tag: String) -> URL {
    let base: URL
    if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
        base = URL(fileURLWithPath: tmp, isDirectory: true)
    } else {
        base = FileManager.default.temporaryDirectory
    }
    let dir = base
        .appendingPathComponent("pt-w\(tag)-\(UUID().uuidString.prefix(8))",
                                isDirectory: true)
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    return dir
}

/// One second of low-energy synthetic audio at 16 kHz mono. The wedge
/// test only cares whether decode returns; segments may be empty.
private func makeSyntheticSamples(seconds: Int) -> [Float] {
    let sampleRate = 16_000
    let count = sampleRate * seconds
    // A bit of sub-threshold noise so whisper sees "audio" rather than
    // a hard-zero buffer — defensive even though the wedged subprocess
    // never reaches the inference path.
    var result = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let phase = Float(i) / Float(sampleRate)
        result[i] = 0.001 * Float(sinf(2 * .pi * 220 * phase))
    }
    return result
}

// MARK: - Sequenced real-host factory

/// `RemoteWindowTranscriber.HostFactory` that returns a sequence of
/// real `WhisperSubprocessHost` instances, each built from its own
/// canned `WhisperSubprocessHost.Configuration`. Lets the wedge test
/// inject `--hang-on-sentinel` for the *first* spawn and a normal
/// config for the respawn — something the engine-facing
/// `RemoteWindowTranscriber.Configuration` cannot express on its own
/// (it has one set of args for every host the transcriber builds).
private final class SequencedRealHostConfigs: @unchecked Sendable {
    let configs: [WhisperSubprocessHost.Configuration]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(configs: [WhisperSubprocessHost.Configuration]) {
        self.configs = configs
    }

    /// Closure compatible with `RemoteWindowTranscriber.HostFactory`.
    ///
    /// On the i'th call we return a host built from `configs[i]`,
    /// ignoring the `RemoteWindowTranscriber`'s own derived config —
    /// the test is asserting on argv differences, so the canned
    /// configs are the source of truth.
    var factory: RemoteWindowTranscriber.HostFactory {
        return { [self] _, logger in
            let idx: Int = lock.withLock {
                let i = _callCount
                _callCount += 1
                return i
            }
            let config: WhisperSubprocessHost.Configuration
            if idx < configs.count {
                config = configs[idx]
            } else {
                // Past the end of the canned configs, return the last
                // one again rather than crashing — tests that don't
                // expect a third spawn will fail earlier on
                // `callCount`.
                config = configs.last!
            }
            return WhisperSubprocessHost(configuration: config, logger: logger)
        }
    }
}

// MARK: - Handshake reader (used by the flock test)

/// Read one `\n`-terminated line from `fh` within `timeout`. Spawns a
/// detached thread to do the blocking read (so the timeout can be
/// honored) and signals a `DispatchSemaphore` on completion.
///
/// On timeout, closes the underlying fd to unblock the thread, then
/// throws `AcceptanceTestError.handshakeTimeout`.
///
/// (Why not reuse `WhisperSubprocessHost.readHandshake`? It is private
/// to the host. Lifting it here keeps the test independent of
/// internal-typed APIs while staying small.)
private func readLineWithTimeout(
    from fh: FileHandle, timeout: Duration
) throws -> String {
    let resultBox = HandshakeReaderBox()
    let sem = DispatchSemaphore(value: 0)

    Thread.detachNewThread {
        var buffer = Data()
        while true {
            let chunk = fh.availableData
            if chunk.isEmpty {
                resultBox.setEOF()
                sem.signal()
                return
            }
            buffer.append(chunk)
            if let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let prefix = buffer.prefix(through: newlineIdx)
                let line = String(data: prefix, encoding: .utf8) ?? ""
                resultBox.setLine(line)
                sem.signal()
                return
            }
        }
    }

    let parts = timeout.components
    let ms = Int(parts.seconds) * 1000
        + Int(parts.attoseconds / 1_000_000_000_000_000)
    switch sem.wait(timeout: .now() + .milliseconds(ms)) {
    case .success:
        if let line = resultBox.line { return line }
        if resultBox.eof {
            throw AcceptanceTestError.readError(
                "stdout closed before handshake (subprocess exited?)")
        }
        throw AcceptanceTestError.handshakeTimeout
    case .timedOut:
        // Unblock the reader by closing the fd. The thread returns on
        // EOF and frees its memory; we don't wait for it.
        try? fh.close()
        throw AcceptanceTestError.handshakeTimeout
    }
}

/// Reference-typed shared state for the handshake reader thread.
/// `Thread.detachNewThread` requires a `@Sendable` closure under Swift
/// 6 strict concurrency, so the closure cannot capture mutable locals
/// — it captures this class by reference instead.
private final class HandshakeReaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _line: String?
    private var _eof: Bool = false
    var line: String? { lock.withLock { _line } }
    var eof: Bool { lock.withLock { _eof } }
    func setLine(_ s: String) { lock.withLock { _line = s } }
    func setEOF() { lock.withLock { _eof = true } }
}

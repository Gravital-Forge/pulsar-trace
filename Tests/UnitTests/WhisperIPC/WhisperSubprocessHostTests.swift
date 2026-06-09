import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Pure-Swift coverage of `WhisperSubprocessHost`'s value types.
///
/// Real subprocess wiring — spawn + handshake + Init + Decode + kill —
/// is exercised by the Phase 7 acceptance suite. Keeping this phase to
/// fakeable unit tests avoids the cost and flakiness of real-binary
/// spawn in the unit layer; the value types here still need their own
/// regressions for default values and error descriptions.
@Suite("WhisperSubprocessHost")
struct WhisperSubprocessHostTests {

    @Test("Configuration default deadlines match the spec")
    func configurationDefaults() {
        let config = WhisperSubprocessHost.Configuration(
            binaryURL: URL(fileURLWithPath: "/tmp/pulsartrace-whisper"),
            socketDirectory: URL(fileURLWithPath: "/tmp/sockets"))
        // 10 s matches `DecodeWatchdog.deadline` and the spec §6
        // budget for handshake propagation.
        #expect(config.spawnTimeout == .seconds(10))
        // 180 s — see `Configuration.init` doc. Base-model cold load
        // is sub-second; the headroom is for a warm respawn whose
        // GPU/CoreML state from a SIGKILLed predecessor takes seconds
        // to release (2026-05-28 incident — the prior 60 s default
        // tripped `init refused` and the live pass never recovered).
        #expect(config.initTimeout == .seconds(180))
        #expect(config.forceCPU == false)
        #expect(config.lockPath == nil)
    }

    @Test("HostError descriptions identify the failure mode")
    func errorDescriptions() {
        let cases: [(WhisperSubprocessHost.HostError, String)] = [
            (.binaryNotFound("/tmp/x"), "binary"),
            (.spawnFailed("oh no"), "spawn"),
            (.handshakeTimedOut, "handshake"),
            (.handshakeMalformed("garbage"), "malformed"),
            (.connectFailed(errno: 2), "UDS connect"),
            (.initRefused("init no"), "init"),
            (.readTimedOut, "timed out"),
            (.readEOF, "between frames"),
            (.writeFailed("EPIPE"), "write"),
            (.subprocessGone(exitStatus: 75), "exited"),
        ]
        for (err, fragment) in cases {
            #expect(err.description.contains(fragment),
                    "expected \"\(err.description)\" to contain \"\(fragment)\"")
        }
    }

    @Test("HostError Equatable distinguishes variants and payloads")
    func errorEquatable() {
        #expect(WhisperSubprocessHost.HostError.handshakeTimedOut
                == WhisperSubprocessHost.HostError.handshakeTimedOut)
        #expect(WhisperSubprocessHost.HostError.binaryNotFound("/a")
                != WhisperSubprocessHost.HostError.binaryNotFound("/b"))
        #expect(WhisperSubprocessHost.HostError.connectFailed(errno: 2)
                != WhisperSubprocessHost.HostError.connectFailed(errno: 13))
        #expect(WhisperSubprocessHost.HostError.subprocessGone(exitStatus: nil)
                != WhisperSubprocessHost.HostError.subprocessGone(exitStatus: 0))
    }

    /// Verifies the stderr drainer: each newline-terminated line that
    /// arrives on a pipe's read end becomes one `notice` log call with a
    /// `[whisper-subprocess]` prefix. Without this, whisper.cpp's
    /// pre-death stderr (Metal errors, ggml assertions, OOM aborts) is
    /// invisible from `~/Library/Logs/PulsarTrace/*.log` — exactly the
    /// gap the 2026-05-27 12-second crash exposed.
    @Test("drainStderrLines forwards each newline-delimited stderr line as a notice and exits on EOF")
    func drainStderrLinesForwardsLines() {
        let pipe = Pipe()
        let capture = CapturingDrainLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            WhisperSubprocessHost.drainStderrLines(
                from: pipe.fileHandleForReading, logger: logger)
            done.signal()
        }

        let payload = "whisper_init: failed to init Metal backend\nfatal: GGML_ASSERT(false)\n"
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        try? pipe.fileHandleForWriting.close()
        // The drainer must exit on EOF — otherwise the subprocess's
        // teardown task leaks.
        let result = done.wait(timeout: .now() + .seconds(2))
        #expect(result == .success, "drainer must exit promptly on EOF")

        let messages = capture.messages
        #expect(messages.contains {
            $0.contains("[whisper-subprocess]") && $0.contains("Metal backend")
        }, "saw: \(messages)")
        #expect(messages.contains {
            $0.contains("[whisper-subprocess]") && $0.contains("GGML_ASSERT")
        }, "saw: \(messages)")
    }

    @Test("drainStderrLines flushes a trailing partial line (no terminating newline) at EOF")
    func drainStderrLinesFlushesTrailingPartial() {
        let pipe = Pipe()
        let capture = CapturingDrainLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            WhisperSubprocessHost.drainStderrLines(
                from: pipe.fileHandleForReading, logger: logger)
            done.signal()
        }

        // No trailing newline — subprocess killed mid-line.
        pipe.fileHandleForWriting.write(Data("partial death rattle".utf8))
        try? pipe.fileHandleForWriting.close()
        _ = done.wait(timeout: .now() + .seconds(2))

        #expect(capture.messages.contains {
            $0.contains("[whisper-subprocess]") && $0.contains("death rattle")
        }, "trailing partial line must be flushed; saw: \(capture.messages)")
    }

    /// Hard Invariant #7: the operational log never contains full user
    /// paths. `pulsartrace-whisper` writes its lock path to stderr on
    /// lock failure ("ERROR: could not acquire whisper lock at …"), so
    /// the drainer must redact `NSHomeDirectory()` before forwarding.
    @Test("forwarded stderr lines have the home directory redacted (Invariant 7)")
    func drainRedactsHomePaths() {
        let pipe = Pipe()
        let capture = CapturingDrainLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            WhisperSubprocessHost.drainStderrLines(
                from: pipe.fileHandleForReading, logger: logger)
            done.signal()
        }

        let raw = "ERROR: could not acquire whisper lock at \(NSHomeDirectory())/Library/Application Support/PulsarTrace/whisper.lock: errno 13\n"
        pipe.fileHandleForWriting.write(Data(raw.utf8))
        try? pipe.fileHandleForWriting.close()
        _ = done.wait(timeout: .now() + .seconds(2))

        let messages = capture.messages
        #expect(!messages.isEmpty, "expected at least one forwarded line")
        #expect(!messages.contains {
            $0.contains(NSHomeDirectory())
        }, "raw home path leaked into the log; saw: \(messages)")
        #expect(messages.contains {
            $0.contains("~/Library/Application Support/PulsarTrace/whisper.lock")
        }, "expected the redacted ~-form; saw: \(messages)")
    }

    @Test("the EOF-flushed trailing partial line is also home-redacted (Invariant 7)")
    func drainRedactsHomePathsInTrailingPartial() {
        let pipe = Pipe()
        let capture = CapturingDrainLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            WhisperSubprocessHost.drainStderrLines(
                from: pipe.fileHandleForReading, logger: logger)
            done.signal()
        }

        // No trailing newline — exercises the EOF-flush emit site.
        let raw = "ERROR: could not acquire whisper lock at \(NSHomeDirectory())/Library/Application Support/PulsarTrace/whisper.lock"
        pipe.fileHandleForWriting.write(Data(raw.utf8))
        try? pipe.fileHandleForWriting.close()
        _ = done.wait(timeout: .now() + .seconds(2))

        let messages = capture.messages
        #expect(!messages.isEmpty, "expected the trailing partial line to be flushed")
        #expect(!messages.contains {
            $0.contains(NSHomeDirectory())
        }, "raw home path leaked via the EOF flush; saw: \(messages)")
        #expect(messages.contains {
            $0.contains("~/Library/Application Support/PulsarTrace/whisper.lock")
        }, "expected the redacted ~-form on the EOF flush; saw: \(messages)")
    }

    @Test("startAndInitialize on a nonexistent binary throws .binaryNotFound without spawning")
    func nonexistentBinary() throws {
        let config = WhisperSubprocessHost.Configuration(
            binaryURL: URL(fileURLWithPath: "/nonexistent/pulsartrace-whisper"),
            socketDirectory: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true))
        let host = WhisperSubprocessHost(
            configuration: config,
            logger: .init(label: "test"))
        #expect(host.isAlive == false)
        do {
            try host.startAndInitialize(model: "/tmp/model.bin")
            Issue.record("expected throw")
        } catch WhisperSubprocessHost.HostError.binaryNotFound(let path) {
            #expect(path == "/nonexistent/pulsartrace-whisper")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(host.isAlive == false)
        #expect(host.exitStatus == nil)
    }

    // NOTE: the real-spawn "wire-up" test for `startAndInitialize`'s
    // stderr drainer lives in `WhisperSubprocessAcceptanceTests`
    // (`startAndInitializeDrainsStderrFromRealSubprocess`). It is in
    // the serialized acceptance suite because the subprocess fork
    // imposes kernel-scheduling latency that flakes the tight-budget
    // timing tests in adjacent unit suites (the 80 ms heartbeat / the
    // 30 ms respawn-backoff log) when run in parallel.
}

/// Lock-protected log sink used by the stderr-drainer tests. Same
/// shape as the helper in the other WhisperIPC tests but kept private
/// to this file so the unit-tests target doesn't grow yet another
/// transitive symbol.
private final class CapturingDrainLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _m: [String] = []
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey k: String) -> Logger.Metadata.Value? {
        get { metadata[k] } set { metadata[k] = newValue }
    }
    var messages: [String] { lock.withLock { _m } }
    func log(level: Logger.Level, message: Logger.Message,
             metadata: Logger.Metadata?, source: String,
             file: String, function: String, line: UInt) {
        lock.withLock { _m.append("\(message)") }
    }
}


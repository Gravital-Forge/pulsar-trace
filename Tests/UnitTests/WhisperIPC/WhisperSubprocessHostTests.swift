import Testing
import Foundation
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
        // 60 s is a generous cap on model-load time; large-v3 takes
        // ~5–15 s in practice but bounding it prevents an unbounded
        // hang on a corrupted model.
        #expect(config.initTimeout == .seconds(60))
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
}

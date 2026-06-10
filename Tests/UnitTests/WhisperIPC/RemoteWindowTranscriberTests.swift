import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Coverage of `RemoteWindowTranscriber`'s decode + watchdog state
/// machine via a fake `WhisperHostProtocol`. The real host is not
/// spawned here — those code paths are exercised by Phase 7.
@Suite("RemoteWindowTranscriber")
struct RemoteWindowTranscriberTests {

    // MARK: - Happy path

    @Test("happy path: decode returns a TranscriptionResult shifted into recording-absolute time")
    func happyPath() throws {
        let fake = FakeHost()
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [
                WhisperIPCSegment(text: "hello", startMs: 12_000, endMs: 13_500),
                WhisperIPCSegment(text: "world", startMs: 13_500, endMs: 15_000),
            ],
            language: "en"))
        let factory = SingleHostFactory(host: fake)

        let trans = makeTranscriber(factory: factory.factory)
        let result = try trans.transcribeWindow(
            [0.1, 0.2, 0.3],
            windowStart: .seconds(12),
            options: WhisperOptions(),
            abort: nil)

        #expect(result.language == "en")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "hello")
        #expect(result.segments[0].start == .seconds(12))
        #expect(result.segments[0].end == .milliseconds(13_500))
        #expect(result.segments[1].text == "world")
        #expect(fake.startCalls == 1)
        #expect(fake.decodeCalls == 1)
        // Lazy-init: only one host built so far.
        #expect(factory.callCount == 1)
    }

    @Test("subsequent decodes reuse the same host — no respawn on the steady path")
    func decodesReuseHost() throws {
        let fake = FakeHost()
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [WhisperIPCSegment(text: "x", startMs: 0, endMs: 100)],
            language: "en"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        for _ in 0..<3 {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(0),
                options: WhisperOptions(), abort: nil)
        }
        #expect(fake.startCalls == 1)
        #expect(fake.decodeCalls == 3)
        #expect(factory.callCount == 1)
    }

    // MARK: - Empty audio

    @Test("empty samples throw emptyAudio without spawning a host")
    func emptyAudioShortCircuits() {
        let fake = FakeHost()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeWindow(
                [], windowStart: .seconds(0),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.emptyAudio {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(factory.callCount == 0)
    }

    // MARK: - Deadline + respawn

    @Test("readTimedOut: host SIGKILL'd, fresh host spawned, wedged window surfaced as transcriptionFailed")
    func deadlineTriggersRespawn() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut

        let fresh = FakeHost()
        fresh.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [WhisperIPCSegment(text: "recovered", startMs: 5_000, endMs: 6_000)],
            language: "en"))

        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let trans = makeTranscriber(
            factory: factory.factory,
            logBackoffInitial: .milliseconds(10))

        // First decode: hits the wedge → SIGKILL + respawn + throws
        // transcriptionFailed for this window.
        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(1),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed(let code) {
            #expect(code == -1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
        #expect(factory.callCount == 2)

        // Second decode (the "next window" in the engine's stream)
        // succeeds on the fresh host.
        let result = try trans.transcribeWindow(
            [0.1], windowStart: .seconds(2),
            options: WhisperOptions(), abort: nil)
        #expect(result.segments.first?.text == "recovered")
        #expect(fresh.decodeCalls == 1)
    }

    @Test("readTimedOut: emits the legacy 'exceeded deadline' warning so log-greppers keep working")
    func deadlineLogsLegacyMessage() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut
        let fresh = FakeHost()
        fresh.cannedDecode = decodedResponse()
        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(10))

        _ = try? trans.transcribeWindow(
            [0.1], windowStart: .seconds(1),
            options: WhisperOptions(), abort: nil)

        let exceeded = capture.messages.filter { $0.contains("exceeded deadline") }
        #expect(exceeded.count == 1, "saw: \(capture.messages)")
    }

    // Gated under `--filter UnitTests`: the test relies on a detached
    // backoff-log `Task` firing within a short slow-host window, and the
    // 50+ suites in the broad UnitTests run starve the cooperative pool
    // hard enough that the Task often doesn't schedule before the window
    // closes — the same cross-suite parallelism race CLAUDE.md documents
    // for `--filter PipelineTests`. Passes deterministically under
    // `--filter RemoteWindowTranscriber`. Re-enable when the cross-suite
    // async mutex lands (see CLAUDE.md "Known limitation").
    @Test(
        "respawn that takes longer than the initial backoff emits at least one 'still waiting' log line",
        .disabled("flaky under parallel UnitTests pool starvation; verify with --filter RemoteWindowTranscriber"))
    func backoffLogFires() async throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut
        let slow = FakeHost()
        slow.startDelay = .milliseconds(500)
        slow.cannedDecode = decodedResponse()

        let factory = SequencedHostFactory(hosts: [wedged, slow])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(30))

        _ = try? trans.transcribeWindow(
            [0.1], windowStart: .seconds(1),
            options: WhisperOptions(), abort: nil)

        let waiting = capture.messages.filter {
            $0.contains("still waiting for whisper subprocess respawn")
        }
        #expect(waiting.count >= 1,
                "expected backoff log; saw: \(capture.messages)")
    }

    // MARK: - Subprocess-reported error

    @Test(".error response from subprocess surfaces as a WhisperTranscribeError matching the kind")
    func subprocessErrorSurfaced() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "transcription_failed",
            message: "whisper_full returned -1"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(1),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
        // No respawn — the subprocess is still healthy, the *window*
        // failed decode.
        #expect(fake.sigkillCalls == 0)
        #expect(factory.callCount == 1)
    }

    @Test(".error with an unknown kind logs kind+message before collapsing to transcriptionFailed(-1)")
    func subprocessUnknownErrorLogsPayload() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "decode_internal",
            message: "samples decode failed: bad base64"))
        let factory = SingleHostFactory(host: fake)
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture })

        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(1),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
        let payloadMatches = capture.messages.filter {
            $0.contains("decode_internal") && $0.contains("bad base64")
        }
        #expect(payloadMatches.count >= 1,
                "expected subprocess error kind/message to be logged; saw: \(capture.messages)")
    }

    @Test(".error with kind=model_not_found maps to WhisperTranscribeError.modelNotFound")
    func subprocessModelNotFoundMapped() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "model_not_found",
            message: "no model"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(1),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelNotFound {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    // MARK: - Non-recoverable spawn failure

    @Test("first start fails with .binaryNotFound — surfaced as modelLoadFailed")
    func startBinaryNotFound() {
        let factory = SequencedHostFactory(
            hosts: [],
            startErrors: [.binaryNotFound("/nope")])
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(0),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let message) {
            #expect(message.contains("/nope"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("handleHostError log identifies the specific HostError variant, not 'exceeded deadline' for all 4 cases")
    func handleHostErrorLogIdentifiesVariant() throws {
        // Mirrors the refinement counterpart: the warning has to
        // identify whether the failure was a true `decodeDeadline`
        // expiry vs a `readEOF` / `writeFailed` / `subprocessGone`
        // crash. Today's log lied with "exceeded deadline" for all
        // four variants — even a 12-second subprocess crash with a
        // 120-second deadline.
        let wedged = FakeHost()
        wedged.cannedDecodeError = .subprocessGone(exitStatus: 134)
        let fresh = FakeHost()
        fresh.cannedDecode = decodedResponse()
        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(10))

        _ = try? trans.transcribeWindow(
            [0.1], windowStart: .seconds(1),
            options: WhisperOptions(), abort: nil)

        let variantMatches = capture.messages.filter {
            $0.contains("killing subprocess for respawn")
                && ($0.contains("subprocessGone") || $0.contains("exited (status=134)"))
        }
        #expect(variantMatches.count >= 1,
                "expected HostError variant in warning; saw: \(capture.messages)")
    }

    @Test("respawn that fails to start the replacement host logs the spawn error before rethrowing")
    func respawnFailureLogsSpawnError() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut

        let factory = SequencedHostFactory(
            hosts: [wedged],
            // Second factory call (the respawn) throws.
            startErrors: [nil, .binaryNotFound("/gone")])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(10))

        _ = try? trans.transcribeWindow(
            [0.1], windowStart: .seconds(1),
            options: WhisperOptions(), abort: nil)

        // Before 2026-05-27 the respawn's catch did `throw error` with
        // no logger call — so a wedge that hit a real spawn failure
        // (binary missing, lock held, handshake timed out) left no
        // trace beyond "still waiting" backoff lines. The fix adds an
        // explicit error log when the respawn cannot bring a host back.
        let respawnFailure = capture.messages.filter {
            $0.contains("whisper subprocess respawn failed")
                && $0.contains("/gone")
        }
        #expect(respawnFailure.count >= 1,
                "expected respawn-failure log; saw: \(capture.messages)")
    }

    @Test("respawn fails with .binaryNotFound — surfaced as modelLoadFailed on the wedged window")
    func respawnFailureSurfacesModelLoadFailed() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut

        let factory = SequencedHostFactory(
            hosts: [wedged],
            // Second factory call (the respawn) throws.
            startErrors: [nil, .binaryNotFound("/gone")])
        let trans = makeTranscriber(
            factory: factory.factory,
            logBackoffInitial: .milliseconds(10))

        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(1),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let m) {
            #expect(m.contains("/gone"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
    }

    @Test("first start with .initRefused surfaces as modelLoadFailed")
    func initRefusedNonRecoverable() {
        let factory = SequencedHostFactory(
            hosts: [],
            startErrors: [.initRefused("model corrupt")])
        let trans = makeTranscriber(factory: factory.factory)
        do {
            _ = try trans.transcribeWindow(
                [0.1], windowStart: .seconds(0),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let m) {
            #expect(m.contains("model corrupt"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    // MARK: - Shutdown

    @Test("shutdown: terminates the host cooperatively")
    func shutdownTerminatesHost() throws {
        let fake = FakeHost()
        fake.cannedDecode = decodedResponse()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        _ = try trans.transcribeWindow(
            [0.1], windowStart: .seconds(0),
            options: WhisperOptions(), abort: nil)

        trans.shutdown()
        #expect(fake.terminateCalls == 1)
        // Idempotent: a second shutdown is a no-op.
        trans.shutdown()
        #expect(fake.terminateCalls == 1)
    }

    @Test("abort token is silently ignored (no log, no failure)")
    func abortTokenIgnored() throws {
        let fake = FakeHost()
        fake.cannedDecode = decodedResponse()
        let factory = SingleHostFactory(host: fake)
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture })

        let token = AbortToken()
        let result = try trans.transcribeWindow(
            [0.1], windowStart: .seconds(0),
            options: WhisperOptions(),
            abort: token)
        #expect(result.segments.count >= 1)
        // No warning about ignoring the token — silent on purpose.
        let warns = capture.messages.filter { $0.lowercased().contains("abort") }
        #expect(warns.isEmpty)
    }
}

// MARK: - Test fixtures

private func makeTranscriber(
    factory: @escaping RemoteWindowTranscriber.HostFactory,
    logger: Logger = Logger(label: "test"),
    logBackoffInitial: Duration = .milliseconds(5)
) -> RemoteWindowTranscriber {
    let config = RemoteWindowTranscriber.Configuration(
        binaryURL: URL(fileURLWithPath: "/tmp/fake-whisper"),
        modelURL: URL(fileURLWithPath: "/tmp/model.bin"),
        socketDirectory: URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true),
        decodeDeadline: .milliseconds(50),
        respawnDeadline: .seconds(2),
        spawnTimeout: .seconds(2),
        logBackoffInitial: logBackoffInitial,
        logBackoffCap: .milliseconds(100))
    return RemoteWindowTranscriber(
        configuration: config,
        logger: logger,
        hostFactory: factory)
}

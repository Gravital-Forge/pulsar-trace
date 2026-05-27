import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Coverage of `RemoteRegionTranscriber`'s decode + watchdog state
/// machine via a fake `WhisperHostProtocol`. The real host is not
/// spawned here — those code paths are exercised by Phase 7.
///
/// Mirrors `RemoteWindowTranscriberTests` for the refinement path.
@Suite("RemoteRegionTranscriber")
struct RemoteRegionTranscriberTests {

    // MARK: - Happy path

    @Test("happy path: decode returns a TranscriptionResult with recording-absolute segment times")
    func happyPath() throws {
        let fake = FakeHost()
        // Subprocess returns recording-absolute segment timestamps (it
        // applied the regionStartMs shift internally), matching the
        // in-process `WhisperTranscriber.transcribeRegion` contract.
        fake.cannedDecode = .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [
                WhisperIPCSegment(text: "hello", startMs: 12_000, endMs: 13_500),
                WhisperIPCSegment(text: "world", startMs: 13_500, endMs: 15_000),
            ],
            language: "en"))
        let factory = SingleHostFactory(host: fake)

        let trans = makeTranscriber(factory: factory.factory)
        let region = SpeechRegion(start: .seconds(12), end: .seconds(15))
        let result = try trans.transcribeRegion(
            [0.1, 0.2, 0.3],
            region: region,
            options: WhisperOptions())

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

        let region = SpeechRegion(start: .zero, end: .seconds(1))
        for _ in 0..<3 {
            _ = try trans.transcribeRegion(
                [0.1], region: region, options: WhisperOptions())
        }
        #expect(fake.startCalls == 1)
        #expect(fake.decodeCalls == 3)
        #expect(factory.callCount == 1)
    }

    // MARK: - Request shape

    @Test("transcribeRegion sends a decodeRegion request carrying region bounds")
    func sendsDecodeRegionRequest() throws {
        let fake = FakeHost()
        fake.cannedDecode = decodedResponse()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        let region = SpeechRegion(
            start: .milliseconds(2_500),
            end: .milliseconds(7_750))
        _ = try trans.transcribeRegion(
            [0.1, 0.2], region: region, options: WhisperOptions())

        let captured = fake.lastRequest
        guard case .decodeRegion(let payload) = captured else {
            Issue.record("expected a decodeRegion request, got: \(String(describing: captured))")
            return
        }
        #expect(payload.regionStartMs == 2_500)
        #expect(payload.regionEndMs == 7_750)
    }

    // MARK: - Empty audio

    @Test("empty samples throw emptyAudio without spawning a host")
    func emptyAudioShortCircuits() {
        let fake = FakeHost()
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                [], region: SpeechRegion(start: .zero, end: .seconds(1)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.emptyAudio {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(factory.callCount == 0)
    }

    // MARK: - Deadline + respawn

    @Test("readTimedOut: host SIGKILL'd, fresh host spawned, wedged region surfaced as transcriptionFailed")
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

        let region = SpeechRegion(start: .seconds(1), end: .seconds(5))
        // First decode: hits the wedge → SIGKILL + respawn + throws
        // transcriptionFailed for this region. ResumableRefiner upstream
        // will surface this throw and resume from the previous
        // checkpoint on the next attempt.
        do {
            _ = try trans.transcribeRegion(
                [0.1], region: region, options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed(let code) {
            #expect(code == -1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
        #expect(factory.callCount == 2)

        // Second decode (the "retry" in ResumableRefiner's flow)
        // succeeds on the fresh host.
        let result = try trans.transcribeRegion(
            [0.1], region: region, options: WhisperOptions())
        #expect(result.segments.first?.text == "recovered")
        #expect(fresh.decodeCalls == 1)
    }

    @Test("readTimedOut: emits the 'region decode exceeded deadline' warning so log-greps disambiguate refinement from live")
    func deadlineLogsRegionMessage() throws {
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

        _ = try? trans.transcribeRegion(
            [0.1],
            region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
            options: WhisperOptions())

        let exceeded = capture.messages.filter {
            $0.contains("whisper region decode exceeded deadline")
        }
        #expect(exceeded.count == 1, "saw: \(capture.messages)")
    }

    @Test("subprocessGone during decode is treated as a recoverable wedge")
    func subprocessGoneTriggersRespawn() throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .subprocessGone(exitStatus: 1)

        let fresh = FakeHost()
        fresh.cannedDecode = decodedResponse()

        let factory = SequencedHostFactory(hosts: [wedged, fresh])
        let trans = makeTranscriber(
            factory: factory.factory,
            logBackoffInitial: .milliseconds(10))

        do {
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .zero, end: .seconds(2)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed(let code) {
            #expect(code == -1)
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
        #expect(factory.callCount == 2)
    }

    @Test("respawn that takes longer than the initial backoff emits at least one 'still waiting' log line")
    func backoffLogFires() async throws {
        let wedged = FakeHost()
        wedged.cannedDecodeError = .readTimedOut
        // Slow host: artificially delay `startAndInitialize` past the
        // first backoff interval so the throttled log fires at least
        // once before the respawn completes.
        //
        // Margins match the window-variant tests: 30ms backoff / 500ms
        // slow-start = ~470ms slack, plenty for the global pool to
        // schedule + sleep + log even when 50+ other suites run
        // concurrently.
        let slow = FakeHost()
        slow.startDelay = .milliseconds(500)
        slow.cannedDecode = decodedResponse()

        let factory = SequencedHostFactory(hosts: [wedged, slow])
        let capture = CapturingLogHandler()
        let trans = makeTranscriber(
            factory: factory.factory,
            logger: Logger(label: "test") { _ in capture },
            logBackoffInitial: .milliseconds(30))

        _ = try? trans.transcribeRegion(
            [0.1],
            region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
            options: WhisperOptions())

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
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
        // No respawn — the subprocess is still healthy, the *region*
        // failed decode.
        #expect(fake.sigkillCalls == 0)
        #expect(factory.callCount == 1)
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
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelNotFound {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test(".error with kind=empty_audio maps to WhisperTranscribeError.emptyAudio")
    func subprocessEmptyAudioMapped() throws {
        let fake = FakeHost()
        fake.cannedDecode = .error(WhisperIPCError(
            requestId: UUID(),
            kind: "empty_audio",
            message: "no samples"))
        let factory = SingleHostFactory(host: fake)
        let trans = makeTranscriber(factory: factory.factory)

        do {
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.emptyAudio {
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
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .zero, end: .seconds(1)),
                options: WhisperOptions())
            Issue.record("expected throw")
        } catch WhisperTranscribeError.modelLoadFailed(let message) {
            #expect(message.contains("/nope"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("respawn fails with .binaryNotFound — surfaced as modelLoadFailed on the wedged region")
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
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .seconds(1), end: .seconds(5)),
                options: WhisperOptions())
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
            _ = try trans.transcribeRegion(
                [0.1],
                region: SpeechRegion(start: .zero, end: .seconds(1)),
                options: WhisperOptions())
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

        _ = try trans.transcribeRegion(
            [0.1],
            region: SpeechRegion(start: .zero, end: .seconds(1)),
            options: WhisperOptions())

        trans.shutdown()
        #expect(fake.terminateCalls == 1)
        // Idempotent: a second shutdown is a no-op.
        trans.shutdown()
        #expect(fake.terminateCalls == 1)
    }
}

// MARK: - Test fixtures

private func makeTranscriber(
    factory: @escaping RemoteRegionTranscriber.HostFactory,
    logger: Logger = Logger(label: "test"),
    logBackoffInitial: Duration = .milliseconds(5)
) -> RemoteRegionTranscriber {
    let config = RemoteRegionTranscriber.Configuration(
        binaryURL: URL(fileURLWithPath: "/tmp/fake-whisper"),
        modelURL: URL(fileURLWithPath: "/tmp/model.bin"),
        socketDirectory: URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true),
        decodeDeadline: .milliseconds(50),
        respawnDeadline: .seconds(2),
        logBackoffInitial: logBackoffInitial,
        logBackoffCap: .milliseconds(100))
    return RemoteRegionTranscriber(
        configuration: config,
        logger: logger,
        hostFactory: factory)
}

private func decodedResponse() -> WhisperIPCResponse {
    .decoded(WhisperIPCDecoded(
        requestId: UUID(),
        segments: [WhisperIPCSegment(text: "ok", startMs: 0, endMs: 100)],
        language: "en"))
}

/// Fake `WhisperHostProtocol` for unit tests. One canned decode +
/// optional canned error; counts calls so tests can assert sigkill +
/// respawn happened. Records the last request so callers can assert
/// the request shape (e.g. that a `decodeRegion` carries the right
/// region bounds).
private final class FakeHost: WhisperHostProtocol, @unchecked Sendable {
    /// What `decode` returns (if no error is configured).
    var cannedDecode: WhisperIPCResponse?
    /// What `decode` throws (takes precedence over `cannedDecode`).
    var cannedDecodeError: WhisperSubprocessHost.HostError?
    /// Delay applied inside `startAndInitialize` — used to let the
    /// backoff log fire before init returns.
    var startDelay: Duration = .zero

    private let lock = NSLock()
    private var _startCalls = 0
    private var _decodeCalls = 0
    private var _terminateCalls = 0
    private var _sigkillCalls = 0
    private var _alive = false
    private var _lastRequest: WhisperIPCRequest?

    var startCalls: Int { lock.withLock { _startCalls } }
    var decodeCalls: Int { lock.withLock { _decodeCalls } }
    var terminateCalls: Int { lock.withLock { _terminateCalls } }
    var sigkillCalls: Int { lock.withLock { _sigkillCalls } }
    var isAlive: Bool { lock.withLock { _alive } }
    var lastRequest: WhisperIPCRequest? { lock.withLock { _lastRequest } }

    func startAndInitialize(model: String) throws {
        if startDelay > .zero {
            let ms = millis(startDelay)
            Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000.0)
        }
        lock.withLock {
            _startCalls += 1
            _alive = true
        }
    }

    func decode(
        _ request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse {
        lock.withLock {
            _decodeCalls += 1
            _lastRequest = request
        }
        if let err = cannedDecodeError {
            throw err
        }
        guard let resp = cannedDecode else {
            throw WhisperSubprocessHost.HostError.readTimedOut
        }
        return resp
    }

    func terminate(grace: Duration) {
        lock.withLock {
            _terminateCalls += 1
            _alive = false
        }
    }

    func sigkill() {
        lock.withLock {
            _sigkillCalls += 1
            _alive = false
        }
    }
}

private func millis(_ d: Duration) -> Int {
    let parts = d.components
    return Int(parts.seconds) * 1000
        + Int(parts.attoseconds / 1_000_000_000_000_000)
}

/// Factory that always returns the same fake host.
private final class SingleHostFactory: @unchecked Sendable {
    let host: FakeHost
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(host: FakeHost) { self.host = host }

    var factory: RemoteRegionTranscriber.HostFactory {
        return { _, _ in
            self.lock.withLock { self._callCount += 1 }
            return self.host
        }
    }
}

/// Factory that returns a sequence of hosts, optionally injecting
/// `startAndInitialize` errors at specific calls (the `startErrors[i]`,
/// if non-nil, makes the i'th host throw on start).
private final class SequencedHostFactory: @unchecked Sendable {
    let hosts: [FakeHost]
    let startErrors: [WhisperSubprocessHost.HostError?]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(
        hosts: [FakeHost],
        startErrors: [WhisperSubprocessHost.HostError?] = []
    ) {
        self.hosts = hosts
        self.startErrors = startErrors
    }

    var factory: RemoteRegionTranscriber.HostFactory {
        return { [self] _, _ in
            let idx: Int = lock.withLock {
                let i = _callCount
                _callCount += 1
                return i
            }
            // If a start error is configured for this call, return a
            // throwing fake. Otherwise return the i'th canned host.
            if idx < startErrors.count, let err = startErrors[idx] {
                return ThrowingStartHost(error: err)
            }
            // If we've exhausted the canned hosts, return a fresh
            // empty one — tests that don't care about subsequent
            // calls won't reach this path.
            if idx < hosts.count {
                return hosts[idx]
            }
            return FakeHost()
        }
    }
}

/// Host whose `startAndInitialize` always throws — used to simulate
/// non-recoverable spawn failure in the respawn path.
private final class ThrowingStartHost: WhisperHostProtocol, @unchecked Sendable {
    let error: WhisperSubprocessHost.HostError
    init(error: WhisperSubprocessHost.HostError) { self.error = error }

    var isAlive: Bool { false }

    func startAndInitialize(model: String) throws { throw error }
    func decode(
        _ request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse {
        throw error
    }
    func terminate(grace: Duration) {}
    func sigkill() {}
}

/// Lock-protected log sink — same shape as the window-variant tests.
private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
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

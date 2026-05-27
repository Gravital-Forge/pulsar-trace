import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Coverage of `SerializingHostProxy` — the parent-side shim that lets
/// two `RemoteWindowTranscriber` instances share one
/// `pulsartrace-whisper` subprocess. Exercised exclusively against a
/// fake `WhisperHostProtocol`; no real subprocess is spawned here. The
/// Phase 4-fix end-to-end shape is covered by the live engine
/// integration tests (and Phase 7 acceptance).
@Suite("SerializingHostProxy")
struct SerializingHostProxyTests {

    // MARK: - Lifecycle / model gating

    @Test("idempotent init on the same model — factory + inner.start called exactly once")
    func idempotentInitOnSameModel() throws {
        let fake = FakeWhisperHost()
        let factory = ScriptedInnerFactory(scripts: [.host(fake)])

        let proxy = makeProxy(factory: factory.factory)
        try proxy.startAndInitialize(model: "model-X")
        try proxy.startAndInitialize(model: "model-X")

        #expect(factory.callCount == 1)
        #expect(fake.startCalls == 1)
    }

    @Test("mismatched model on a second init throws .initRefused")
    func mismatchedModelThrows() throws {
        let fake = FakeWhisperHost()
        let factory = ScriptedInnerFactory(scripts: [.host(fake)])
        let proxy = makeProxy(factory: factory.factory)

        try proxy.startAndInitialize(model: "A")
        do {
            try proxy.startAndInitialize(model: "B")
            Issue.record("expected throw")
        } catch let e as WhisperSubprocessHost.HostError {
            switch e {
            case .initRefused(let m):
                #expect(m.contains("different model"))
            default:
                Issue.record("unexpected error kind: \(e)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // No respawn — the existing inner stays alive.
        #expect(factory.callCount == 1)
        #expect(fake.startCalls == 1)
    }

    // MARK: - Serialization

    @Test("concurrent decodes serialize through the proxy's lock — no interval overlap")
    func concurrentDecodesSerialize() async throws {
        let recorder = IntervalRecorder()
        let fake = FakeWhisperHost()
        fake.decodeBehavior = .sleepAndReturn(
            sleep: .milliseconds(50),
            response: Self.okResponse(),
            recorder: recorder)
        let factory = ScriptedInnerFactory(scripts: [.host(fake)])
        let proxy = makeProxy(factory: factory.factory)
        try proxy.startAndInitialize(model: "X")

        async let a: WhisperIPCResponse = Self.decode(proxy: proxy)
        async let b: WhisperIPCResponse = Self.decode(proxy: proxy)
        _ = try await (a, b)

        let intervals = recorder.snapshot()
        #expect(intervals.count == 2, "expected exactly two recorded intervals")
        // The two intervals must not overlap. Sort by start time and
        // require the earlier one's end <= the later one's start.
        let sorted = intervals.sorted { $0.start < $1.start }
        #expect(sorted[0].end <= sorted[1].start,
                "decodes overlapped: \(sorted[0]) and \(sorted[1])")
    }

    // MARK: - sigkill + respawn

    @Test("sigkill then startAndInitialize: factory called twice, inner alive again")
    func sigkillAllowsFreshInit() throws {
        let first = FakeWhisperHost()
        let second = FakeWhisperHost()
        let factory = ScriptedInnerFactory(scripts: [.host(first), .host(second)])
        let proxy = makeProxy(factory: factory.factory)

        try proxy.startAndInitialize(model: "M")
        #expect(factory.callCount == 1)
        #expect(first.sigkillCalls == 0)

        proxy.sigkill()
        #expect(first.sigkillCalls == 1)
        #expect(proxy.isAlive == false)

        try proxy.startAndInitialize(model: "M")
        #expect(factory.callCount == 2)
        #expect(second.startCalls == 1)
        #expect(proxy.isAlive == true)

        // A decode now hits the second inner, not the first.
        second.decodeBehavior = .return(Self.okResponse())
        let resp = try Self.decode(proxy: proxy)
        if case .decoded = resp {
            // ok
        } else {
            Issue.record("expected .decoded, got \(resp)")
        }
        #expect(second.decodeCalls == 1)
        #expect(first.decodeCalls == 0)
    }

    // MARK: - Terminate latch

    @Test("terminate latches: second terminate is a no-op; later decode/start throw .subprocessGone")
    func terminateLatches() throws {
        let fake = FakeWhisperHost()
        let factory = ScriptedInnerFactory(scripts: [.host(fake)])
        let proxy = makeProxy(factory: factory.factory)

        try proxy.startAndInitialize(model: "M")
        proxy.terminate(grace: .milliseconds(10))
        #expect(fake.terminateCalls == 1)

        // Second terminate must not touch the inner again.
        proxy.terminate(grace: .milliseconds(10))
        #expect(fake.terminateCalls == 1)

        // decode after terminate → subprocessGone.
        do {
            _ = try Self.decode(proxy: proxy)
            Issue.record("expected throw")
        } catch let e as WhisperSubprocessHost.HostError {
            if case .subprocessGone = e { } else {
                Issue.record("unexpected error: \(e)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // start after terminate → subprocessGone (latched).
        do {
            try proxy.startAndInitialize(model: "M")
            Issue.record("expected throw")
        } catch let e as WhisperSubprocessHost.HostError {
            if case .subprocessGone = e { } else {
                Issue.record("unexpected error: \(e)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The factory was not re-invoked.
        #expect(factory.callCount == 1)
    }

    // MARK: - Wedge recovery shape

    @Test("readTimedOut is propagated cleanly; sigkill + re-init then decode succeeds on the fresh inner")
    func readTimedOutDoesNotPoison() throws {
        let wedged = FakeWhisperHost()
        wedged.decodeBehavior = .throwOnce(.readTimedOut, then: .return(Self.okResponse()))
        let fresh = FakeWhisperHost()
        fresh.decodeBehavior = .return(Self.okResponse())
        let factory = ScriptedInnerFactory(scripts: [.host(wedged), .host(fresh)])
        let proxy = makeProxy(factory: factory.factory)

        try proxy.startAndInitialize(model: "M")

        // First decode wedges — the proxy must propagate, not swallow.
        do {
            _ = try Self.decode(proxy: proxy)
            Issue.record("expected throw")
        } catch let e as WhisperSubprocessHost.HostError {
            if case .readTimedOut = e { } else {
                Issue.record("unexpected error: \(e)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The proxy doesn't auto-respawn; the caller drives sigkill +
        // re-init (RemoteWindowTranscriber.handleHostError does this).
        proxy.sigkill()
        try proxy.startAndInitialize(model: "M")
        #expect(factory.callCount == 2)

        // Second decode lands on the fresh inner and succeeds.
        let resp = try Self.decode(proxy: proxy)
        if case .decoded = resp { } else {
            Issue.record("expected .decoded, got \(resp)")
        }
        #expect(fresh.decodeCalls == 1)
    }

    // MARK: - Shared-host end-to-end with two transcribers

    @Test("two RemoteWindowTranscribers share one proxy — one inner subprocess for both streams")
    func twoTranscribersShareOneProxy() throws {
        let fake = FakeWhisperHost()
        fake.decodeBehavior = .return(Self.okResponse())
        let factory = ScriptedInnerFactory(scripts: [.host(fake)])
        let proxy = makeProxy(factory: factory.factory)

        let hostFactory: RemoteWindowTranscriber.HostFactory = { _, _ in proxy }
        let transA = Self.makeTranscriber(hostFactory: hostFactory)
        let transB = Self.makeTranscriber(hostFactory: hostFactory)

        let resA = try transA.transcribeWindow(
            [0.1], windowStart: .seconds(0),
            options: WhisperOptions(), abort: nil)
        let resB = try transB.transcribeWindow(
            [0.2], windowStart: .seconds(1),
            options: WhisperOptions(), abort: nil)
        #expect(resA.segments.first?.text == "ok")
        #expect(resB.segments.first?.text == "ok")
        // One inner subprocess shared between the two transcribers.
        #expect(factory.callCount == 1)
        #expect(fake.startCalls == 1)
        #expect(fake.decodeCalls == 2)
    }

    @Test("wedge in transcriber A respawns the shared inner; transcriber B's next decode succeeds on the fresh inner")
    func wedgeInOneRespawnsForBoth() throws {
        let wedged = FakeWhisperHost()
        // First decode wedges; subsequent decodes return ok.
        wedged.decodeBehavior = .throwOnce(.readTimedOut, then: .return(Self.okResponse()))
        let fresh = FakeWhisperHost()
        fresh.decodeBehavior = .return(Self.okResponse())
        let factory = ScriptedInnerFactory(scripts: [.host(wedged), .host(fresh)])
        let proxy = makeProxy(factory: factory.factory)

        let hostFactory: RemoteWindowTranscriber.HostFactory = { _, _ in proxy }
        let transA = Self.makeTranscriber(hostFactory: hostFactory)
        let transB = Self.makeTranscriber(hostFactory: hostFactory)

        // Transcriber A's first call wedges → handleHostError sigkills
        // the shared inner and respawns it. The window is surfaced as
        // transcriptionFailed (spec §6).
        do {
            _ = try transA.transcribeWindow(
                [0.1], windowStart: .seconds(0),
                options: WhisperOptions(), abort: nil)
            Issue.record("expected throw")
        } catch WhisperTranscribeError.transcriptionFailed(let c) {
            #expect(c == -1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(wedged.sigkillCalls == 1)
        #expect(factory.callCount == 2)

        // Transcriber B's next decode now goes through the fresh inner.
        let resB = try transB.transcribeWindow(
            [0.2], windowStart: .seconds(1),
            options: WhisperOptions(), abort: nil)
        #expect(resB.segments.first?.text == "ok")
        #expect(fresh.decodeCalls == 1)
        // Final tally: one initial inner + one respawn = two factory calls total.
        #expect(factory.callCount == 2)
    }

    // MARK: - Helpers

    /// Build a SerializingHostProxy with the given factory + a no-op
    /// configuration (paths/timeouts irrelevant to the proxy itself —
    /// only the inner host uses them, and the fake inner ignores them).
    private func makeProxy(
        factory: @escaping SerializingHostProxy.InnerFactory
    ) -> SerializingHostProxy {
        let config = WhisperSubprocessHost.Configuration(
            binaryURL: URL(fileURLWithPath: "/tmp/fake-whisper"),
            socketDirectory: URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true),
            forceCPU: true,
            spawnTimeout: .seconds(1),
            initTimeout: .seconds(1))
        return SerializingHostProxy(
            configuration: config,
            logger: Logger(label: "test"),
            innerFactory: factory)
    }

    private static func makeTranscriber(
        hostFactory: @escaping RemoteWindowTranscriber.HostFactory
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
            logBackoffInitial: .milliseconds(5),
            logBackoffCap: .milliseconds(100))
        return RemoteWindowTranscriber(
            configuration: config,
            logger: Logger(label: "test"),
            hostFactory: hostFactory)
    }

    /// Send a no-op decode request through the proxy.
    private static func decode(proxy: SerializingHostProxy) throws -> WhisperIPCResponse {
        let req = WhisperIPCRequest.decodeWindow(
            WhisperIPCDecodeWindow(
                requestId: UUID(),
                samplesBase64: WhisperIPCSamples.encode([0.1, 0.2]),
                windowStartMs: 0,
                options: WhisperIPCOptions(from: WhisperOptions())))
        return try proxy.decode(req, deadline: .seconds(1))
    }

    private static func okResponse() -> WhisperIPCResponse {
        .decoded(WhisperIPCDecoded(
            requestId: UUID(),
            segments: [WhisperIPCSegment(text: "ok", startMs: 0, endMs: 100)],
            language: "en"))
    }
}

// MARK: - FakeWhisperHost

/// Configurable fake `WhisperHostProtocol`. Knobs:
///   * `decodeBehavior` — what `decode` does (return a response, sleep
///     first, throw once then return, etc).
///   * `aliveOverride` — pin `isAlive` to a value (defaults to
///     "true after start, false after terminate/sigkill").
///   * Call counters for every method.
private final class FakeWhisperHost: WhisperHostProtocol, @unchecked Sendable {

    indirect enum DecodeBehavior {
        /// Return this response immediately.
        case `return`(WhisperIPCResponse)
        /// Sleep, then return this response. Record the interval in `recorder`.
        case sleepAndReturn(
            sleep: Duration,
            response: WhisperIPCResponse,
            recorder: IntervalRecorder)
        /// Throw `error` on the first call, then behave as `then` on later calls.
        case throwOnce(WhisperSubprocessHost.HostError, then: DecodeBehavior)
        /// Default if nothing is configured: throw .readTimedOut.
        case unset
    }

    var decodeBehavior: DecodeBehavior = .unset
    var aliveOverride: Bool? = nil

    private let lock = NSLock()
    private var _startCalls = 0
    private var _decodeCalls = 0
    private var _terminateCalls = 0
    private var _sigkillCalls = 0
    private var _alive = false

    var startCalls: Int { lock.withLock { _startCalls } }
    var decodeCalls: Int { lock.withLock { _decodeCalls } }
    var terminateCalls: Int { lock.withLock { _terminateCalls } }
    var sigkillCalls: Int { lock.withLock { _sigkillCalls } }
    var isAlive: Bool {
        if let aliveOverride { return aliveOverride }
        return lock.withLock { _alive }
    }

    func startAndInitialize(model: String) throws {
        lock.withLock {
            _startCalls += 1
            _alive = true
        }
    }

    func decode(
        _ request: WhisperIPCRequest, deadline: Duration
    ) throws -> WhisperIPCResponse {
        lock.withLock { _decodeCalls += 1 }
        return try runDecode()
    }

    private func runDecode() throws -> WhisperIPCResponse {
        // Resolve and possibly mutate `decodeBehavior` under the lock so
        // a `.throwOnce` advances to `.then` for the next caller.
        let behavior: DecodeBehavior = lock.withLock {
            let b = self.decodeBehavior
            if case .throwOnce(_, let then) = b {
                self.decodeBehavior = then
            }
            return b
        }
        switch behavior {
        case .return(let resp):
            return resp
        case .sleepAndReturn(let sleep, let resp, let recorder):
            let start = ContinuousClock.now
            // Coarse blocking sleep — `decode` is a sync call on the
            // transcriber side.
            let ms = millisOf(sleep)
            Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000.0)
            let end = ContinuousClock.now
            recorder.record(Interval(start: start, end: end))
            return resp
        case .throwOnce(let err, _):
            throw err
        case .unset:
            throw WhisperSubprocessHost.HostError.readTimedOut
        }
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

// MARK: - ScriptedInnerFactory

/// Hands out a scripted sequence of inner hosts. Each call to `factory`
/// pulls the next script entry; if the scripts are exhausted, returns a
/// default `FakeWhisperHost` (which will throw `.readTimedOut` from
/// `decode` if used). Counts factory invocations so tests can assert how
/// many inner subprocesses the proxy spun up.
private final class ScriptedInnerFactory: @unchecked Sendable {

    enum Script {
        /// Use this exact fake host on this call.
        case host(FakeWhisperHost)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    var factory: SerializingHostProxy.InnerFactory {
        return { [self] _, _ in
            let next: Script? = lock.withLock {
                _callCount += 1
                guard !scripts.isEmpty else { return nil }
                return scripts.removeFirst()
            }
            switch next {
            case .host(let h)?: return h
            case nil:
                // Unscripted call — return a fresh fake.
                return FakeWhisperHost()
            }
        }
    }
}

// MARK: - Interval recorder for the serialization test

/// Records `(start, end)` intervals from concurrent decode calls so the
/// test can assert non-overlap. Lock-protected so the two recording
/// threads can append without UB.
private final class IntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _intervals: [Interval] = []

    func record(_ i: Interval) {
        lock.withLock { _intervals.append(i) }
    }
    func snapshot() -> [Interval] {
        lock.withLock { _intervals }
    }
}

private struct Interval: CustomStringConvertible {
    let start: ContinuousClock.Instant
    let end: ContinuousClock.Instant
    var description: String { "[\(start)…\(end)]" }
}

// MARK: - Misc

private func millisOf(_ d: Duration) -> Int {
    let parts = d.components
    return Int(parts.seconds) * 1000
        + Int(parts.attoseconds / 1_000_000_000_000_000)
}

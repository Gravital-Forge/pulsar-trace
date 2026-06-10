import Foundation
import Logging
@testable import PulsarTraceEngine

// Shared fakes for the WhisperIPC unit suites — used by the
// `RemoteWindowTranscriber`, `RemoteRegionTranscriber`, and
// `WhisperSubprocessHost` tests. Previously each transcriber test file
// carried a private copy; these are the superset variants (the
// `FakeHost` records `lastRequest` so region tests can assert request
// shape).
//
// NOTE: `SerializingHostProxyTests` keeps its own `FakeWhisperHost` on
// purpose — it is a different design (DecodeBehavior enum).

/// Canned successful decode response shared by the transcriber suites.
func decodedResponse() -> WhisperIPCResponse {
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
final class FakeHost: WhisperHostProtocol, @unchecked Sendable {
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

func millis(_ d: Duration) -> Int {
    let parts = d.components
    return Int(parts.seconds) * 1000
        + Int(parts.attoseconds / 1_000_000_000_000_000)
}

/// Factory that always returns the same fake host. The factory type is
/// written out structurally — `RemoteWindowTranscriber.HostFactory` and
/// `RemoteRegionTranscriber.HostFactory` both resolve to it, so either
/// transcriber's `hostFactory:` init parameter accepts it.
final class SingleHostFactory: @unchecked Sendable {
    let host: FakeHost
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(host: FakeHost) { self.host = host }

    var factory: @Sendable (WhisperSubprocessHost.Configuration, Logger) -> WhisperHostProtocol {
        return { _, _ in
            self.lock.withLock { self._callCount += 1 }
            return self.host
        }
    }
}

/// Factory that returns a sequence of hosts, optionally injecting
/// `startAndInitialize` errors at specific calls (the `startErrors[i]`,
/// if non-nil, makes the i'th host throw on start).
final class SequencedHostFactory: @unchecked Sendable {
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

    var factory: @Sendable (WhisperSubprocessHost.Configuration, Logger) -> WhisperHostProtocol {
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
final class ThrowingStartHost: WhisperHostProtocol, @unchecked Sendable {
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

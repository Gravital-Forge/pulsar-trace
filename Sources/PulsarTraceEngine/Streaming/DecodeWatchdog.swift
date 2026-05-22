import Foundation
import Logging

/// Watches the worker's in-flight whisper decode and interrupts a hang.
///
/// Two stages, driven by one background polling task:
///  1. **deadline** — after this long, flip the decode's `AbortToken` so whisper
///     bails at its next decode-step boundary and releases `metalLock`; the
///     worker drops that window and continues.
///  2. **abort-grace** — if the decode is *still* outstanding this long after the
///     abort was signalled, the abort did not take (a hang inside a single
///     encode/decode step, where control never reaches the next abort poll).
///     Emit an escalating, greppable warning with a growing age so the
///     unrecoverable case is visible and countable.
///
/// The watchdog runs as its own task, so it keeps observing even while the
/// worker is suspended awaiting a blocking decode (the decode runs on a
/// DispatchQueue thread; this poll runs on the cooperative pool).
actor DecodeWatchdog {
    private let deadline: Duration
    private let abortGrace: Duration
    private let logger: Logger

    private var token: AbortToken?
    private var stream = ""
    private var startedAt: ContinuousClock.Instant?
    private var abortSignalledAt: ContinuousClock.Instant?
    private var poller: Task<Void, Never>?

    init(deadline: Duration, abortGrace: Duration, logger: Logger) {
        self.deadline = deadline
        self.abortGrace = abortGrace
        self.logger = logger
    }

    /// Arm the watchdog for one decode.
    func beginDecode(token: AbortToken, stream: String) {
        self.token = token
        self.stream = stream
        self.startedAt = .now
        self.abortSignalledAt = nil
        poller?.cancel()
        poller = Task { [weak self] in await self?.poll() }
    }

    /// Disarm after the decode returns (aborted or not).
    func endDecode() {
        poller?.cancel()
        poller = nil
        token = nil
        startedAt = nil
        abortSignalledAt = nil
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            guard let startedAt else { return }
            let age = ContinuousClock.now - startedAt
            if abortSignalledAt == nil, age >= deadline {
                token?.cancel()
                abortSignalledAt = .now
                logger.warning("whisper decode exceeded deadline; aborting stream=\(stream)")
            }
            if let sig = abortSignalledAt {
                let sinceAbort = ContinuousClock.now - sig
                if sinceAbort >= abortGrace {
                    let ms = Self.millis(sinceAbort)
                    logger.warning("whisper decode did not honor abort; age=\(ms)ms past abort signal, stream=\(stream)")
                }
            }
        }
    }

    private static func millis(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000
            + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}

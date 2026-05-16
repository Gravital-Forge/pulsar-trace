import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A thread-safe "Ctrl-C was pressed" latch for the long-running CLI commands
/// (`events tail`, `record`).
///
/// `SIGINT`'s default disposition is replaced by a `DispatchSource` so a
/// command's poll loop can notice the interrupt and shut down cleanly —
/// flushing files and letting `AppLifecycle` emit `app_stopped` — instead of
/// the process being killed mid-operation. The latch is one-shot: once set it
/// stays set.
final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    private let source: DispatchSourceSignal

    /// Whether Ctrl-C has been pressed.
    var isSet: Bool {
        lock.withLock { flagged }
    }

    init() {
        // Ignore SIGINT's default disposition so the DispatchSource — not the
        // kernel's default handler — observes Ctrl-C.
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue(label: "com.pulsartrace.signal"))
        source.setEventHandler { [weak self] in
            self?.lock.withLock { self?.flagged = true }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

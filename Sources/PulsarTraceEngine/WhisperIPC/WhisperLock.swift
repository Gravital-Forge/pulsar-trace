import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Process-wide exclusive lock for the `pulsartrace-whisper` subprocess
/// (spec §4 Layer 2). `flock(LOCK_EX | LOCK_NB)` against a path under
/// `~/Library/Application Support/PulsarTrace/`. The fd is kept open for
/// the process's lifetime; the lock releases automatically on process
/// death — including SIGKILL — so a wedged-and-killed subprocess never
/// leaves a stale lock that future invocations would trip on.
///
/// Two enforcement layers exist for "at most one whisper subprocess at a
/// time" (spec §4). Lifecycle (layer 1, in mac-app) makes the
/// two-instance scenario a non-event in normal operation. This type is
/// the structural backstop (layer 2): if a lifecycle bug or a race ever
/// launches a second instance, it cannot acquire the lock and exits with
/// code 75, surfacing the misuse rather than corrupting state.
public enum WhisperLockError: Error, CustomStringConvertible, Equatable {
    /// `open(2)` of the lock file failed before the `flock(2)` call —
    /// permission denied, parent dir missing, etc. Distinct from `.held`
    /// because the operational response differs (chmod / create dir vs.
    /// "another instance is alive").
    case openFailed(path: String, errno: Int32)
    /// `flock(LOCK_EX | LOCK_NB)` returned `EWOULDBLOCK` — another
    /// process (or another in-process `WhisperLock`) is holding the lock.
    /// `pulsartrace-whisper` maps this to exit code 75 (`EX_TEMPFAIL`).
    case held

    public var description: String {
        switch self {
        case .openFailed(let p, let e):
            return "open(\(p)) failed: errno \(e)"
        case .held:
            return "whisper lock is held by another process"
        }
    }
}

/// An acquired `flock` on a filesystem path. The fd is owned for the
/// object's lifetime: `deinit` closes it, which releases the lock. The
/// kernel also releases it on process death, so a hard-killed subprocess
/// (SIGKILL — the recovery path for a wedged decode) never leaves a stale
/// lock file.
///
/// `@unchecked Sendable`: the type holds only an immutable fd after
/// construction. `deinit` closes it; no other mutation is exposed.
public final class WhisperLock: @unchecked Sendable {

    /// The held file descriptor — owned for the object's lifetime. Closed
    /// in `deinit`, which atomically releases the kernel `flock`.
    private let fd: Int32

    /// Acquire `flock(LOCK_EX | LOCK_NB)` on `lockPath`. The file is
    /// created with mode 0644 if absent; the lock object exists for the
    /// directory entry, so two different filesystems / paths are
    /// independent. Tests pass a per-test temp path so they don't collide
    /// with each other or with a real subprocess.
    ///
    /// - Throws: `WhisperLockError.openFailed` if the file can't be
    ///   opened; `WhisperLockError.held` if another process owns the
    ///   lock.
    public init(lockPath: URL) throws {
        let path = lockPath.path
        let fd = path.withCString { cstr in
            open(cstr, O_CREAT | O_RDWR, 0o644)
        }
        guard fd >= 0 else {
            throw WhisperLockError.openFailed(path: path, errno: errno)
        }
        // `flock(LOCK_EX | LOCK_NB)`: exclusive, non-blocking. Returns
        // `-1`/`EWOULDBLOCK` immediately if another process holds it; we
        // map that to `.held` and let the caller decide exit policy.
        let r = flock(fd, LOCK_EX | LOCK_NB)
        if r != 0 {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK {
                throw WhisperLockError.held
            }
            // Any other flock error is rare on a Unix filesystem; surface
            // it via `.openFailed` with the errno for diagnosability
            // rather than inventing a new case.
            throw WhisperLockError.openFailed(path: path, errno: e)
        }
        self.fd = fd
    }

    deinit {
        // Closing the fd releases the `flock` atomically. We don't
        // explicitly call `flock(fd, LOCK_UN)` first: `close` is
        // sufficient and avoids a window where the fd is closed before
        // the lock state machine observes the unlock.
        close(fd)
    }
}

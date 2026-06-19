import Foundation
import Logging
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Spawns `pulsartrace-engine --diarizer-worker` and accepts its socket
/// connection. The engine owns the listening socket for the whole run; each
/// worker incarnation connects to it, so a respawn does not churn the path (D43).
public final class DiarWorkerProcessLauncher: DiarWorkerLaunching, @unchecked Sendable {
    private let socketPath: String
    private let cacheRoot: URL
    private let executableURL: URL
    private let logger: Logger
    private let lock = NSLock()
    private var listenFd: Int32 = -1
    /// Retains the live worker `Process` so its `terminationHandler` fires and
    /// it is not deallocated mid-run. Replaced on each launch (the prior worker
    /// has already been killed + reaped by the supervisor before relaunch).
    private var currentProcess: Process?

    public init(socketURL: URL, cacheRoot: URL,
                executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
                logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.socketPath = socketURL.path
        self.cacheRoot = cacheRoot
        self.executableURL = executableURL
        self.logger = logger
    }

    public func launch() async throws -> DiarWorkerHandle {
        try ensureListening()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--diarizer-worker", "--diar-socket", socketPath,
                             "--cache-root", cacheRoot.path]
        let exited = ProcessExitGate()
        process.terminationHandler = { _ in Task { await exited.signal() } }
        try process.run()
        lock.withLock { currentProcess = process }
        // Capture ONLY the pid (Sendable) in the @Sendable kill closure — never
        // the non-Sendable Process, and never pid <= 0 (which would signal the
        // whole process group).
        let pid = process.processIdentifier

        // Any failure between spawn and returning the handle must reap the worker
        // so it cannot become an orphan holding the ANE (I1).
        do {
            // accept() blocks until the worker connects (after it loads models).
            let connFd = try accept(timeout: .seconds(120))
            let connection = DiarWorkerConnection(fd: connFd)

            // First inbound frame must be the hello (carries the model revision).
            var revision = ""
            for await body in connection.inboundBodies {
                // Consume ONLY the hello here; the SAME single-buffer AsyncStream is then drained by DiarWorkerClient.startReader. Safe because the worker emits no result frame until it receives a request, which cannot be sent before startReader is attached.
                if case let .hello(rev)? = try? DiarWorkerProtocol.decodeMessage(body) { revision = rev }
                break
            }

            return DiarWorkerHandle(
                connection: connection,
                modelRevision: revision,
                kill: { if pid > 0 { Darwin.kill(pid, SIGKILL) } },
                awaitExit: { await exited.wait() })
        } catch {
            if pid > 0 { Darwin.kill(pid, SIGKILL) }
            throw error
        }
    }

    private func ensureListening() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenFd < 0 else { return }
        unlink(socketPath)
        let fd = socket(AF_UNIX, sockStreamType, 0)
        guard fd >= 0 else { throw DiarWorkerLaunchError.socket(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, src, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw DiarWorkerLaunchError.bind(errno) }
        guard listen(fd, 1) == 0 else { close(fd); throw DiarWorkerLaunchError.listen(errno) }
        listenFd = fd
    }

    private func accept(timeout: Duration) throws -> Int32 {
        let fd = lock.withLock { listenFd }   // M2: snapshot under the lock
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(timeout.components.seconds * 1000)
        let rc = poll(&pfd, 1, ms)
        guard rc > 0 else { throw DiarWorkerLaunchError.acceptTimeout }
        let conn = Darwin.accept(fd, nil, nil)
        guard conn >= 0 else { throw DiarWorkerLaunchError.accept(errno) }
        return conn
    }

    deinit { if listenFd >= 0 { close(listenFd); unlink(socketPath) } }
}

public enum DiarWorkerLaunchError: Error, Equatable {
    case socket(Int32), bind(Int32), listen(Int32), accept(Int32), acceptTimeout
}

/// One-shot async gate for process exit.
actor ProcessExitGate {
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { exited = true; for w in waiters { w.resume() }; waiters.removeAll() }
    func wait() async {
        if exited { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

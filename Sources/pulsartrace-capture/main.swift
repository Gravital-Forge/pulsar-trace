import Foundation
import PulsarTraceCapture
import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `pulsartrace-capture` — the real device-capture daemon.
///
/// It owns AVFoundation (mic) and ScreenCaptureKit (system audio) — the only
/// PulsarTrace process that needs TCC permissions (R4) — and streams 16 kHz
/// mono Float32 frames to two Unix domain sockets the engine reads via
/// `SocketSource`.
///
/// Usage:
///   pulsartrace-capture --recording-id <id> [--out <dir>]
///                       [--system-socket <path>] [--mic-socket <path>]
///                       [--mic-device <uniqueID>] [--no-system-audio]
///                       [--model <name>]
///
/// Startup handshake: the daemon binds both sockets, prints `ready` on stdout,
/// then starts capture. An orchestrator (the `pulsartrace record` CLI
/// or the menubar) waits for that line before connecting the engine —
/// the engine's `SocketSource` has no connect-retry.
@main
struct CaptureMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let lifecycle = await AppLifecycle.start()

        let recordingId = value(of: "--recording-id", in: args)
            ?? RecordingFolder.recordingId(forName: "capture-" + timestampStem())
        let systemAudioEnabled = !args.contains("--no-system-audio")
        let micDeviceID = value(of: "--mic-device", in: args)
        let modelLive = value(of: "--model", in: args) ?? "base"

        let paths = AppPaths.standard
        let systemSocket = value(of: "--system-socket", in: args)
            .map { URL(fileURLWithPath: $0) }
            ?? paths.systemSocketURL(recordingId: recordingId)
        let micSocket = value(of: "--mic-socket", in: args)
            .map { URL(fileURLWithPath: $0) }
            ?? paths.micSocketURL(recordingId: recordingId)
        let outputDirBasename = value(of: "--out", in: args)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? recordingId

        // --- permissions (R4): the daemon is the only TCC-gated process -----
        let checker = PermissionChecker(events: lifecycle.events)
        _ = await checker.requestMicrophoneIfNeeded()
        let status = await checker.checkAndEmit()
        if !status.microphoneGranted {
            fail("microphone permission not granted — grant it in System "
                 + "Settings ▸ Privacy & Security ▸ Microphone",
                 lifecycle: lifecycle, code: 2)
        }
        if systemAudioEnabled && !status.screenRecordingGranted {
            fail("screen recording permission not granted — grant it in "
                 + "System Settings ▸ Privacy & Security ▸ Screen Recording, "
                 + "or pass --no-system-audio for a mic-only recording",
                 lifecycle: lifecycle, code: 2)
        }

        // --- bind the sockets before announcing readiness -------------------
        let source = DeviceCaptureSource(configuration: .init(
            recordingId: recordingId,
            outputDirBasename: outputDirBasename,
            micDeviceID: micDeviceID,
            systemAudioEnabled: systemAudioEnabled,
            systemSocketPath: systemSocket,
            micSocketPath: micSocket,
            modelLive: modelLive,
            events: lifecycle.events))
        do {
            try source.prepareForCapture()
        } catch {
            fail("could not bind capture sockets: \(error)",
                 lifecycle: lifecycle, code: 1)
        }

        // The orchestrator waits for this line before connecting the engine.
        FileHandle.standardOutput.write(Data("ready\n".utf8))

        do {
            try await source.startCapture()
        } catch {
            fail("capture failed to start: \(error)",
                 lifecycle: lifecycle, code: 1)
        }

        // Idle until SIGTERM / SIGINT, then stop cleanly.
        await TerminationWaiter().wait()
        await source.stopCapture(reason: "user_stop")
        await lifecycle.stop()
        exit(0)
    }

    /// Print a diagnostic to stderr, stop the lifecycle, and exit. `Never`.
    static func fail(_ message: String, lifecycle: AppLifecycle, code: Int32) -> Never {
        FileHandle.standardError.write(
            Data("pulsartrace-capture: \(message)\n".utf8))
        // The lifecycle stop is fire-and-forget on the exit path.
        let semaphore = DispatchSemaphore(value: 0)
        Task { await lifecycle.stop(); semaphore.signal() }
        semaphore.wait()
        exit(code)
    }

    static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag),
              index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// A filesystem-safe timestamp stem for an unnamed capture session.
    static func timestampStem() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// Suspends until the process receives `SIGTERM` or `SIGINT`.
///
/// `DispatchSource` signal sources work without a run loop, so the daemon can
/// `await` termination while the IOKit power monitor and the socket write
/// threads keep running. The waiter retains its sources until one fires.
final class TerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { self.continuation = continuation }
            let queue = DispatchQueue(label: "com.pulsartrace.capture.signal")
            for signalNumber in [SIGTERM, SIGINT] {
                // Ignore the default disposition so the DispatchSource — not
                // the kernel's default handler — observes the signal.
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber, queue: queue)
                source.setEventHandler { [weak self] in self?.fire() }
                source.resume()
                lock.withLock { sources.append(source) }
            }
        }
    }

    private func fire() {
        // Take the continuation and the sources in one critical section so a
        // second signal cannot find a nil continuation but live sources.
        let (continuation, toCancel) = lock.withLock {
            () -> (CheckedContinuation<Void, Never>?, [DispatchSourceSignal]) in
            let pending = self.continuation
            self.continuation = nil
            let captured = sources
            sources.removeAll()
            return (pending, captured)
        }
        for source in toCancel { source.cancel() }
        continuation?.resume()
    }
}

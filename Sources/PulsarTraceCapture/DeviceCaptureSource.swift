import Foundation
import PulsarTraceEngine

/// Owns one recording session's real device capture: the microphone engine,
/// the system-audio engine, their two socket servers, and the sleep/wake
/// monitor. It is the producer side of the `AudioFrameSource` seam — the
/// engine consumes the two sockets via `SocketSource` and cannot tell this
/// from a fixture WAV (Hard Invariant #3).
///
/// `DeviceCaptureSource` is also the authoritative emitter of the
/// recording-lifecycle events (`recording_started` / `_paused` / `_resumed` /
/// `_stopped`): it owns the hardware and the session clock.
///
/// Lifecycle: `prepareForCapture()` (bind sockets — call before the engine
/// connects) → `startCapture()` (start hardware) → `stopCapture(reason:)`.
public final class DeviceCaptureSource: @unchecked Sendable {

    /// One recording session's capture configuration.
    public struct Configuration: Sendable {
        /// Recording id (`rec_<short>`) — scopes sockets and stamps events.
        public let recordingId: String
        /// Basename of the recording's output folder (events carry basenames).
        public let outputDirBasename: String
        /// Microphone `uniqueID`, or `nil` for the system default (R5).
        public let micDeviceID: String?
        /// Whether to capture system audio; `false` for a mic-only run (R6).
        public let systemAudioEnabled: Bool
        /// Where the system-audio socket is bound.
        public let systemSocketPath: URL
        /// Where the microphone socket is bound.
        public let micSocketPath: URL
        /// Whisper model name the live pass will use (recorded in the event).
        public let modelLive: String
        /// Events-log writer, or `nil` to skip event emission.
        public let events: EventWriter?

        public init(
            recordingId: String,
            outputDirBasename: String,
            micDeviceID: String?,
            systemAudioEnabled: Bool,
            systemSocketPath: URL,
            micSocketPath: URL,
            modelLive: String,
            events: EventWriter?
        ) {
            self.recordingId = recordingId
            self.outputDirBasename = outputDirBasename
            self.micDeviceID = micDeviceID
            self.systemAudioEnabled = systemAudioEnabled
            self.systemSocketPath = systemSocketPath
            self.micSocketPath = micSocketPath
            self.modelLive = modelLive
            self.events = events
        }
    }

    private enum Stream { case system, mic }

    private let configuration: Configuration
    private let systemServer: CaptureSocketServer
    private let micServer: CaptureSocketServer
    private let sleepWake = SleepWakeMonitor()

    private let lock = NSLock()
    private var micEngine: MicCaptureEngine?
    private var systemEngine: SystemAudioCaptureEngine?
    private var paused = false
    /// Set once `stopCapture()` begins. A sleep/wake handler that fires during
    /// or after teardown is a no-op — it must not resurrect engines or enqueue
    /// onto a closing socket.
    private var stopped = false
    private var startWall: Date?
    private var pauseWall: Date?
    private var resolvedMicName = "none"

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.systemServer = CaptureSocketServer(socketPath: configuration.systemSocketPath)
        self.micServer = CaptureSocketServer(socketPath: configuration.micSocketPath)
    }

    /// Create the socket directory and `bind()` + `listen()` both sockets.
    /// Must return before the engine `connect()`s — there is no connect-retry
    /// on the engine side.
    public func prepareForCapture() throws {
        let socketDir = configuration.micSocketPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: socketDir, withIntermediateDirectories: true)
        try micServer.start()
        if configuration.systemAudioEnabled {
            try systemServer.start()
        }
    }

    /// Start hardware capture, begin serving both sockets, and emit
    /// `recording_started`.
    public func startCapture() async throws {
        lock.withLock { startWall = Date() }

        micServer.beginServing()
        if configuration.systemAudioEnabled {
            systemServer.beginServing()
        }

        let mic = makeMicEngine()
        try mic.start()
        lock.withLock {
            micEngine = mic
            resolvedMicName = mic.deviceName
        }

        if configuration.systemAudioEnabled {
            let system = makeSystemEngine()
            try await system.start()
            lock.withLock { systemEngine = system }
        }

        sleepWake.onSleep = { [weak self] in self?.handleSleep() }
        sleepWake.onWake = { [weak self] in self?.handleWake() }
        sleepWake.start()

        await emit(RecordingStartedEvent(
            recordingId: configuration.recordingId,
            outputDirBasename: configuration.outputDirBasename,
            micDevice: lock.withLock { resolvedMicName },
            systemAudioEnabled: configuration.systemAudioEnabled,
            modelLive: configuration.modelLive))
    }

    /// Stop hardware capture, flush both streams (drain + end-of-stream
    /// sentinel), tear down the sockets, and emit `recording_stopped`.
    public func stopCapture(reason: String) async {
        // Latch `stopped` first: `sleepWake.stop()` halts new power callbacks,
        // but a sleep/wake handler already in flight checks this flag and
        // bails rather than racing the teardown below.
        lock.withLock { stopped = true }
        sleepWake.stop()

        let (mic, system, start) = lock.withLock {
            (micEngine, systemEngine, startWall)
        }
        mic?.stop()
        await system?.stop()

        // `stop()` drains the queue and writes EOS before joining, so the
        // tail of captured audio is not dropped.
        micServer.stop()
        if configuration.systemAudioEnabled {
            systemServer.stop()
        }

        let duration = start.map { Date().timeIntervalSince($0) } ?? 0
        await emit(RecordingStoppedEvent(
            recordingId: configuration.recordingId,
            durationSeconds: duration,
            reason: reason))
    }

    // MARK: - Engine construction

    private func makeMicEngine() -> MicCaptureEngine {
        let engine = MicCaptureEngine(deviceID: configuration.micDeviceID)
        engine.onEvent = { [weak self] event in self?.route(event, .mic) }
        return engine
    }

    private func makeSystemEngine() -> SystemAudioCaptureEngine {
        let engine = SystemAudioCaptureEngine(filter: .allApps)
        engine.onEvent = { [weak self] event in self?.route(event, .system) }
        return engine
    }

    /// Route a captured event to its socket. Frames are dropped while paused
    /// so no audio from a sleep window leaks onto the wire; everything is
    /// dropped once teardown has begun.
    private func route(_ event: AudioStreamEvent, _ stream: Stream) {
        let (isPaused, isStopped) = lock.withLock { (paused, stopped) }
        if isStopped { return }
        if isPaused, case .frame = event { return }
        switch stream {
        case .system: systemServer.enqueue(event)
        case .mic: micServer.enqueue(event)
        }
    }

    // MARK: - Sleep / wake (R7)

    private func handleSleep() {
        let skip = lock.withLock { () -> Bool in
            if stopped || paused { return true }
            paused = true
            pauseWall = Date()
            return false
        }
        guard !skip else { return }

        // Mark the gap in both streams before the engines wind down.
        micServer.enqueue(.paused)
        if configuration.systemAudioEnabled {
            systemServer.enqueue(.paused)
        }
        let (mic, system) = lock.withLock { (micEngine, systemEngine) }
        Task {
            mic?.stop()
            await system?.stop()
            await emit(RecordingPausedEvent(
                recordingId: configuration.recordingId, reason: "sleep"))
        }
    }

    private func handleWake() {
        let pausedAt = lock.withLock { () -> Date? in
            guard !stopped, paused else { return nil }
            return pauseWall
        }
        guard let pausedAt else { return }
        let gap = Date().timeIntervalSince(pausedAt)

        Task {
            guard !lock.withLock({ stopped }) else { return }
            // Fresh engine instances — the capture sessions were torn down on
            // sleep — feeding the same socket servers.
            let mic = makeMicEngine()
            try? mic.start()
            var system: SystemAudioCaptureEngine?
            if configuration.systemAudioEnabled {
                let engine = makeSystemEngine()
                try? await engine.start()
                system = engine
            }
            // Teardown may have begun while the engines were starting — if so,
            // stop the just-created engines instead of installing them.
            let abort = lock.withLock { () -> Bool in
                guard !stopped else { return true }
                micEngine = mic
                systemEngine = system
                return false
            }
            if abort {
                mic.stop()
                await system?.stop()
                return
            }
            // Announce the resume on both sockets *before* un-gating frames,
            // so the engine never sees post-resume audio ahead of its resume
            // marker; `paused` still gates `route()` until the line below.
            let gapEvent = AudioStreamEvent.resumed(gap: .seconds(gap))
            micServer.enqueue(gapEvent)
            if configuration.systemAudioEnabled {
                systemServer.enqueue(gapEvent)
            }
            lock.withLock {
                paused = false
                pauseWall = nil
            }
            await emit(RecordingResumedEvent(
                recordingId: configuration.recordingId, reason: "sleep"))
        }
    }

    private func emit<P: EventPayload>(_ payload: P) async {
        guard let events = configuration.events else { return }
        _ = try? await events.append(payload)
    }
}

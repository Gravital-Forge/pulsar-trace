import Foundation
import Logging

/// One provisional speaker turn from the live pass: a stitched stable label
/// active over a recording-absolute span, plus the pyannote embedding behind
/// it (so the speaker-library lookup can put a name to it).
public struct LiveSpeakerSpan: Sendable, Equatable {
    /// Stable provisional speaker key for this recording — `Them`, `Them #2`,
    /// … Stitched across windows by `LiveDiarizer` (the raw per-window pyannote
    /// labels are not stable, so they are not exposed).
    public let provisionalKey: String
    /// Recording-absolute start.
    public let start: Duration
    /// Recording-absolute end.
    public let end: Duration
    /// The pyannote embedding for this window's speaker (256-d). Empty if the
    /// window produced none.
    public let embedding: [Float]

    public init(
        provisionalKey: String,
        start: Duration,
        end: Duration,
        embedding: [Float]
    ) {
        self.provisionalKey = provisionalKey
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

/// Live (streaming) speaker diarization for the system stream (Epic 6 — R15,
/// R16).
///
/// ## diart vs windowed-pyannote — Open Question #1 (project-docs/DECISIONS.md D19)
///
/// The PRD recommended `diart`. `diart` cannot be installed in this project's
/// venv without downgrading `pyannote.audio` from the pinned 4.0.4 to 3.4.0
/// (and `numpy` to 1.26.4) — `pip install diart` resolves exactly that. That
/// downgrade would break the working Epic 3 offline diarization, which depends
/// on `pyannote/speaker-diarization-community-1` (a pyannote 4.x model) and on
/// embeddings staying cross-comparable with the speaker library (R29). PRD §16
/// explicitly lists **windowed-pyannote** as the viable alternative, so that is
/// what PulsarTrace ships: the existing pyannote 4.x pipeline run on a sliding
/// window of recent system audio.
///
/// ## A long-lived subprocess, not one-shot per window
///
/// `LiveDiarizer` launches `python -m pulsartrace_ai.live_diarize` **once** and
/// keeps it alive for the whole recording — the ~10-30 s pyannote model load is
/// paid a single time. The engine then streams windows to it over a newline
/// JSON protocol: write a `{window_wav, window_start}` request line, read back
/// a `{speakers, spans, embeddings}` response line.
///
/// ## Provisional label stitching
///
/// pyannote's per-window labels (`SPEAKER_00`, …) are **not stable** across
/// windows — windowed online diarization spawns labels freely (a known
/// limitation the PRD accepts: "live diarization spawning many speaker IDs in
/// a 2-person call — provisional, fine — post-pass corrects"). `LiveDiarizer`
/// stitches them into stable per-recording keys (`Them`, `Them #2`, …) by
/// matching each window-speaker's embedding against the running set of live
/// speakers' centroids by cosine similarity. A new voice that matches nothing
/// gets a fresh `Them #N`. This is **best-effort**; the post-pass is the
/// source of truth.
///
/// An `actor`: it owns subprocess state and the running live-speaker set, both
/// mutable and not safe to touch concurrently.
public actor LiveDiarizer {

    /// Reuses the offline `Diarizer.Configuration` shape — same Python
    /// interpreter, working directory, environment. Only the module differs.
    public struct Configuration: Sendable {
        public let pythonExecutable: URL
        public let workingDirectory: URL
        public let moduleName: String
        public let environment: [String: String]
        /// How long to wait for the subprocess's `{"ready":true}` line — the
        /// model load. Generous: pyannote community-1 loads in ~10-30 s.
        public let startupTimeout: Duration
        /// Per-window decode ceiling. A window that overruns this is given up
        /// on (the live pass stays provisional anyway).
        public let windowTimeout: Duration

        public init(
            pythonExecutable: URL,
            workingDirectory: URL,
            moduleName: String = "pulsartrace_ai.live_diarize",
            environment: [String: String] = [:],
            startupTimeout: Duration = .seconds(120),
            windowTimeout: Duration = .seconds(30)
        ) {
            self.pythonExecutable = pythonExecutable
            self.workingDirectory = workingDirectory
            self.moduleName = moduleName
            self.environment = environment
            self.startupTimeout = startupTimeout
            self.windowTimeout = windowTimeout
        }
    }

    public enum LiveDiarizeError: Error, CustomStringConvertible {
        case pythonNotFound(String)
        case launchFailed(String)
        case startupFailed(String)
        case notRunning

        public var description: String {
            switch self {
            case .pythonNotFound(let p): return "python interpreter not found: \(p)"
            case .launchFailed(let m): return "live diarization failed to launch: \(m)"
            case .startupFailed(let m): return "live diarization startup failed: \(m)"
            case .notRunning: return "live diarization subprocess is not running"
            }
        }
    }

    /// Cosine-similarity threshold for stitching a window-speaker to an
    /// existing live speaker. Above → same speaker; below → a new `Them #N`.
    public static let stitchThreshold = 0.55

    private let configuration: Configuration
    private let logger: Logger
    private let pythonLogger: Logger
    /// Scratch directory for per-window WAVs (cleaned up on `stop`).
    private let scratchDirectory: URL

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutLines: AsyncLineReader?
    private var stderrTask: Task<Void, Never>?
    private var windowCounter = 0

    /// The pyannote model checkpoint's HF commit SHA, reported by the
    /// subprocess in its `{"ready":...}` handshake. Empty until `start()`
    /// completes, or if the subprocess could not resolve it. The speaker-
    /// library lookup (R18) keys centroid compatibility on this so it never
    /// matches a centroid across a pyannote model change (Open Question #3).
    private var pyannoteModelRevision = ""

    /// Running set of live speakers, one centroid per stitched provisional key.
    private struct LiveSpeaker {
        let key: String
        var centroid: [Float]
        var appearances: Int
    }
    private var liveSpeakers: [LiveSpeaker] = []

    public init(
        configuration: Configuration,
        scratchDirectory: URL,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.configuration = configuration
        self.logger = logger
        self.pythonLogger = Logger(label: LogSubsystem.engine)
        self.scratchDirectory = scratchDirectory
    }

    /// Test seam: pre-seed the running live-speaker set and the model
    /// revision, so the R18 speaker-library lookup can be exercised without
    /// spawning the Python subprocess. Not part of the public protocol — the
    /// real path populates both via `start()` + `stitch()`.
    func _seedForTesting(
        speakers: [(key: String, centroid: [Float])],
        modelRevision: String
    ) {
        liveSpeakers = speakers.map {
            LiveSpeaker(key: $0.key, centroid: $0.centroid, appearances: 1)
        }
        pyannoteModelRevision = modelRevision
    }

    /// Launch the long-lived subprocess and wait for it to load the model.
    public func start() async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(
            atPath: configuration.pythonExecutable.path) else {
            throw LiveDiarizeError.pythonNotFound(
                configuration.pythonExecutable.path)
        }
        try FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = configuration.pythonExecutable
        proc.arguments = ["-m", configuration.moduleName]
        proc.currentDirectoryURL = configuration.workingDirectory

        var env = ProcessInfo.processInfo.environment
        for (k, v) in configuration.environment { env[k] = v }
        env["PYANNOTE_METRICS_ENABLED"] = "false"   // Hard Invariant #1 / D12
        if env["PYTHONHASHSEED"] == nil { env["PYTHONHASHSEED"] = "1729" }
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw LiveDiarizeError.launchFailed(String(describing: error))
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutLines = AsyncLineReader(
            handle: stdoutPipe.fileHandleForReading)

        // Forward stderr into the operational log tagged [python] (R60),
        // basenaming any stray path (Hard Invariant #7).
        let stderrHandle = stderrPipe.fileHandleForReading
        let pyLog = pythonLogger
        self.stderrTask = Task.detached {
            let reader = AsyncLineReader(handle: stderrHandle)
            while let line = await reader.next() {
                pyLog.notice("[python] \(Diarizer.redactingPaths(in: line))")
            }
        }

        // Wait for the `{"ready":...}` handshake (the model load). The ready
        // line also carries `model_revision` (the pyannote checkpoint's HF
        // commit SHA) — capture it for the R18 library lookup.
        guard let reader = stdoutLines else {
            throw LiveDiarizeError.startupFailed("no stdout")
        }
        let readyLine = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask {
                while let line = await reader.next() {
                    if line.contains("\"ready\"") { return line }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: self.configuration.startupTimeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? nil
        }
        guard let readyLine else {
            stop()
            throw LiveDiarizeError.startupFailed(
                "subprocess did not report ready (model load failed/timed out)")
        }
        if let data = readyLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data)
               as? [String: Any],
           let revision = json["model_revision"] as? String {
            pyannoteModelRevision = revision
        }
        logger.notice("live diarization subprocess ready (windowed-pyannote)")
    }

    /// Diarize one window of recent system-stream audio.
    ///
    /// Writes `samples` to a scratch WAV, sends a request line, reads one
    /// response line, and stitches the window's raw pyannote labels into stable
    /// provisional keys. Returns the provisional spans for this window.
    ///
    /// `windowStart` is the window's offset from the start of the recording.
    /// A subprocess hiccup yields `[]` (the live pass degrades, never crashes).
    public func diarizeWindow(
        samples: [Float],
        windowStart: Duration
    ) async -> [LiveSpeakerSpan] {
        guard let stdinHandle, let stdoutLines, process?.isRunning == true else {
            return []
        }
        windowCounter += 1
        let wavURL = scratchDirectory.appendingPathComponent(
            String(format: "win-%06d.wav", windowCounter))
        defer { try? FileManager.default.removeItem(at: wavURL) }

        do {
            try WAVWriter.write(samples: samples, to: wavURL)
        } catch {
            logger.error("live diarization: window WAV write failed")
            return []
        }

        let request: [String: Any] = [
            "window_wav": wavURL.path,
            "window_start": windowStart.seconds,
        ]
        guard let requestData = try? JSONSerialization.data(
                withJSONObject: request),
              let requestLine = String(data: requestData, encoding: .utf8) else {
            return []
        }
        do {
            try stdinHandle.write(contentsOf: Data((requestLine + "\n").utf8))
        } catch {
            logger.error("live diarization: subprocess stdin closed")
            return []
        }

        // Read one response line, bounded by the per-window timeout.
        let response = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { await stdoutLines.next() }
            group.addTask {
                try? await Task.sleep(for: self.configuration.windowTimeout)
                return nil
            }
            let line = await group.next() ?? nil
            group.cancelAll()
            return line ?? nil
        }
        guard let response,
              let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any] else {
            logger.warning("live diarization: window produced no usable result")
            return []
        }
        if let err = json["error"] as? String {
            // `err` is the Python subprocess's error string — it can carry a
            // full path. Redact before logging (Hard Invariant #7), same as
            // the stderr handling above.
            logger.warning(
                "live diarization: window error (\(Diarizer.redactingPaths(in: err)))")
            return []
        }
        return stitch(windowJSON: json)
    }

    /// Shut the subprocess down cleanly and remove the scratch directory.
    public func stop() {
        stderrTask?.cancel()
        stderrTask = nil
        // Closing stdin makes the Python loop hit EOF and exit 0.
        try? stdinHandle?.close()
        stdinHandle = nil
        if let process, process.isRunning {
            // Give it a moment to exit on EOF, then ensure it is gone.
            process.terminate()
        }
        process = nil
        stdoutLines = nil
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    // MARK: - Stitching

    /// Turn one window's response JSON into stable-keyed `LiveSpeakerSpan`s.
    private func stitch(windowJSON: [String: Any]) -> [LiveSpeakerSpan] {
        let rawSpans = windowJSON["spans"] as? [[String: Any]] ?? []
        let embeddings = windowJSON["embeddings"] as? [String: [Double]] ?? [:]

        // Stitch each raw label that has an embedding to a stable key.
        var keyByRawLabel: [String: String] = [:]
        for (rawLabel, vectorD) in embeddings.sorted(by: { $0.key < $1.key }) {
            let vector = vectorD.map(Float.init)
            keyByRawLabel[rawLabel] = stitchKey(for: vector)
        }

        var out: [LiveSpeakerSpan] = []
        for span in rawSpans {
            guard let raw = span["speaker"] as? String,
                  let start = span["start"] as? Double,
                  let end = span["end"] as? Double else { continue }
            // A raw label with no embedding still gets a key — fall back to a
            // by-name mapping so its span is not dropped.
            let key = keyByRawLabel[raw]
                ?? fallbackKey(forRawLabel: raw)
            let embedding = embeddings[raw]?.map(Float.init) ?? []
            out.append(LiveSpeakerSpan(
                provisionalKey: key,
                start: .milliseconds(Int(start * 1000)),
                end: .milliseconds(Int(end * 1000)),
                embedding: embedding))
        }
        return out
    }

    /// Match an embedding to an existing live speaker (cosine ≥ threshold),
    /// refining its centroid; or create a fresh `Them #N`.
    private func stitchKey(for embedding: [Float]) -> String {
        guard !embedding.isEmpty else {
            return fallbackKey(forRawLabel: "noembed")
        }
        var bestIndex = -1
        var bestScore = Self.stitchThreshold
        for (i, speaker) in liveSpeakers.enumerated() {
            let score = Centroid.cosineSimilarity(speaker.centroid, embedding)
            if score >= bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        if bestIndex >= 0 {
            // Returning live speaker: refine the centroid (running mean).
            let s = liveSpeakers[bestIndex]
            liveSpeakers[bestIndex].centroid = Centroid.runningMean(
                existing: s.centroid,
                appearanceCount: s.appearances,
                appearance: embedding)
            liveSpeakers[bestIndex].appearances += 1
            return s.key
        }
        // A new voice.
        let key = Self.provisionalKey(index: liveSpeakers.count)
        liveSpeakers.append(LiveSpeaker(
            key: key, centroid: embedding, appearances: 1))
        return key
    }

    /// Fallback key for a raw label with no embedding — keep it stable per
    /// raw label so the same window-speaker maps consistently.
    private var fallbackByRaw: [String: String] = [:]
    private func fallbackKey(forRawLabel raw: String) -> String {
        if let existing = fallbackByRaw[raw] { return existing }
        let key = Self.provisionalKey(index: liveSpeakers.count
            + fallbackByRaw.count)
        fallbackByRaw[raw] = key
        return key
    }

    /// The Nth provisional speaker key: `Them`, `Them #2`, `Them #3`, …
    /// (R16 — the `(provisional)` suffix is added by the line formatter).
    public static func provisionalKey(index: Int) -> String {
        index == 0 ? "Them" : "Them #\(index + 1)"
    }

    /// The live-speaker centroids, for a read-only speaker-library lookup
    /// (R18) — keyed by provisional key.
    public func centroids() -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for s in liveSpeakers { out[s.key] = s.centroid }
        return out
    }

    /// The pyannote model checkpoint's HF commit SHA (from the subprocess's
    /// ready handshake). The R18 speaker-library lookup keys centroid
    /// compatibility on this — `bestMatch` skips speakers recorded under a
    /// different revision (Open Question #3). Empty if the subprocess could
    /// not resolve it; an empty revision matches nothing in a populated
    /// library, so the lookup degrades to generic `Them` labels rather than
    /// risking a cross-model false match.
    public func modelRevision() -> String {
        pyannoteModelRevision
    }
}

/// Minimal async line reader over a `FileHandle` — yields one decoded UTF-8
/// line at a time off the actor's executor. Used for the live-diarization
/// subprocess's stdout/stderr.
final class AsyncLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private var eof = false
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Next line (without the trailing newline), or `nil` at EOF.
    func next() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: readLine())
            }
        }
    }

    private func readLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                let line = String(decoding: lineData, as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            if eof {
                guard !buffer.isEmpty else { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                eof = true
                continue
            }
            buffer.append(chunk)
        }
    }
}

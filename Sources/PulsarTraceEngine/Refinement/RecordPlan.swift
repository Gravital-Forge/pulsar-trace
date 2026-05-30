import Foundation

/// The fully-resolved launch plan for one `pulsartrace record` session (R47):
/// the recording id, output folder, socket paths, and the exact argument
/// vectors for the `pulsartrace-capture` and `pulsartrace-engine` subprocesses.
///
/// `RecordPlan` is pure — it derives argv from already-parsed options and
/// never touches the filesystem or spawns a process. `RecordOrchestrator`
/// consumes the plan; `RecordCommand` (CLI) parses options into it. Keeping
/// argv construction here makes the capture↔engine wiring unit-testable
/// without real audio, and is the orchestration code path the menubar
/// reuses.
public struct RecordPlan: Sendable, Equatable {
    /// The recording id (`rec_<short>`) shared by capture, engine, and events.
    public let recordingId: String
    /// The recording folder — engine writes `live.md` + the audio WAVs here;
    /// a later `refine` of this folder produces `final.md`.
    public let outputFolder: URL
    /// The system-audio capture socket.
    public let systemSocket: URL
    /// The microphone capture socket.
    public let micSocket: URL
    /// argv for `pulsartrace-capture` (excludes the binary itself).
    public let captureArguments: [String]
    /// argv for `pulsartrace-engine` (excludes the binary itself).
    public let engineArguments: [String]

    /// Build the launch plan.
    ///
    /// - Parameters:
    ///   - outputFolder: the recording folder; its basename names the recording.
    ///   - paths: resolves the per-session socket locations.
    ///   - micDeviceID: an `AVCaptureDevice.uniqueID`, or `nil` for the default
    ///     microphone (R5).
    ///   - systemAudioEnabled: `false` for a mic-only recording (R6) — the
    ///     engine then reads a single stream from the mic socket and no system
    ///     socket is wired.
    ///   - modelName: whisper model for both the live pass and the post-pass.
    ///   - allowedLanguages: optional ISO-639-1 allow list for the live
    ///     pass's per-window language detection. Empty (the default) →
    ///     unrestricted auto-detect. When non-empty, the engine is launched
    ///     with `--allowed-languages a,b,...` and pre-detects per window,
    ///     forcing the highest-probability allowed code.
    public static func make(
        outputFolder: URL,
        paths: AppPaths,
        micDeviceID: String?,
        systemAudioEnabled: Bool,
        modelName: String,
        allowedLanguages: [String] = []
    ) -> RecordPlan {
        let recordingId = RecordingFolder.recordingId(
            forName: outputFolder.lastPathComponent)
        let systemSocket = paths.systemSocketURL(recordingId: recordingId)
        let micSocket = paths.micSocketURL(recordingId: recordingId)

        var captureArgs = [
            "--recording-id", recordingId,
            "--out", outputFolder.path,
            "--system-socket", systemSocket.path,
            "--mic-socket", micSocket.path,
            "--model", modelName,
        ]
        if let micDeviceID {
            captureArgs += ["--mic-device", micDeviceID]
        }
        if !systemAudioEnabled {
            captureArgs.append("--no-system-audio")
        }

        var engineArgs = [
            "--live",
            "--out", outputFolder.path,
            "--recording-id", recordingId,
            "--model", modelName,
        ]
        if systemAudioEnabled {
            // Two-socket mode: the system stream is diarized, the mic stream
            // is the `You` stream.
            engineArgs += [
                "--system-socket", systemSocket.path,
                "--mic-socket", micSocket.path,
            ]
        } else {
            // Mic-only: the engine reads a single stream from the mic socket.
            engineArgs += ["--mic-socket", micSocket.path]
        }
        if !allowedLanguages.isEmpty {
            engineArgs += ["--allowed-languages",
                           allowedLanguages.joined(separator: ",")]
        }

        return RecordPlan(
            recordingId: recordingId,
            outputFolder: outputFolder,
            systemSocket: systemSocket,
            micSocket: micSocket,
            captureArguments: captureArgs,
            engineArguments: engineArgs)
    }
}

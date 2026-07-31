import Foundation

/// The fully-resolved launch plan for one `pulsartrace record` session (PT-R47):
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
    /// The system-audio capture socket. Derived unconditionally, but unused
    /// (not wired into any argv) in fixture mode.
    public let systemSocket: URL
    /// The microphone capture socket. Derived unconditionally, but unused
    /// (not wired into any argv) in fixture mode.
    public let micSocket: URL
    /// argv for `pulsartrace-capture` (excludes the binary itself).
    public let captureArguments: [String]
    /// argv for `pulsartrace-engine` (excludes the binary itself).
    public let engineArguments: [String]

    /// Fixture WAVs standing in for the two capture streams (PT-R127).
    ///
    /// Engine semantics: the primary `--source fixture` stream is the
    /// *system* stream (diarized); `--mic-fixture` pairs the `You` stream.
    /// With only `mic` set, that WAV rides as the primary single stream and
    /// its utterances get diarized labels rather than `You`.
    public struct Fixtures: Sendable, Equatable {
        public let system: URL?
        public let mic: URL?

        /// The stream that rides as the engine's primary `--source fixture`
        /// argument. Non-nil by the init invariant (at least one stream).
        public var primary: URL { system ?? mic! }

        /// At least one stream is required.
        public init?(system: URL?, mic: URL?) {
            guard system != nil || mic != nil else { return nil }
            self.system = system
            self.mic = mic
        }

        /// The process overrides' fixtures; `nil` when fixture capture is
        /// inactive (the production path).
        public static func from(_ overrides: EnvironmentOverrides) -> Fixtures? {
            Fixtures(system: overrides.systemFixture,
                     mic: overrides.micFixture)
        }
    }

    /// Build the launch plan.
    ///
    /// - Parameters:
    ///   - outputFolder: the recording folder; its basename names the recording.
    ///   - paths: resolves the per-session socket locations.
    ///   - micDeviceID: an `AVCaptureDevice.uniqueID`, or `nil` for the default
    ///     microphone (PT-R5).
    ///   - systemAudioEnabled: `false` for a mic-only recording (PT-R6) — the
    ///     engine then reads a single stream from the mic socket and no system
    ///     socket is wired.
    ///   - allowedLanguages: optional ISO-639-1 allow list. When non-empty,
    ///     the engine is launched with `--allowed-languages a,b,...`. The live
    ///     pass uses it as a *script hint*: exactly one code → that code hints
    ///     Parakeet (which has no language-ID head); otherwise → auto. The
    ///     refine pass reproduces the old pin / detect-among semantics over the
    ///     allow list (tasks 13/14). Empty (the default) → auto.
    ///   - fixtures: when non-nil (PT-R127), the plan replaces both device
    ///     streams with committed fixture WAVs and empties `captureArguments`;
    ///     the orchestrator factory
    ///     (`RecordingViewModel.defaultOrchestratorFactory`) skips the capture
    ///     spawn for such plans, and the engine reads the fixtures through its
    ///     realtime `--source fixture` source. `nil` (the default) is the
    ///     unchanged device-capture path.
    ///   - diarizeMic: PT-R147 — the recording's mic-diarization stamp. When
    ///     `true` the engine is launched with `--diarize-mic`, which turns on the
    ///     second windowed diarizer over the mic stream (owner → library → Guest
    ///     labels) instead of the flat `You`. The engine also honors the same
    ///     stamp from `options.json`; the flag is the direct-launch path.
    public static func make(
        outputFolder: URL,
        paths: AppPaths,
        micDeviceID: String?,
        systemAudioEnabled: Bool,
        allowedLanguages: [String] = [],
        diarizeMic: Bool = false,
        fixtures: Fixtures? = nil
    ) -> RecordPlan {
        let recordingId = RecordingFolder.recordingId(
            forName: outputFolder.lastPathComponent)
        let systemSocket = paths.systemSocketURL(recordingId: recordingId)
        let micSocket = paths.micSocketURL(recordingId: recordingId)

        var engineArgs = [
            "--live",
            "--out", outputFolder.path,
            "--recording-id", recordingId,
        ]
        var captureArgs: [String] = []
        if let fixtures {
            // PT-R127: no capture daemon; the engine reads the committed
            // fixture WAVs through its existing realtime fixture source.
            engineArgs += ["--source", "fixture", fixtures.primary.path]
            if fixtures.system != nil, let mic = fixtures.mic {
                engineArgs += ["--mic-fixture", mic.path]
            }
        } else {
            captureArgs = [
                "--recording-id", recordingId,
                "--out", outputFolder.path,
                "--system-socket", systemSocket.path,
                "--mic-socket", micSocket.path,
                // The live pass has exactly one backend (PT-P5-D1). Capture still
                // takes `--model` because the value feeds the public
                // `recording_started` event's `model_live` field
                // (RecordingStartedEvent) — removing an event field is a
                // breaking public-API change. Fixed to the only live model.
                "--model", "parakeet-v3",
            ]
            if let micDeviceID {
                captureArgs += ["--mic-device", micDeviceID]
            }
            if !systemAudioEnabled {
                captureArgs.append("--no-system-audio")
            }

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
        }
        if !allowedLanguages.isEmpty {
            engineArgs += ["--allowed-languages",
                           allowedLanguages.joined(separator: ",")]
        }
        if diarizeMic {
            engineArgs.append("--diarize-mic")   // PT-R147
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

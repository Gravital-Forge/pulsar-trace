import Foundation
import PulsarTraceCapture
import PulsarTraceEngine

/// `pulsartrace record [--output PATH] [--duration MIN] [--mic INDEX]
/// [--no-system-audio] [--list-mics]` — headless recording (R47).
///
/// `record` spawns `pulsartrace-capture` (the TCC-gated daemon, R4) and
/// `pulsartrace-engine --live`, runs the live pass for `--duration` minutes
/// (or until Ctrl-C), then refines the recording into `final.md`. It produces
/// the same recording folder a menubar recording would, with no UI involved.
enum RecordCommand {

    /// Parsed `record` options.
    struct Options {
        let outputFolder: URL?
        let durationMinutes: Int?
        let micIndex: Int?
        let systemAudioEnabled: Bool
        let listMics: Bool
    }

    /// Run `pulsartrace record`. Returns the process exit code.
    static func run(_ args: [String], events: EventWriter) async -> Int32 {
        let options: Options
        do {
            options = try parse(args)
        } catch {
            err("\(error)")
            err(usage)
            return 2
        }

        if options.listMics {
            listMicrophones()
            return 0
        }

        // --- host guards (edge cases) ---------------------------------------
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion < 14 {
            err("record: PulsarTrace requires macOS 14 or later "
                + "(this Mac runs macOS \(HostInfo.macosVersion)).")
            return 1
        }
        if !DoctorCommand.isAppleSilicon() {
            err("record: warning — Intel Mac; transcription will be slow.")
        }
        if let minutes = options.durationMinutes, minutes <= 0 {
            err("record: --duration must be a positive number of minutes")
            return 2
        }

        // --- resolve the microphone ----------------------------------------
        let micDeviceID: String?
        if let index = options.micIndex {
            let devices = AudioInputDevices.available()
            guard index >= 0, index < devices.count else {
                err("record: --mic \(index) is out of range — "
                    + "\(devices.count) input device(s); run "
                    + "`pulsartrace record --list-mics`")
                return 2
            }
            micDeviceID = devices[index].uniqueID
        } else {
            micDeviceID = nil
        }

        // --- resolve the recording folder ----------------------------------
        let outputFolder = options.outputFolder ?? defaultOutputFolder()
        do {
            try SecureFiles.createDirectoryPrivateIfNew(at: outputFolder)
        } catch {
            err("record: cannot create output folder \(outputFolder.path) — \(error)")
            return 1
        }

        // --- locate the sibling daemon binaries ----------------------------
        guard let binDir = binaryDirectory() else {
            err("record: could not locate the pulsartrace-capture / "
                + "pulsartrace-engine binaries")
            return 1
        }

        let plan = RecordPlan.make(
            outputFolder: outputFolder,
            paths: .standard,
            micDeviceID: micDeviceID,
            systemAudioEnabled: options.systemAudioEnabled)

        // --- run the capture + live-engine session -------------------------
        let orchestrator = RecordOrchestrator(configuration: .init(
            captureBinary: binDir.appendingPathComponent("pulsartrace-capture"),
            captureArguments: plan.captureArguments,
            engineBinary: binDir.appendingPathComponent("pulsartrace-engine"),
            engineArguments: plan.engineArguments))

        do {
            err("record: starting capture…")
            try await orchestrator.start(readyTimeout: .seconds(20))
        } catch let e as RecordOrchestrator.StartError {
            err("record: \(e)")
            if case .captureExitedBeforeReady(let code, _) = e, code == 2 {
                return 2   // a permission failure — capture's own exit code
            }
            return 1
        } catch {
            err("record: \(error)")
            return 1
        }

        if let minutes = options.durationMinutes {
            err("record: recording for \(minutes) min "
                + "(\(plan.recordingId)) — Ctrl-C to stop early")
        } else {
            err("record: recording (\(plan.recordingId)) — Ctrl-C to stop")
        }

        await waitForStop(
            orchestrator: orchestrator,
            durationMinutes: options.durationMinutes)

        err("record: stopping…")
        let outcome = await orchestrator.stop()
        if outcome.engineExitCode != 0 {
            err("record: warning — live pass exited with code "
                + "\(outcome.engineExitCode)")
        }
        out("record: live pass complete — \(outputFolder.appendingPathComponent("live.md").path)")

        // --- refine into final.md ------------------------------------------
        err("record: refining…")
        let refineCode = await RefineCommand.run(
            // Interim: refine still runs on whisper.cpp until task 14 adds
            // `--refine-model`; "base" keeps D24's no-surprise-download
            // default. Task 14 replaces this with options.refineModelName.
            [outputFolder.path, "--model", "base"], events: events)
        if refineCode != 0 {
            err("record: refinement failed — `live.md` is preserved; "
                + "re-run `pulsartrace refine \(outputFolder.path)`")
            return refineCode
        }
        return 0
    }

    // MARK: - Stop condition

    /// Block until the recording should stop: the duration elapsed, Ctrl-C was
    /// pressed, or the engine exited on its own. A 200 ms poll keeps this free
    /// of task-group cancellation hazards.
    private static func waitForStop(
        orchestrator: RecordOrchestrator,
        durationMinutes: Int?
    ) async {
        let interrupt = InterruptFlag()
        let deadline = durationMinutes.map {
            ContinuousClock.now + .seconds($0 * 60)
        }
        while true {
            if interrupt.isSet { return }
            if let deadline, ContinuousClock.now >= deadline { return }
            if await !orchestrator.isEngineRunning() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Microphones

    private static func listMicrophones() {
        let devices = AudioInputDevices.available()
        if devices.isEmpty {
            out("No audio input devices found.")
            return
        }
        out("Audio input devices (use the index with --mic):")
        for (index, device) in devices.enumerated() {
            out("  [\(index)] \(device.name)")
        }
    }

    // MARK: - Path resolution

    /// The directory holding the `pulsartrace-capture` / `pulsartrace-engine`
    /// binaries — siblings of the running `pulsartrace`. `PULSARTRACE_BIN_DIR`
    /// overrides it (tests, and running off the build host — project-docs/DECISIONS.md D3).
    static func binaryDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["PULSARTRACE_BIN_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    /// A timestamped recording folder in the current directory.
    private static func defaultOutputFolder() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("pulsartrace-\(f.string(from: Date()))",
                                    isDirectory: true)
    }

    // MARK: - Argument parsing

    enum ArgError: Error, CustomStringConvertible {
        case missingValue(String)
        case notANumber(flag: String, value: String)
        case unexpectedArgument(String)

        var description: String {
            switch self {
            case .missingValue(let flag):
                return "record: \(flag) needs a value"
            case .notANumber(let flag, let value):
                return "record: \(flag) expects a number, got '\(value)'"
            case .unexpectedArgument(let a):
                return "record: unexpected argument '\(a)'"
            }
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        var outputFolder: URL?
        var durationMinutes: Int?
        var micIndex: Int?
        var systemAudioEnabled = true
        var listMics = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            func value(_ flag: String) throws -> String {
                guard i + 1 < args.count else { throw ArgError.missingValue(flag) }
                let v = args[i + 1]
                i += 2
                return v
            }
            switch arg {
            case "--output":
                outputFolder = recordingFolderURL(from: try value("--output"))
            case "--duration":
                let raw = try value("--duration")
                guard let minutes = Int(raw) else {
                    throw ArgError.notANumber(flag: "--duration", value: raw)
                }
                durationMinutes = minutes
            case "--mic":
                let raw = try value("--mic")
                guard let index = Int(raw) else {
                    throw ArgError.notANumber(flag: "--mic", value: raw)
                }
                micIndex = index
            case "--no-system-audio":
                systemAudioEnabled = false
                i += 1
            case "--list-mics":
                listMics = true
                i += 1
            default:
                throw ArgError.unexpectedArgument(arg)
            }
        }
        return Options(
            outputFolder: outputFolder,
            durationMinutes: durationMinutes,
            micIndex: micIndex,
            systemAudioEnabled: systemAudioEnabled,
            listMics: listMics)
    }

    /// Interpret `--output PATH` as the recording-folder directory. A trailing
    /// `.md` is stripped as a courtesy so `--output meeting.md` produces the
    /// folder `meeting/` (final.md lands inside it) — project-docs/DECISIONS.md D24.
    private static func recordingFolderURL(from path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "md" {
            return url.deletingPathExtension()
        }
        return url
    }

    static let usage =
        "usage: pulsartrace record [--output PATH] [--duration MIN] "
        + "[--mic INDEX] [--no-system-audio] [--list-mics]"

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

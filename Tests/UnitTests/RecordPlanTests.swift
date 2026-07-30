import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 1 — `RecordPlan`, the pure capture↔engine argv builder behind
/// `pulsartrace record` (PT-R47).
@Suite("RecordPlan (record, PT-R47)")
struct RecordPlanTests {

    private let paths = AppPaths(home: URL(fileURLWithPath: "/tmp/pt-home"))
    private let folder = URL(fileURLWithPath: "/tmp/meetings/standup", isDirectory: true)

    /// Value following `flag` in an argv, or `nil`.
    private func value(after flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    @Test("system + mic mode wires both sockets into capture and engine")
    func systemAndMic() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true)

        // The recording id threads through both argv.
        #expect(value(after: "--recording-id", in: plan.captureArguments)
            == plan.recordingId)
        #expect(value(after: "--recording-id", in: plan.engineArguments)
            == plan.recordingId)

        // Capture binds both sockets; no mic-only flag.
        #expect(value(after: "--system-socket", in: plan.captureArguments)
            == plan.systemSocket.path)
        #expect(value(after: "--mic-socket", in: plan.captureArguments)
            == plan.micSocket.path)
        #expect(!plan.captureArguments.contains("--no-system-audio"))
        #expect(!plan.captureArguments.contains("--mic-device"))

        // The engine runs the live pass off both sockets.
        #expect(plan.engineArguments.contains("--live"))
        #expect(value(after: "--system-socket", in: plan.engineArguments)
            == plan.systemSocket.path)
        #expect(value(after: "--mic-socket", in: plan.engineArguments)
            == plan.micSocket.path)
        #expect(value(after: "--out", in: plan.engineArguments) == folder.path)
        // The live pass has exactly one backend (PT-P5-D1): the engine takes no
        // model flag; capture still reports the fixed name in
        // `recording_started.model_live`.
        #expect(!plan.engineArguments.contains("--model"))
        #expect(value(after: "--model", in: plan.captureArguments) == "parakeet-v3")
    }

    @Test("mic-only mode passes --no-system-audio and no engine system socket")
    func micOnly() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: false)

        #expect(plan.captureArguments.contains("--no-system-audio"))
        // The engine reads a single stream from the mic socket — no system one.
        #expect(!plan.engineArguments.contains("--system-socket"))
        #expect(value(after: "--mic-socket", in: plan.engineArguments)
            == plan.micSocket.path)
    }

    @Test("an explicit microphone id is forwarded to capture as --mic-device")
    func explicitMicDevice() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: "BuiltInMic-7F3A", systemAudioEnabled: true)
        #expect(value(after: "--mic-device", in: plan.captureArguments)
            == "BuiltInMic-7F3A")
        #expect(value(after: "--model", in: plan.captureArguments) == "parakeet-v3")
    }

    @Test("allowedLanguages non-empty emits --allowed-languages a,b on the engine argv")
    func allowedLanguagesEmitted() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true,
            allowedLanguages: ["en", "pl"])
        #expect(value(after: "--allowed-languages", in: plan.engineArguments)
            == "en,pl")
        // Not a capture-side concern — the allow-list is an engine flag that
        // drives the live pass's script hint (and the refine pass's pin /
        // detect-among semantics), so it lives on the engine argv only.
        #expect(!plan.captureArguments.contains("--allowed-languages"))
    }

    @Test("empty allowedLanguages omits the flag entirely (legacy auto)")
    func allowedLanguagesEmptyOmitsFlag() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true)
        #expect(!plan.engineArguments.contains("--allowed-languages"))
    }

    @Test("socket paths live under the configured socket directory")
    func socketPathsUnderSocketDir() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true)
        #expect(plan.systemSocket == paths.systemSocketURL(recordingId: plan.recordingId))
        #expect(plan.micSocket == paths.micSocketURL(recordingId: plan.recordingId))
        #expect(plan.systemSocket.path.hasSuffix("-system.sock"))
        #expect(plan.micSocket.path.hasSuffix("-mic.sock"))
    }

    @Test("capture carries the fixed live model name for the recording_started event")
    func captureCarriesTheFixedLiveModelName() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true)
        #expect(value(after: "--model", in: plan.captureArguments) == "parakeet-v3")
        #expect(!plan.engineArguments.contains("--model"))
    }

    @Test("diarizeMic appends --diarize-mic to engine args (PT-R147)")
    func diarizeMicFlag() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true,
            diarizeMic: true)
        #expect(plan.engineArguments.contains("--diarize-mic"))
        // Capture is not a diarization concern — the flag rides the engine argv.
        #expect(!plan.captureArguments.contains("--diarize-mic"))
    }

    @Test("default keeps engine args byte-identical to today")
    func defaultOmitsFlag() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true)
        #expect(!plan.engineArguments.contains("--diarize-mic"))
    }
}

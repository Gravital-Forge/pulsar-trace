import Testing
import Foundation
@testable import PulsarTraceEngine

/// Fixture-mode argv derivation (PT-P7-R2).
@Suite("RecordPlan fixtures")
struct RecordPlanFixtureTests {

    private let out = URL(fileURLWithPath: "/tmp/pt-rec/2026-07-02-090000")
    private let paths = AppPaths(home: URL(fileURLWithPath: "/tmp/pt-home"))
    private let system = URL(fileURLWithPath: "/tmp/fx/system.wav")
    private let mic = URL(fileURLWithPath: "/tmp/fx/mic.wav")

    @Test("paired fixtures: no capture argv; engine reads both fixture streams")
    func pairedFixtures() {
        let plan = RecordPlan.make(
            outputFolder: out, paths: paths, micDeviceID: nil,
            systemAudioEnabled: true,
            fixtures: RecordPlan.Fixtures(system: system, mic: mic))
        #expect(plan.captureArguments.isEmpty)
        #expect(plan.engineArguments == [
            "--live",
            "--out", out.path,
            "--recording-id", plan.recordingId,
            "--source", "fixture", system.path,
            "--mic-fixture", mic.path,
        ])
    }

    @Test("mic-only fixture rides as the primary single stream")
    func micOnly() {
        let plan = RecordPlan.make(
            outputFolder: out, paths: paths, micDeviceID: nil,
            systemAudioEnabled: false,
            fixtures: RecordPlan.Fixtures(system: nil, mic: mic))
        #expect(plan.captureArguments.isEmpty)
        #expect(plan.engineArguments == [
            "--live",
            "--out", out.path,
            "--recording-id", plan.recordingId,
            "--source", "fixture", mic.path,
        ])
    }

    @Test("allowed languages still ride the fixture argv")
    func languages() {
        let plan = RecordPlan.make(
            outputFolder: out, paths: paths, micDeviceID: nil,
            systemAudioEnabled: true, allowedLanguages: ["en", "pl"],
            fixtures: RecordPlan.Fixtures(system: system, mic: nil))
        #expect(plan.engineArguments.suffix(2)
            == ["--allowed-languages", "en,pl"])
    }

    @Test("Fixtures requires at least one URL; from(_:) mirrors activity")
    func construction() {
        #expect(RecordPlan.Fixtures(system: nil, mic: nil) == nil)
        #expect(RecordPlan.Fixtures.from(EnvironmentOverrides(
            environment: [:])) == nil)
        let active = RecordPlan.Fixtures.from(EnvironmentOverrides(
            environment: ["PULSARTRACE_MIC_FIXTURE": "/tmp/fx/mic.wav"]))
        #expect(active?.mic == URL(fileURLWithPath: "/tmp/fx/mic.wav"))
        #expect(active?.system == nil)
    }

    @Test("nil fixtures — parity with the device plan")
    func parity() {
        let device = RecordPlan.make(
            outputFolder: out, paths: paths, micDeviceID: "mic-1",
            systemAudioEnabled: true)
        #expect(!device.captureArguments.isEmpty)
        #expect(device.engineArguments.contains("--system-socket"))
    }
}

import Testing
import Foundation
@testable import PulsarTraceEngine

/// The end-to-end override variables (PT-R126, PT-R127).
@Suite("EnvironmentOverrides")
struct EnvironmentOverridesTests {

    @Test("all five variables parse; paths become file URLs")
    func parsesAll() {
        let o = EnvironmentOverrides(environment: [
            "PULSARTRACE_HOME": "/tmp/pt-home",
            "PULSARTRACE_DEFAULTS_SUITE": "com.gravitalforge.PulsarTrace.uitest",
            "PULSARTRACE_MODELS_DIR": "/tmp/models",
            "PULSARTRACE_SYSTEM_FIXTURE": "/tmp/system.wav",
            "PULSARTRACE_MIC_FIXTURE": "/tmp/mic.wav",
        ])
        #expect(o.home == URL(fileURLWithPath: "/tmp/pt-home", isDirectory: true))
        #expect(o.defaultsSuite == "com.gravitalforge.PulsarTrace.uitest")
        #expect(o.modelsDirectory == URL(fileURLWithPath: "/tmp/models", isDirectory: true))
        #expect(o.systemFixture == URL(fileURLWithPath: "/tmp/system.wav", isDirectory: false))
        #expect(o.micFixture == URL(fileURLWithPath: "/tmp/mic.wav", isDirectory: false))
        #expect(o.fixtureCaptureActive)
    }

    @Test("a trailing slash on home yields the same URL as no slash")
    func homeTrailingSlashStandardized() {
        let slashed = EnvironmentOverrides(
            environment: ["PULSARTRACE_HOME": "/tmp/pt-home/"])
        let plain = EnvironmentOverrides(
            environment: ["PULSARTRACE_HOME": "/tmp/pt-home"])
        #expect(slashed.home == plain.home)
        #expect(slashed.home == URL(fileURLWithPath: "/tmp/pt-home", isDirectory: true))
    }

    @Test("absent and empty values are unset; fixture capture inactive")
    func absentAndEmpty() {
        let o = EnvironmentOverrides(environment: [
            "PULSARTRACE_HOME": "",
            "UNRELATED": "x",
        ])
        #expect(o.home == nil)
        #expect(o.defaultsSuite == nil)
        #expect(o.modelsDirectory == nil)
        #expect(o.systemFixture == nil)
        #expect(o.micFixture == nil)
        #expect(!o.fixtureCaptureActive)
    }

    @Test("one fixture variable alone activates fixture capture")
    func singleFixture() {
        let o = EnvironmentOverrides(
            environment: ["PULSARTRACE_MIC_FIXTURE": "/tmp/mic.wav"])
        #expect(o.fixtureCaptureActive)
        #expect(o.systemFixture == nil)
    }
}

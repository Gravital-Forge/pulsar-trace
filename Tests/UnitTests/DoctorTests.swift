import Testing
@testable import PulsarTraceEngine

/// Layer 1 — `EnvironmentDoctor`, the pure decision logic behind
/// `pulsartrace doctor` (R50). Environment *gathering* lives in the CLI's
/// `DoctorCommand` and is covered by a real-binary smoke run.
@Suite("EnvironmentDoctor (doctor, R50)")
struct DoctorTests {

    // MARK: - macOS

    @Test("macOS 14+ passes; older is a hard failure")
    func macOSThreshold() {
        #expect(EnvironmentDoctor.macOSCheck(
            majorVersion: 14, versionString: "14.0").status == .ok)
        #expect(EnvironmentDoctor.macOSCheck(
            majorVersion: 26, versionString: "26.3.1").status == .ok)
        #expect(EnvironmentDoctor.macOSCheck(
            majorVersion: 13, versionString: "13.6").status == .fail)
    }

    // MARK: - architecture

    @Test("Apple Silicon passes; Intel is a warning, not a failure")
    func architecture() {
        #expect(EnvironmentDoctor.architectureCheck(
            isAppleSilicon: true).status == .ok)
        #expect(EnvironmentDoctor.architectureCheck(
            isAppleSilicon: false).status == .warn)
    }

    // MARK: - diarization models

    @Test("cached diarization models pass")
    func diarizerModelsCachedIsOK() {
        let check = EnvironmentDoctor.diarizerModelsCheck(cached: true)
        #expect(check.status == .ok)
    }

    @Test("missing diarization models are an informational warning")
    func diarizerModelsMissingIsInformationalWarn() {
        let check = EnvironmentDoctor.diarizerModelsCheck(cached: false)
        #expect(check.status == .warn)
        #expect(check.detail.contains("first"))
    }

    // MARK: - speaker library

    @Test("a library that will not open is a hard failure")
    func speakerLibrary() {
        #expect(EnvironmentDoctor.speakerLibraryCheck(
            opened: true, backupAvailable: false).status == .ok)
        let failWithBackup = EnvironmentDoctor.speakerLibraryCheck(
            opened: false, backupAvailable: true)
        #expect(failWithBackup.status == .fail)
        #expect(failWithBackup.detail.contains("backup"))
    }

    // MARK: - permissions

    @Test("a missing permission is a warning — offline commands still work")
    func permissions() {
        #expect(EnvironmentDoctor.permissionCheck(
            permission: "Microphone", granted: true).status == .ok)
        #expect(EnvironmentDoctor.permissionCheck(
            permission: "Microphone", granted: false).status == .warn)
    }

    // MARK: - directories

    @Test("a non-writable required directory is a hard failure")
    func directoryWritable() {
        #expect(EnvironmentDoctor.directoryWritableCheck(
            name: "Logs", writable: true).status == .ok)
        #expect(EnvironmentDoctor.directoryWritableCheck(
            name: "Logs", writable: false).status == .fail)
    }

    // MARK: - report rollup

    @Test("the report rolls up failures and warnings; only failures are fatal")
    func reportRollup() {
        let report = DoctorReport(checks: [
            EnvironmentDoctor.macOSCheck(majorVersion: 14, versionString: "14.0"),
            EnvironmentDoctor.architectureCheck(isAppleSilicon: false),
            EnvironmentDoctor.directoryWritableCheck(name: "Logs", writable: false),
        ])
        #expect(report.failureCount == 1)
        #expect(report.warningCount == 1)
        #expect(report.hasFailure)
    }

    @Test("an all-ok report is not a failure and renders a clean summary")
    func reportAllOK() {
        let report = DoctorReport(checks: [
            EnvironmentDoctor.macOSCheck(majorVersion: 26, versionString: "26.3"),
            EnvironmentDoctor.architectureCheck(isAppleSilicon: true),
        ])
        #expect(!report.hasFailure)
        #expect(report.warningCount == 0)
        let rendered = report.render()
        #expect(rendered.contains("All checks passed."))
        #expect(rendered.contains("[ ok ]"))
    }
}

import Foundation
import PulsarTraceCapture
import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `pulsartrace doctor [--capture-test]` — environment self-check (R50, R68).
///
/// `doctor` gathers facts about the host (macOS version, CPU, model cache,
/// Python runtime, speaker library, TCC permissions, writable directories) and
/// runs each through `EnvironmentDoctor`'s pure decision logic, then prints an
/// actionable report. `--capture-test` additionally runs a sine sweep through
/// the real capture path (R68).
///
/// Exit code: `0` when no check failed (warnings are advisory), `1` otherwise.
enum DoctorCommand {

    /// Run `pulsartrace doctor`. Returns the process exit code.
    static func run(_ args: [String], events: EventWriter) async -> Int32 {
        if let unknown = args.first(where: { $0 != "--capture-test" }) {
            err("doctor: unexpected argument '\(unknown)'")
            err("usage: pulsartrace doctor [--capture-test]")
            return 2
        }

        let report = await buildReport()
        out(report.render())

        if args.contains("--capture-test") {
            out("")
            return await CaptureTest.run(baseFailure: report.hasFailure)
        }
        return report.hasFailure ? 1 : 0
    }

    // MARK: - Report

    /// Gather the host environment and run every `EnvironmentDoctor` check.
    static func buildReport() async -> DoctorReport {
        var checks: [DoctorCheck] = []

        // --- macOS + CPU ----------------------------------------------------
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(EnvironmentDoctor.macOSCheck(
            majorVersion: os.majorVersion,
            versionString: HostInfo.macosVersion))
        checks.append(EnvironmentDoctor.architectureCheck(
            isAppleSilicon: isAppleSilicon()))

        // --- whisper model cache -------------------------------------------
        let modelDir = ModelStore.defaultCacheDirectory()
        for model in ModelCatalog.all {
            let url = modelDir.appendingPathComponent(model.fileName)
            checks.append(EnvironmentDoctor.modelCheck(
                name: model.name,
                present: modelFilePresent(url, expectedSize: model.sizeBytes)))
        }

        // --- Python diarization runtime ------------------------------------
        checks.append(EnvironmentDoctor.pythonRuntimeCheck(
            interpreterPresent: FileManager.default.fileExists(
                atPath: venvPythonURL().path)))

        // --- speaker library ------------------------------------------------
        let dbURL = AppPaths.standard.speakersDatabaseURL
        let libraryOpened: Bool
        do {
            _ = try await SpeakerLibrary(databaseURL: dbURL)
            libraryOpened = true
        } catch {
            libraryOpened = false
        }
        let backupURL = dbURL.appendingPathExtension("bak")
        checks.append(EnvironmentDoctor.speakerLibraryCheck(
            opened: libraryOpened,
            backupAvailable: FileManager.default.fileExists(
                atPath: backupURL.path)))

        // --- TCC permissions ------------------------------------------------
        let checker = PermissionChecker(events: nil)
        checks.append(EnvironmentDoctor.permissionCheck(
            permission: "Microphone",
            granted: checker.microphoneGranted()))
        checks.append(EnvironmentDoctor.permissionCheck(
            permission: "Screen Recording",
            granted: await checker.screenRecordingGranted()))

        // --- writable directories ------------------------------------------
        let paths = AppPaths.standard
        checks.append(EnvironmentDoctor.directoryWritableCheck(
            name: "Application Support", writable: isWritable(paths.applicationSupport)))
        checks.append(EnvironmentDoctor.directoryWritableCheck(
            name: "Logs directory", writable: isWritable(paths.logDirectory)))

        return DoctorReport(checks: checks)
    }

    // MARK: - Environment probes

    /// True on Apple Silicon hardware — `hw.optional.arm64` reports the host
    /// CPU regardless of whether the process is translated.
    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return rc == 0 && value == 1
    }

    /// A cheap "model present" probe: the file exists and is the expected size.
    /// Full SHA-256 verification happens at load time (R54d) — too slow for a
    /// diagnostic over a multi-GB model.
    private static func modelFilePresent(_ url: URL, expectedSize: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.path), let size = attrs[.size] as? Int else { return false }
        return size == expectedSize
    }

    /// True when `directory` can be created and written. Probes by creating the
    /// directory and writing (then removing) a hidden marker file.
    private static func isWritable(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil else {
            return false
        }
        let probe = directory.appendingPathComponent(".pt-doctor-probe")
        guard (try? Data().write(to: probe)) != nil else { return false }
        try? fm.removeItem(at: probe)
        return true
    }

    /// Resolve the Python diarization interpreter, mirroring
    /// `RefineCommand.makeDiarizer` (`PULSARTRACE_VENV_PYTHON`, else the
    /// repo-tree venv — project-docs/DECISIONS.md D3).
    static func venvPythonURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["PULSARTRACE_VENV_PYTHON"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let repoRoot: URL
        if let root = env["PULSARTRACE_REPO_ROOT"], !root.isEmpty {
            repoRoot = URL(fileURLWithPath: root)
        } else {
            repoRoot = URL(fileURLWithPath: #filePath)   // …/Sources/pulsartrace/DoctorCommand.swift
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        return repoRoot.appendingPathComponent("python/pulsartrace-ai/.venv/bin/python")
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

import Foundation

/// One environment self-check result for `pulsartrace doctor` (R50).
public struct DoctorCheck: Sendable, Equatable {
    /// A check's outcome. `warn` is advisory (the CLI still works); `fail`
    /// means something the user must fix.
    public enum Status: String, Sendable {
        case ok
        case warn
        case fail
    }

    /// Short check name, e.g. `macOS version`.
    public let name: String
    /// The outcome.
    public let status: Status
    /// An *actionable* one-line detail — what was found and, for warn/fail,
    /// what to do about it.
    public let detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// The result of a `pulsartrace doctor` run — a list of checks plus the
/// rollup the CLI uses for its exit code and summary line.
public struct DoctorReport: Sendable {
    public let checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.checks = checks
    }

    /// Any hard failure — the CLI exits non-zero when true.
    public var hasFailure: Bool { checks.contains { $0.status == .fail } }
    public var warningCount: Int { checks.count { $0.status == .warn } }
    public var failureCount: Int { checks.count { $0.status == .fail } }

    /// A human-readable, fixed-width report.
    public func render() -> String {
        var lines = ["PulsarTrace doctor — environment self-check", ""]
        let nameWidth = checks.map(\.name.count).max() ?? 0
        for check in checks {
            let tag: String
            switch check.status {
            case .ok: tag = "[ ok ]"
            case .warn: tag = "[warn]"
            case .fail: tag = "[FAIL]"
            }
            let paddedName = check.name.padding(
                toLength: nameWidth, withPad: " ", startingAt: 0)
            lines.append("  \(tag)  \(paddedName)  \(check.detail)")
        }
        lines.append("")
        let summary: String
        if failureCount == 0 && warningCount == 0 {
            summary = "All checks passed."
        } else {
            summary = "\(failureCount) failure(s), \(warningCount) warning(s)."
        }
        lines.append(summary)
        return lines.joined(separator: "\n")
    }
}

/// Builds the individual `DoctorCheck`s for `pulsartrace doctor` (R50).
///
/// Every function here is **pure** — it maps an already-gathered environment
/// fact to a check result. The environment *gathering* (filesystem probes, TCC
/// queries, model-cache inspection) lives in the CLI's `DoctorCommand`, which
/// then feeds these. Keeping the decision logic pure makes the actionable
/// messages and status thresholds unit-testable without a real environment.
public enum EnvironmentDoctor {

    /// macOS version. PulsarTrace requires macOS 14+ (PRD §8). An older host is
    /// a hard failure — the engine will not run correctly.
    public static func macOSCheck(majorVersion: Int, versionString: String) -> DoctorCheck {
        if majorVersion >= 14 {
            return DoctorCheck(
                name: "macOS version", status: .ok,
                detail: "macOS \(versionString) (supported)")
        }
        return DoctorCheck(
            name: "macOS version", status: .fail,
            detail: "macOS \(versionString) — PulsarTrace requires macOS 14 "
                + "or later; upgrade macOS to use PulsarTrace")
    }

    /// CPU architecture. Apple Silicon is the supported target; PulsarTrace
    /// runs on Intel but transcription is much slower (PRD Epic 9/10 edge case).
    public static func architectureCheck(isAppleSilicon: Bool) -> DoctorCheck {
        if isAppleSilicon {
            return DoctorCheck(
                name: "CPU architecture", status: .ok,
                detail: "Apple Silicon")
        }
        return DoctorCheck(
            name: "CPU architecture", status: .warn,
            detail: "Intel Mac — PulsarTrace works but transcription is slow; "
                + "Apple Silicon is recommended")
    }

    /// A pinned whisper model's cache state. An absent model is only a warning:
    /// it downloads automatically on first transcription (R54c).
    public static func modelCheck(name: String, present: Bool) -> DoctorCheck {
        if present {
            return DoctorCheck(
                name: "whisper model: \(name)", status: .ok,
                detail: "cached")
        }
        return DoctorCheck(
            name: "whisper model: \(name)", status: .warn,
            detail: "not downloaded — it downloads automatically on first use "
                + "(`pulsartrace refine` / `record`)")
    }

    /// The Python diarization runtime. Without it, diarization is unavailable
    /// and transcripts fall back to a single unlabeled speaker.
    public static func pythonRuntimeCheck(interpreterPresent: Bool) -> DoctorCheck {
        if interpreterPresent {
            return DoctorCheck(
                name: "Python diarization", status: .ok,
                detail: "runtime found")
        }
        return DoctorCheck(
            name: "Python diarization", status: .warn,
            detail: "diarization runtime not found — transcripts will not be "
                + "speaker-labeled; build it with `python/build-venv.sh`")
    }

    /// The persistent speaker library. A database that will not open is a hard
    /// failure; the detail points at the auto-restore path when a backup exists.
    public static func speakerLibraryCheck(
        opened: Bool, backupAvailable: Bool
    ) -> DoctorCheck {
        if opened {
            return DoctorCheck(
                name: "Speaker library", status: .ok,
                detail: "opens cleanly")
        }
        let hint = backupAvailable
            ? "a last-good backup exists — it is auto-restored on next open"
            : "no backup found; the library will be recreated empty on next use"
        return DoctorCheck(
            name: "Speaker library", status: .fail,
            detail: "speakers.sqlite did not open — \(hint)")
    }

    /// A TCC permission `pulsartrace-capture` needs. Absence is a warning, not
    /// a failure: the offline commands (`refine`, `speakers`) work without it —
    /// only `record` needs it.
    public static func permissionCheck(
        permission: String, granted: Bool
    ) -> DoctorCheck {
        if granted {
            return DoctorCheck(
                name: "\(permission) permission", status: .ok,
                detail: "granted")
        }
        return DoctorCheck(
            name: "\(permission) permission", status: .warn,
            detail: "not granted — `pulsartrace record` needs it; grant it in "
                + "System Settings ▸ Privacy & Security")
    }

    /// A directory PulsarTrace must be able to write (events log, output).
    public static func directoryWritableCheck(
        name: String, writable: Bool
    ) -> DoctorCheck {
        if writable {
            return DoctorCheck(name: name, status: .ok, detail: "writable")
        }
        return DoctorCheck(
            name: name, status: .fail,
            detail: "not writable — check folder permissions")
    }
}

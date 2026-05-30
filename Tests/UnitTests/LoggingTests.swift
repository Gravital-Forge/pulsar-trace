import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Unit coverage of log-line formatting, rotation, retention, and the
/// content-leak scan scaffolding (R57–R61, §11).
@Suite("Logging")
struct LoggingTests {

    @Test("Log line uses ISO-8601 UTC · level · subsystem · message format")
    func logLineFormat() {
        let ts = Date(timeIntervalSince1970: 1_777_559_405.123)
        let line = FileLogHandler.format(
            timestamp: ts, level: .notice, subsystem: "engine", message: "Recording started")
        #expect(line.hasPrefix("2026-04-30T14:30:05.123Z"))
        #expect(line.contains("notice"))
        #expect(line.contains("engine"))
        #expect(line.hasSuffix("Recording started"))
    }

    @Test("Multi-line messages collapse to one physical log line")
    func logLineSingleLine() {
        let line = FileLogHandler.format(
            timestamp: Date(), level: .error, subsystem: "engine", message: "a\nb\nc")
        #expect(!line.dropFirst().contains("\n"))
    }

    @Test("LogRotator opens today's file and writes a line")
    func rotatorWritesFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedDay = Date(timeIntervalSince1970: 1_777_559_405)
        let rotator = LogRotator(directory: dir, retentionDays: 7, clock: { fixedDay })
        rotator.bootstrap()
        rotator.append("hello log")
        rotator.flush()

        let url = rotator.currentFileURL()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("hello log"))
        #expect(url.lastPathComponent == "2026-04-30.log")
    }

    @Test("LogRotator prunes files older than the retention window")
    func rotatorPrunes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // An old file (well outside a 7-day window) and a recent one.
        let old = dir.appendingPathComponent("2026-01-01.log")
        let recent = dir.appendingPathComponent("2026-04-29.log")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try "recent".write(to: recent, atomically: true, encoding: .utf8)

        let now = Date(timeIntervalSince1970: 1_777_559_405)  // 2026-04-30
        let rotator = LogRotator(directory: dir, retentionDays: 7, clock: { now })
        rotator.bootstrap()

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test("Content-leak scan flags transcript text in a log")
    func contentLeakScanCatchesLeak() {
        let leaky = "2026-04-30T14:30:05.123Z  notice  engine  the authentication flow breaks"
        let findings = ContentLeakScanner.scan(
            logText: leaky, forbidden: ["the authentication flow breaks"])
        #expect(!findings.isEmpty)
    }

    @Test("Content-leak scan passes a clean log")
    func contentLeakScanPassesClean() {
        let clean = "2026-04-30T14:30:05.123Z  notice  engine  Frame consumption finished; frames=1500"
        let findings = ContentLeakScanner.scan(
            logText: clean, forbidden: ["secret transcript", "/Users/alice/Meetings"])
        #expect(findings.isEmpty)
    }

    /// `pulsartrace-mac` will call `LogSystem.bootstrap` from its
    /// `AppEnvironment.bootstrap()` so the in-process refinement queue's
    /// `Logger(label: LogSubsystem.engine)` lines reach the daily log
    /// file. Some earlier subprocess in the same address space (or an
    /// earlier in-test bootstrap from another suite) may have already
    /// installed a factory — `LoggingSystem.bootstrap` traps on a second
    /// global-factory install, so `LogSystem.bootstrap` must be
    /// idempotent. This regression-guards that contract.
    @Test("LogSystem.bootstrap can be called twice without trapping")
    func bootstrapIsIdempotent() async {
        let home1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-boot1-\(UUID().uuidString)")
        let home2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-boot2-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: home1)
            try? FileManager.default.removeItem(at: home2)
        }
        let paths1 = AppPaths(home: home1)
        let paths2 = AppPaths(home: home2)
        // Both calls return cleanly — no fatalError from
        // `LoggingSystem.bootstrap` being called twice.
        _ = await LogSystem.bootstrap(paths: paths1)
        _ = await LogSystem.bootstrap(paths: paths2)
        // After the second call, the shared `rotator` is non-nil and
        // ready to flush — the bare minimum the mac-app relies on.
        #expect(LogSystem.rotator != nil)
    }
}

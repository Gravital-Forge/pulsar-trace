import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Pipeline coverage that a clean process lifecycle emits the
/// `app_started` / `app_stopped` event pair into today's events file (§8.13,
/// Epic 1 "Done" criterion).
@Suite("Lifecycle events")
struct LifecycleEventTests {

    @Test("A clean start/stop emits the app_started/app_stopped pair")
    func startStopEmitsPair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-life-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)

        let lifecycle = await AppLifecycle.start(paths: paths)
        await lifecycle.stop()

        let dayFile = paths.eventsDirectory
            .appendingPathComponent("\(Timestamps.dayStamp(Date())).jsonl")
        let text = try String(contentsOf: dayFile, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        let types = try lines.map { line -> String in
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return obj["type"] as! String
        }
        #expect(types.contains("app_started"))
        #expect(types.contains("app_stopped"))
        // app_started precedes app_stopped — events are causally ordered.
        if let s = types.firstIndex(of: "app_started"),
           let e = types.firstIndex(of: "app_stopped") {
            #expect(s < e)
        }
    }

    @Test("Operational log lines for lifecycle events leak no content")
    func lifecycleLogIsClean() async throws {
        // The `FileLogHandler` produces the operational log; route a logger
        // through a dedicated rotator (the global `LoggingSystem` factory is
        // process-wide and set once, so this exercises the handler directly).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-oplog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rotator = LogRotator(directory: dir, retentionDays: 7)
        rotator.bootstrap()

        var logger = Logger(label: LogSubsystem.app) { label in
            FileLogHandler(label: label, rotator: rotator, level: .notice)
        }
        logger.notice(
            "PulsarTrace started; version=\(HostInfo.appVersion), macos=\(HostInfo.macosVersion)")
        logger.notice("PulsarTrace stopping")
        // No sleep workaround needed: `FileLogHandler.log` appends synchronously
        // on the rotator's serial queue, and `flush()` is a barrier that drains
        // every queued line before returning.
        rotator.flush()

        let text = try String(contentsOf: rotator.currentFileURL(), encoding: .utf8)
        #expect(text.contains("PulsarTrace started"))
        let findings = ContentLeakScanner.scan(
            logText: text, forbidden: ["coffee shop", "authentication flow"])
        #expect(findings.isEmpty)
    }
}

import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the events-log JSONL writer, envelope, rotation, and
/// privacy guarantee (R78–R84, §8.13).
@Suite("EventWriter")
struct EventWriterTests {

    /// A deterministic writer over a fresh temp directory.
    private func makeWriter(
        day: Date = Date(timeIntervalSince1970: 1_777_559_405),
        retentionDays: Int = 30
    ) -> (EventWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-events-\(UUID().uuidString)")
        let ulids = DeterministicULIDFactory(seed: 1234)
        let writer = EventWriter(
            directory: dir,
            retentionDays: retentionDays,
            clock: { day },
            ulidFactory: { ulids.make($0) }
        )
        return (writer, dir)
    }

    @Test("Every event line carries the common envelope")
    func envelopeOnEveryLine() async throws {
        let (writer, dir) = makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        await writer.bootstrap()
        try await writer.append(AppStartedEvent(version: "0.1.0", macosVersion: "26.3.1"))

        let url = await writer.currentFileURL()
        let line = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(obj["ts"] != nil)
        #expect(obj["type"] as? String == "app_started")
        #expect((obj["id"] as? String)?.hasPrefix("evt_") == true)
        #expect(obj["version"] as? Int == 1)
    }

    @Test("app_started payload includes version and macos_version")
    func appStartedPayload() async throws {
        let (writer, dir) = makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        await writer.bootstrap()
        try await writer.append(AppStartedEvent(version: "0.1.0", macosVersion: "26.3.1"))

        let url = await writer.currentFileURL()
        let line = try String(contentsOf: url, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(
            with: Data(line.split(separator: "\n").first!.utf8)) as! [String: Any]
        #expect(obj["macos_version"] as? String == "26.3.1")
    }

    @Test("Events file is named for the local day")
    func dailyFileName() async throws {
        let (writer, dir) = makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        await writer.bootstrap()
        let url = await writer.currentFileURL()
        #expect(url.lastPathComponent == "2026-04-30.jsonl")
    }

    @Test("Appends are append-only — second event keeps the first")
    func appendOnly() async throws {
        let (writer, dir) = makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        await writer.bootstrap()
        try await writer.append(AppStartedEvent(version: "0.1.0", macosVersion: "26.3.1"))
        try await writer.append(AppStoppedEvent(version: "0.1.0", macosVersion: "26.3.1"))

        let url = await writer.currentFileURL()
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
    }

    @Test("Old events files beyond 30 days are pruned on bootstrap")
    func retentionPrune() async throws {
        let (writer, dir) = makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("2026-01-01.jsonl")
        try "{}".write(to: old, atomically: true, encoding: .utf8)

        await writer.bootstrap()
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test("Events log contains no transcript text or full user paths")
    func eventsNoContentLeak() async throws {
        let (writer, dir) = makeWriter()
        defer { try? FileManager.default.removeItem(at: dir) }
        await writer.bootstrap()
        try await writer.append(AppStartedEvent(version: "0.1.0", macosVersion: "26.3.1"))
        try await writer.append(AppStoppedEvent(version: "0.1.0", macosVersion: "26.3.1"))

        let url = await writer.currentFileURL()
        let text = try String(contentsOf: url, encoding: .utf8)
        let findings = ContentLeakScanner.scan(
            logText: text,
            forbidden: ["coffee shop", "authentication flow"])
        #expect(findings.isEmpty)
    }

    @Test("Event registry knows the app_started/app_stopped pair")
    func registryHasSystemEvents() {
        #expect(EventRegistry.entry(for: "app_started")?.version == 1)
        #expect(EventRegistry.entry(for: "app_stopped")?.category == .system)
    }
}

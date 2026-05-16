import Testing
import Foundation
import SnapshotTesting
@testable import PulsarTraceEngine

/// Snapshot coverage of the events-log JSONL line format (R65).
///
/// The events log is a public API surface; a format regression an LLM might
/// introduce ("nicer key names") shows up here as a text diff. The snapshot is
/// recorded on first run and must only be updated as a deliberate contract
/// change (determinism rule / `swift-snapshot-testing` discipline).
@Suite("Event snapshot")
struct EventSnapshotTests {

    @Test("app_started JSONL line matches the recorded snapshot")
    func appStartedSnapshot() throws {
        let envelope = EventWriter.Envelope(
            ts: "2026-04-30T14:30:05Z",
            type: AppStartedEvent.eventType,
            id: "evt_01HW000000000000000000000A",
            version: AppStartedEvent.schemaVersion)
        let payload = AppStartedEvent(version: "0.1.0-dev", macosVersion: "26.3.1")
        let line = try EventWriter.encodeLine(envelope: envelope, payload: payload)
        assertSnapshot(of: line, as: .lines)
    }

    @Test("app_stopped JSONL line matches the recorded snapshot")
    func appStoppedSnapshot() throws {
        let envelope = EventWriter.Envelope(
            ts: "2026-04-30T15:12:48Z",
            type: AppStoppedEvent.eventType,
            id: "evt_01HW000000000000000000000B",
            version: AppStoppedEvent.schemaVersion)
        let payload = AppStoppedEvent(version: "0.1.0-dev", macosVersion: "26.3.1")
        let line = try EventWriter.encodeLine(envelope: envelope, payload: payload)
        assertSnapshot(of: line, as: .lines)
    }
}

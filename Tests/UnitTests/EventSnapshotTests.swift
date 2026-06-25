import Testing
import Foundation
import SnapshotTesting
@testable import PulsarTraceEngine

/// Snapshot coverage of the events-log JSONL line format (PT-R65).
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

    // MARK: - Speaker library events

    /// Encode `payload` with a fixed envelope so the JSONL line is snapshot-stable.
    private func line<P: EventPayload>(
        _ payload: P, id: String = "evt_01HW00000000000000000000SP"
    ) throws -> String {
        let envelope = EventWriter.Envelope(
            ts: "2026-04-30T14:30:05Z",
            type: P.eventType, id: id, version: P.schemaVersion)
        return try EventWriter.encodeLine(envelope: envelope, payload: payload)
    }

    @Test("speaker_created JSONL line matches the recorded snapshot")
    func speakerCreatedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerCreatedEvent(
            speakerId: "spk_a1b2", initialName: "Unknown #3",
            sourceRecordingId: "rec_4f2a")), as: .lines)
    }

    @Test("speaker_renamed JSONL line matches the recorded snapshot")
    func speakerRenamedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerRenamedEvent(
            speakerId: "spk_a1b2", oldName: "Unknown #3", newName: "Steve",
            appliedToRecordings: [])), as: .lines)
    }

    @Test("speaker_merged JSONL line matches the recorded snapshot")
    func speakerMergedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerMergedEvent(
            primarySpeakerId: "spk_a1b2", mergedSpeakerId: "spk_c3d4",
            appliedToRecordings: [])), as: .lines)
    }

    @Test("speaker_split JSONL line matches the recorded snapshot")
    func speakerSplitSnapshot() throws {
        assertSnapshot(of: try line(SpeakerSplitEvent(
            originalSpeakerId: "spk_a1b2", newSpeakerId: "spk_e5f6",
            appliedToRecordings: [])), as: .lines)
    }

    @Test("speaker_deleted JSONL line matches the recorded snapshot")
    func speakerDeletedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerDeletedEvent(
            speakerId: "spk_a1b2",
            recoverableUntil: "2026-05-30T14:30:05Z")), as: .lines)
    }

    @Test("speaker_undeleted JSONL line matches the recorded snapshot")
    func speakerUndeletedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerUndeletedEvent(
            speakerId: "spk_a1b2")), as: .lines)
    }

    @Test("speaker_unmerged JSONL line matches the recorded snapshot")
    func speakerUnmergedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerUnmergedEvent(
            primarySpeakerId: "spk_a1b2", mergedSpeakerId: "spk_c3d4")),
            as: .lines)
    }

    @Test("speaker_unsplit JSONL line matches the recorded snapshot")
    func speakerUnsplitSnapshot() throws {
        assertSnapshot(of: try line(SpeakerUnsplitEvent(
            originalSpeakerId: "spk_a1b2", newSpeakerId: "spk_e5f6")),
            as: .lines)
    }

    @Test("speaker_centroid_updated JSONL line matches the recorded snapshot")
    func speakerCentroidUpdatedSnapshot() throws {
        assertSnapshot(of: try line(SpeakerCentroidUpdatedEvent(
            speakerId: "spk_a1b2", recordingId: "rec_4f2a",
            appearanceCount: 3)), as: .lines)
    }

    @Test("library_backup_created JSONL line matches the recorded snapshot")
    func libraryBackupCreatedSnapshot() throws {
        assertSnapshot(of: try line(LibraryBackupCreatedEvent(
            pathBasename: "speakers.sqlite.bak",
            sha256: "a3b1c2d4e5f6")), as: .lines)
    }

    @Test("library_corruption_detected JSONL line matches the recorded snapshot")
    func libraryCorruptionDetectedSnapshot() throws {
        assertSnapshot(of: try line(LibraryCorruptionDetectedEvent(
            pathBasename: "speakers.sqlite",
            recoveredFromBackup: true)), as: .lines)
    }

    // MARK: - Live-pass events

    @Test("live_md_started JSONL line matches the recorded snapshot")
    func liveMDStartedSnapshot() throws {
        assertSnapshot(of: try line(LiveMDStartedEvent(
            recordingId: "rec_two-speakers-alternating",
            pathBasename: "live.md")), as: .lines)
    }

    // MARK: - Recording-lifecycle events

    @Test("recording_started JSONL line matches the recorded snapshot")
    func recordingStartedSnapshot() throws {
        assertSnapshot(of: try line(RecordingStartedEvent(
            recordingId: "rec_4f2a", outputDirBasename: "meeting-2026-05-16",
            micDevice: "MacBook Air Microphone", systemAudioEnabled: true,
            modelLive: "base")), as: .lines)
    }

    @Test("recording_paused JSONL line matches the recorded snapshot")
    func recordingPausedSnapshot() throws {
        assertSnapshot(of: try line(RecordingPausedEvent(
            recordingId: "rec_4f2a", reason: "sleep")), as: .lines)
    }

    @Test("recording_resumed JSONL line matches the recorded snapshot")
    func recordingResumedSnapshot() throws {
        assertSnapshot(of: try line(RecordingResumedEvent(
            recordingId: "rec_4f2a", reason: "sleep")), as: .lines)
    }

    @Test("recording_stopped JSONL line matches the recorded snapshot")
    func recordingStoppedSnapshot() throws {
        assertSnapshot(of: try line(RecordingStoppedEvent(
            recordingId: "rec_4f2a", durationSeconds: 1843.5,
            reason: "user_stop")), as: .lines)
    }

    @Test("permission_changed JSONL line matches the recorded snapshot")
    func permissionChangedSnapshot() throws {
        assertSnapshot(of: try line(PermissionChangedEvent(
            permission: "screen_recording", granted: true)), as: .lines)
    }
}

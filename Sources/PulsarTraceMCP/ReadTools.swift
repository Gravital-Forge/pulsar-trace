import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar

/// The read surface: recordings, speakers, events (PT-P6-R3, PT-P6-R4, PT-P6-R7).
public enum ReadTools {

    /// Shared ISO-8601 parser/formatter. Fully configured at init and
    /// afterwards only read via `date(from:)` / `string(from:)` — Apple
    /// documents that as thread-safe on a no-longer-mutated formatter (the
    /// same hand-checked invariant `RecordingEntry.iso8601` relies on).
    nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    // PT-P6-R3
    public static func listRecordings(recordings: any RecordingsProviding) -> MCPTool {
        MCPTool(
            name: "list_recordings",
            description: "List recordings with their metadata and filesystem paths "
                + "(never transcript or audio content). Filter by since/until (ISO-8601 start time), "
                + "status (live | refined | all), and limit.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object(["type": .string("string"), "description": .string("ISO-8601; include recordings started at/after")]),
                    "until": .object(["type": .string("string"), "description": .string("ISO-8601; include recordings started at/before")]),
                    "status": .object(["type": .string("string"), "enum": .array([.string("live"), .string("refined"), .string("all")])]),
                    "limit": .object(["type": .string("integer")]),
                ]),
            ])
        ) { args in
            let liveID = await recordings.liveRecordingID()
            var entries = await recordings.snapshot()

            if let since = args?["since"]?.stringValue, let d = iso.date(from: since) {
                entries = entries.filter { $0.recordingStart >= d }
            }
            if let until = args?["until"]?.stringValue, let d = iso.date(from: until) {
                entries = entries.filter { $0.recordingStart <= d }
            }
            switch args?["status"]?.stringValue {
            case "refined": entries = entries.filter { $0.isRefined }
            case "live": entries = entries.filter { !$0.isRefined }
            default: break
            }
            if let limit = args?["limit"]?.intValue, limit >= 0 {
                entries = Array(entries.prefix(limit))
            }

            let items = entries.map { Self.recordingDTO($0, liveID: liveID) }
            return Self.jsonResult(["recordings": items])
        }
    }

    // PT-P6-R3
    public static func getRecordingMeta(recordings: any RecordingsProviding) -> MCPTool {
        MCPTool(
            name: "get_recording_meta",
            description: "Fetch one recording's metadata and filesystem paths by id. "
                + "Never returns transcript or audio content — read those from the returned paths.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["id": .object(["type": .string("string")])]),
                "required": .array([.string("id")]),
            ])
        ) { args in
            guard let id = args?["id"]?.stringValue else {
                return errorResult("get_recording_meta requires an `id` argument.")
            }
            let liveID = await recordings.liveRecordingID()
            guard let entry = await recordings.snapshot().first(where: { $0.id == id }) else {
                return errorResult("No recording with id \(id).")
            }
            return jsonResult(["recording": recordingDTO(entry, liveID: liveID)])
        }
    }

    static func recordingDTO(_ e: RecordingEntry, liveID: String?) -> [String: Any] {
        [
            "id": e.id,
            "title": e.displayTitle,
            "start": iso.string(from: e.recordingStart),
            "duration_seconds": e.durationSeconds,
            "language": e.language as Any,
            "refinement_state": e.isRefined ? "refined" : "live",
            "is_live": e.id == liveID,
            "speakers": e.speakers.map {
                ["label": $0.label, "speaker_id": $0.speakerId as Any, "is_microphone": $0.isMicrophone]
            },
            "final_path": e.finalURL.path,
            "live_path": e.liveURL.path,
            "audio_system_path": e.folderURL.appendingPathComponent(RecordingFolder.FileName.audioSystem).path,
            "audio_mic_path": e.folderURL.appendingPathComponent(RecordingFolder.FileName.audioMic).path,
        ]
    }

    // PT-P6-R4
    public static func listSpeakers(library: SpeakerLibrary) -> MCPTool {
        MCPTool(
            name: "list_speakers",
            description: "List the live speakers in the library (id, name, appearance count, last seen). "
                + "Excludes deleted and delisted speakers.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ) { _ in
            do {
                let speakers = try await library.liveSpeakers().map { speakerSummary($0) }
                return jsonResult(["speakers": speakers])
            } catch {
                return errorResult("Could not read the speaker library: \(error)")
            }
        }
    }

    // PT-P6-R4
    public static func getSpeaker(library: SpeakerLibrary) -> MCPTool {
        MCPTool(
            name: "get_speaker",
            description: "Fetch one speaker by id with the recordings it appears in.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["id": .object(["type": .string("string")])]),
                "required": .array([.string("id")]),
            ])
        ) { args in
            guard let id = args?["id"]?.stringValue else {
                return errorResult("get_speaker requires an `id` argument.")
            }
            do {
                guard let speaker = try await library.speaker(id: id) else {
                    return errorResult("No speaker with id \(id).")
                }
                let appearances = try await library.appearances(of: id).map {
                    ["recording_id": $0.recordingId, "recording_folder": $0.recordingFolderName,
                     "observed_at": $0.observedAt]
                }
                var dto = speakerSummary(speaker)
                dto["appearances"] = appearances
                return jsonResult(["speaker": dto])
            } catch {
                return errorResult("Could not read speaker \(id): \(error)")
            }
        }
    }

    /// Summary DTO for a speaker. `lastSeen` is already an ISO-8601 UTC string on
    /// the engine `Speaker`, so it is surfaced verbatim (no Date conversion).
    static func speakerSummary(_ s: Speaker) -> [String: Any] {
        ["id": s.id, "name": s.name, "appearance_count": s.appearanceCount, "last_seen": s.lastSeen]
    }

    static func jsonResult(_ object: [String: Any]) -> CallTool.Result {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], isError: false)
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

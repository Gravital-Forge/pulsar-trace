import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar

/// The read surface: recordings, speakers, events (PT-R117, PT-R118, PT-R121).
public enum ReadTools {

    /// Shared ISO-8601 parser/formatter. Fully configured at init and
    /// afterwards only read via `date(from:)` / `string(from:)` — Apple
    /// documents that as thread-safe on a no-longer-mutated formatter (the
    /// same hand-checked invariant `RecordingEntry.iso8601` relies on).
    nonisolated(unsafe) static let iso = ISO8601DateFormatter()

    // PT-R117
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

    // PT-R117
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
            // PT-P8-R9/PT-P8-R10: the per-recording mic-diarization input stamp
            // (`options.json`) and the last refine's output flag (`metadata.json`
            // `mic_diarized`, absent → false). The stamp is what the NEXT refine
            // will honor; `mic_diarized` is what the CURRENT `final.md` reflects.
            "diarize_mic_stamp": e.diarizeMicStamp,
            "mic_diarized": micDiarized(e),
            "final_path": e.finalURL.path,
            "live_path": e.liveURL.path,
            "audio_system_path": e.folderURL.appendingPathComponent(RecordingFolder.FileName.audioSystem).path,
            "audio_mic_path": e.folderURL.appendingPathComponent(RecordingFolder.FileName.audioMic).path,
        ]
    }

    /// The last refine's `mic_diarized` flag from `metadata.json` (PT-P8-R10);
    /// `false` when the recording is unrefined or the file is absent/malformed.
    private static func micDiarized(_ e: RecordingEntry) -> Bool {
        let url = e.folderURL.appendingPathComponent(RecordingFolder.FileName.metadata)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(RefinementMetadata.self, from: data)
        else { return false }
        return metadata.micDiarized
    }

    // PT-R118
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

    // PT-R118
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

    // PT-R121
    public static func recentEvents(events: EventLogReader) -> MCPTool {
        MCPTool(
            name: "recent_events",
            description: "Return recent events (newest first) so an agent can confirm the effect of an "
                + "operation and observe recording lifecycle. Optional `since` (ISO-8601), `type` "
                + "(string or array of event types), and `limit`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object(["type": .string("string")]),
                    "type": .object(["description": .string("an event type or array of types")]),
                    "limit": .object(["type": .string("integer")]),
                ]),
            ])
        ) { args in
            let since = args?["since"]?.stringValue
            let types: Set<String> = {
                if case let .array(arr)? = args?["type"] { return Set(arr.compactMap { $0.stringValue }) }
                if let one = args?["type"]?.stringValue { return [one] }
                return []
            }()
            let limit = max(0, args?["limit"]?.intValue ?? 100)
            do {
                let items = try events.recent(since: since, types: types, limit: limit).map { entry -> Any in
                    (try? JSONSerialization.jsonObject(with: Data(entry.line.utf8)))
                        ?? ["ts": entry.ts, "type": entry.type]
                }
                return jsonResult(["events": items])
            } catch {
                return errorResult("Could not read events: \(error)")
            }
        }
    }

    static func jsonResult(_ object: [String: Any]) -> CallTool.Result {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], isError: false)
    }

    static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

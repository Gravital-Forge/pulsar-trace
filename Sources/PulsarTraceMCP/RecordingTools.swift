import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar

/// The recording-management surface (PT-R120): set a title, request a refine.
public enum RecordingTools {

    // PT-R120
    public static func renameRecording(recordings: any RecordingsProviding) -> MCPTool {
        MCPTool(
            name: "rename_recording",
            description: "Set a recording's title (stored as a title.txt sidecar). A blank title "
                + "clears it back to the date-based default. The recording's folder name and id never change.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id"), .string("title")]),
            ])
        ) { args in
            guard let id = args?["id"]?.stringValue, let title = args?["title"]?.stringValue else {
                return ReadTools.errorResult("rename_recording requires `id` and `title`.")
            }
            guard let entry = await recordings.snapshot().first(where: { $0.id == id }) else {
                return ReadTools.errorResult("No recording with id \(id).")
            }
            do {
                // `RecordingTitleStore.write` normalizes the title and removes the
                // sidecar when nothing printable remains, so a blank `title`
                // clears it back to the date-based default (no branch needed).
                try RecordingTitleStore.write(title, folderURL: entry.folderURL)
                return ReadTools.jsonResult(["id": id, "title": title])
            } catch {
                return ReadTools.errorResult("Could not set the title: \(error)")
            }
        }
    }

    // PT-R120
    public static func requestRefine(
        recordings: any RecordingsProviding, refine: any RefineRequesting
    ) -> MCPTool {
        MCPTool(
            name: "request_refine",
            description: "Enqueue a (re-)refinement of a recording and return immediately. The refine "
                + "runs in the background; observe progress via recent_events. "
                + "Pass the optional `diarize_mic` (boolean) to set the recording's mic-diarization "
                + "stamp before enqueueing — the tick-then-refine flow: true splits microphone speech "
                + "into You + guests, false collapses all microphone speech to You. Omit it to keep "
                + "the recording's existing stamp.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "diarize_mic": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ) { args in
            guard let id = args?["id"]?.stringValue else {
                return ReadTools.errorResult("request_refine requires an `id`.")
            }
            guard let entry = await recordings.snapshot().first(where: { $0.id == id }) else {
                return ReadTools.errorResult("No recording with id \(id).")
            }
            // PT-P8-R9: when present, persist the stamp before enqueue so the
            // background refine — and every subsequent one — agrees with it.
            if let diarizeMic = args?["diarize_mic"]?.boolValue {
                var options = RecordingOptions.read(from: entry.folderURL)
                options.diarizeMic = diarizeMic
                try? options.write(to: entry.folderURL)
            }
            do {
                try await refine.requestRefine(folderURL: entry.folderURL, recordingId: entry.id)
                return ReadTools.jsonResult(["status": "enqueued", "id": id])
            } catch {
                return ReadTools.errorResult("Could not enqueue a refine for \(id): \(error)")
            }
        }
    }
}

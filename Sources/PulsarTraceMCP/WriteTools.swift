import Foundation
import MCP
import PulsarTraceEngine

/// The speaker-management surface (PT-P6-R5): thin one-to-one wrappers over the
/// `SpeakerEditService`, each gated against in-progress capture.
public enum WriteTools {

    public typealias Roots = @Sendable () async -> [URL]

    static func stringSchema(_ desc: String) -> Value {
        .object(["type": .string("string"), "description": .string(desc)])
    }

    static func ids(_ result: SpeakerEditService.EditResult) -> CallTool.Result {
        ReadTools.jsonResult(["rewritten_recording_ids": result.rewrittenRecordingIds])
    }

    // PT-P6-R5
    public static func renameSpeaker(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "rename_speaker",
            description: "Rename a speaker; rewrites the label across past final.md transcripts.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["speaker_id": stringSchema("the speaker id (spk_…)"),
                                       "to": stringSchema("the new name")]),
                "required": .array([.string("speaker_id"), .string("to")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            guard let id = args?["speaker_id"]?.stringValue, let to = args?["to"]?.stringValue else {
                return ReadTools.errorResult("rename_speaker requires `speaker_id` and `to`.")
            }
            do { return ids(try await service.rename(speakerId: id, to: to, outputFolderRoots: await outputRoots())) }
            catch { return ReadTools.errorResult("\(error)") }
        }
    }

    // PT-P6-R5
    public static func mergeSpeakers(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "merge_speakers",
            description: "Merge one speaker into another; rewrites the merged label to the primary's.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["primary_id": stringSchema("the speaker to keep"),
                                       "other_id": stringSchema("the speaker merged away")]),
                "required": .array([.string("primary_id"), .string("other_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            guard let primary = args?["primary_id"]?.stringValue, let other = args?["other_id"]?.stringValue else {
                return ReadTools.errorResult("merge_speakers requires `primary_id` and `other_id`.")
            }
            do { return ids(try await service.merge(primaryId: primary, otherId: other, outputFolderRoots: await outputRoots())) }
            catch { return ReadTools.errorResult("\(error)") }
        }
    }

    // PT-P6-R5
    public static func splitSpeaker(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "split_speaker",
            description: "Split some of a speaker's recordings out under a new name.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "original_id": stringSchema("the speaker to split"),
                    "moving_recording_ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "to": stringSchema("the new speaker name"),
                ]),
                "required": .array([.string("original_id"), .string("moving_recording_ids"), .string("to")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            guard let original = args?["original_id"]?.stringValue, let to = args?["to"]?.stringValue,
                  case let .array(rawIds)? = args?["moving_recording_ids"] else {
                return ReadTools.errorResult("split_speaker requires `original_id`, `moving_recording_ids`, `to`.")
            }
            let moving = rawIds.compactMap { $0.stringValue }
            do { return ids(try await service.split(originalId: original, movingRecordingIds: moving, newName: to, outputFolderRoots: await outputRoots())) }
            catch { return ReadTools.errorResult("\(error)") }
        }
    }
}

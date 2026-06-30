import Foundation
import MCP
import PulsarTraceEngine

/// The speaker-management surface (PT-R119): thin one-to-one wrappers over the
/// `SpeakerEditService`, each gated against in-progress capture.
public enum WriteTools {

    public typealias Roots = @Sendable () async -> [URL]

    static func stringSchema(_ desc: String) -> Value {
        .object(["type": .string("string"), "description": .string(desc)])
    }

    static func ids(_ result: SpeakerEditService.EditResult) -> CallTool.Result {
        ReadTools.jsonResult(["rewritten_recording_ids": result.rewrittenRecordingIds])
    }

    /// Either a validated `speaker_id` (`.success`) or an `isError` result to return
    /// directly (`.failure`). Not `Swift.Result` — `CallTool.Result` isn't an `Error`.
    enum IdArg {
        case success(String)
        case failure(CallTool.Result)
    }

    static func idArg(_ args: [String: Value]?, _ tool: String) -> IdArg {
        guard let id = args?["speaker_id"]?.stringValue else {
            return .failure(ReadTools.errorResult("\(tool) requires `speaker_id`."))
        }
        return .success(id)
    }

    /// All nine speaker-management tools (PT-R119, PT-P6-D6).
    public static func all(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> [MCPTool] {
        [
            renameSpeaker(service: service, gate: gate, outputRoots: outputRoots),
            mergeSpeakers(service: service, gate: gate, outputRoots: outputRoots),
            splitSpeaker(service: service, gate: gate, outputRoots: outputRoots),
            unmergeSpeakers(service: service, gate: gate, outputRoots: outputRoots),
            unsplitSpeaker(service: service, gate: gate, outputRoots: outputRoots),
            deleteSpeaker(service: service, gate: gate),
            undeleteSpeaker(service: service, gate: gate),
            delistSpeaker(service: service, gate: gate, outputRoots: outputRoots),
            undelistSpeaker(service: service, gate: gate, outputRoots: outputRoots),
        ]
    }

    // PT-R119
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

    // PT-R119
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

    // PT-R119
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

    // PT-R119
    public static func unmergeSpeakers(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "unmerge_speakers",
            description: "Reverse a merge, restoring the other speaker and its label.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["primary_id": stringSchema("the kept speaker"),
                                       "other_id": stringSchema("the previously merged-away speaker")]),
                "required": .array([.string("primary_id"), .string("other_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            guard let primary = args?["primary_id"]?.stringValue, let other = args?["other_id"]?.stringValue else {
                return ReadTools.errorResult("unmerge_speakers requires `primary_id` and `other_id`.")
            }
            do { return ids(try await service.unmerge(primaryId: primary, otherId: other, outputFolderRoots: await outputRoots())) }
            catch { return ReadTools.errorResult("\(error)") }
        }
    }

    // PT-R119
    public static func unsplitSpeaker(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "unsplit_speaker",
            description: "Reverse a split, folding the split-off speaker back into the original.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["original_id": stringSchema("the original speaker"),
                                       "new_id": stringSchema("the split-off speaker to fold back")]),
                "required": .array([.string("original_id"), .string("new_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            guard let original = args?["original_id"]?.stringValue, let new = args?["new_id"]?.stringValue else {
                return ReadTools.errorResult("unsplit_speaker requires `original_id` and `new_id`.")
            }
            do { return ids(try await service.unsplit(originalId: original, newId: new, outputFolderRoots: await outputRoots())) }
            catch { return ReadTools.errorResult("\(error)") }
        }
    }

    // PT-R119
    public static func deleteSpeaker(service: SpeakerEditService, gate: RecordingGate) -> MCPTool {
        MCPTool(
            name: "delete_speaker",
            description: "Soft-delete a speaker (recoverable for 30 days). No transcript rewrite.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["speaker_id": stringSchema("the speaker id")]),
                "required": .array([.string("speaker_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            switch idArg(args, "delete_speaker") {
            case .failure(let err): return err
            case .success(let id):
                do { return ids(try await service.delete(speakerId: id)) }
                catch { return ReadTools.errorResult("\(error)") }
            }
        }
    }

    // PT-R119
    public static func undeleteSpeaker(service: SpeakerEditService, gate: RecordingGate) -> MCPTool {
        MCPTool(
            name: "undelete_speaker",
            description: "Restore a soft-deleted speaker. No transcript rewrite.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["speaker_id": stringSchema("the speaker id")]),
                "required": .array([.string("speaker_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            switch idArg(args, "undelete_speaker") {
            case .failure(let err): return err
            case .success(let id):
                do { return ids(try await service.undelete(speakerId: id)) }
                catch { return ReadTools.errorResult("\(error)") }
            }
        }
    }

    // PT-R119
    public static func delistSpeaker(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "delist_speaker",
            description: "Stop recognizing a speaker; drops its label from past final.md (solo lines "
                + "become Unrecognized). The microphone speaker cannot be delisted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["speaker_id": stringSchema("the speaker id")]),
                "required": .array([.string("speaker_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            switch idArg(args, "delist_speaker") {
            case .failure(let err): return err
            case .success(let id):
                do { return ids(try await service.delist(speakerId: id, outputFolderRoots: await outputRoots())) }
                catch { return ReadTools.errorResult("\(error)") }
            }
        }
    }

    // PT-R119
    public static func undelistSpeaker(
        service: SpeakerEditService, gate: RecordingGate, outputRoots: @escaping Roots
    ) -> MCPTool {
        MCPTool(
            name: "undelist_speaker",
            description: "Resume recognizing a previously delisted speaker; restores its label.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["speaker_id": stringSchema("the speaker id")]),
                "required": .array([.string("speaker_id")]),
            ])
        ) { args in
            if let blocked = await gate.blockIfRecording() { return blocked }
            switch idArg(args, "undelist_speaker") {
            case .failure(let err): return err
            case .success(let id):
                do { return ids(try await service.undelist(speakerId: id, outputFolderRoots: await outputRoots())) }
                catch { return ReadTools.errorResult("\(error)") }
            }
        }
    }
}

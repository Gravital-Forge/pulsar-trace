import Foundation
import PulsarTraceEngine

/// `pulsartrace speakers <list|rename|merge|delete>` — terminal management of
/// the persistent speaker library (R49, Epic 5).
///
/// Operates directly on `~/Library/Application Support/PulsarTrace/speakers.sqlite`
/// and emits the corresponding `speaker_*` events.
///
/// Scope note (project-docs/DECISIONS.md D16): `rename`/`merge` here update the library and
/// emit the speaker event, but do NOT retroactively rewrite past `final.md`
/// files — that retroactive rewrite (and the paired `final_md_rewritten`
/// event) is Epic 8 scope per PRD §15. The new name takes effect on the next
/// `pulsartrace refine` of a recording, when reconciliation applies it.
enum SpeakersCommand {

    /// Run `pulsartrace speakers …`. Returns the process exit code.
    ///
    /// - Parameters:
    ///   - args: arguments *after* the `speakers` token.
    ///   - events: process-wide events writer.
    ///   - databaseURL: library path; defaults to the standard location.
    ///     Tests inject a temp path.
    static func run(
        _ args: [String],
        events: EventWriter,
        databaseURL: URL = AppPaths.standard.speakersDatabaseURL
    ) async -> Int32 {
        guard let sub = args.first else {
            err("speakers: missing subcommand")
            printUsage()
            return 2
        }
        let rest = Array(args.dropFirst())

        let library: SpeakerLibrary
        do {
            library = try await SpeakerLibrary(
                databaseURL: databaseURL, events: events)
        } catch {
            err("speakers: could not open the speaker library — \(error)")
            return 1
        }

        do {
            switch sub {
            case "list":
                return try await list(library)
            case "rename":
                return try await rename(rest, library: library)
            case "merge":
                return try await merge(rest, library: library)
            case "delete":
                return try await delete(rest, library: library)
            case "help", "--help", "-h":
                printUsage()
                return 0
            default:
                err("speakers: unknown subcommand '\(sub)'")
                printUsage()
                return 2
            }
        } catch {
            err("speakers: \(error)")
            return 1
        }
    }

    // MARK: - list

    private static func list(_ library: SpeakerLibrary) async throws -> Int32 {
        let speakers = try await library.liveSpeakers()
        if speakers.isEmpty {
            out("No speakers in the library yet. Run `pulsartrace refine` on a "
                + "recording to populate it.")
            return 0
        }
        out("\(speakers.count) speaker(s):")
        for speaker in speakers {
            let appearances = (try? await library.appearances(of: speaker.id).count) ?? 0
            out("  \(speaker.id)  \(speaker.name)")
            out("      appearances=\(appearances)  last_seen=\(speaker.lastSeen)")
        }
        return 0
    }

    // MARK: - rename

    private static func rename(
        _ args: [String], library: SpeakerLibrary
    ) async throws -> Int32 {
        guard args.count == 2 else {
            err("usage: pulsartrace speakers rename <speaker-id> <new-name>")
            return 2
        }
        let id = args[0]
        let newName = args[1]
        try await library.rename(speakerId: id, to: newName)
        out("renamed \(id) → \"\(newName)\"")
        out("note: past final.md files are not rewritten; the new name applies "
            + "on the next `pulsartrace refine` (Epic 8 adds retroactive rewrite).")
        return 0
    }

    // MARK: - merge

    private static func merge(
        _ args: [String], library: SpeakerLibrary
    ) async throws -> Int32 {
        guard args.count == 2 else {
            err("usage: pulsartrace speakers merge <primary-id> <other-id>")
            return 2
        }
        try await library.merge(primaryId: args[0], otherId: args[1])
        out("merged \(args[1]) into \(args[0]) (recoverable for 30 days — "
            + "the merged speaker is soft-deleted)")
        return 0
    }

    // MARK: - delete

    private static func delete(
        _ args: [String], library: SpeakerLibrary
    ) async throws -> Int32 {
        guard args.count == 1 else {
            err("usage: pulsartrace speakers delete <speaker-id>")
            return 2
        }
        try await library.delete(speakerId: args[0])
        out("deleted \(args[0]) (soft delete — recoverable for 30 days)")
        return 0
    }

    // MARK: - usage

    static func printUsage() {
        err("""
            usage: pulsartrace speakers <subcommand>

            subcommands:
              list                          List library speakers
              rename <speaker-id> <name>    Rename a speaker (id stays stable)
              merge  <primary-id> <other-id>  Merge two speakers (soft, undoable)
              delete <speaker-id>           Soft-delete a speaker (undoable 30d)

            Split and the menubar editor are delivered in Epic 8.
            """)
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

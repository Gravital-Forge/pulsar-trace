import Foundation
import PulsarTraceEngine

/// `pulsartrace speakers <list|rename|merge|delete>` — terminal management of
/// the persistent speaker library (PT-R49).
///
/// Operates directly on `~/Library/Application Support/PulsarTrace/speakers.sqlite`
/// and emits the corresponding `speaker_*` events.
///
/// Scope note (PT-P6-R9, PT-P6-D7): `rename`, `merge`, and `delete` all route
/// through the shared `SpeakerEditService`, so they produce the same file +
/// event effects as the menubar and MCP paths. `rename`/`merge` retroactively
/// rewrite past `final.md` files (and emit the paired `final_md_rewritten`
/// events) — closing the PT-R90 gap the CLI previously skipped; `delete` keeps
/// its no-rewrite behaviour but still flows through the shared service.
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
        // PT-P6-R9: pull the repeated `--output-folder <path>` flags out of the
        // raw args before dispatching, and resolve the roots the rewrite scans.
        let parsed = OutputFolderArgs.parse(args)
        let roots = OutputFolderRoots.resolved(explicit: parsed.roots)
        guard let sub = parsed.positional.first else {
            err("speakers: missing subcommand")
            printUsage()
            return 2
        }
        let rest = Array(parsed.positional.dropFirst())

        let library: SpeakerLibrary
        do {
            library = try await SpeakerLibrary(
                databaseURL: databaseURL, events: events)
        } catch {
            err("speakers: could not open the speaker library — \(error)")
            return 1
        }
        let service = SpeakerEditService(library: library, events: events)

        do {
            switch sub {
            case "list":
                return try await list(library)
            case "rename":
                return try await rename(rest, service: service, roots: roots)
            case "merge":
                return try await merge(rest, service: service, roots: roots)
            case "delete":
                return try await delete(rest, service: service)
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

    // PT-P6-R9
    private static func rename(
        _ args: [String], service: SpeakerEditService, roots: [URL]
    ) async throws -> Int32 {
        guard args.count == 2 else {
            err("usage: pulsartrace speakers rename <speaker-id> <new-name> "
                + "[--output-folder <path>]…")
            return 2
        }
        let result = try await service.rename(
            speakerId: args[0], to: args[1], outputFolderRoots: roots)
        out("renamed \(args[0]) → \"\(args[1])\" "
            + "(rewrote \(result.rewrittenRecordingIds.count) past transcript(s))")
        return 0
    }

    // MARK: - merge

    // PT-P6-R9
    private static func merge(
        _ args: [String], service: SpeakerEditService, roots: [URL]
    ) async throws -> Int32 {
        guard args.count == 2 else {
            err("usage: pulsartrace speakers merge <primary-id> <other-id> "
                + "[--output-folder <path>]…")
            return 2
        }
        let result = try await service.merge(
            primaryId: args[0], otherId: args[1], outputFolderRoots: roots)
        out("merged \(args[1]) into \(args[0]) "
            + "(rewrote \(result.rewrittenRecordingIds.count) past transcript(s); "
            + "the merged speaker is soft-deleted, recoverable for 30 days)")
        return 0
    }

    // MARK: - delete

    // PT-P6-R9
    private static func delete(
        _ args: [String], service: SpeakerEditService
    ) async throws -> Int32 {
        guard args.count == 1 else {
            err("usage: pulsartrace speakers delete <speaker-id>")
            return 2
        }
        _ = try await service.delete(speakerId: args[0])
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

            rename and merge rewrite the new name across past final.md files.
            Pass --output-folder <path> (repeatable) to scan non-default output
            folders; it defaults to ~/Documents/PulsarTrace.

            Speaker split is available in the menubar speaker editor.
            """)
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

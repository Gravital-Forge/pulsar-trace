import Foundation
import PulsarTraceEngine

/// `pulsartrace events tail [--type TYPE]… [--no-follow]` — live-tail today's
/// events log (PT-R86).
///
/// The events log is a public API surface (`docs/events-schema.md`). `tail`
/// streams it verbatim — one JSONL line per event — so scripts and agents can
/// pipe it. `--type` keeps only the named event type(s); it may be repeated.
/// `--no-follow` prints what is already on disk and exits (the default follows
/// like `tail -f`, polling for appended lines until interrupted).
enum EventsCommand {

    /// Parsed `events tail` arguments.
    struct Options {
        /// Event-type filter; empty means "every type".
        let types: Set<String>
        /// Follow the file (`tail -f`) vs. print-and-exit.
        let follow: Bool
    }

    /// Run `pulsartrace events …`. Returns the process exit code.
    ///
    /// - Parameters:
    ///   - args: arguments *after* the `events` token.
    ///   - eventsDirectory: events directory; defaults to the standard
    ///     location. Tests inject a temp directory.
    static func run(
        _ args: [String],
        eventsDirectory: URL = AppPaths.standard.eventsDirectory
    ) async -> Int32 {
        guard let sub = args.first else {
            err("events: missing subcommand")
            printUsage()
            return 2
        }
        switch sub {
        case "tail":
            return await tail(Array(args.dropFirst()), directory: eventsDirectory)
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            err("events: unknown subcommand '\(sub)'")
            printUsage()
            return 2
        }
    }

    // MARK: - tail

    private static func tail(_ args: [String], directory: URL) async -> Int32 {
        let options: Options
        do {
            options = try parse(args)
        } catch {
            err("\(error)")
            err("usage: pulsartrace events tail [--type TYPE]… [--no-follow]")
            return 2
        }

        let tail = EventLogTail(directory: directory)

        // Print whatever is already on disk for today, then (unless
        // --no-follow) poll for appended lines.
        var fileURL = tail.currentFileURL()
        var offset = printExisting(fileURL, types: options.types)

        guard options.follow else { return 0 }

        let interrupt = InterruptFlag()
        var remainder = ""
        while !interrupt.isSet {
            // A day rollover renames the file; re-resolve and restart at 0.
            let nowURL = tail.currentFileURL()
            if nowURL != fileURL {
                fileURL = nowURL
                offset = 0
                remainder = ""
            }
            let (newText, newOffset) = readAppended(fileURL, from: offset)
            offset = newOffset
            if !newText.isEmpty {
                let combined = remainder + newText
                let split = EventLogTail.splitLines(combined)
                remainder = split.remainder
                for line in split.lines where
                    EventLogTail.lineMatches(line, types: options.types) {
                    out(line)
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return 0
    }

    /// Read the whole current file and print matching lines. Returns the byte
    /// offset to continue a follow from (the file's current size).
    private static func printExisting(_ url: URL, types: Set<String>) -> UInt64 {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return 0 }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where EventLogTail.lineMatches(String(line), types: types) {
            out(String(line))
        }
        return UInt64(data.count)
    }

    /// Read bytes appended past `offset`. Returns the new text and the updated
    /// offset. A file that shrank (rotation/truncation) restarts from 0.
    private static func readAppended(
        _ url: URL, from offset: UInt64
    ) -> (text: String, offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ("", offset)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A shrunk file (rotation/truncation) restarts from the beginning.
        let from: UInt64 = size < offset ? 0 : offset
        guard size > from else { return ("", size) }
        try? handle.seek(toOffset: from)
        let data = (try? handle.readToEnd()) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "", size)
    }

    // MARK: - Argument parsing

    enum ArgError: Error, CustomStringConvertible {
        case missingTypeValue
        case unknownType(String)
        case unexpectedArgument(String)

        var description: String {
            switch self {
            case .missingTypeValue:
                return "events tail: --type needs an event-type value"
            case .unknownType(let t):
                return "events tail: unknown event type '\(t)' — known types: "
                    + EventRegistry.all.map(\.type).sorted().joined(separator: ", ")
            case .unexpectedArgument(let a):
                return "events tail: unexpected argument '\(a)'"
            }
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        var types: Set<String> = []
        var follow = true

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--type":
                guard i + 1 < args.count else { throw ArgError.missingTypeValue }
                try types.insert(validatedType(args[i + 1]))
                i += 2
            case let a where a.hasPrefix("--type="):
                try types.insert(validatedType(String(a.dropFirst("--type=".count))))
                i += 1
            case "--no-follow":
                follow = false
                i += 1
            default:
                throw ArgError.unexpectedArgument(arg)
            }
        }
        return Options(types: types, follow: follow)
    }

    /// Reject a `--type` value that is not a registered event type — almost
    /// always a typo, and silently matching nothing is the worse failure.
    private static func validatedType(_ raw: String) throws -> String {
        guard EventRegistry.entry(for: raw) != nil else {
            throw ArgError.unknownType(raw)
        }
        return raw
    }

    // MARK: - usage

    static func printUsage() {
        err("""
            usage: pulsartrace events tail [--type TYPE]… [--no-follow]

            Streams today's events log (one JSONL event per line).

              --type TYPE    Keep only this event type; may be repeated.
              --no-follow    Print what is on disk and exit (default follows).
            """)
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

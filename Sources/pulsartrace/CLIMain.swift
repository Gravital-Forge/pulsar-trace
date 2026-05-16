import Foundation
import PulsarTraceEngine

/// `pulsartrace` — the user-facing CLI.
///
/// Epic 1 ships a subcommand-dispatch skeleton only. The real subcommands
/// (`refine`, `record`, `speakers`, `events`, `doctor`) land in later epics;
/// each is currently a stub that explains which epic delivers it. Wiring the
/// dispatch and the `AppLifecycle` event pair now keeps later epics additive.
@main
struct CLIMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let lifecycle = await AppLifecycle.start()

        let exitCode = await dispatch(args, events: lifecycle.events)

        await lifecycle.stop()
        exit(exitCode)
    }

    /// Route to a subcommand. Returns the process exit code.
    static func dispatch(_ args: [String], events: EventWriter) async -> Int32 {
        guard let subcommand = args.first else {
            printUsage()
            return 0
        }
        switch subcommand {
        case "help", "--help", "-h":
            printUsage()
            return 0
        case "version", "--version":
            out("pulsartrace \(HostInfo.appVersion)")
            return 0
        case "refine":
            return await RefineCommand.run(Array(args.dropFirst()), events: events)
        case "record":
            return await RecordCommand.run(Array(args.dropFirst()), events: events)
        case "speakers":
            return await SpeakersCommand.run(Array(args.dropFirst()), events: events)
        case "install-cli":
            return InstallCommand.run(Array(args.dropFirst()))
        case "events":
            return await EventsCommand.run(Array(args.dropFirst()))
        case "doctor":
            return await DoctorCommand.run(Array(args.dropFirst()), events: events)
        default:
            err("unknown subcommand: \(subcommand)")
            printUsage()
            return 2
        }
    }

    static func printUsage() {
        out("""
            pulsartrace \(HostInfo.appVersion) — local-only meeting transcription

            usage: pulsartrace <subcommand> [options]

            subcommands:
              record             Record a meeting headlessly
                                 [--output PATH] [--duration MIN] [--mic INDEX]
                                 [--no-system-audio] [--model base|large-v3]
                                 [--list-mics]
              refine <audio>     Transcribe + diarize a recording
                                 [--model base|large-v3]
              speakers           Manage the speaker library
                                 list | rename | merge | delete
              events tail        Tail the events log [--type TYPE] [--no-follow]
              doctor             Run environment self-checks [--capture-test]
              install-cli        Symlink pulsartrace into /usr/local/bin
                                 [--uninstall]
              version            Print version
              help               Show this message
            """)
    }

    static func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}

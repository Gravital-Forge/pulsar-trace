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

        let exitCode = await dispatch(args)

        await lifecycle.stop()
        exit(exitCode)
    }

    /// Route to a subcommand. Returns the process exit code.
    static func dispatch(_ args: [String]) async -> Int32 {
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
            err("`pulsartrace refine` is delivered in Epic 4 (Refinement Pipeline).")
            return 1
        case "record":
            err("`pulsartrace record` is delivered in Epic 9 (CLI Surface).")
            return 1
        case "speakers":
            err("`pulsartrace speakers` is delivered in Epic 5 (Speaker Library).")
            return 1
        case "events":
            err("`pulsartrace events tail` is delivered in Epic 9 (CLI Surface).")
            return 1
        case "doctor":
            err("`pulsartrace doctor` is delivered in Epic 9 (CLI Surface).")
            return 1
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
              refine <audio>     Transcribe + diarize a recording   (Epic 4)
              record             Record a meeting headlessly        (Epic 9)
              speakers           Manage the speaker library         (Epic 5)
              events tail        Tail the events log                (Epic 9)
              doctor             Run environment self-checks        (Epic 9)
              version            Print version
              help               Show this message
            """)
    }

    static func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}

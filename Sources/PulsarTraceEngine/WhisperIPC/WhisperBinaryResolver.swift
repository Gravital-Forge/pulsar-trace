import Foundation

/// Locates the `pulsartrace-whisper` subprocess binary the live engine
/// (and, in Phase 5, the refinement queue) spawns to run whisper out of
/// process.
///
/// In production the engine binary and the whisper binary are siblings —
/// the SPM build emits both under `.build/<config>/`, and a deployed bundle
/// puts them in the same directory. The default resolution walks from
/// `CommandLine.arguments[0]` (the engine's own path) and looks for a
/// sibling `pulsartrace-whisper`.
///
/// `PULSARTRACE_WHISPER_BINARY` overrides the resolution outright. In
/// production both real callers — `pulsartrace-mac` (via
/// `RecordOrchestrator.Configuration.engineEnvironment`) and `pulsartrace
/// record` (via the same path in `RecordCommand`) — **always** set this
/// env var explicitly, because the `argv[0]` sibling lookup is unreliable
/// when the calling process lives outside `.build/<config>/` (mac-app
/// process, Xcode DerivedData, etc.). The refinement path in
/// `RefinementJobQueue.makeStandard` takes the URL as a required
/// parameter for the same reason and does not call this resolver at all.
///
/// As a result, the `/usr/local/bin/pulsartrace-whisper` fallback below
/// is effectively a dev-only safety net for ad-hoc invocations that
/// forget the env var. The code path stays in place because
/// `RemoteWindowTranscriber` surfaces a clean
/// `WhisperTranscribeError.modelLoadFailed("pulsartrace-whisper not
/// found: …")` from its host's `binaryNotFound` mapping — better than
/// guessing somewhere the binary almost certainly isn't.
public enum WhisperBinaryResolver {

    /// Environment variable that, when non-empty, overrides the sibling
    /// lookup. Useful in dev and in tests.
    public static let envOverrideKey = "PULSARTRACE_WHISPER_BINARY"

    /// Resolve the `pulsartrace-whisper` binary URL.
    ///
    /// Order of preference:
    /// 1. `PULSARTRACE_WHISPER_BINARY` if set and non-empty.
    /// 2. A sibling of `CommandLine.arguments[0]` (the production layout).
    /// 3. `/usr/local/bin/pulsartrace-whisper` (last-resort fallback).
    public static func defaultBinaryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        argv0: String? = CommandLine.arguments.first,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[envOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let argv0, !argv0.isEmpty {
            let argv0URL = URL(fileURLWithPath: argv0)
            let sibling = argv0URL.deletingLastPathComponent()
                .appendingPathComponent("pulsartrace-whisper")
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        // Fallback — `RemoteWindowTranscriber` will fail cleanly with
        // `.binaryNotFound` → `.modelLoadFailed` surfacing this path.
        return URL(fileURLWithPath: "/usr/local/bin/pulsartrace-whisper")
    }
}

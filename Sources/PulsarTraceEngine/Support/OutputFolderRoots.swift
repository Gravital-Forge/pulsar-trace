import Foundation

/// Resolve the output-folder roots a non-menubar caller (the CLI) should scan
/// when rewriting transcripts (PT-R123, PT-P6-D7).
// PT-R123
public enum OutputFolderRoots {

    /// `~/Documents/PulsarTrace` — the product default output folder; under a
    /// `PULSARTRACE_HOME` override, `<home>/Documents/PulsarTrace` (PT-P7-R1).
    public static var defaultRoot: URL { defaultRoot(overrides: .current) }

    // PT-P7-R1
    public static func defaultRoot(overrides: EnvironmentOverrides) -> URL {
        if let home = overrides.home {
            return home.appendingPathComponent(
                "Documents/PulsarTrace", isDirectory: true)
        }
        return FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulsarTrace", isDirectory: true)
    }

    /// Explicit roots when given, otherwise the single default root.
    public static func resolved(explicit: [URL]) -> [URL] {
        explicit.isEmpty ? [defaultRoot] : explicit
    }
}

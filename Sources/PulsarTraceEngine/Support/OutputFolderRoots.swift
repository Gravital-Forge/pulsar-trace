import Foundation

/// Resolve the output-folder roots a non-menubar caller (the CLI) should scan
/// when rewriting transcripts (PT-P6-R9, PT-P6-D7).
// PT-P6-R9
public enum OutputFolderRoots {

    /// `~/Documents/PulsarTrace` — the product default output folder.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulsarTrace", isDirectory: true)
    }

    /// Explicit roots when given, otherwise the single default root.
    public static func resolved(explicit: [URL]) -> [URL] {
        explicit.isEmpty ? [defaultRoot] : explicit
    }
}

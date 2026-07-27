import Foundation

/// Extract repeated `--output-folder <path>` flags from a CLI argument list
/// (PT-R123). Returns the roots and the remaining positional arguments.
public enum OutputFolderArgs {
    public static func parse(_ args: [String]) -> (roots: [URL], positional: [String]) {
        var roots: [URL] = []
        var positional: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--output-folder", i + 1 < args.count {
                roots.append(URL(fileURLWithPath: args[i + 1]))
                i += 2
            } else {
                positional.append(args[i])
                i += 1
            }
        }
        return (roots, positional)
    }
}

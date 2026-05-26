import Foundation
import PulsarTraceEngine

/// Scans the output folder(s) for past recordings and surfaces them to the
/// menubar recordings list (R31).
///
/// A recording is any subdirectory containing a `metadata.json`. The scanner
/// reads the current output folder plus every previously-used folder (so
/// recordings made before the user changed the output folder still appear),
/// decodes each `metadata.json` into a `RecordingEntry`, and sorts newest
/// first. Malformed folders are skipped per-entry — one bad `metadata.json`
/// never fails the whole scan (R31 edge case).
@MainActor
@Observable
public final class RecordingsScanner {

    /// The recordings found by the most recent `refresh()`, newest first.
    public private(set) var recordings: [RecordingEntry] = []

    /// True while a `refresh()` is in flight.
    public private(set) var isScanning = false

    private let settings: MenuBarSettings

    /// - Parameters:
    ///   - settings: provides the output folder(s) to scan.
    public init(
        settings: MenuBarSettings
    ) {
        self.settings = settings
    }

    /// Rescan every output folder and rebuild `recordings`.
    public func refresh() async {
        isScanning = true
        defer { isScanning = false }

        var roots = [settings.outputFolderURL].compactMap { $0 }
        roots += settings.previousFolderURLs
        // De-duplicate roots so a folder listed both currently and previously
        // is not scanned twice.
        var seenRoots = Set<String>()
        let uniqueRoots = roots.filter { seenRoots.insert($0.path).inserted }

        var entries: [RecordingEntry] = []
        var seenIDs = Set<String>()
        for root in uniqueRoots {
            for entry in Self.scanRoot(root) where seenIDs.insert(entry.id).inserted {
                entries.append(entry)
            }
        }
        entries.sort { $0.recordingStart > $1.recordingStart }
        recordings = entries
    }

    // MARK: - Scanning

    /// Decode every recording subdirectory of one root. A folder with a valid
    /// `metadata.json` decodes as a refined entry; a folder without one but
    /// with a `live.md` / `audio-system.wav` decodes as an *unrefined* entry
    /// (`isRefined == false`, FIX 3). A folder that is neither — empty or
    /// garbage — is silently skipped.
    nonisolated static func scanRoot(_ root: URL) -> [RecordingEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return children.compactMap { child -> RecordingEntry? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return RecordingEntry.decode(folderURL: child)
        }
    }

}

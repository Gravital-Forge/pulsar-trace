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

    /// True while a `refresh()` or `reRefine(_:)` is in flight.
    public private(set) var isScanning = false

    /// The last error a scan or re-refine surfaced, for the UI.
    public private(set) var lastError: String?

    private let settings: MenuBarSettings
    private let reRefiner: @Sendable (URL) async throws -> Void

    /// - Parameters:
    ///   - settings: provides the output folder(s) to scan.
    ///   - paths: app paths — resolves the speaker-library location.
    ///   - events: the process-wide events writer the in-process re-refine
    ///     emits through; `nil` only in tests that inject their own `reRefiner`.
    ///   - reRefiner: drives a re-refine of one recording folder. The default
    ///     runs `OfflineRefiner` **in-process** (D23 — the menubar never shells
    ///     out to the `pulsartrace` CLI); tests inject a stub.
    public init(
        settings: MenuBarSettings,
        paths: AppPaths = .standard,
        events: EventWriter? = nil,
        reRefiner: (@Sendable (URL) async throws -> Void)? = nil
    ) {
        self.settings = settings
        self.reRefiner = reRefiner
            ?? RecordingsScanner.makeDefaultReRefiner(
                settings: settings, paths: paths, events: events)
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

    /// Re-run the offline refine pass over one recording, then rescan (R31 —
    /// re-refine from the recordings list).
    public func reRefine(_ entry: RecordingEntry) async {
        isScanning = true
        defer { isScanning = false }
        do {
            try await reRefiner(entry.folderURL)
            lastError = nil
        } catch {
            lastError = "Re-refine failed: \(error)"
        }
        await refresh()
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

    // MARK: - Default re-refiner

    /// Production re-refiner: runs `OfflineRefiner` **in-process** (D23 — the
    /// menubar must not shell out to the `pulsartrace` CLI). A refine failure
    /// is propagated to `reRefine`'s `lastError`, never swallowed.
    ///
    /// Requires an `EventWriter`; when `events` is `nil` (a test path that did
    /// not inject a `reRefiner`) the closure throws rather than silently
    /// no-op.
    private static func makeDefaultReRefiner(
        settings: MenuBarSettings,
        paths: AppPaths,
        events: EventWriter?
    ) -> @Sendable (URL) async throws -> Void {
        let modelName = settings.refineModelName
        return { folderURL in
            guard let events else { throw ReRefineError.noEventWriter }
            let model = ModelCatalog.model(named: modelName) ?? ModelCatalog.base
            let refiner = OfflineRefiner(events: events, paths: paths)
            _ = try await refiner.refine(inputPath: folderURL, model: model)
        }
    }

    /// A re-refine failure.
    public enum ReRefineError: Error, CustomStringConvertible {
        case noEventWriter

        public var description: String {
            switch self {
            case .noEventWriter:
                return "re-refine unavailable: no events writer configured"
            }
        }
    }
}

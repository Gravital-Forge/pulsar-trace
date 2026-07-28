// PT-R129
import XCTest
import PulsarTraceEngine

/// Shared artifact probes for the flow suites — the generic polling +
/// on-disk-inspection helpers every end-to-end UI test needs to wait on the
/// real engine's outputs (recording folders, `live.md`/`final.md`, the events
/// log). They live here once rather than being copied per suite: the
/// record-, settings-, and speaker-flow tests all wait on the same artifacts.
extension XCTestCase {

    /// Poll `probe` until it returns a non-nil value or `timeout` elapses,
    /// failing (and throwing) on timeout so the test stops at the first
    /// unmet precondition rather than cascading. `observed`, when supplied, is
    /// evaluated only on timeout and appended to the failure message — a
    /// snapshot of on-disk/UI state that tells an engine crash apart from slow
    /// startup. Existing callers omit it and compile unchanged.
    @discardableResult
    func poll<T>(
        timeout: TimeInterval, message: String,
        observed: (() -> String)? = nil, _ probe: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try probe() { return value }
            usleep(200_000)
        }
        var failure = "timed out after \(Int(timeout))s waiting for \(message)"
        if let observed { failure += " — observed \(observed())" }
        XCTFail(failure)
        throw PollTimeout(message: message)
    }

    /// The newest sub-directory of `root` whose basename is not in `excluding`,
    /// or nil while none has appeared yet.
    func newestFolder(in root: URL, excluding: [String]) throws -> URL? {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        let candidates = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !excluding.contains($0.lastPathComponent)
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(
                forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(
                forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da < db
        }
    }

    /// The size in bytes of the file at `url`.
    func size(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    /// The `type` of every event in the seeded home's events log, in file order
    /// (files sorted by name, lines in order) — reads
    /// `<home>/Library/Application Support/PulsarTrace/events/*.jsonl`.
    func eventTypes(home: URL) throws -> [String] {
        let dir = AppPaths(home: home).eventsDirectory
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var types: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let type = (object as? [String: Any])?["type"] as? String
                else { continue }
                types.append(type)
            }
        }
        return types
    }
}

/// Thrown by `poll` on timeout so a missed precondition halts the test at the
/// point of failure rather than cascading into misleading later assertions.
struct PollTimeout: Error { let message: String }

// MARK: - Failure-time evidence preservation (PT-R129)

extension XCTestCase {

    /// Copy the seed home's diagnosable state out to a repo-local directory
    /// BEFORE the seed is purged in `tearDown`, so an intermittent UI-flow
    /// failure leaves behind the artifacts needed to root-cause it (PT-R129).
    ///
    /// The seed home is a throwaway `$TMPDIR/pt-ui-seed-<uuid>` that `tearDown`
    /// deletes — which is why a flake that only reproduces on the CI/desktop
    /// box otherwise vanishes without a trace. This captures, into
    /// `.build/ui-test-diagnostics/<stamp>-<label>/`:
    ///
    /// - `logs/` — the operational log (`Library/Logs/PulsarTrace/`): the
    ///   engine's `parakeet:`/`diarizer:`/`live.md created` notices and the
    ///   app/menubar lines, so a wedge before `live.md` is pinpointed by the
    ///   last line the engine wrote.
    /// - `events/` — the events JSONL (`…/PulsarTrace/events/`): which
    ///   lifecycle events actually fired (`live_md_started`, `refinement_*`).
    /// - `recording/<name>/` — the newest non-seeded recording folder under
    ///   the output root: exactly what the engine did or did not produce.
    /// - `manifest.txt` — a recursive listing (path + size) of the output root
    ///   and the two Library subtrees, so an empty recording folder (folder
    ///   created, `live.md` never written) is itself visible.
    ///
    /// Behavior-neutral on green runs (callers gate it on a non-zero failure
    /// count); best-effort throughout — never throws, so it cannot turn a
    /// diagnostic copy into a second failure. Returns the destination, or
    /// `nil` if it could not even be created.
    @discardableResult
    func preserveSeedDiagnostics(_ seed: SeededHome, label: String) -> URL? {
        let fm = FileManager.default
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"   // colon-free: filesystem-safe
            return f.string(from: Date())
        }()
        // Repo root from this file: UITests/PulsarTraceUITests/ArtifactProbes.swift.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PulsarTraceUITests
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // repo root
        let dest = repoRoot
            .appendingPathComponent(".build/ui-test-diagnostics", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(label)", isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let paths = AppPaths(home: seed.home)
        copyTree(paths.logDirectory, to: dest.appendingPathComponent("logs"))
        copyTree(paths.eventsDirectory, to: dest.appendingPathComponent("events"))
        if let folder = try? newestFolder(
            in: seed.outputRoot, excluding: SeededHome.recordingFolders) {
            copyTree(folder, to: dest.appendingPathComponent(
                "recording/\(folder.lastPathComponent)"))
        }

        // A recursive size manifest so an *absent* file (e.g. live.md never
        // written into a folder that does exist) is itself evidence.
        var manifest = "seed home: \(seed.home.path)\n\n"
        for root in [seed.outputRoot,
                     paths.applicationSupport,
                     paths.logDirectory] {
            manifest += "## \(root.path)\n" + listTree(root) + "\n"
        }
        try? manifest.write(
            to: dest.appendingPathComponent("manifest.txt"),
            atomically: true, encoding: .utf8)
        return dest
    }

    /// Copy a directory (or file) tree, best-effort — a missing source or a
    /// mid-flight file is skipped, never fatal.
    private func copyTree(_ src: URL, to dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? fm.copyItem(at: src, to: dst)
    }

    /// A recursive `path\t<bytes>` listing of `root` (relative paths), or a
    /// one-line note when it does not exist.
    private func listTree(_ root: URL) -> String {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
        else { return "  (absent)\n" }
        var lines: [String] = []
        for case let url as URL in en {
            let vals = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isDirectoryKey])
            let isDir = vals?.isDirectory ?? false
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            lines.append(isDir ? "  \(rel)/" : "  \(rel)\t\(vals?.fileSize ?? 0)")
        }
        return lines.isEmpty ? "  (empty)\n" : lines.sorted().joined(separator: "\n") + "\n"
    }
}

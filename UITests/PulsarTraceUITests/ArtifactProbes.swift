// PT-P7-R4
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
    /// unmet precondition rather than cascading.
    @discardableResult
    func poll<T>(
        timeout: TimeInterval, message: String, _ probe: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try probe() { return value }
            usleep(200_000)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(message)")
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
